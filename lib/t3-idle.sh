# Idle checks (spec: Automatic update). Any doubt means busy.

T3_PROVIDERS=" claude codex cursor-agent agent opencode "
T3_SHELLS=" bash sh zsh dash fish "

t3_idle_db() {
  local out
  if out=$(python3 -B "$T3_LIB_DIR/t3_idle.py" "$T3CODE_HOME/userdata/state.sqlite" \
      "$T3_QUIET_SECONDS" "$(date +%s)" "$1" 2>/dev/null); then
    return 0
  fi
  T3_BUSY=${out:-busy:db_error}
  return 1
}

t3_tty_quiet() {
  local tty a m limit=$(( $2 - T3_QUIET_SECONDS ))
  tty=$(readlink "/proc/$1/fd/0" 2>/dev/null) || return 1
  case "$tty" in /dev/pts/*) ;; *) return 1 ;; esac
  a=$(stat -c %X "$tty" 2>/dev/null) || return 1
  m=$(stat -c %Y "$tty" 2>/dev/null) || return 1
  [ "$a" -lt "$limit" ] && [ "$m" -lt "$limit" ]
}

# t3 serve starts its own resource sampler for its whole life (comm is cut
# to 15 characters, so the full name comes from argv[0]).
t3_resource_monitor() {
  local -a a
  mapfile -d '' -t a 2>/dev/null < "/proc/$1/cmdline" || return 1
  [ "${a[0]##*/}" = t3-resource-monitor ]
}

# Check 3. A provider is allowed when it and every ancestor up to the server
# is provider-named (covers a node launcher with a native child).
t3_idle_procs() {
  local super server p q name now
  local -A par=() nm=() kids=()
  T3_BUSY=""; T3_BUSY_LIST=()
  super=$(t3_owner_field pid)
  server=$(t3_json_get "$T3CODE_HOME/userdata/server-runtime.json" .pid)
  t3_scope "$super" "$(t3_owner_field sid)" "$(t3_owner_field token)"
  for p in "${T3_SCOPE[@]}"; do
    t3_stat "$p" || continue
    par[$p]=$T3S_PPID
    nm[$p]=$(t3_proc_name "$p")
    kids[$T3S_PPID]=$(( ${kids[$T3S_PPID]:-0} + 1 ))
  done
  now=$(date +%s)
  for p in "${!par[@]}"; do
    name=${nm[$p]}
    [ "$p" = "$server" ] && continue
    [ "$name" = cloudflared ] && continue
    [ "$name" = t3-resource-mon ] && [ "${par[$p]}" = "$server" ] && t3_resource_monitor "$p" && continue
    if [[ "$T3_PROVIDERS" == *" $name "* ]]; then
      q=${par[$p]}
      while [ -n "$q" ] && [ "$q" != "$server" ] && [[ "$T3_PROVIDERS" == *" ${nm[$q]:-} "* ]]; do q=${par[$q]:-}; done
      [ "$q" = "$server" ] && continue
    fi
    if [[ "$T3_SHELLS" == *" $name "* ]] && [ "${kids[$p]:-0}" = 0 ] && t3_tty_quiet "$p" "$now"; then
      continue
    fi
    T3_BUSY_LIST+=("busy:process_${name//[^A-Za-z0-9_.-]/_} (pid $p)")
    [ "${T3_IDLE_COLLECT:-0}" = 1 ] || { T3_BUSY=${T3_BUSY_LIST[0]}; return 1; }
  done
  [ ${#T3_BUSY_LIST[@]} -eq 0 ] || { T3_BUSY=${T3_BUSY_LIST[0]}; return 1; }
}

t3_cpu_total() {
  local p
  T3_CPU=0
  for p in "${T3_SCOPE[@]}"; do t3_stat "$p" && T3_CPU=$((T3_CPU + T3S_CPU)); done
}

# Check 4: re-list the scope every second; any non-allowed process seen means
# busy, and total CPU (children already reaped included) must stay under the
# threshold across the window.
t3_idle_window() {
  local i start
  t3_idle_procs || return 1
  t3_cpu_total; start=$T3_CPU
  for ((i = 0; i < T3_IDLE_WINDOW; i++)); do
    sleep 1
    t3_idle_procs || return 1
  done
  t3_cpu_total
  [ $((T3_CPU - start)) -lt "$T3_IDLE_CPU_TICKS" ] \
    || { T3_BUSY="busy:cpu $((T3_CPU - start)) ticks in ${T3_IDLE_WINDOW}s"; return 1; }
}

t3_idle_full() {
  T3_BUSY=""
  t3_idle_db 12 && t3_idle_procs && t3_idle_window && t3_idle_db 12 && t3_idle_procs
}

t3_workloads() {
  local -a found=()
  T3_IDLE_COLLECT=1 t3_idle_procs || true
  found=("${T3_BUSY_LIST[@]}")
  t3_idle_db 1 || found+=("$T3_BUSY")
  T3_BUSY_LIST=("${found[@]}")
}
