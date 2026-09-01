#!/usr/bin/env bats

setup() {
  TMPDIR=$(mktemp -d)
  export AICODING_MANIFEST="$TMPDIR/manifest.json"
  export HOME="$TMPDIR"
  # umask 0002 is the container default and the condition under which the
  # 664 modes were observed live.
  umask 0002
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

@test "classify_file: new_file_existing when untracked but dest already on disk" {
  # A personal file at a path the blueprint just started managing must not
  # classify as plain new_file — that bucket deploys with no backup.
  echo "personal content" > "$TMPDIR/dest"
  echo "blueprint content" > "$TMPDIR/src"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  manifest_stage_begin
  manifest_stage_commit
  run classify_file "$TMPDIR/dest" "$TMPDIR/src" "overwrite"
  [ "$status" -eq 0 ]
  [ "$output" = "new_file_existing" ]
}

@test "apply_managed_buckets: new_file_existing backs up before deploying" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  export AICODING_BLUEPRINT_CLONE="$TMPDIR/clone"
  mkdir -p "$AICODING_BLUEPRINT_CLONE/configs/codex" "$HOME/.codex"
  echo "blueprint codex config" > "$AICODING_BLUEPRINT_CLONE/configs/codex/config.toml"
  echo "personal codex config" > "$HOME/.codex/config.toml"
  echo '{"schema_version":1,"files":{}}' > "$AICODING_MANIFEST"

  declare -gA BUCKETS FILE_MODE FILE_SOURCE
  BUCKETS[$HOME/.codex/config.toml]=new_file_existing
  FILE_MODE[$HOME/.codex/config.toml]=overwrite
  FILE_SOURCE[$HOME/.codex/config.toml]=configs/codex/config.toml

  manifest_stage_begin
  # No `run`: it subshells, which would discard the staged-manifest mutation
  # this test asserts on.
  apply_managed_buckets "new_file_existing"
  manifest_stage_commit

  grep -q "blueprint codex config" "$HOME/.codex/config.toml"
  local bak
  bak=$(ls "$HOME"/.codex/config.toml.bak.* 2>/dev/null | head -1)
  [ -n "$bak" ]
  grep -q "personal codex config" "$bak"
  jq -e '.files["'"$HOME"'/.codex/config.toml"]' "$AICODING_MANIFEST"
}

@test "apply_managed_buckets: no backup when disk already matches incoming content" {
  # Regression: a newly managed path whose on-disk file already equals the
  # rendered blueprint content got a .bak byte-identical to the live file on
  # every run (7 identical bw-deny-files.sh.bak.* piled up on one container,
  # 2026-08-21..23). A backup that duplicates what deploy is about to write
  # protects nothing — skip it.
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  export AICODING_BLUEPRINT_CLONE="$TMPDIR/clone"
  mkdir -p "$AICODING_BLUEPRINT_CLONE/configs/codex" "$HOME/.codex"
  echo "identical content" > "$AICODING_BLUEPRINT_CLONE/configs/codex/config.toml"
  echo "identical content" > "$HOME/.codex/config.toml"
  echo '{"schema_version":1,"files":{}}' > "$AICODING_MANIFEST"

  declare -gA BUCKETS FILE_MODE FILE_SOURCE
  BUCKETS[$HOME/.codex/config.toml]=new_file_existing
  FILE_MODE[$HOME/.codex/config.toml]=overwrite
  FILE_SOURCE[$HOME/.codex/config.toml]=configs/codex/config.toml

  manifest_stage_begin
  apply_managed_buckets "new_file_existing"
  manifest_stage_commit

  grep -q "identical content" "$HOME/.codex/config.toml"
  # No .bak sibling — it would only duplicate the live file.
  if ls "$HOME"/.codex/config.toml.bak.* 2>/dev/null; then false; fi
  # The file is still adopted into the manifest.
  jq -e '.files["'"$HOME"'/.codex/config.toml"]' "$AICODING_MANIFEST"
}

