# lib/auto-update.sh — scheduler selection and persistent fallback worker.

: "${AICODING_STATE_DIR:=$HOME/.local/state/aicoding}"
: "${AICODING_AUTO_UPDATE_INTERVAL:=21600}"
: "${AICODING_AUTO_UPDATE_MIN_BACKOFF:=300}"
: "${AICODING_AUTO_UPDATE_MAX_BACKOFF:=3600}"

_aicoding_auto_positive_integer() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }

_aicoding_auto_state_dir() { printf '%s/auto-update\n' "$AICODING_STATE_DIR"; }

# Detached scheduler processes cannot inherit the installer's writer locks:
# their new shell has none of the bookkeeping that makes those FDs reentrant.
# Inspect descriptor targets, never their contents, including locks inherited
# from an older installer that did not export a descriptor list.
_aicoding_auto_shared_lock_fds() {
  local pid=$1 path target fd
  for path in /proc/"$pid"/fd/[0-9]*; do
    fd=${path##*/}
    [ "$fd" -gt 2 ] 2>/dev/null || continue
    target=$(readlink "$path" 2>/dev/null) || continue
    case "$target" in
      */.aicoding-update.lock|*/.aicoding-update.lock\ \(deleted\)) printf '%s\n' "$fd" ;;
    esac
  done
}

_aicoding_auto_close_shared_lock_fds() {
  local fd
  while IFS= read -r fd; do
    exec {fd}>&- || return 1
  done < <(_aicoding_auto_shared_lock_fds "$$")
}

_aicoding_auto_recover_shared_lock_worker() (
  local state pid fds ensure_fd
  state=$(_aicoding_auto_state_dir) || return 1
  mkdir -p "$state" || return 1
  exec {ensure_fd}>"$state/ensure.lock" || return 1
  flock -n "$ensure_fd" || return 0
  pid=$(cat "$state/worker.pid" 2>/dev/null || true)
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 0
  fds=$(_aicoding_auto_shared_lock_fds "$pid")
  [ -n "$fds" ] || return 0
  # The stop helper verifies worker identity before signaling any process.
  _aicoding_auto_stop_worker
)

_aicoding_auto_atomic_number() {
  local path=$1 value=$2 tmp
  tmp="${path}.tmp.$$"
  printf '%s\n' "$value" > "$tmp" || return 1
  mv -f -- "$tmp" "$path"
}

aicoding_auto_update_once() {
  local state sync output rc=0
  state=$(_aicoding_auto_state_dir) || return 1
  mkdir -p "$state" || return 1
  sync=$(command -v aicoding-sync 2>/dev/null || true)
  if [ -z "$sync" ] && [ -x "${AICODING_RUNTIME_ROOT:-}/bin/aicoding-sync" ]; then
    sync="${AICODING_RUNTIME_ROOT}/bin/aicoding-sync"
  fi
  [ -x "$sync" ] || { echo 'aicoding-auto-update: aicoding-sync is unavailable' >&2; return 1; }
  output=$(mktemp "$state/.once.XXXXXX") || return 1
  # Capture synchronously so a late process-substitution writer cannot race
  # the busy check or append into a removed attempt file.
  # A scheduler tick and an explicit --once are update requests, rather than
  # shell-start noise. Bypass sync's legacy boot throttle for this invocation
  # so a timer firing at the same cadence as the TTL still checks components.
  (cd "$state" && AICODING_UPDATE_TTL=0 "$sync" --boot </dev/null) >"$output" 2>&1 || rc=$?
  cat "$output"
  AICODING_AUTO_UPDATE_PERFORMED=1
  AICODING_AUTO_UPDATE_DEFERRED=0
  grep -qF 'aicoding-sync: update already running' "$output" 2>/dev/null \
    && AICODING_AUTO_UPDATE_PERFORMED=0
  grep -qF 'aicoding-sync: completed with deferrals' "$output" 2>/dev/null \
    && AICODING_AUTO_UPDATE_DEFERRED=1
  rm -f -- "$output"
  return "$rc"
}

_aicoding_auto_linger_enabled() {
  command -v loginctl >/dev/null 2>&1 || return 1
  [ "$(timeout 10 loginctl show-user "$(id -un)" --property=Linger --value 2>/dev/null)" = yes ]
}

_aicoding_auto_enable_linger() {
  _aicoding_auto_linger_enabled && return 0
  command -v sudo >/dev/null 2>&1 || return 1
  timeout 15 sudo -n loginctl enable-linger "$(id -un)" </dev/null >/dev/null 2>&1 || return 1
  _aicoding_auto_linger_enabled
}

_aicoding_auto_user_manager_available() {
  command -v systemctl >/dev/null 2>&1 || return 1
  local state version
  state=$(timeout 10 systemctl --user is-system-running 2>/dev/null) || return 1
  case "$state" in running|degraded|starting) ;; *) return 1 ;; esac
  version=$(timeout 10 systemctl --user show --property=Version --value 2>/dev/null) || return 1
  [[ "$version" =~ ^[0-9]+([.][0-9]+)*$ ]]
}

