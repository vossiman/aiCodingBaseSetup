# aicoding boot sync — deployed on host-profile machines only. Containers
# get day-2 sync from on-start.sh on attach; this gives bare hosts the same
# freshness on terminal open. Own 6h throttle (aicoding-sync --boot throttles
# binaries/provision but fetches the blueprint every run — too much for every
# shell), stamped BEFORE the run so parallel shells don't pile up, and
# backgrounded so shell startup never blocks on the network.
_aicoding_boot_sync() {
  command -v aicoding-sync >/dev/null 2>&1 || return 0
  [ "${AICODINGSETUP_SKIP_NETWORK:-}" = 1 ] && return 0
  local stamp="$HOME/.local/state/aicoding/updates/.boot-sync.stamp"
  [ -n "$(find "$stamp" -newermt "-21600 seconds" 2>/dev/null)" ] && return 0
  mkdir -p "${stamp%/*}" "$HOME/.cache/aicoding" 2>/dev/null || return 0
  : > "$stamp"
  (aicoding-sync --boot >> "$HOME/.cache/aicoding/boot-sync.log" 2>&1 &)
}
_aicoding_boot_sync
unset -f _aicoding_boot_sync
