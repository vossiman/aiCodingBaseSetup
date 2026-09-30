#!/bin/bash
# Keep /etc/codex (Codex managed hooks, incl. the secrets deny hook) equal to
# the blueprint. Same code the user-side install runs, minus the escalation.
set -euo pipefail
root=${AICODING_BLUEPRINT_ROOT:?}
header() { :; }
info() { echo "  $*"; }
ok() { echo "  ok: $*"; }
warn() { echo "  warn: $*" >&2; }
. "$root/lib/codex-managed.sh"

state=0
codex_managed_state "$root" || state=$?
case "$state" in
  0) ok "codex managed hooks up to date" ;;
  1) codex_managed_write "$root" && ok "codex managed hooks installed ($CODEX_MANAGED_DIR)" ;;
  2) warn "blueprint hook sources missing"; exit 1 ;;
  3) warn "$CODEX_MANAGED_DIR/requirements.toml is not blueprint-managed; leaving it untouched"; exit 1 ;;
esac
