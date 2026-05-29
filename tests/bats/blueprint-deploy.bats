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

@test "classify_file: up_to_date when current == deployed == new" {
  echo "same" > "$TMPDIR/dest"
  echo "same" > "$TMPDIR/src"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  manifest_stage_begin
  local h
  h=$(compute_hash "$TMPDIR/dest")
  manifest_set_file "$TMPDIR/dest" "$(jq -n --arg s configs/x --arg h "$h" \
    '{mode:"overwrite",source:$s,deployed_hash:$h}')"
  manifest_stage_commit
  run classify_file "$TMPDIR/dest" "$TMPDIR/src" "overwrite"
  [ "$status" -eq 0 ]
  [ "$output" = "up_to_date" ]
}

@test "classify_file: will_update when current == deployed != new" {
  echo "old" > "$TMPDIR/dest"
  echo "new" > "$TMPDIR/src"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  manifest_stage_begin
  local h
  h=$(compute_hash "$TMPDIR/dest")
  manifest_set_file "$TMPDIR/dest" "$(jq -n --arg h "$h" \
    '{mode:"overwrite",source:"configs/x",deployed_hash:$h}')"
  manifest_stage_commit
  run classify_file "$TMPDIR/dest" "$TMPDIR/src" "overwrite"
  [ "$status" -eq 0 ]
  [ "$output" = "will_update" ]
}

@test "classify_file: drifted_but_aligned when current != deployed and current == new" {
  echo "user-edit" > "$TMPDIR/dest"
  echo "user-edit" > "$TMPDIR/src"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  manifest_stage_begin
  manifest_set_file "$TMPDIR/dest" '{"mode":"overwrite","source":"configs/x","deployed_hash":"obsolete"}'
  manifest_stage_commit
  run classify_file "$TMPDIR/dest" "$TMPDIR/src" "overwrite"
  [ "$status" -eq 0 ]
  [ "$output" = "drifted_but_aligned" ]
}

@test "classify_file: drifted_and_updating when all three differ" {
  echo "user-edit" > "$TMPDIR/dest"
  echo "new-blueprint" > "$TMPDIR/src"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  manifest_stage_begin
  manifest_set_file "$TMPDIR/dest" '{"mode":"overwrite","source":"configs/x","deployed_hash":"obsolete"}'
  manifest_stage_commit
  run classify_file "$TMPDIR/dest" "$TMPDIR/src" "overwrite"
  [ "$status" -eq 0 ]
  [ "$output" = "drifted_and_updating" ]
}

@test "classify_file: new_file when not in manifest" {
  echo "new" > "$TMPDIR/src"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  manifest_stage_begin
  manifest_stage_commit
  run classify_file "$TMPDIR/dest" "$TMPDIR/src" "overwrite"
  [ "$status" -eq 0 ]
  [ "$output" = "new_file" ]
}

@test "classify_file: to_remove when in manifest but src is absent" {
  echo "old" > "$TMPDIR/dest"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  manifest_stage_begin
  local h
  h=$(compute_hash "$TMPDIR/dest")
  manifest_set_file "$TMPDIR/dest" "$(jq -n --arg h "$h" \
    '{mode:"overwrite",source:"configs/x",deployed_hash:$h}')"
  manifest_stage_commit
  run classify_file "$TMPDIR/dest" "$TMPDIR/missing-src" "overwrite"
  [ "$status" -eq 0 ]
  [ "$output" = "to_remove" ]
}

@test "classify_file: merge mode always returns merge" {
  echo "current" > "$TMPDIR/dest"
  echo "new" > "$TMPDIR/src"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run classify_file "$TMPDIR/dest" "$TMPDIR/src" "merge"
  [ "$status" -eq 0 ]
  [ "$output" = "merge" ]
}

