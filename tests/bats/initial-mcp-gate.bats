#!/usr/bin/env bats

setup() {
  : "${BLUEPRINT_ROOT:?run via tests/bats/run.sh}"
  TEST_ROOT=$(mktemp -d)
  export HOME="$TEST_ROOT/home" SCRIPT_DIR="$TEST_ROOT/source"
  export AICODING_BLUEPRINT_CLONE="$SCRIPT_DIR"
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
  header() { :; }
  ok() { :; }
  info() { :; }
  warn() { printf '%s\n' "$*" >> "$TEST_ROOT/warnings"; }
  managed_retired_files() { :; }
  managed_inventory() {
    printf '%s|raw|%s\n' "$HOME/safe" configs/safe
    printf '%s|raw|%s\n' "$HOME/.codex/config.toml" configs/codex
    printf '%s|raw|%s\n' "$HOME/.claude/settings.json" configs/claude
  }
  aicoding_config_is_compatible() {
    [ "$1" = "$HOME/safe" ] || [ "$1" = "$HOME/.codex/config.toml" ]
  }
}

teardown() { rm -rf "$TEST_ROOT"; }

@test "first deployment preserves MCP-dependent config until its exact runtime is ready" {
  install_managed_config

  [ "$(cat "$HOME/safe")" = safe ]
  [ "$(cat "$HOME/.codex/config.toml")" = codex ]
  [ "$(cat "$HOME/.claude/settings.json")" = '{"personal":true}' ]
  grep -q 'runtime is not ready' "$TEST_ROOT/warnings"
  [ "$_AICODING_INITIAL_CONFIG_DEFERRED" = 1 ]
  [ ! -e "$AICODING_STATE_DIR/blueprint_commit" ]
}

@test "an incompatible existing config is left untouched and defers the install" {
  printf 'personal-codex\n' > "$HOME/.codex/config.toml"
  aicoding_config_is_compatible() { [ "$1" = "$HOME/safe" ]; }

  install_managed_config

  [ "$(cat "$HOME/.codex/config.toml")" = personal-codex ]
  [ "${MANAGED_RESULT[$HOME/.codex/config.toml]}" = blocked:runtime_compatibility_unavailable ]
  [ "$_AICODING_INITIAL_CONFIG_DEFERRED" = 1 ]
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

@test "exact MCP config readiness does not wait for the retired Kanban launcher" {
  _load_real_compatibility_guard
  _record_exact_mcp_receipts
  _aicoding_active_kanban_mcp_valid() { return 1; }
  run aicoding_exact_mcp_config_ready "$HOME/.codex/config.toml"
  [ "$status" -eq 0 ]
}

@test "managed Kanban MCP entries name only the hosted endpoint and a bearer placeholder" {
  run python3 - "$BLUEPRINT_ROOT/configs/codex/config.toml" <<'PY2'
import sys, tomllib
entry = tomllib.load(open(sys.argv[1], "rb"))["mcp_servers"]["kanban"]
assert entry == {
    "url": "https://kanban.dataprospectors.at/mcp",
    "http_headers": {"Authorization": "Bearer {{KANBAN_TOKEN}}"},
    "required": False,
}, entry
PY2
  [ "$status" -eq 0 ]
  jq -e '.mcpServers.kanban == {"url":"https://kanban.dataprospectors.at/mcp","headers":{"Authorization":"Bearer {{KANBAN_TOKEN}}"}}' \
    "$BLUEPRINT_ROOT/configs/cursor/mcp.json"
  jq -e '.mcp.kanban == {"type":"remote","url":"https://kanban.dataprospectors.at/mcp","headers":{"Authorization":"Bearer {{KANBAN_TOKEN}}"},"oauth":false,"enabled":true}' \
    "$BLUEPRINT_ROOT/configs/opencode/opencode.json"
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
    grep -Fq 'the canonical workflow. Native lifecycle hooks register the session' "$guidance"
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