_aicoding_auto_stage_systemd() {
  local source="${AICODING_RUNTIME_ROOT:-}/configs/systemd"
  local target="$HOME/.config/systemd/user"
  [ -f "$source/aicoding-auto-update.service" ] || return 1
  [ -f "$source/aicoding-auto-update.timer" ] || return 1
  mkdir -p "$target" "$(_aicoding_auto_state_dir)" || return 1
  install -m 0644 "$source/aicoding-auto-update.service" "$target/aicoding-auto-update.service" || return 1
  install -m 0644 "$source/aicoding-auto-update.timer" "$target/aicoding-auto-update.timer" || return 1
  timeout 10 systemctl --user daemon-reload </dev/null >/dev/null 2>&1
}

_aicoding_auto_enable_systemd() {
  timeout 15 systemctl --user enable --now aicoding-auto-update.timer </dev/null >/dev/null 2>&1 || return 1
  [ "$(timeout 10 systemctl --user is-enabled aicoding-auto-update.timer 2>/dev/null)" = enabled ] || return 1
  [ "$(timeout 10 systemctl --user is-active aicoding-auto-update.timer 2>/dev/null)" = active ] || return 1
}

_aicoding_auto_disable_systemd() {
  local enabled active
  timeout 15 systemctl --user disable --now aicoding-auto-update.timer </dev/null >/dev/null 2>&1 || true
  enabled=$(timeout 10 systemctl --user is-enabled aicoding-auto-update.timer 2>/dev/null || true)
  active=$(timeout 10 systemctl --user is-active aicoding-auto-update.timer 2>/dev/null || true)
  [ "$enabled" != enabled ] && [ "$active" != active ]
}

_aicoding_auto_rotate_log() {
  local log=$1 size
  [ -f "$log" ] || return 0
  size=$(wc -c < "$log" 2>/dev/null) || return 0
  [ "$size" -le 1048576 ] || mv -f -- "$log" "$log.previous" 2>/dev/null || true
}

_aicoding_auto_start_worker() {
  local state log self
  state=$(_aicoding_auto_state_dir) || return 1
  mkdir -p "$state" || return 1
  log="$state/worker.log"
  _aicoding_auto_rotate_log "$log"
  self=${AICODING_AUTO_UPDATE_SELF:-${AICODING_RUNTIME_ROOT}/bin/aicoding-auto-update}
  [ -x "$self" ] || return 1
  # The worker opens its bounded log for each pass. Do not retain this append
  # descriptor forever: rotating its pathname would otherwise leave the live
  # process writing into the renamed, unbounded inode until the next login.
  nohup setsid "$self" --worker </dev/null >/dev/null 2>&1 &
  return 0
}

_aicoding_auto_stop_worker() {
  local state pid argument arguments= i
  state=$(_aicoding_auto_state_dir) || return 1
  pid=$(cat "$state/worker.pid" 2>/dev/null || true)
  if [[ ! "$pid" =~ ^[1-9][0-9]*$ ]]; then
    rm -f -- "$state/worker.pid"
    return 0
  fi
  if [ ! -d "/proc/$pid" ]; then
    [ "$(cat "$state/worker.pid" 2>/dev/null || true)" != "$pid" ] || rm -f -- "$state/worker.pid"
    return 0
  fi
  [ -r "/proc/$pid/cmdline" ] || return 1
  while IFS= read -r -d '' argument; do arguments+="$argument "; done < "/proc/$pid/cmdline"
  case "$arguments" in
    *aicoding-auto-update*' --worker '*) ;;
    *) [ "$(cat "$state/worker.pid" 2>/dev/null || true)" != "$pid" ] || rm -f -- "$state/worker.pid"; return 0 ;;
  esac
  kill "$pid" 2>/dev/null || return 0
  for ((i=0; i<20; i++)); do
    [ -e "$state/worker.pid" ] || return 0
    if ! kill -0 "$pid" 2>/dev/null; then
      [ "$(cat "$state/worker.pid" 2>/dev/null || true)" != "$pid" ] || rm -f -- "$state/worker.pid"
      return 0
    fi
    sleep 0.1
  done
  return 1
}