@test "apply_managed_buckets: drifted_but_aligned records the MANAGED hash (codex trust sections)" {
  # Regression: the refresh used compute_hash, so a codex config.toml with
  # [projects.*] trust sections stored a hash the next classify (which strips
  # them) could never match — permanent re-drift on every sync.
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  export AICODING_BLUEPRINT_CLONE="$TMPDIR/clone"
  mkdir -p "$AICODING_BLUEPRINT_CLONE/configs/codex" "$HOME/.codex"
  printf 'model = "personal"\n' > "$AICODING_BLUEPRINT_CLONE/configs/codex/config.toml"
  printf 'model = "personal"\n\n[projects."/w/x"]\ntrust_level = "trusted"\n' \
    > "$HOME/.codex/config.toml"
  cat > "$AICODING_MANIFEST" <<EOF
{"schema_version":1,"files":{"$HOME/.codex/config.toml":{"mode":"overwrite","source":"configs/codex/config.toml","deployed_hash":"obsolete"}}}
EOF

  declare -gA BUCKETS FILE_MODE FILE_SOURCE
  FILE_MODE[$HOME/.codex/config.toml]=overwrite
  FILE_SOURCE[$HOME/.codex/config.toml]=configs/codex/config.toml
  BUCKETS[$HOME/.codex/config.toml]=$(classify_file "$HOME/.codex/config.toml" \
    "$AICODING_BLUEPRINT_CLONE/configs/codex/config.toml" overwrite)
  [ "${BUCKETS[$HOME/.codex/config.toml]}" = "drifted_but_aligned" ]

  manifest_stage_begin
  apply_managed_buckets "drifted_but_aligned"
  manifest_stage_commit

  local stored managed
  stored=$(jq -r '.files["'"$HOME"'/.codex/config.toml"].deployed_hash' "$AICODING_MANIFEST")
  managed=$(compute_managed_hash "$HOME/.codex/config.toml")
  [ "$stored" = "$managed" ]
  # Stable: the next classification converges instead of re-drifting.
  run classify_file "$HOME/.codex/config.toml" \
    "$AICODING_BLUEPRINT_CLONE/configs/codex/config.toml" overwrite
  [ "$output" = "up_to_date" ]
}

@test "_substitute_file_to: strips memory-router from cursor mcp.json when token absent" {
  unset MEMORY_ROUTER_TOKEN
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  mkdir -p "$TMPDIR/clone/configs/cursor"
  cp "$BLUEPRINT_ROOT/configs/cursor/mcp.json" "$TMPDIR/clone/configs/cursor/mcp.json"
  _substitute_file_to "$TMPDIR/clone/configs/cursor/mcp.json" "$TMPDIR/out.json"
  run jq -e '.mcpServers["memory-router"]' "$TMPDIR/out.json"
  [ "$status" -ne 0 ]
  # Other servers survive the strip.
  jq -e '.mcpServers.context7' "$TMPDIR/out.json"
}

@test "_substitute_file_to: keeps memory-router with substituted header when token set" {
  export MEMORY_ROUTER_TOKEN=tok-123
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  mkdir -p "$TMPDIR/clone/configs/cursor"
  cp "$BLUEPRINT_ROOT/configs/cursor/mcp.json" "$TMPDIR/clone/configs/cursor/mcp.json"
  _substitute_file_to "$TMPDIR/clone/configs/cursor/mcp.json" "$TMPDIR/out.json"
  jq -e '.mcpServers["memory-router"].headers.Authorization == "Bearer tok-123"' "$TMPDIR/out.json"
}

@test "_substitute_file_to: strips the codex memory-router section when token absent" {
  unset MEMORY_ROUTER_TOKEN
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  mkdir -p "$TMPDIR/clone/configs/codex"
  cp "$BLUEPRINT_ROOT/configs/codex/config.toml" "$TMPDIR/clone/configs/codex/config.toml"
  _substitute_file_to "$TMPDIR/clone/configs/codex/config.toml" "$TMPDIR/out.toml"
  if grep -q '^\[mcp_servers.memory-router\]' "$TMPDIR/out.toml"; then false; fi
  # No dangling empty bearer anywhere in the rendered file.
  if grep -q 'Bearer "' "$TMPDIR/out.toml"; then false; fi
  # Other content is intact.
  grep -q '^model' "$TMPDIR/out.toml"
}

