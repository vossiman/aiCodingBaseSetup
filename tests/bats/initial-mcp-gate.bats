#!/usr/bin/env bats

setup() {
  : "${BLUEPRINT_ROOT:?run via tests/bats/run.sh}"
  TEST_ROOT=$(mktemp -d)
  export HOME="$TEST_ROOT/home" SCRIPT_DIR="$TEST_ROOT/source"
  export CLAUDE_DIR="$HOME/.claude" AICODING_REQUIRE_UPDATE_RECEIPT=1
  export AICODING_STATE_DIR="$TEST_ROOT/state" AICODING_DATA_DIR="$TEST_ROOT/data"
  mkdir -p "$SCRIPT_DIR/configs" "$SCRIPT_DIR/skills" "$SCRIPT_DIR/commands" \
    "$HOME/.claude" "$HOME/.codex"
  printf 'safe\n' > "$SCRIPT_DIR/configs/safe"
  printf 'codex\n' > "$SCRIPT_DIR/configs/codex"
  printf '{"managed":true}\n' > "$SCRIPT_DIR/configs/claude"
  printf '{"personal":true}\n' > "$HOME/.claude/settings.json"

  # The initial helper classifies every destination and locks shared roots
  # before checking runtime compatibility, just as installer main does.
  unset AICODING_SHARED_CONFIG_ROOTS _AICODING_INSTALL_SHARED_LOCKS_READY
  source "$BLUEPRINT_ROOT/lib/runtime.sh"
  source "$BLUEPRINT_ROOT/lib/update-components.sh"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  source "$BLUEPRINT_ROOT/lib/provision-managed-files.sh"
  manifest_stage_begin() { :; }
  manifest_stage_commit() { :; }
  manifest_stage_set_blueprint() { :; }
  manifest_set_file() { printf '%s\n' "$1" >> "$TEST_ROOT/manifest-files"; }
  deploy_marker_block() { :; }
  managed_bashrc_block_body() { :; }
  compute_managed_hash() { printf hash; }
  enumerate_skill_files() { :; }
  blueprint_origin() { echo test; }
  ok() { :; }
  info() { :; }
  BASHRC_BLOCK_START='# start'; BASHRC_BLOCK_END='# end'
  warn() { printf '%s\n' "$*" >> "$TEST_ROOT/warnings"; }
  managed_inventory_overwrite() {
    printf '%s|overwrite|%s\n' "$HOME/safe" configs/safe
    printf '%s|overwrite|%s\n' "$HOME/.codex/config.toml" configs/codex
  }
  managed_inventory_merge() {
    printf '%s|merge|%s\n' "$HOME/.claude/settings.json" configs/claude
  }
  deploy_overwrite_file_rendered() { cp "$1" "$2"; }
  _ensure_merge_dest() { :; }
  deploy_merge_file_substituted() { cp "$1" "$2"; }
  aicoding_config_is_compatible() {
    [ "$1" = "$HOME/safe" ] || [ "$1" = "$HOME/.codex/config.toml" ]
  }
}

teardown() { rm -rf "$TEST_ROOT"; }

@test "first deployment preserves MCP-dependent config until its exact runtime is ready" {
  deploy_all_managed_files

  [ "$(cat "$HOME/safe")" = safe ]
  [ "$(cat "$HOME/.codex/config.toml")" = codex ]
  [ "$(cat "$HOME/.claude/settings.json")" = '{"personal":true}' ]
  grep -q 'runtime is not ready' "$TEST_ROOT/warnings"
  [ "$_AICODING_INITIAL_CONFIG_DEFERRED" = 1 ]
}

@test "adopt preserves incompatible existing config without recording it as applied" {
  printf 'personal-codex\n' > "$HOME/.codex/config.toml"
  aicoding_config_is_compatible() { [ "$1" = "$HOME/safe" ]; }

  adopt_existing_files

  [ "$(cat "$HOME/.codex/config.toml")" = personal-codex ]
  if grep -Fxq "$HOME/.codex/config.toml" "$TEST_ROOT/manifest-files" 2>/dev/null; then false; fi
  [ "$_AICODING_INITIAL_CONFIG_DEFERRED" = 1 ]
}

