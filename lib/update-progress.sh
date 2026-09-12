# Progress for slow pure operations. Sourced by runtime/updater libraries.
# Run external commands or read-only functions here: the operation executes in
# a subshell, so callers needing shell-state mutations must call them directly.
aicoding_progress_run() (
  local label=$1 owner=$BASHPID ticker operation= started=$SECONDS rc=0 interval
  shift
  interval=${AICODING_PROGRESS_INTERVAL:-15}
  [[ "$interval" =~ ^[0-9]+([.][0-9]+)?$ ]] && [[ ! "$interval" =~ ^0+([.]0+)?$ ]] || interval=15
  printf 'INFO: %s — starting\n' "$label" >&2
  (
    # A ticker must never retain installer/update locks. Close its copies,
    # without flock -u (which would unlock the parent's open description).
    local fd target state sleeper=
    for target in /proc/$BASHPID/fd/*; do
      fd=${target##*/}
      [[ "$fd" =~ ^[0-9]+$ ]] && [ "$fd" -gt 2 ] || continue
      eval "exec ${fd}>&-" 2>/dev/null || true
    done
    trap 'if [ -n "$sleeper" ]; then kill "$sleeper" 2>/dev/null || true; wait "$sleeper" 2>/dev/null || true; fi; exit 0' TERM INT HUP
    while kill -0 "$owner" 2>/dev/null; do
      sleep "$interval" & sleeper=$!
      wait "$sleeper" || exit 0
      sleeper=
      kill -0 "$owner" 2>/dev/null || exit 0
      if read -r _ _ state _ <"/proc/$owner/stat" 2>/dev/null; then
        [ "$state" != Z ] || exit 0
      else
        exit 0
      fi
      printf 'INFO: %s — still running (%ss elapsed)\n' "$label" "$((SECONDS - started))" >&2
    done
  ) </dev/null &
  ticker=$!
  trap 'kill "$ticker" 2>/dev/null || true; wait "$ticker" 2>/dev/null || true' EXIT
  # Monitor mode gives this one background job its own process group, including
  # descendants of shell functions. Disable notifications immediately afterward.
  # This permits cancellation of the whole operation without signaling callers.
  _aicoding_progress_cancel() {
    local code=$1
    if [ -n "$operation" ]; then
      kill -TERM -- "-$operation" 2>/dev/null || true
      sleep 0.1
      kill -KILL -- "-$operation" 2>/dev/null || true
      wait "$operation" 2>/dev/null || true
    fi
    exit "$code"
  }
  trap '_aicoding_progress_cancel 143' TERM
  trap '_aicoding_progress_cancel 130' INT
  trap '_aicoding_progress_cancel 129' HUP
  # GNU timeout otherwise creates a nested process group that escapes the
  # supervisor. Within this pure-operation subshell it must keep our group.
  timeout() { command timeout --foreground "$@"; }
  set -m
  "$@" & operation=$!
  set +m
  wait "$operation" 2>/dev/null || rc=$?
  # A timed-out shell may leave grandchildren behind even after its direct
  # process exited; no background work belongs to a completed staging step.
  if [ "$rc" -ne 0 ]; then
    kill -TERM -- "-$operation" 2>/dev/null || true
    kill -KILL -- "-$operation" 2>/dev/null || true
  fi
  case "$rc" in
    0) printf 'INFO: %s — completed (%ss)\n' "$label" "$((SECONDS - started))" >&2 ;;
    124|137) printf 'WARN: %s — timed out or terminated (%ss, exit %s)\n' "$label" "$((SECONDS - started))" "$rc" >&2 ;;
    *) printf 'WARN: %s — failed (%ss, exit %s)\n' "$label" "$((SECONDS - started))" "$rc" >&2 ;;
  esac
  exit "$rc"
)

# Preserve the vendor's original quiet-output contract while keeping the
# wrapper's progress on stderr. Never echo argv, environment or vendor output.
_aicoding_progress_capture() {
  local log=$1; shift
  "$@" >/dev/null 2>"$log"
}

_aicoding_progress_quiet_stderr() {
  "$@" 2>/dev/null
}