@test "merge with token absent preserves an existing manual memory-router entry" {
  unset MEMORY_ROUTER_TOKEN
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  mkdir -p "$TMPDIR/clone/configs/opencode" "$TMPDIR/dest"
  cp "$BLUEPRINT_ROOT/configs/opencode/opencode.json" "$TMPDIR/clone/configs/opencode/opencode.json"
  cat > "$TMPDIR/dest/opencode.json" <<'EOF'
{"mcp":{"memory-router":{"type":"remote","url":"http://myown:9999/mcp","headers":{"Authorization":"Bearer manual-token"},"enabled":true}}}
EOF
  echo '{"schema_version":1,"files":{}}' > "$AICODING_MANIFEST"
  manifest_stage_begin
  deploy_merge_file_substituted "$TMPDIR/clone/configs/opencode/opencode.json" \
    "$TMPDIR/dest/opencode.json" configs/opencode/opencode.json
  manifest_stage_commit
  # The manual registration is untouched; blueprint keys still merged in.
  jq -e '.mcp["memory-router"].headers.Authorization == "Bearer manual-token"' "$TMPDIR/dest/opencode.json"
  jq -e '.mcp["memory-router"].url == "http://myown:9999/mcp"' "$TMPDIR/dest/opencode.json"
  jq -e '.mcp.context7' "$TMPDIR/dest/opencode.json"
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

@test "classify_file: merge mode fail-open — non-JSON target still returns merge" {
  echo "current" > "$TMPDIR/dest"
  echo "new" > "$TMPDIR/src"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run classify_file "$TMPDIR/dest" "$TMPDIR/src" "merge"
  [ "$status" -eq 0 ]
  [ "$output" = "merge" ]
}

@test "_json_merge_into: leaves a non-JSON target untouched (no clobber)" {
  echo "definitely-not-json" > "$TMPDIR/target"
  echo '{"a":1}' > "$TMPDIR/source"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run _json_merge_into "$TMPDIR/target" "$TMPDIR/source"
  [ "$status" -ne 0 ]
  [ "$(cat "$TMPDIR/target")" = "definitely-not-json" ]
}

@test "classify_file: merge target is up_to_date when re-merge is a no-op" {
  echo '{"blueprint":{"a":1}}' > "$TMPDIR/src"
  echo '{"user":2}' > "$TMPDIR/dest"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  # Produce dest exactly as a prior sync would have left it.
  _json_merge_into "$TMPDIR/dest" "$TMPDIR/src"
  run classify_file "$TMPDIR/dest" "$TMPDIR/src" "merge"
  [ "$status" -eq 0 ]
  [ "$output" = "up_to_date" ]
}

@test "classify_file: merge target stays merge when blueprint adds a key" {
  echo '{"blueprint":{"a":1}}' > "$TMPDIR/src"
  echo '{"user":2}' > "$TMPDIR/dest"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  _json_merge_into "$TMPDIR/dest" "$TMPDIR/src"
  echo '{"blueprint":{"a":1,"b":2}}' > "$TMPDIR/src"
  run classify_file "$TMPDIR/dest" "$TMPDIR/src" "merge"
  [ "$status" -eq 0 ]
  [ "$output" = "merge" ]
}

@test "classify_file: merge target with missing dest returns merge" {
  echo '{"blueprint":{"a":1}}' > "$TMPDIR/src"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run classify_file "$TMPDIR/absent-dest" "$TMPDIR/src" "merge"
  [ "$status" -eq 0 ]
  [ "$output" = "merge" ]
}

@test "classify_file: substituted overwrite file is up_to_date after substituted deploy" {
  printf 'key = "{{FIRECRAWL_API_KEY}}"\n' > "$TMPDIR/src"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  export FIRECRAWL_API_KEY="sekret-value"
  manifest_stage_begin
  deploy_overwrite_file_rendered "$TMPDIR/src" "$TMPDIR/dest" "configs/x"
  manifest_stage_commit
  # Nothing changed since deploy: must NOT be perpetually will_update.
  run classify_file "$TMPDIR/dest" "$TMPDIR/src" "overwrite"
  [ "$status" -eq 0 ]
  [ "$output" = "up_to_date" ]
}

@test "classify_file: substituted overwrite file is will_update when blueprint changes" {
  printf 'key = "{{FIRECRAWL_API_KEY}}"\n' > "$TMPDIR/src"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  export FIRECRAWL_API_KEY="sekret-value"
  manifest_stage_begin
  deploy_overwrite_file_rendered "$TMPDIR/src" "$TMPDIR/dest" "configs/x"
  manifest_stage_commit
  printf 'key = "{{FIRECRAWL_API_KEY}}"\nextra = true\n' > "$TMPDIR/src"
  run classify_file "$TMPDIR/dest" "$TMPDIR/src" "overwrite"
  [ "$status" -eq 0 ]
  [ "$output" = "will_update" ]
}

@test "classify_file: codex config.toml ignores codex-written [projects.*] trust sections" {
  # codex ≥0.147 auto-appends a blank line + [projects."<dir>"] trust_level
  # after opening any directory; that must never count as drift.
  mkdir -p "$TMPDIR/.codex"
  printf 'model = "m"\n\n[tui]\nstatus_line = ["run-state"]\n' > "$TMPDIR/src"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  manifest_stage_begin
  deploy_overwrite_file_rendered "$TMPDIR/src" "$TMPDIR/.codex/config.toml" "configs/codex/config.toml"
  manifest_stage_commit
  printf '\n[projects."/some/dir"]\ntrust_level = "trusted"\n' >> "$TMPDIR/.codex/config.toml"
  run classify_file "$TMPDIR/.codex/config.toml" "$TMPDIR/src" "overwrite"
  [ "$status" -eq 0 ]
  [ "$output" = "up_to_date" ]
}

@test "classify_file: codex config.toml still detects real user edits alongside trust sections" {
  mkdir -p "$TMPDIR/.codex"
  printf 'model = "m"\n' > "$TMPDIR/src"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  manifest_stage_begin
  deploy_overwrite_file_rendered "$TMPDIR/src" "$TMPDIR/.codex/config.toml" "configs/codex/config.toml"
  manifest_stage_commit
  printf 'model = "changed-by-user"\n\n[projects."/some/dir"]\ntrust_level = "trusted"\n' > "$TMPDIR/.codex/config.toml"
  printf 'model = "new-blueprint"\n' > "$TMPDIR/src"
  run classify_file "$TMPDIR/.codex/config.toml" "$TMPDIR/src" "overwrite"
  [ "$status" -eq 0 ]
  [ "$output" = "drifted_and_updating" ]
}

@test "compute_managed_hash: adopt and classify agree on a codex config carrying trust sections" {
  # adopt_existing_files records the hash an already-present file will later
  # be compared against — both sides must strip [projects.*] identically.
  mkdir -p "$TMPDIR/.codex"
  printf 'model = "m"\n\n[projects."/a"]\ntrust_level = "trusted"\n' > "$TMPDIR/.codex/config.toml"
  printf 'model = "m"\n' > "$TMPDIR/clean"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  local with_trust without_trust
  with_trust=$(compute_managed_hash "$TMPDIR/.codex/config.toml")
  without_trust=$(compute_hash "$TMPDIR/clean")
  [ "$with_trust" = "$without_trust" ]
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

@test "deploy_overwrite_file: creates the destination at 0600" {
  echo hello > "$TMPDIR/src"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  manifest_stage_begin
  deploy_overwrite_file "$TMPDIR/src" "$TMPDIR/out/dest" "label"
  manifest_stage_commit
  [ "$(stat -c '%a' "$TMPDIR/out/dest")" = "600" ]
}

@test "deploy_overwrite_file: narrows a permissive existing destination" {
  echo hello > "$TMPDIR/src"
  echo stale > "$TMPDIR/dest"
  chmod 664 "$TMPDIR/dest"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  manifest_stage_begin
  deploy_overwrite_file "$TMPDIR/src" "$TMPDIR/dest" "label"
  manifest_stage_commit
  # A bare cp preserves 664 here, which is how the credential-bearing skill
  # file ended up group-readable.
  [ "$(stat -c '%a' "$TMPDIR/dest")" = "600" ]
}

@test "deploy_overwrite_file: keeps the executable bit at 0700" {
  printf '#!/bin/sh\n' > "$TMPDIR/src"
  chmod +x "$TMPDIR/src"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  manifest_stage_begin
  deploy_overwrite_file "$TMPDIR/src" "$TMPDIR/dest" "label"
  manifest_stage_commit
  [ "$(stat -c '%a' "$TMPDIR/dest")" = "700" ]
  [ -x "$TMPDIR/dest" ]
}

@test "_backup_file: a backup inherits the restrictive mode" {
  echo secret > "$TMPDIR/dest"
  chmod 600 "$TMPDIR/dest"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run _backup_file "$TMPDIR/dest"
  [ "$status" -eq 0 ]
  local bak; bak=$(ls "$TMPDIR"/dest.bak.* | head -1)
  [ "$(stat -c '%a' "$bak")" = "600" ]
}

@test "_ensure_merge_dest: an empty merge destination is created at 0600" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  _ensure_merge_dest "$TMPDIR/merge/target.json"
  [ "$(stat -c '%a' "$TMPDIR/merge/target.json")" = "600" ]
  [ "$(cat "$TMPDIR/merge/target.json")" = "{}" ]
}

@test "deploy_merge_file: narrows an ALREADY-EXISTING permissive target to 0600" {
  # The atomic-0600 guarantee used to hold only for files _json_merge_into
  # created: its final write was a plain `> "$target"` redirect, which keeps
  # an existing file's mode. So on every machine provisioned before that
  # work, ~/.cursor/mcp.json and ~/.config/opencode/opencode.json — the two
  # most credential-dense deployed files (FIRECRAWL_API_KEY, BRAVE_API_KEY,
  # the MEMORY_ROUTER_TOKEN bearer header) — stayed 664 forever. Start from
  # 664, as those machines are, not from nothing.
  echo '{"userKey":"userValue"}' > "$TMPDIR/dest"
  chmod 664 "$TMPDIR/dest"
  [ "$(stat -c '%a' "$TMPDIR/dest")" = "664" ]   # before
  echo '{"apiKey":"sekret-value"}' > "$TMPDIR/src"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  manifest_stage_begin
  ( umask 0002; deploy_merge_file "$TMPDIR/src" "$TMPDIR/dest" "configs/x" )
  manifest_stage_commit
  [ "$(stat -c '%a' "$TMPDIR/dest")" = "600" ]   # after
  jq -e '.userKey == "userValue"' "$TMPDIR/dest"
  jq -e '.apiKey == "sekret-value"' "$TMPDIR/dest"
}

@test "deploy_merge_file: a first-install copy lands at 0600 under a lax umask" {
  # The absent-target branch of _json_merge_into was a bare `cp`, which
  # creates under the ambient umask (0664 under umask 0002).
  echo '{"apiKey":"sekret-value"}' > "$TMPDIR/src"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  manifest_stage_begin
  ( umask 0002; deploy_merge_file "$TMPDIR/src" "$TMPDIR/fresh/dest.json" "configs/x" )
  manifest_stage_commit
  [ "$(stat -c '%a' "$TMPDIR/fresh/dest.json")" = "600" ]
  jq -e '.apiKey == "sekret-value"' "$TMPDIR/fresh/dest.json"
}

@test "_json_merge_into: leaves no temp file behind in the destination dir" {
  mkdir -p "$TMPDIR/merge"
  echo '{"a":1}' > "$TMPDIR/merge/dest.json"
  echo '{"b":2}' > "$TMPDIR/src"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  _json_merge_into "$TMPDIR/merge/dest.json" "$TMPDIR/src"
  run bash -c "ls -A '$TMPDIR/merge' | grep -c aicoding-deploy"
  [ "$output" = "0" ]
}

@test "_ensure_merge_dest: leaves an existing destination untouched" {
  mkdir -p "$TMPDIR/merge"
  echo '{"k":"v"}' > "$TMPDIR/merge/target.json"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  _ensure_merge_dest "$TMPDIR/merge/target.json"
  jq -e '.k == "v"' "$TMPDIR/merge/target.json"
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

@test "deploy_merge_file: unions 'deny' arrays (sync must not drop user deny rules)" {
  echo '{"permissions":{"deny":["Shell(rm)"],"allow":["a"]}}' > "$TMPDIR/dest"
  echo '{"permissions":{"deny":["Read(**/.aicodingsetup/**)"]}}' > "$TMPDIR/src"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  manifest_stage_begin
  deploy_merge_file "$TMPDIR/src" "$TMPDIR/dest" "configs/example.json"
  manifest_stage_commit
  jq -e '.permissions.deny | sort == ["Read(**/.aicodingsetup/**)","Shell(rm)"]' "$TMPDIR/dest"
  jq -e '.permissions.allow == ["a"]' "$TMPDIR/dest"
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
  if grep -q "old block content" "$TMPDIR/dest"; then false; fi
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

@test "managed_inventory_overwrite: includes global claude CLAUDE.md" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run managed_inventory_overwrite
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "$HOME/.claude/CLAUDE.md|overwrite|configs/claude/CLAUDE.md"
}

@test "managed_inventory_overwrite: includes bw-deny-files hook" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run managed_inventory_overwrite
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "$HOME/.claude/hooks/bw-deny-files.sh|overwrite|configs/claude/hooks/bw-deny-files.sh"
}

@test "managed_inventory_merge: includes cursor mcp.json" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run managed_inventory_merge
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "$HOME/.cursor/mcp.json|merge|configs/cursor/mcp.json"
}

