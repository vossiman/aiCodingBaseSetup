#!/usr/bin/env bats
setup() {
  : "${BLUEPRINT_ROOT:?run via tests/bats/run.sh}"
  export TMP; TMP=$(mktemp -d)
  export HOME="$TMP/home" AICODING_STATE_DIR="$TMP/state"
  mkdir -p "$HOME"
  . "$BLUEPRINT_ROOT/lib/sync.sh"
  . "$BLUEPRINT_ROOT/lib/update-results.sh"
  . "$BLUEPRINT_ROOT/lib/update-components.sh"
  declare -gA MANAGED_RESULT=() _SYNC_DEFERRED_PROVISION_COMPONENTS=()
  _SYNC_PASS_DEFERRED=0
  target=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  first="$HOME/.claude/settings.json"
  second="$HOME/.claude/CLAUDE.md"
  aicoding_result_record config-claude conflict old managed_config_conflict
}
teardown() { rm -rf "$TMP"; }

state() { jq -r --arg c "$1" '.components[$c] | "\(.state) \(.reason)"' "$AICODING_RESULTS_FILE"; }

@test "a clean pass replaces an old conflict receipt with verified current" {
  MANAGED_RESULT[$first]=unchanged
  MANAGED_RESULT[$second]=updated
  _sync_record_config_results "$target"
  [ "$(state config-claude)" = "current reconciliation_verified" ]
  [ "$(state config)" = "current applied" ]
  [ "${#_SYNC_DEFERRED_PROVISION_COMPONENTS[@]}" -eq 0 ]
  [ "$_SYNC_PASS_DEFERRED" -eq 0 ]
}

@test "every destination of a component must be current before it recovers" {
  MANAGED_RESULT[$first]=unchanged
  MANAGED_RESULT[$second]=blocked:claude_update_not_verified
  _sync_record_config_results "$target"
  [ "$(state config-claude)" = "blocked claude_update_not_verified" ]
  [ "$(state config)" = "blocked partial_config_blocked" ]
  [ "${_SYNC_DEFERRED_PROVISION_COMPONENTS[claude]}" = 1 ]
  [ "$_SYNC_PASS_DEFERRED" -eq 1 ]
}

@test "a failed write outranks blocked and malformed destinations" {
  MANAGED_RESULT[$first]=malformed
  MANAGED_RESULT[$second]=failed
  MANAGED_RESULT[$HOME/.claude/hooks/x.sh]=blocked:claude_not_installed
  _sync_record_config_results "$target"
  [ "$(state config-claude)" = "failed managed_config_apply_failed" ]
  [ "$(state config)" = "failed managed_config_apply_failed" ]
}

@test "held shared files defer that harness's shared provisioning but stay current" {
  MANAGED_RESULT[$first]=held
  MANAGED_RESULT[$HOME/.codex/config.toml]=held
  _sync_record_config_results "$target"
  [ "$(state config-claude)" = "current reconciliation_verified" ]
  [ "${_SYNC_DEFERRED_PROVISION_COMPONENTS[claude]}" = 1 ]
  [ "${_SYNC_DEFERRED_PROVISION_COMPONENTS[codex]}" = 1 ]
}

@test "a malformed file is reported without deferring provisioning" {
  MANAGED_RESULT[$first]=malformed
  _sync_record_config_results "$target"
  [ "$(state config-claude)" = "blocked managed_config_malformed" ]
  [ "${#_SYNC_DEFERRED_PROVISION_COMPONENTS[@]}" -eq 0 ]
  [ "$_SYNC_PASS_DEFERRED" -eq 0 ]
}

@test "a component with no destination this pass keeps its receipt" {
  aicoding_result_record config-codex blocked old codex_not_installed
  MANAGED_RESULT[$first]=unchanged
  _sync_record_config_results "$target"
  [ "$(state config-codex)" = "blocked codex_not_installed" ]
}

@test "a blocked config receipt carries the MCP staging cause as its detail" {
  aicoding_exact_mcp_config_cause() { echo "mcp-context7: blocked exact_package_not_staged"; return 1; }
  MANAGED_RESULT[$first]=blocked:mcp_exact_version_staging_unavailable
  _sync_record_config_results "$target"
  jq -e '.components["config-claude"].detail == "mcp-context7: blocked exact_package_not_staged"' "$AICODING_RESULTS_FILE"
}

@test "an MCP staging cause never replaces another destination's reason" {
  MANAGED_RESULT[$first]=blocked:mcp_exact_version_staging_unavailable
  MANAGED_RESULT[$second]=blocked:claude_update_not_verified
  _sync_record_config_results "$target"
  [ "$(state config-claude)" = "blocked claude_update_not_verified" ]
}
