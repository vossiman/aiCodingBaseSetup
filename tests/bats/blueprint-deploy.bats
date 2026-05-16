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

@test "compute_hash: returns sha256 of file content" {
  echo -n "hello" > "$TMPDIR/f"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run compute_hash "$TMPDIR/f"
  [ "$status" -eq 0 ]
  [ "$output" = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824" ]
}

@test "compute_hash: returns empty string for missing file" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run compute_hash "$TMPDIR/missing"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "compute_block_hash: returns hash of content between markers" {
  cat > "$TMPDIR/f" <<EOF
prelude line
# START
managed line 1
managed line 2
# END
trailing line
EOF
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run compute_block_hash "$TMPDIR/f" "# START" "# END"
  [ "$status" -eq 0 ]
  # sha256 of "managed line 1\nmanaged line 2\n"
  [ "$output" = "9123922db7288db5afecea8743efe7e43368a5d0baebb29a9fa49f802622e663" ]
}

@test "compute_block_hash: returns empty if markers absent" {
  echo "no markers here" > "$TMPDIR/f"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run compute_block_hash "$TMPDIR/f" "# START" "# END"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "compute_block_hash: returns empty when end marker is absent" {
  cat > "$TMPDIR/f" <<EOF
prelude
# START
only opening marker
no end marker here
EOF
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run compute_block_hash "$TMPDIR/f" "# START" "# END"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "compute_block_hash: returns empty when start marker is absent" {
  cat > "$TMPDIR/f" <<EOF
prelude
only closing marker below
# END
trailer
EOF
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run compute_block_hash "$TMPDIR/f" "# START" "# END"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