@test "managed_inventory_merge: includes cursor cli-config.json (deny rules)" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run managed_inventory_merge
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "$HOME/.cursor/cli-config.json|merge|configs/cursor/cli-config.json"
}

@test "cursor cli-config fragment: valid JSON, statusLine reuses the claude script" {
  jq -e '.statusLine.type == "command"' "$BLUEPRINT_ROOT/configs/cursor/cli-config.json"
  jq -re '.statusLine.command' "$BLUEPRINT_ROOT/configs/cursor/cli-config.json" \
    | grep -qF '{{HOME}}/.claude/hooks/custom-statusline.js'
}

@test "codex config fragment: carries a [tui] status_line item list" {
  grep -qE '^status_line = \[' "$BLUEPRINT_ROOT/configs/codex/config.toml"
  grep -q 'context-used' "$BLUEPRINT_ROOT/configs/codex/config.toml"
}

@test "codex config fragment: disables the alternate screen (tmux scrollback)" {
  grep -qE '^alternate_screen = "never"' "$BLUEPRINT_ROOT/configs/codex/config.toml"
}

@test "managed_inventory_overwrite: includes bash aliases" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run managed_inventory_overwrite
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "$HOME/.bashrc.d/aicoding-aliases.sh|overwrite|configs/bash/aliases.sh"
}