@test "deploy_overwrite_file: writes file and records hash in pending manifest" {
  echo "content" > "$TMPDIR/src"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  manifest_stage_begin
  deploy_overwrite_file "$TMPDIR/src" "$TMPDIR/dest" "configs/example.sh"
  manifest_stage_commit
  diff "$TMPDIR/src" "$TMPDIR/dest"
  jq -e '.files["'"$TMPDIR"'/dest"].mode == "overwrite"' "$AICODING_MANIFEST"
  jq -e '.files["'"$TMPDIR"'/dest"].source == "configs/example.sh"' "$AICODING_MANIFEST"
  local expect_h
  expect_h=$(compute_hash "$TMPDIR/dest")
  jq -e --arg h "$expect_h" '.files["'"$TMPDIR"'/dest"].deployed_hash == $h' "$AICODING_MANIFEST"
}

@test "deploy_overwrite_file: creates parent directory if missing" {
  echo "content" > "$TMPDIR/src"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  manifest_stage_begin
  deploy_overwrite_file "$TMPDIR/src" "$TMPDIR/nested/dir/dest" "configs/x"
  manifest_stage_commit
  [ -f "$TMPDIR/nested/dir/dest" ]
}

@test "deploy_merge_file: preserves user-added top-level keys" {
  echo '{"theme":"dark","userKey":"userValue"}' > "$TMPDIR/dest"
  echo '{"theme":"light","newKey":"newValue"}' > "$TMPDIR/src"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  manifest_stage_begin
  deploy_merge_file "$TMPDIR/src" "$TMPDIR/dest" "configs/example.json"
  manifest_stage_commit
  jq -e '.userKey == "userValue"' "$TMPDIR/dest"
  jq -e '.newKey == "newValue"' "$TMPDIR/dest"
  jq -e '.theme == "light"' "$TMPDIR/dest"  # source wins for shared keys
}

@test "deploy_merge_file: unions 'allow' arrays" {
  echo '{"permissions":{"allow":["a","b"]}}' > "$TMPDIR/dest"
  echo '{"permissions":{"allow":["b","c"]}}' > "$TMPDIR/src"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  manifest_stage_begin
  deploy_merge_file "$TMPDIR/src" "$TMPDIR/dest" "configs/example.json"
  manifest_stage_commit
  jq -e '.permissions.allow | sort == ["a","b","c"]' "$TMPDIR/dest"
}

@test "deploy_merge_file: records mode=merge in manifest, no hash" {
  echo '{}' > "$TMPDIR/dest"
  echo '{}' > "$TMPDIR/src"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  manifest_stage_begin
  deploy_merge_file "$TMPDIR/src" "$TMPDIR/dest" "configs/example.json"
  manifest_stage_commit
  jq -e '.files["'"$TMPDIR"'/dest"].mode == "merge"' "$AICODING_MANIFEST"
  jq -e '.files["'"$TMPDIR"'/dest"].source == "configs/example.json"' "$AICODING_MANIFEST"
  jq -e '.files["'"$TMPDIR"'/dest"] | has("deployed_hash") | not' "$AICODING_MANIFEST"
}

@test "deploy_merge_file: copies file when dest doesn't exist" {
  echo '{"key":"value"}' > "$TMPDIR/src"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  manifest_stage_begin
  deploy_merge_file "$TMPDIR/src" "$TMPDIR/dest" "configs/example.json"
  manifest_stage_commit
  jq -e '.key == "value"' "$TMPDIR/dest"
}

@test "deploy_marker_block: inserts block at end when file lacks markers" {
  echo "prelude line" > "$TMPDIR/dest"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  manifest_stage_begin
  deploy_marker_block "$TMPDIR/dest" "block content here" "# START" "# END"
  manifest_stage_commit
  grep -q "^prelude line$" "$TMPDIR/dest"
  grep -q "^# START$" "$TMPDIR/dest"
  grep -q "^block content here$" "$TMPDIR/dest"
  grep -q "^# END$" "$TMPDIR/dest"
}

@test "deploy_marker_block: replaces block when markers already present" {
  cat > "$TMPDIR/dest" <<EOF
prelude
# START
old block content
# END
trailer
EOF
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  manifest_stage_begin
  deploy_marker_block "$TMPDIR/dest" "new block content" "# START" "# END"
  manifest_stage_commit
  grep -q "^prelude$" "$TMPDIR/dest"
  grep -q "^new block content$" "$TMPDIR/dest"
  ! grep -q "old block content" "$TMPDIR/dest"
  grep -q "^trailer$" "$TMPDIR/dest"
}