@test "persistent reconcile blocks ordinary and smart incompatible destinations before apply" {
  classify_managed_files() {
    BUCKETS["$HOME/.codex/config.toml"]=$TEST_BUCKET
    FILE_MODE["$HOME/.codex/config.toml"]=overwrite
    FILE_SOURCE["$HOME/.codex/config.toml"]=configs/codex
  }
  _is_owned_overwrite() { return 1; }
  apply_managed_buckets() {
    local dest="$HOME/.codex/config.toml"
    printf '%s\n' "${BUCKETS[$dest]}" > "$TEST_ROOT/applied-bucket"
  }
  aicoding_config_is_compatible() { echo codex_update_not_verified; return 1; }

  local TEST_BUCKET
  for TEST_BUCKET in will_update smart_conflict; do
    : > "$TEST_ROOT/applied-bucket"
    _AICODING_INITIAL_CONFIG_DEFERRED=0
    reconcile_existing_install
    [ "$(cat "$TEST_ROOT/applied-bucket")" = blocked ]
    [ "$_AICODING_INITIAL_CONFIG_DEFERRED" = 1 ]
  done
}

@test "persistent container and host enrollment prepare exact MCPs before deployment" {
  for installer in install.sh install-host.sh; do
    grep -q 'aicoding_prepare_installed_config_tools' "$BLUEPRINT_ROOT/$installer"
    grep -q 'aicoding_prepare_exact_mcps --register-claude' "$BLUEPRINT_ROOT/$installer"
    grep -q 'Required provisioning is incomplete' "$BLUEPRINT_ROOT/$installer"
  done
  grep -q 'AICODING_PERSISTENT_ENROLLMENT=1' "$BLUEPRINT_ROOT/bin/aicoding-install"
}

_load_real_compatibility_guard() {
  unset -f aicoding_config_is_compatible
  aicoding_activate_version() { :; }
  source "$BLUEPRINT_ROOT/lib/update-results.sh"
  source "$BLUEPRINT_ROOT/lib/update-components.sh"
  _aicoding_active_kanban_mcp_valid() { return 0; }
  mkdir -p "$TEST_ROOT/bin"
  export PATH="$TEST_ROOT/bin:/usr/bin:/bin"
}

_record_exact_mcp_receipts() {
  local component
  for component in mcp-context7 mcp-playwright mcp-kanban; do
    aicoding_result_record "$component" current 1.0.0 installed 1.0.0
  done
}

@test "first deployment defers Codex config when the verified tool is too old" {
  _load_real_compatibility_guard
  cat > "$TEST_ROOT/bin/codex" <<'EOF'
#!/bin/sh
echo 'codex-cli 0.130.0'
EOF
  chmod +x "$TEST_ROOT/bin/codex"
  aicoding_result_record codex current 0.130.0 installed 0.130.0
  _record_exact_mcp_receipts

  run _aicoding_initial_config_ready "$HOME/.codex/config.toml"
  [ "$status" -ne 0 ]
  grep -q 'codex_requires_0.148' "$TEST_ROOT/warnings"
}

