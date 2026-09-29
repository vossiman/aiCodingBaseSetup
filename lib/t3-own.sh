# Ownership (spec: Ownership and control), readiness, start and stop.

t3_owner_field() { t3_json_get "$T3_STATE/owner.json" ".$1"; }

t3_running() {
  local fd
  exec {fd}>>"$T3_STATE/owner.lock" || return 1
  if flock -n "$fd"; then flock -u "$fd"; exec {fd}>&-; return 1; fi
  exec {fd}>&-
  return 0
}

t3_owner_verified() {
  local pid
  pid=$(t3_owner_field pid)
  [[ "$pid" =~ ^[0-9]+$ ]] && t3_stat "$pid" \
    && [ "$T3S_START" = "$(t3_owner_field start)" ] \
    && t3_proc_env_has "$pid" "T3_AICODING_OWNER=$(t3_owner_field token)"
}

t3_serve_dir() {
  local d
  d=$(cat "$T3_STATE/serve-dir" 2>/dev/null) || d=""
  printf '%s\n' "${d:-${T3_DEFAULT_SERVE_DIR:-/workspaces/$T3_KEY}}"
}

t3_launch() {
  local v=$1 token i
  token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  t3_running && { t3_say "a server already owns this workspace; not launching"; return 1; }
  rm -f "$T3_STATE/owner.json"
  T3_LAUNCH_EPOCH=$(date +%s)
  T3_AICODING_OWNER=$token setsid "$T3_LIB_DIR/t3-supervise" "$T3_STATE" "$(t3_exe "$v")" \
    "$(t3_serve_dir)" "$v" "$token" </dev/null >>"$T3CODE_HOME/supervisor.log" 2>&1 7>&- 8>&- &
  for ((i = 0; i < 100; i++)); do
    [ "$(t3_owner_field token)" = "$token" ] && return 0
    sleep 0.1
  done
  t3_say "the supervisor did not take ownership; see $T3CODE_HOME/supervisor.log"
  return 1
}

t3_connect_green() {
  local out
  out=$(timeout 30 "$(t3_launcher "$1")" connect status 2>/dev/null) || return 1
  grep -q 'Authorization: stored credential' <<< "$out" \
    && grep -q 'Environment link: provisioned' <<< "$out" \
    && grep -q 'Publish agent activity: enabled' <<< "$out"
}

t3_ready_procs() {
  local rt="$T3CODE_HOME/userdata/server-runtime.json" pid port super n=0 p
  pid=$(t3_json_get "$rt" .pid); port=$(t3_json_get "$rt" .port); super=$(t3_owner_field pid)
  [[ "$pid" =~ ^[0-9]+$ && "$port" =~ ^[0-9]+$ ]] || return 1
  t3_stat "$pid" && [ "$T3S_PPID" = "$super" ] || return 1
  timeout 3 bash -c 'exec 3<>"/dev/tcp/127.0.0.1/$1"' t3probe "$port" 2>/dev/null || return 1
  t3_scope "$super" "$(t3_owner_field sid)" "$(t3_owner_field token)"
  for p in "${T3_SCOPE[@]}"; do [ "$(t3_proc_name "$p")" = cloudflared ] && n=$((n + 1)); done
  [ "$n" -eq 1 ]
}

t3_ready_once() {
  local v=$1 rt="$T3CODE_HOME/userdata/server-runtime.json" started
  t3_running || return 1
  [ "$("$(t3_launcher "$v")" --version 2>/dev/null | t3_parse_version)" = "$v" ] || return 1
  [ -f "$rt" ] || return 1
  started=$(date -d "$(t3_json_get "$rt" .startedAt)" +%s 2>/dev/null) || return 1
  [ "$started" -ge "$T3_LAUNCH_EPOCH" ] || return 1
  t3_ready_procs || return 1
  [ "$(cat "$T3CODE_HOME/userdata/environment-id" 2>/dev/null)" = "$(cat "$T3_STATE/setup-done" 2>/dev/null)" ] || return 1
  t3_connect_green "$v"
}

