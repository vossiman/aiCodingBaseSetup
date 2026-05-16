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

@test "read_manifest: returns empty manifest when file missing" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run read_manifest
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '. == {"schema_version": 1, "files": {}}'
}

@test "read_manifest: returns existing manifest" {
  cp "$BLUEPRINT_ROOT/tests/bats/fixtures/sample-manifest.json" "$AICODING_MANIFEST"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run read_manifest
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.schema_version == 1'
  echo "$output" | jq -e '.blueprint_commit == "abc1234"'
}

@test "write_manifest: writes atomically via tmp+mv" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  write_manifest '{"schema_version":1,"files":{}}'
  [ -f "$AICODING_MANIFEST" ]
  jq -e '.schema_version == 1' "$AICODING_MANIFEST"
  # No leftover tmp file.
  [ ! -f "$AICODING_MANIFEST.tmp" ]
}

@test "write_manifest: creates parent directory if missing" {
  rm -rf "$TMPDIR"
  mkdir -p "$TMPDIR"
  export AICODING_MANIFEST="$TMPDIR/nested/dir/manifest.json"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  write_manifest '{"schema_version":1,"files":{}}'
  [ -f "$AICODING_MANIFEST" ]
}

@test "manifest_get_file: returns per-file entry as JSON" {
  cp "$BLUEPRINT_ROOT/tests/bats/fixtures/sample-manifest.json" "$AICODING_MANIFEST"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run manifest_get_file "/tmp/test-home/.tmux.conf"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.mode == "overwrite"'
  echo "$output" | jq -e '.source == "configs/tmux/tmux.conf"'
}

@test "manifest_get_file: returns 'null' for missing entry" {
  echo '{"schema_version":1,"files":{}}' > "$AICODING_MANIFEST"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run manifest_get_file "/tmp/test-home/.missing"
  [ "$status" -eq 0 ]
  [ "$output" = "null" ]
}

@test "manifest_set_file: stages a file entry in pending manifest" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  manifest_stage_begin
  manifest_set_file "/tmp/foo" '{"mode":"overwrite","source":"x","deployed_hash":"deadbeef"}'
  manifest_stage_commit
  jq -e '.files["/tmp/foo"].mode == "overwrite"' "$AICODING_MANIFEST"
  jq -e '.files["/tmp/foo"].deployed_hash == "deadbeef"' "$AICODING_MANIFEST"
}

@test "manifest_set_file: overwrites existing entry" {
  cp "$BLUEPRINT_ROOT/tests/bats/fixtures/sample-manifest.json" "$AICODING_MANIFEST"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  manifest_stage_begin
  manifest_set_file "/tmp/test-home/.tmux.conf" '{"mode":"overwrite","source":"x","deployed_hash":"newhash"}'
  manifest_stage_commit
  jq -e '.files["/tmp/test-home/.tmux.conf"].deployed_hash == "newhash"' "$AICODING_MANIFEST"
}
