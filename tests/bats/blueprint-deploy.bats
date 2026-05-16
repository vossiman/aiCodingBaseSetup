#!/usr/bin/env bats

setup() {
  TMPDIR=$(mktemp -d)
  export AICODING_MANIFEST="$TMPDIR/manifest.json"
  export HOME="$TMPDIR"
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "library: sources cleanly under set -euo pipefail" {
  bash -c "set -euo pipefail; . '$BLUEPRINT_ROOT/lib/blueprint-deploy.sh'"
}
