#!/bin/bash
# One-time host setup for the aicoding root runner. Run via
# `aicoding-root-install`, which asks sudo for this script alone. After this
# the runner refreshes itself from the repo; nothing here needs rerunning.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(dirname "$here")

die() { echo "aicoding-root-install: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "must run as root (use aicoding-root-install)"
if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then
  die "this is a container; containers have passwordless sudo and do not need the runner"
fi
[ -d /run/systemd/system ] || die "systemd is not running as init; the runner needs systemd timers"
command -v git >/dev/null && command -v flock >/dev/null && command -v curl >/dev/null \
  && command -v jq >/dev/null || die "needs git, flock, curl and jq on root's PATH"

. "$here/lib.sh"
aicoding_root_install_files "$repo" || die "installing runner and units failed"

echo "Running the first pass (fetches the repo from GitHub; may take a minute)..."
if systemctl start aicoding-root.service; then
  echo "Done: $(cat /var/lib/aicoding-root/status 2>/dev/null)"
  echo "The runner now keeps root-owned files current every 15 minutes."
else
  journalctl -u aicoding-root.service -n 40 --no-pager || true
  die "the first pass failed (see above); the timer will retry"
fi
