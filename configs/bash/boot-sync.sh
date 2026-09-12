# Persistent automatic updater enrollment. Sourced by host login shells; the
# command performs no foreground network work and is safe to repeat.
_aicoding_auto_update_ensure() {
  local command
  command=$(command -v aicoding-auto-update 2>/dev/null) \
    || command="$HOME/.local/bin/aicoding-auto-update"
  [ -x "$command" ] || return 0
  [ "${AICODINGSETUP_SKIP_NETWORK:-0}" != 1 ] || return 0
  "$command" --ensure </dev/null >/dev/null 2>&1 || true
}
_aicoding_auto_update_ensure
unset -f _aicoding_auto_update_ensure