@test "first deployment requires shared Claude consumer evidence" {
  _load_real_compatibility_guard
  cat > "$TEST_ROOT/bin/claude" <<'EOF'
#!/bin/sh
echo '2.1.50 (Claude Code)'
EOF
  chmod +x "$TEST_ROOT/bin/claude"
  mkdir -p "$HOME/.claude"
  local shared_root expires
  shared_root=$(readlink -f "$HOME/.claude")
  expires=$(( $(date +%s) + 3600 ))
  export AICODING_SHARED_CONFIG_ROOTS="$shared_root"
  export AICODING_SHARED_CONSUMERS_FILE="$TEST_ROOT/consumers.json"
  jq -n --arg root "$shared_root" --argjson expires "$expires" '{schema:1,roots:[{
    shared_root:$root,inventory_complete:true,expires_at:$expires,consumers:[{
      id:"known",components:{
        "mcp-context7":{version:"1.0.0",config_compatible:true},
        "mcp-playwright":{version:"1.0.0",config_compatible:true},
        "mcp-kanban":{version:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",config_compatible:true}
      }
    }]
  }]}' > "$AICODING_SHARED_CONSUMERS_FILE"
  aicoding_result_record claude current 2.1.50 installed 2.1.50
  _record_exact_mcp_receipts
  local component
  for component in mcp-registration-claude-context7 mcp-registration-claude-playwright \
      mcp-registration-claude-kanban; do
    aicoding_result_record "$component" current 1.0.0 registration_verified 1.0.0
  done

  run _aicoding_initial_config_ready "$HOME/.claude/settings.json"
  [ "$status" -ne 0 ]
  grep -q 'claude_shared_consumers_incompatible' "$TEST_ROOT/warnings"
}

@test "exact MCP config readiness requires the immutable Kanban launcher" {
  _load_real_compatibility_guard
  _record_exact_mcp_receipts
  _aicoding_active_kanban_mcp_valid() { return 1; }
  run aicoding_exact_mcp_config_ready "$HOME/.codex/config.toml"
  [ "$status" -ne 0 ]

  _aicoding_active_kanban_mcp_valid() { return 0; }
  run aicoding_exact_mcp_config_ready "$HOME/.codex/config.toml"
  [ "$status" -eq 0 ]
}

@test "managed Kanban MCP entries contain only the local command" {
  grep -A2 '^\[mcp_servers\.kanban\]$' "$BLUEPRINT_ROOT/configs/codex/config.toml" \
    | grep -Fxq 'command = "kanban-mcp"'
  jq -e '.mcpServers.kanban == {"command":"kanban-mcp"}' \
    "$BLUEPRINT_ROOT/configs/cursor/mcp.json"
  jq -e '.mcp.kanban == {"type":"local","command":["kanban-mcp"],"enabled":true}' \
    "$BLUEPRINT_ROOT/configs/opencode/opencode.json"
  local entry
  entry=$(sed -n '/^\[mcp_servers\.kanban\]$/,/^\[/p' "$BLUEPRINT_ROOT/configs/codex/config.toml")
  entry+=$(jq -c '.mcpServers.kanban' "$BLUEPRINT_ROOT/configs/cursor/mcp.json")
  entry+=$(jq -c '.mcp.kanban' "$BLUEPRINT_ROOT/configs/opencode/opencode.json")
  if printf '%s' "$entry" | grep -Eqi \
      'KANBAN_TOKEN|Authorization|secret|/checkout|github\.com|https?://|dataprospectors'; then
    false
  fi
}