@test "deploy_marker_block: records mode=marker_block with block hash" {
  echo "prelude" > "$TMPDIR/dest"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  manifest_stage_begin
  deploy_marker_block "$TMPDIR/dest" "body" "# START" "# END"
  manifest_stage_commit
  jq -e '.files["'"$TMPDIR"'/dest"].mode == "marker_block"' "$AICODING_MANIFEST"
  jq -e '.files["'"$TMPDIR"'/dest"].marker_start == "# START"' "$AICODING_MANIFEST"
  jq -e '.files["'"$TMPDIR"'/dest"].marker_end == "# END"' "$AICODING_MANIFEST"
  local expect_h
  expect_h=$(compute_block_hash "$TMPDIR/dest" "# START" "# END")
  jq -e --arg h "$expect_h" '.files["'"$TMPDIR"'/dest"].deployed_block_hash == $h' "$AICODING_MANIFEST"
}

@test "remove_managed_file: deletes file and removes manifest entry" {
  echo "x" > "$TMPDIR/dest"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  manifest_stage_begin
  manifest_set_file "$TMPDIR/dest" '{"mode":"overwrite","source":"x","deployed_hash":"y"}'
  manifest_stage_commit

  manifest_stage_begin
  remove_managed_file "$TMPDIR/dest"
  manifest_stage_commit

  [ ! -e "$TMPDIR/dest" ]
  jq -e '.files | has("'"$TMPDIR"'/dest") | not' "$AICODING_MANIFEST"
}

@test "remove_managed_file: tolerates missing file" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  manifest_stage_begin
  manifest_set_file "$TMPDIR/dest" '{"mode":"overwrite","source":"x","deployed_hash":"y"}'
  manifest_stage_commit

  manifest_stage_begin
  remove_managed_file "$TMPDIR/dest"   # file already absent
  manifest_stage_commit

  jq -e '.files | has("'"$TMPDIR"'/dest") | not' "$AICODING_MANIFEST"
}

@test "apply_managed_buckets: applies only the listed buckets" {
  # Restoring a missing file is in the allowed set; to_remove is not.
  export AICODING_BLUEPRINT_CLONE="$TMPDIR/clone"
  mkdir -p "$AICODING_BLUEPRINT_CLONE/configs/tmux"
  echo "tmux from blueprint" > "$AICODING_BLUEPRINT_CLONE/configs/tmux/tmux.conf"
  mkdir -p "$HOME/.aicodingsetup"
  local tmux_hash
  tmux_hash=$(sha256sum "$AICODING_BLUEPRINT_CLONE/configs/tmux/tmux.conf" | awk '{print $1}')
  cat > "$AICODING_MANIFEST" <<EOF
{"schema_version":1,"files":{
  "$HOME/.tmux.conf":{"mode":"overwrite","source":"configs/tmux/tmux.conf","deployed_hash":"$tmux_hash"},
  "$HOME/.obsolete":{"mode":"overwrite","source":"configs/obsolete","deployed_hash":"$tmux_hash"}
}}
EOF
  # ~/.tmux.conf missing → bucket restore. ~/.obsolete not in inventory → to_remove.
  touch "$HOME/.obsolete"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  declare -gA BUCKETS FILE_MODE FILE_SOURCE
  classify_managed_files
  [ "${BUCKETS[$HOME/.tmux.conf]}" = "restore" ]
  [ "${BUCKETS[$HOME/.obsolete]}" = "to_remove" ]

  # Apply only restore + new_file + will_update + drifted_but_aligned + merge.
  manifest_stage_begin
  apply_managed_buckets "restore new_file will_update drifted_but_aligned merge"
  manifest_stage_commit

  # tmux.conf restored.
  [ -f "$HOME/.tmux.conf" ]
  grep -q "tmux from blueprint" "$HOME/.tmux.conf"
  # obsolete file NOT removed (to_remove was excluded).
  [ -f "$HOME/.obsolete" ]
}

