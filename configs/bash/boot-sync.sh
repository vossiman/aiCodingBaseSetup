# aicoding boot sync — deployed on host-profile machines only. Containers
# get day-2 sync from on-start.sh on attach; this gives bare hosts the same
# freshness on terminal open. Own 6h throttle (aicoding-sync --boot throttles
# binaries/provision but fetches the blueprint every run — too much for every
# shell), stamped BEFORE the run so parallel shells don't pile up, and
# backgrounded so shell startup never blocks on the network.
_aicoding_boot_sync() {
  # Resolve the binary explicitly, falling back to ~/.local/bin: a fresh
  # machine's first login shell may predate that dir appearing on PATH
  # (Debian/Mint add it only when it existed at login), which would
  # otherwise silently defer the first sync until the next login.
  local sync_bin
  sync_bin=$(command -v aicoding-sync 2>/dev/null) || sync_bin="$HOME/.local/bin/aicoding-sync"
  [ -x "$sync_bin" ] || return 0
  [ "${AICODINGSETUP_SKIP_NETWORK:-}" = 1 ] && return 0
  local stamp="$HOME/.local/state/aicoding/updates/.boot-sync.stamp"
  [ -n "$(find "$stamp" -newermt "-21600 seconds" 2>/dev/null)" ] && return 0
  mkdir -p "${stamp%/*}" "$HOME/.cache/aicoding" 2>/dev/null || return 0
  : > "$stamp"
  ("$sync_bin" --boot >> "$HOME/.cache/aicoding/boot-sync.log" 2>&1 &)
}
_aicoding_boot_sync
unset -f _aicoding_boot_sync