@test "relocated pinned Kanban MCP passes the real SDK 2.2 protocol contract" {
  local source_release=${AICODING_KANBAN_PROTOCOL_RELEASE:-}
  [ -n "$source_release" ] || skip \
    "set AICODING_KANBAN_PROTOCOL_RELEASE to a reviewed retained release; offline tests never download it"
  [ -d "$source_release" ] || {
    echo "AICODING_KANBAN_PROTOCOL_RELEASE is not a directory: $source_release" >&2
    false
  }
  local revision relocated
  revision=$(cat "$BLUEPRINT_ROOT/configs/versions/kanban-mcp.rev")
  _aicoding_kanban_release_valid "$source_release" "$revision" || {
    echo "supplied protocol release is not an integrity-checked physical tree for the pinned revision" >&2
    false
  }
  relocated="$AICODING_DATA_DIR/versions/mcp-kanban/$revision"
  mkdir -p "$(dirname "$relocated")"
  cp -a "$source_release" "$relocated"
  _aicoding_kanban_release_valid "$relocated" "$revision"

  run "$relocated/.venv/bin/python" -B \
    "$BLUEPRINT_ROOT/tests/helpers/verify-kanban-mcp-protocol.py" \
    "$relocated/.venv/bin/kanban-mcp"

  [ "$status" -eq 0 ]
  [[ "$output" == *'legacy: protocol/read/instructions/isError PASS'* ]]
  [[ "$output" == *'default-v2: protocol/read/instructions/isError PASS'* ]]
  _aicoding_release_integrity_valid "$relocated"

  source "$BLUEPRINT_ROOT/lib/update-results.sh"
  export AICODINGSETUP_SKIP_NETWORK=1
  AICODING_MCP_REGISTRATION_DISABLE=1 run aicoding_update_component mcp-kanban
  [ "$status" -eq 0 ]
  [ "$("$HOME/.local/bin/kanban-mcp" --version)" = 'kanban-mcp 0.1.0' ]
  jq -e '.components["mcp-kanban"].state == "updated"
    and .components["mcp-kanban"].reason == "installed"' "$AICODING_RESULTS_FILE"
}

@test "managed agent guidance points to canonical MCP instructions without copied lifecycle commands" {
  local guidance
  for guidance in \
      "$BLUEPRINT_ROOT/configs/claude/CLAUDE.md" \
      "$BLUEPRINT_ROOT/configs/codex/AGENTS.md" \
      "$BLUEPRINT_ROOT/configs/cursor/skills/aicoding-estate/SKILL.md"; do
    grep -Fq 'the canonical workflow. Native lifecycle adapters bind' "$guidance"
    grep -Fq 'credential-safe recovery CLI; it is not a status-transition bypass.' "$guidance"
    if grep -Eq 'kanban-post --(patch|done|link)|POST[[:space:]]+/api/work|PATCH[[:space:]]+/api/tickets' "$guidance"; then
      false
    fi
  done
  grep -Fq '["--json", "instructions"]' \
    "$BLUEPRINT_ROOT/configs/opencode/plugins/kanban-work.js"
}

@test "all Cursor and Pi managed destinations use the initial compatibility guard" {
  local seen="$TEST_ROOT/seen"
  aicoding_config_is_compatible() { printf '%s\n' "$1" >> "$seen"; echo deferred; return 1; }
  local dest
  for dest in "$HOME/.cursor/mcp.json" "$HOME/.cursor/cli-config.json" \
      "$HOME/.cursor/hooks.json" "$HOME/.pi/agent/extensions/bw-deny-files.ts"; do
    run _aicoding_initial_config_ready "$dest"
    [ "$status" -ne 0 ]
  done
  grep -Fxq "$HOME/.cursor/mcp.json" "$seen"
  grep -Fxq "$HOME/.cursor/cli-config.json" "$seen"
  grep -Fxq "$HOME/.cursor/hooks.json" "$seen"
  grep -Fxq "$HOME/.pi/agent/extensions/bw-deny-files.ts" "$seen"
}

@test "required preparation failure is retained as a partial receipt" {
  source "$BLUEPRINT_ROOT/lib/provision.sh"
  aicoding_installed_components() { printf 'claude\ncursor\n'; }
  aicoding_update_component() {
    [ "$1" != claude ] || { aicoding_result_record claude failed 2.1.51 stage_install_failed; return 1; }
  }
  _provision_ensure_update_components() { return 0; }
  source "$BLUEPRINT_ROOT/lib/update-results.sh"

  run aicoding_prepare_installed_config_tools
  [ "$status" -ne 0 ]
  jq -e '.components.claude.state == "failed" and .components.cursor == null' \
    "$AICODING_RESULTS_FILE"
}

@test "Gitless immutable source records its full version in the manifest" {
  local sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  printf '%s\n' "$sha" > "$SCRIPT_DIR/.aicoding-version"
  run _aicoding_managed_source_version "$SCRIPT_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "$sha" ]
}