t3_ready() {
  local v=$1 deadline=$((SECONDS + T3_READY_TIMEOUT))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if t3_ready_once "$v"; then
      sleep "$T3_READY_SETTLE"
      t3_running && t3_ready_procs
      return
    fi
    t3_running || return 1
    sleep 1
  done
  return 1
}

t3_stop_server() {
  local pid fd i
  t3_running || return 0
  t3_owner_verified || { t3_say "owner.json does not match the running supervisor; refusing to signal it"; return 1; }
  pid=$(t3_owner_field pid)
  kill -TERM "$pid" 2>/dev/null
  exec {fd}>>"$T3_STATE/owner.lock"
  for ((i = 0; i < (T3_STOP_GRACE + 15) * 10; i++)); do
    if flock -n "$fd"; then flock -u "$fd"; break; fi
    sleep 0.1
  done
  exec {fd}>&-
  t3_running && { t3_say "the server did not stop"; return 1; }
  t3_scope "$pid" "$(t3_owner_field sid)" "$(t3_owner_field token)"
  [ ${#T3_SCOPE[@]} -eq 0 ] || { t3_say "processes left in scope: ${T3_SCOPE[*]}"; return 1; }
}

t3_orphans() {
  local token sid p
  T3_ORPHANS_TOKEN=(); T3_ORPHANS_SESSION=()
  [ -f "$T3_STATE/owner.json" ] || return 0
  # pid 1 restarts with the container; a record from an earlier life names
  # pids and a session id that may now belong to anything.
  t3_stat 1 && [ "$(t3_owner_field init)" = "$T3S_START" ] || return 0
  token=$(t3_owner_field token); sid=$(t3_owner_field sid)
  for p in /proc/[0-9]*; do
    p=${p#/proc/}
    [ "$p" = "$$" ] || [ "$p" = "$BASHPID" ] && continue
    if [ -n "$token" ] && t3_proc_env_has "$p" "T3_AICODING_OWNER=$token"; then
      T3_ORPHANS_TOKEN+=("$p")
    elif [ -n "$sid" ] && t3_stat "$p" && [ "$T3S_SID" = "$sid" ]; then
      T3_ORPHANS_SESSION+=("$p")
    fi
  done
}

t3_kill_orphans() {
  local p i
  local -A start=()
  t3_running && t3_die "a server is running; use t3-stop"
  t3_orphans
  [ ${#T3_ORPHANS_SESSION[@]} -gt 0 ] \
    && t3_say "session-only matches, not signalled (a session id can be reused): ${T3_ORPHANS_SESSION[*]}"
  [ ${#T3_ORPHANS_TOKEN[@]} -eq 0 ] && { t3_say "no token-matched orphans"; return 0; }
  t3_say "terminating: ${T3_ORPHANS_TOKEN[*]}"
  for p in "${T3_ORPHANS_TOKEN[@]}"; do t3_stat "$p" && start[$p]=$T3S_START; done
  for p in "${!start[@]}"; do t3_stat "$p" && [ "$T3S_START" = "${start[$p]}" ] && kill -TERM "$p" 2>/dev/null; done
  for ((i = 0; i < T3_STOP_GRACE * 10; i++)); do
    local alive=0
    for p in "${!start[@]}"; do t3_stat "$p" && [ "$T3S_START" = "${start[$p]}" ] && alive=1; done
    [ "$alive" = 0 ] && return 0
    sleep 0.1
  done
  for p in "${!start[@]}"; do t3_stat "$p" && [ "$T3S_START" = "${start[$p]}" ] && kill -KILL "$p" 2>/dev/null; done
  return 0
}

# 0 ready; 1 not ready and nothing left running; 2 a server is still running
# that could not be stopped, so callers must not touch its files.
t3_start_version() {
  t3_running && return 2
  t3_install "$1" || return 1
  t3_launch "$1" && t3_ready "$1" && return 0
  t3_stop_server || return 2
  rm -f "$T3CODE_HOME/userdata/server-runtime.json"
  return 1
}

t3_start_selected() {
  local v
  v=$(t3_selected_version)
  t3_install "$v" || { t3_record start failed install_failed "$v"; t3_die "cannot install t3 $v"; }
  if t3_start_version "$v"; then
    t3_write_file "$T3_STATE/enabled" on
    t3_record start ok started "$v"
    t3_say "started t3 $v (supervisor $(t3_owner_field pid))"
    return 0
  fi
  t3_record start failed not_ready "$v"
  t3_die "t3 $v did not become ready; see $T3CODE_HOME/serve.log"
}

# Boot never prompts and never fails loudly. It waits for the control lock in
# T3_BOOT_RETRY_INTERVAL slices and gives up early when there is nothing to do.
t3_boot_entry() {
  local i
  t3_env 2>/dev/null
  for ((i = 0; i < T3_BOOT_RETRY_MAX; i++)); do
    [ -f "$T3_STATE/enabled" ] || return 1
    t3_running && return 1
    if t3_control_lock "$T3_BOOT_RETRY_INTERVAL"; then t3_recover_if_needed; return 0; fi
  done
  t3_record start failed lock_busy "boot gave up waiting for the control lock"
  return 1
}

# A command whose own process is in the server's scope (run from a T3
# terminal or by an agent in a T3 thread) would die with the server. It
# re-runs itself in a new session without the owner token and exits.
t3_detach_if_in_scope() {
  local p me=$$ inside=0
  [ -n "${T3_DETACHED:-}" ] && return 0
  t3_running || return 0
  if t3_proc_env_has "$me" "T3_AICODING_OWNER=$(t3_owner_field token)"; then inside=1; fi
  if t3_stat "$me" && [ "$T3S_SID" = "$(t3_owner_field sid)" ]; then inside=1; fi
  [ "$inside" = 1 ] || return 0
  exec 8>&-
  env -u T3_AICODING_OWNER T3_DETACHED=1 T3_DETACH_PARENT="$me" \
    setsid nohup "$0" "$@" </dev/null >>"$T3_STATE/detached.log" 2>&1 &
  t3_say "this shell runs inside the t3 server; continuing in the background (see t3-status and $T3_STATE/detached.log)"
  exit 0
}

t3_wait_detached_parent() {
  local i
  [ -n "${T3_DETACH_PARENT:-}" ] || return 0
  for ((i = 0; i < 100; i++)); do kill -0 "$T3_DETACH_PARENT" 2>/dev/null || return 0; sleep 0.05; done
}

t3_cmd_start() {
  local boot=0 dir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --boot) boot=1; shift ;;
      --dir) dir=${2:?--dir needs a path}; shift 2 ;;
      *) t3_die "usage: t3-start [--dir PATH]" ;;
    esac
  done
  if [ "$boot" = 1 ]; then
    t3_boot_entry || exit 0
    { t3_set_up && [ -n "$(t3_selected_version)" ]; } || exit 0
  else
    t3_entry
  fi
  t3_set_up || t3_die "not set up; run t3-setup (new) or t3-adopt (existing state)"
  [ -n "$(t3_selected_version)" ] || t3_die "no version.json; run t3-setup or t3-adopt"
  if [ -n "$dir" ]; then
    [ -d "$dir" ] || t3_die "no such directory: $dir"
    t3_write_file "$T3_STATE/serve-dir" "$(readlink -f "$dir")"
  fi
  if t3_running; then t3_say "already running (supervisor $(t3_owner_field pid))"; return 0; fi
  t3_orphans
  if [ ${#T3_ORPHANS_TOKEN[@]} -gt 0 ] || [ ${#T3_ORPHANS_SESSION[@]} -gt 0 ]; then
    t3_die "a previous server left processes behind: ${T3_ORPHANS_TOKEN[*]} ${T3_ORPHANS_SESSION[*]}. Inspect them, then run t3-stop --orphans."
  fi
  if declare -F t3_pending_apply >/dev/null && t3_pending_apply; then return 0; fi
  t3_start_selected
}

t3_cmd_stop() {
  local orphans=0
  [ "${1:-}" = --orphans ] && orphans=1
  t3_wait_detached_parent
  t3_entry
  if [ "$orphans" = 1 ]; then t3_kill_orphans; return; fi
  t3_detach_if_in_scope "$@"
  t3_stop_server || t3_die "stop failed; nothing was changed"
  rm -f "$T3_STATE/enabled"
  t3_record stop ok stopped ""
  t3_say "stopped; it will not start at boot until t3-start"
}