@test "classify_managed_files: populates BUCKETS for tracked + on-disk + missing scenarios" {
  # Set up a blueprint clone with one overwrite file.
  export AICODING_BLUEPRINT_CLONE="$TMPDIR/clone"
  mkdir -p "$AICODING_BLUEPRINT_CLONE/configs/tmux" "$AICODING_BLUEPRINT_CLONE/configs/claude"
  echo "blueprint tmux content" > "$AICODING_BLUEPRINT_CLONE/configs/tmux/tmux.conf"
  echo '{}' > "$AICODING_BLUEPRINT_CLONE/configs/claude/settings.json"
  # Manifest tracks the tmux file with matching hash.
  mkdir -p "$HOME/.aicodingsetup"
  local tmux_hash
  tmux_hash=$(sha256sum "$AICODING_BLUEPRINT_CLONE/configs/tmux/tmux.conf" | awk '{print $1}')
  cat > "$AICODING_MANIFEST" <<EOF
{"schema_version":1,"files":{"$HOME/.tmux.conf":{"mode":"overwrite","source":"configs/tmux/tmux.conf","deployed_hash":"$tmux_hash"}}}
EOF
  # File is missing on disk → should classify as restore.
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  declare -gA BUCKETS FILE_MODE FILE_SOURCE
  classify_managed_files
  [ "${BUCKETS[$HOME/.tmux.conf]}" = "restore" ]
}

@test "apply_managed_buckets: drifted_and_updating backs up and redeploys" {
  # Source the lib (other tests in this file do the same).
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"

  export AICODING_BLUEPRINT_CLONE="$TMPDIR/clone"
  mkdir -p "$AICODING_BLUEPRINT_CLONE/configs/tmux"
  echo "new blueprint tmux" > "$AICODING_BLUEPRINT_CLONE/configs/tmux/tmux.conf"

  # User has an edited file (drift). Manifest hash is from neither current
  # disk content nor blueprint content → bucket drifted_and_updating.
  mkdir -p "$HOME/.aicodingsetup"
  echo "user edited tmux" > "$HOME/.tmux.conf"
  local stale_hash
  stale_hash=$(echo "original deployed content" | sha256sum | awk '{print $1}')
  cat > "$AICODING_MANIFEST" <<EOF
{"schema_version":1,"files":{"$HOME/.tmux.conf":{"mode":"overwrite","source":"configs/tmux/tmux.conf","deployed_hash":"$stale_hash"}}}
EOF

  declare -gA BUCKETS FILE_MODE FILE_SOURCE
  classify_managed_files
  [ "${BUCKETS[$HOME/.tmux.conf]}" = "drifted_and_updating" ]

  manifest_stage_begin
  run apply_managed_buckets "drifted_and_updating"
  manifest_stage_commit
  [ "$status" -eq 0 ]

  # Blueprint version deployed.
  grep -q "new blueprint tmux" "$HOME/.tmux.conf"
  # A .bak.<stamp> sibling exists with the user's previous content.
  local bak
  bak=$(ls "$HOME"/.tmux.conf.bak.* 2>/dev/null | head -1)
  [ -n "$bak" ]
  grep -q "user edited tmux" "$bak"
  # Output mentions the backup line (visible-failure regression guard).
  echo "$output" | grep -qE "^      backup: $HOME/.tmux.conf.bak\.[0-9]+-[0-9]+$"
}

@test "managed_inventory_overwrite: includes codex config.toml" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run managed_inventory_overwrite
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "$HOME/.codex/config.toml|overwrite|configs/codex/config.toml"
}

@test "managed_inventory_merge: includes cursor mcp.json" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run managed_inventory_merge
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "$HOME/.cursor/mcp.json|merge|configs/cursor/mcp.json"
}

@test "managed_inventory_merge: opencode.json row is unchanged" {
  # Defensive: opencode.json row is still the existing $HOME/.config/opencode
  # path with merge mode — Task 5 widened the source content but did not
  # change the inventory row.
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run managed_inventory_merge
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "$HOME/.config/opencode/opencode.json|merge|configs/opencode/opencode.json"
}
