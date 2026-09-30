# root/lib.sh - install the runner and its systemd units from a checkout.
# Sourced by root/install.sh (first install) and root/apply.sh (every pass),
# so the runner and units update themselves from the repo after one install.

AICODING_ROOT_PREFIX=${AICODING_ROOT_PREFIX:-}
AICODING_ROOT_SYSTEMCTL=${AICODING_ROOT_SYSTEMCTL:-systemctl}
AICODING_ROOT_UNITS=(aicoding-root.service aicoding-root.timer aicoding-root.path)

# Copy $1 to $2 (mode $3) only when it differs. Atomic rename, so the runner
# can replace its own file while bash is still executing the old inode.
# Returns 0 when it wrote, 1 when already current, 2 on error.
_aicoding_root_put() {
  local src=$1 dest=$2 mode=$3 tmp
  cmp -s "$src" "$dest" && return 1
  install -d -m 0755 "$(dirname "$dest")" || return 2
  tmp="$dest.aicoding-new"
  install -m "$mode" -o 0 -g 0 "$src" "$tmp" 2>/dev/null || install -m "$mode" "$src" "$tmp" || return 2
  mv -f "$tmp" "$dest" || return 2
  return 0
}

# aicoding_root_install_files <repo-root>: runner, units, tmpfiles entry.
aicoding_root_install_files() {
  local repo=$1 p=$AICODING_ROOT_PREFIX changed=0 u rc
  # `|| rc=$?`, not `; rc=$?`: install.sh runs under errexit.
  rc=0; _aicoding_root_put "$repo/root/runner" "$p/usr/local/libexec/aicoding-root/runner" 0755 || rc=$?
  [ "$rc" -eq 2 ] && return 1
  for u in "${AICODING_ROOT_UNITS[@]}"; do
    rc=0; _aicoding_root_put "$repo/root/units/$u" "$p/etc/systemd/system/$u" 0644 || rc=$?
    [ "$rc" -eq 2 ] && return 1
    [ "$rc" -eq 0 ] && changed=1
  done
  rc=0; _aicoding_root_put "$repo/root/tmpfiles.conf" "$p/etc/tmpfiles.d/aicoding-root.conf" 0644 || rc=$?
  [ "$rc" -eq 2 ] && return 1
  if [ "$rc" -eq 0 ]; then
    systemd-tmpfiles --create "$p/etc/tmpfiles.d/aicoding-root.conf" || return 1
  fi
  if [ "$changed" -eq 1 ]; then
    "$AICODING_ROOT_SYSTEMCTL" daemon-reload || return 1
  fi
  # Idempotent: keeps the timer and the trigger watch enabled and running,
  # and restarts a path unit a burst of triggers left failed.
  "$AICODING_ROOT_SYSTEMCTL" enable --quiet aicoding-root.timer aicoding-root.path || return 1
  "$AICODING_ROOT_SYSTEMCTL" reset-failed aicoding-root.path 2>/dev/null || true
  "$AICODING_ROOT_SYSTEMCTL" start aicoding-root.timer aicoding-root.path || return 1
}