@test "managed_inventory_overwrite: includes git credential fallback helper" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run managed_inventory_overwrite
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "$HOME/.local/bin/git-credential-aicoding|overwrite|configs/git/git-credential-aicoding"
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

# --- container-local manifest (see: shared-manifest defect) ---------------
# ~/.aicodingsetup is a HOST BIND MOUNT shared by every devpod container, but
# the manifest describes container-local paths (~/.bashrc, ~/.tmux.conf, ...)
# with per-file deployed_hash values. Keeping it there let whichever container
# synced last speak for all of them — which silenced aicoding-status' CTA in
# every other container. The manifest must live on the container filesystem.

@test "manifest default is container-local, not the shared aicodingsetup mount" {
  unset AICODING_MANIFEST
  run bash -c ". '$BLUEPRINT_ROOT/lib/blueprint-deploy.sh'; printf '%s' \"\$AICODING_MANIFEST\""
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  case "$output" in
    */.aicodingsetup/*) echo "manifest still on the shared mount: $output"; return 1 ;;
  esac
  [ "$output" = "$HOME/.local/state/aicoding/manifest.json" ]
}

@test "claude settings fragment: cross-session messaging policy keys" {
  jq -e '.crossSessionInbound == "accept"' "$BLUEPRINT_ROOT/configs/claude/settings.json"
  jq -e '.isolatePeerMachines == true' "$BLUEPRINT_ROOT/configs/claude/settings.json"
}

@test "claude CLAUDE.md fragment: parallel-session coordination protocol" {
  grep -q '^## Parallel-session coordination' "$BLUEPRINT_ROOT/configs/claude/CLAUDE.md"
  grep -q 'gate evidence' "$BLUEPRINT_ROOT/configs/claude/CLAUDE.md"
  grep -q 'dedicated git worktree' "$BLUEPRINT_ROOT/configs/claude/CLAUDE.md"
}

@test "claude CLAUDE.md fragment: retrieval read path goes through memory_search" {
  CM="$BLUEPRINT_ROOT/configs/claude/CLAUDE.md"
  grep -q 'memory_search' "$CM"
  grep -q 'memory-router' "$CM"
  # Fallback and non-blocking clauses must both survive edits.
  grep -q 'grepping the local `~/homelab-wiki` clone' "$CM"
  grep -qi 'rather than blocking' "$CM"
  # The old unconditional "consult the wiki clone first" sentence is gone
  # (it wrapped across two lines, so compare with newlines flattened).
  if tr '\n' ' ' < "$CM" | grep -q 'consult *`~/homelab-wiki` before re-deriving'; then false; fi
}

@test "managed_inventory_overwrite: llmwiki distill hook + distiller agent rows, nudge row gone" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run managed_inventory_overwrite
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "$HOME/.claude/hooks/llmwiki-distill.sh|overwrite|configs/claude/hooks/llmwiki-distill.sh"
  echo "$output" | grep -qF "$HOME/.claude/agents/llmwiki-distiller.md|overwrite|configs/claude/agents/llmwiki-distiller.md"
  if echo "$output" | grep -q 'llmwiki-nudge'; then false; fi
}

@test "claude settings fragment: Stop hook is the async distill launcher" {
  jq -e '.hooks.Stop[0].hooks[0].async == true' "$BLUEPRINT_ROOT/configs/claude/settings.json"
  jq -e '.hooks.Stop[0].hooks[0].timeout == 600' "$BLUEPRINT_ROOT/configs/claude/settings.json"
  jq -re '.hooks.Stop[0].hooks[0].command' "$BLUEPRINT_ROOT/configs/claude/settings.json" \
    | grep -qF '{{HOME}}/.claude/hooks/llmwiki-distill.sh'
  if grep -q 'llmwiki-nudge' "$BLUEPRINT_ROOT/configs/claude/settings.json"; then false; fi
}

@test "manifest_get_profile: defaults to container when manifest absent" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run manifest_get_profile
  [ "$status" -eq 0 ]
  [ "$output" = "container" ]
}

@test "manifest_set_profile then get round-trips host" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  manifest_set_profile host
  run jq -r '.profile' "$AICODING_MANIFEST"
  [ "$output" = "host" ]
  run manifest_get_profile
  [ "$output" = "host" ]
}

@test "manifest_set_profile preserves existing manifest keys" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  manifest_stamp_provision deadbeef
  manifest_set_profile host
  run jq -r '.provision_commit' "$AICODING_MANIFEST"
  [ "$output" = "deadbeef" ]
}

@test "manifest_get_profile: AICODING_PROFILE env overrides manifest" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  manifest_set_profile container
  AICODING_PROFILE=host run manifest_get_profile
  [ "$output" = "host" ]
}

@test "inventories: container profile output is unchanged (no boot-sync, has tmux/codex/cursor)" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run managed_inventory_overwrite
  [[ "$output" == *"/.tmux.conf|"* ]]
  [[ "$output" == *"aicoding-ssh-auth-sock.sh|"* ]]
  [[ "$output" == *"/.codex/config.toml|"* ]]
  [[ "$output" != *"aicoding-boot-sync.sh"* ]]
  run managed_inventory_merge
  [[ "$output" == *"opencode.json|"* ]]
  [[ "$output" == *"/.cursor/mcp.json|"* ]]
}

@test "inventories: host profile drops container-only wiring, keeps agent CLI configs" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  export AICODING_PROFILE=host
  run managed_inventory_overwrite
  # tmux/ssh-agent wiring is container-only; boot-sync is host-only.
  [[ "$output" != *"/.tmux.conf|"* ]]
  [[ "$output" != *"aicoding-ssh-auth-sock.sh|"* ]]
  [[ "$output" == *"$HOME/.bashrc.d/aicoding-boot-sync.sh|overwrite|configs/bash/boot-sync.sh"* ]]
  [[ "$output" == *"/.claude/CLAUDE.md|"* ]]
  # Agent CLI configs are managed on hosts too (user decision 2026-08-19).
  [[ "$output" == *"/.codex/config.toml|"* ]]
  [[ "$output" == *"/.codex/AGENTS.md|"* ]]
  run managed_inventory_merge
  [[ "$output" == *"/.claude/settings.json|"* ]]
  [[ "$output" == *"opencode.json|"* ]]
  [[ "$output" == *"/.cursor/mcp.json|"* ]]
  [[ "$output" == *"/.cursor/cli-config.json|"* ]]
  unset AICODING_PROFILE
}

@test "enumerate_skill_files: lists nested files relative to root, sorted" {
  mkdir -p "$TMPDIR/skills/b-skill/assets" "$TMPDIR/skills/a-skill"
  echo x > "$TMPDIR/skills/a-skill/SKILL.md"
  echo y > "$TMPDIR/skills/b-skill/SKILL.md"
  echo z > "$TMPDIR/skills/b-skill/assets/logo.png"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run enumerate_skill_files "$TMPDIR/skills"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "a-skill/SKILL.md" ]
  [ "${lines[1]}" = "b-skill/SKILL.md" ]
  [ "${lines[2]}" = "b-skill/assets/logo.png" ]
}

@test "enumerate_skill_files: empty for missing root" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run enumerate_skill_files "$TMPDIR/no-such-dir"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "classify_file: overwrite_raw does not substitute placeholders" {
  printf 'binary-ish {{HOME}} content' > "$TMPDIR/src"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  manifest_stage_begin
  deploy_overwrite_file "$TMPDIR/src" "$TMPDIR/dest" "skills/x/a.png"
  manifest_stage_commit
  run classify_file "$TMPDIR/dest" "$TMPDIR/src" overwrite_raw
  [ "$status" -eq 0 ]
  [ "$output" = "up_to_date" ]
  cmp -s "$TMPDIR/src" "$TMPDIR/dest"
}

@test "classify_file: overwrite (substituted) sees drift for same placeholder file" {
  printf 'binary-ish {{HOME}} content' > "$TMPDIR/src"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  manifest_stage_begin
  deploy_overwrite_file "$TMPDIR/src" "$TMPDIR/dest" "skills/x/a.png"
  manifest_stage_commit
  run classify_file "$TMPDIR/dest" "$TMPDIR/src" overwrite
  [ "$status" -eq 0 ]
  [ "$output" = "will_update" ]
}

@test "_apply_deploy: overwrite_raw copies bytes verbatim" {
  printf 'raw {{HOME}} bytes' > "$TMPDIR/clone-src"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  declare -A FILE_SOURCE
  FILE_SOURCE[$TMPDIR/dest]="skills/x/a.png"
  manifest_stage_begin
  _apply_deploy overwrite_raw "$TMPDIR/dest" "$TMPDIR/clone-src"
  manifest_stage_commit
  cmp -s "$TMPDIR/clone-src" "$TMPDIR/dest"
}

@test "_incoming_matches_dest: overwrite_raw compares raw bytes" {
  printf 'raw {{HOME}} bytes' > "$TMPDIR/src"
  printf 'raw {{HOME}} bytes' > "$TMPDIR/dest"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run _incoming_matches_dest overwrite_raw "$TMPDIR/src" "$TMPDIR/dest"
  [ "$status" -eq 0 ]
  printf 'different' > "$TMPDIR/dest"
  run _incoming_matches_dest overwrite_raw "$TMPDIR/src" "$TMPDIR/dest"
  [ "$status" -ne 0 ]
}

@test "classify_managed_files: inventories every skill file with per-mode routing" {
  export AICODING_BLUEPRINT_CLONE="$TMPDIR/clone"
  mkdir -p "$AICODING_BLUEPRINT_CLONE/skills/demo/assets"
  echo '# demo' > "$AICODING_BLUEPRINT_CLONE/skills/demo/SKILL.md"
  printf 'png {{HOME}} bytes' > "$AICODING_BLUEPRINT_CLONE/skills/demo/assets/logo.png"
  echo '{"schema_version":1,"files":{}}' > "$AICODING_MANIFEST"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  declare -gA BUCKETS FILE_MODE FILE_SOURCE
  classify_managed_files
  [ "${FILE_MODE[$HOME/.claude/skills/demo/SKILL.md]}" = "overwrite" ]
  [ "${FILE_MODE[$HOME/.claude/skills/demo/assets/logo.png]}" = "overwrite_raw" ]
  [ "${FILE_SOURCE[$HOME/.claude/skills/demo/assets/logo.png]}" = "skills/demo/assets/logo.png" ]
  [ "${BUCKETS[$HOME/.claude/skills/demo/assets/logo.png]}" = "new_file" ]

  # Apply and verify the binary lands verbatim while SKILL.md is substituted.
  manifest_stage_begin
  apply_managed_buckets "new_file"
  manifest_stage_commit
  cmp -s "$AICODING_BLUEPRINT_CLONE/skills/demo/assets/logo.png" "$HOME/.claude/skills/demo/assets/logo.png"

  # Re-classify: everything up_to_date (idempotent, no phantom drift).
  declare -gA BUCKETS2 FILE_MODE2
  BUCKETS=() ; FILE_MODE=() ; FILE_SOURCE=()
  classify_managed_files
  [ "${BUCKETS[$HOME/.claude/skills/demo/assets/logo.png]}" = "up_to_date" ]
  [ "${BUCKETS[$HOME/.claude/skills/demo/SKILL.md]}" = "up_to_date" ]
}
