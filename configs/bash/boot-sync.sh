# aicoding boot sync — deployed on host-profile machines only. Containers
# get day-2 sync from on-start.sh on attach; this gives bare hosts the same
# freshness on terminal open. Own 6h throttle (aicoding-sync --boot throttles
# binaries/provision but fetches the blueprint every run — too much for every
# shell), serialized with an atomic directory lock, stamped BEFORE the run,
# and backgrounded so shell startup never blocks on the network.
_aicoding_boot_sync() {
  # Resolve the binary explicitly, falling back to ~/.local/bin: a fresh
  # machine's first login shell may predate that dir appearing on PATH
  # (Debian/Mint add it only when it existed at login), which would
  # otherwise silently defer the first sync until the next login.
  local sync_bin
  sync_bin=$(command -v aicoding-sync 2>/dev/null) || sync_bin="$HOME/.local/bin/aicoding-sync"
  [ -x "$sync_bin" ] || return 0
  [ "${AICODINGSETUP_SKIP_NETWORK:-}" = 1 ] && return 0
  local state_dir="$HOME/.local/state/aicoding/updates"
  local stamp="$state_dir/.boot-sync.stamp"
  local lock="$state_dir/.boot-sync.lock"
  local lock_stale_seconds="${AICODING_BOOT_SYNC_LOCK_STALE_SECONDS:-900}"
  mkdir -p "$state_dir" "$HOME/.cache/aicoding" 2>/dev/null || return 0

  # mkdir is the freshness-check mutex: every contender must acquire it
  # before inspecting or writing the stamp. A shell killed inside this short
  # critical section leaves an empty directory; recover it after 15 minutes
  # (overrideable for tests), then compete for mkdir again. rmdir deliberately
  # removes only this exact, empty lock directory.
  if ! mkdir "$lock" 2>/dev/null; then
    [ -n "$(find "$lock" -maxdepth 0 -type d ! -newermt "-${lock_stale_seconds} seconds" -print 2>/dev/null)" ] || return 0
    rmdir "$lock" 2>/dev/null || return 0
    mkdir "$lock" 2>/dev/null || return 0
  fi

  if [ -n "$(find "$stamp" -newermt "-21600 seconds" 2>/dev/null)" ]; then
    rmdir "$lock" 2>/dev/null || true
    return 0
  fi
  if ! : > "$stamp"; then
    rmdir "$lock" 2>/dev/null || true
    return 0
  fi
  ("$sync_bin" --boot >> "$HOME/.cache/aicoding/boot-sync.log" 2>&1 &)
  rmdir "$lock" 2>/dev/null || true
}
_aicoding_boot_sync
unset -f _aicoding_boot_sync