aicoding_auto_update_enroll() {
  local state ensure_fd
  state=$(_aicoding_auto_state_dir) || return 1
  mkdir -p "$state" || return 1
  exec {ensure_fd}>"$state/ensure.lock" || return 1
  flock -w 15 "$ensure_fd" || { exec {ensure_fd}>&-; return 0; }
  if _aicoding_auto_user_manager_available; then
    if _aicoding_auto_enable_linger && _aicoding_auto_stage_systemd; then
      if _aicoding_auto_stop_worker && _aicoding_auto_enable_systemd; then
        exec {ensure_fd}>&-
        return 0
      fi
    fi
    _aicoding_auto_disable_systemd || {
      echo 'aicoding-auto-update: timer activation failed and could not be disabled; fallback deferred' >&2
      exec {ensure_fd}>&-
      return 1
    }
  elif [ -L "$HOME/.config/systemd/user/timers.target.wants/aicoding-auto-update.timer" ]; then
    echo 'aicoding-auto-update: enabled timer state cannot be verified; fallback deferred' >&2
    exec {ensure_fd}>&-
    return 1
  fi
  export AICODING_AUTO_UPDATE_ENSURE_FD=$ensure_fd
  _aicoding_auto_start_worker
  unset AICODING_AUTO_UPDATE_ENSURE_FD
  exec {ensure_fd}>&-
}

aicoding_auto_update_ensure() {
  _aicoding_auto_positive_integer "$AICODING_AUTO_UPDATE_INTERVAL" || {
    echo 'aicoding-auto-update: interval must be a positive integer' >&2
    return 2
  }
  _aicoding_auto_recover_shared_lock_worker || return 1
  local state log self
  state=$(_aicoding_auto_state_dir) || return 1
  mkdir -p "$state" || return 1
  log="$state/enroll.log"
  _aicoding_auto_rotate_log "$log"
  self=${AICODING_AUTO_UPDATE_SELF:-${AICODING_RUNTIME_ROOT}/bin/aicoding-auto-update}
  [ -x "$self" ] || return 1
  nohup setsid "$self" --enroll </dev/null >>"$log" 2>&1 &
  return 0
}

aicoding_auto_update_worker() {
  _aicoding_auto_positive_integer "$AICODING_AUTO_UPDATE_INTERVAL" || return 2
  _aicoding_auto_positive_integer "$AICODING_AUTO_UPDATE_MIN_BACKOFF" || return 2
  _aicoding_auto_positive_integer "$AICODING_AUTO_UPDATE_MAX_BACKOFF" || return 2
  [ "$AICODING_AUTO_UPDATE_MIN_BACKOFF" -le "$AICODING_AUTO_UPDATE_MAX_BACKOFF" ] || return 2

  local state lock_fd pid_file next_file attempt_file success_file log now due delay backoff rc sleep_pid=
  state=$(_aicoding_auto_state_dir) || return 1
  mkdir -p "$state" || return 1
  # The fallback is long-lived. Move off the caller's workspace before taking
  # ownership so rebuilds and workspace removal are never pinned by its cwd.
  cd "$state" || return 1
  state=$PWD
  exec {lock_fd}>"$state/worker.lock" || return 1
  flock -n "$lock_fd" || { exec {lock_fd}>&-; return 0; }
  pid_file="$state/worker.pid"
  printf '%s\n' "$$" > "$pid_file" || { exec {lock_fd}>&-; return 1; }
  trap '[ -z "${sleep_pid:-}" ] || kill "$sleep_pid" 2>/dev/null || true; test "$(cat "$pid_file" 2>/dev/null)" != "$$" || rm -f -- "$pid_file"; exit 0' TERM INT HUP
  next_file="$state/next-due"
  attempt_file="$state/last-attempt"
  success_file="$state/last-success"
  log="$state/worker.log"
  backoff=$AICODING_AUTO_UPDATE_MIN_BACKOFF

  while :; do
    now=$(date +%s) || now=0
    due=$(cat "$next_file" 2>/dev/null || echo 0)
    [[ "$due" =~ ^[0-9]+$ ]] || due=0
    if [ "$due" -le "$now" ]; then
      _aicoding_auto_atomic_number "$attempt_file" "$now" || true
      rc=0
      _aicoding_auto_rotate_log "$log"
      aicoding_auto_update_once >>"$log" 2>&1 || rc=$?
      now=$(date +%s) || now=0
      if [ "$rc" -eq 0 ] && [ "${AICODING_AUTO_UPDATE_PERFORMED:-1}" -eq 1 ]; then
        if [ "${AICODING_AUTO_UPDATE_DEFERRED:-0}" -ne 1 ]; then
          _aicoding_auto_atomic_number "$success_file" "$now" || true
        fi
        _aicoding_auto_atomic_number "$next_file" "$((now + AICODING_AUTO_UPDATE_INTERVAL))" || true
        backoff=$AICODING_AUTO_UPDATE_MIN_BACKOFF
      else
        _aicoding_auto_atomic_number "$next_file" "$now" || true
        sleep "$backoff" & sleep_pid=$!
        wait "$sleep_pid" || true
        sleep_pid=
        backoff=$((backoff * 2))
        [ "$backoff" -le "$AICODING_AUTO_UPDATE_MAX_BACKOFF" ] || backoff=$AICODING_AUTO_UPDATE_MAX_BACKOFF
      fi
      continue
    fi
    delay=$((due - now))
    sleep "$delay" & sleep_pid=$!
    wait "$sleep_pid" || true
    sleep_pid=
  done
}
