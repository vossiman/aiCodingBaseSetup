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
  # (overrideable for tests), then compete for mkdir again. Recovery steals
  # the stale lock by RENAMING it to a private name first — an in-place
  # rmdir+mkdir let two recoverers interleave so the second rmdir removed the
  # first one's fresh lock. mv is atomic: exactly one steal wins, a failed mv
  # means someone else won. The mtime re-check on the private copy (rename
  # preserves it) catches the residual race where the stolen dir was already
  # a competitor's fresh lock — hand it back instead of vaporising it. rmdir
  # deliberately removes only this exact, empty lock directory.
  if ! mkdir "$lock" 2>/dev/null; then
    [ -n "$(find "$lock" -maxdepth 0 -type d ! -newermt "-${lock_stale_seconds} seconds" -print 2>/dev/null)" ] || return 0
    local stolen="$lock.stale.$$"
    mv "$lock" "$stolen" 2>/dev/null || return 0
    if [ -z "$(find "$stolen" -maxdepth 0 -type d ! -newermt "-${lock_stale_seconds} seconds" -print 2>/dev/null)" ]; then
      mv "$stolen" "$lock" 2>/dev/null || rmdir "$stolen" 2>/dev/null || true
      return 0
    fi
    rmdir "$stolen" 2>/dev/null || true
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
