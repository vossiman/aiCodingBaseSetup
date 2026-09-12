#!/usr/bin/env bats
setup() {
  : "${BLUEPRINT_ROOT:?run via tests/bats/run.sh}"
  export TMP; TMP=$(mktemp -d)
  export HOME="$TMP/home" AICODING_STATE_DIR="$TMP/state"
  mkdir -p "$HOME"
  . "$BLUEPRINT_ROOT/lib/sync.sh"
  . "$BLUEPRINT_ROOT/lib/update-results.sh"
  . "$BLUEPRINT_ROOT/lib/update-components.sh"
  declare -gA BUCKETS=() FILE_MODE=() APPLY_FAILURES=() SMART_APPLY_RESULT=() SMART_PLAN=() blocked_reasons=()
  target=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  first="$HOME/.claude/settings.json"
  second="$HOME/.claude/CLAUDE.md"
  aicoding_result_record config-claude blocked old mcp_exact_version_staging_unavailable
}
teardown() { rm -rf "$TMP"; }

@test "all destinations sharing a config receipt must recover before superseding its block" {
  BUCKETS[$first]=up_to_date
  BUCKETS[$second]=blocked
  blocked_reasons[config-claude]=mcp_exact_version_staging_unavailable
  _sync_record_config_results "$target" ''
  jq -e '.components["config-claude"].state == "blocked"' "$AICODING_RESULTS_FILE"
  BUCKETS[$second]=up_to_date
  _sync_record_config_results "$target" ''
  jq -e --arg target "$target" '.components["config-claude"] | .state == "current" and .reason == "reconciliation_verified" and .successful_version == $target and .succeeded_at != null' "$AICODING_RESULTS_FILE"
}

@test "a recovered component does not clear an absent component or unrelated failure" {
  aicoding_result_record config-codex blocked old staging_unavailable
  aicoding_result_record dvw failed old validation_failed
  BUCKETS[$first]=up_to_date
  _sync_record_config_results "$target" ''
  jq -e '.components["config-claude"].state == "current" and .components["config-codex"].state == "blocked" and .components.dvw.state == "failed"' "$AICODING_RESULTS_FILE"
}

@test "one failed destination overrides successful applies sharing its component" {
  BUCKETS[$first]=will_update
  BUCKETS[$second]=will_update
  APPLY_FAILURES[$second]=1
  _sync_record_config_results "$target" 'will_update'
  jq -e '.components["config-claude"].state == "failed" and .components["config-claude"].reason == "managed_config_apply_failed"' "$AICODING_RESULTS_FILE"
}

@test "preserved conflicts remain conflicts even when another destination recovers" {
  BUCKETS[$first]=up_to_date
  BUCKETS[$second]=drifted_and_updating
  _sync_record_config_results "$target" 'will_update'
  jq -e '.components["config-claude"].state == "conflict"' "$AICODING_RESULTS_FILE"
}

@test "pending or unknown destinations provide no evidence of complete recovery" {
  BUCKETS[$first]=up_to_date
  BUCKETS[$second]=will_update
  _sync_record_config_results "$target" ''
  jq -e '.components["config-claude"].state == "blocked"' "$AICODING_RESULTS_FILE"
}

@test "smart conflicts and errors supersede stale compatibility reasons without claiming recovery" {
  first="$HOME/.codex/config.toml"
  BUCKETS=([$first]=smart_conflict)
  SMART_APPLY_RESULT[$first]='{"conflicts":[{"path":["model"]}]}'
  _sync_record_config_results "$target" 'smart_conflict'
  jq -e '.components["config-codex"].state == "conflict"' "$AICODING_RESULTS_FILE"
  SMART_APPLY_RESULT[$first]='{"error":{"code":"fixture_failure"}}'
  _sync_record_config_results "$target" 'smart_conflict'
  jq -e '.components["config-codex"].state == "failed"' "$AICODING_RESULTS_FILE"
}

_recovery_blueprint() {
  export AICODING_BLUEPRINT_CLONE="$TMP/blueprint" AICODING_BLUEPRINT_LOCAL=1 _SYNC_REFRESHED=1
  export AICODING_MANIFEST="$TMP/manifest.json"
  mkdir -p "$AICODING_BLUEPRINT_CLONE/lib"
  # Use a minimal controlled inventory; reconciliation and receipts remain real.
  # Override shared locks, secrets loading and manifest writes in this fixture.
  cat > "$AICODING_BLUEPRINT_CLONE/lib/blueprint-deploy.sh" <<'STUB'
load_secrets_env() { :; }
manifest_check_schema() { :; }
aicoding_shared_locks_acquire_managed_roots() { :; }
classify_managed_files() {
  BUCKETS["$HOME/.claude/settings.json"]=up_to_date
  BUCKETS["$HOME/.claude/CLAUDE.md"]=up_to_date
  BUCKETS["$HOME/.cursor/mcp.json"]=up_to_date
}
manifest_stage_begin() { :; }
manifest_stage_set_blueprint() { printf '%s\n' "$1" > "$AICODING_MANIFEST.stamp"; }
manifest_stage_commit() { [ "${FAIL_MANIFEST:-0}" = 0 ]; }
blueprint_origin() { echo fixture; }
STUB
  printf '%s\n' "$target" > "$AICODING_BLUEPRINT_CLONE/.aicoding-version"
  printf '{"schema_version":1,"files":{},"blueprint_commit":"old"}\n' > "$AICODING_MANIFEST"
  aicoding_config_is_compatible() {
    if [[ "$1" == "${BLOCK_DEST:-}" ]]; then echo prerequisite_unverified; return 1; fi
  }
}

@test "no-op reconciliation rechecks compatibility before recovering all destinations" {
  _recovery_blueprint
  export BLOCK_DEST="$second"
  run _sync_reconcile boot
  [ "$status" -eq 0 ]
  jq -e '.components["config-claude"].state == "blocked" and .components["config-cursor"].state == "current"' "$AICODING_RESULTS_FILE"
  unset BLOCK_DEST
  run _sync_reconcile boot
  [ "$status" -eq 0 ]
  jq -e '.components["config-claude"].state == "current" and .components.config.state == "current"' "$AICODING_RESULTS_FILE"
}

@test "failed manifest persistence does not supersede the previous config blocker" {
  _recovery_blueprint
  export FAIL_MANIFEST=1
  run _sync_reconcile boot
  [ "$status" -ne 0 ]
  jq -e '.components["config-claude"].state == "blocked" and .components.config.reason == "manifest_write_failed"' "$AICODING_RESULTS_FILE"
}

@test "unchanged config without an unresolved receipt does not create a new update deferral" {
  _recovery_blueprint
  aicoding_result_record config-claude current old reconciliation_verified old
  export BLOCK_DEST="$first"
  run _sync_reconcile boot
  [ "$status" -eq 0 ]
  jq -e '.components.config.state == "current" and .components["config-claude"].state == "current"' "$AICODING_RESULTS_FILE"
}

@test "unmanaged smart destinations do not supersede a config blocker when ordinary buckets are allowed" {
  first="$HOME/.codex/config.toml"
  aicoding_result_record config-codex blocked old staging_unavailable
  BUCKETS=([$first]=new_file_existing)
  FILE_MODE[$first]=toml_merge
  SMART_APPLY_RESULT[$first]='{"conflicts":[],"error":null,"unmanaged":true,"applied":false}'
  _sync_record_config_results "$target" 'new_file_existing'
  jq -e '.components["config-codex"].state == "blocked"' "$AICODING_RESULTS_FILE"
  SMART_APPLY_RESULT[$first]='{"conflicts":[],"error":null,"unmanaged":false,"applied":true}'
  _sync_record_config_results "$target" 'new_file_existing'
  jq -e '.components["config-codex"].state == "current"' "$AICODING_RESULTS_FILE"
}

@test "missing merge source fails application instead of clearing its old config blocker" {
  . "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  export AICODING_BLUEPRINT_CLONE="$TMP/absent-blueprint"
  declare -gA FILE_SOURCE=()
  BUCKETS[$first]=merge
  FILE_SOURCE[$first]=configs/claude/settings.json
  local rc=0
  apply_managed_buckets merge boot || rc=$?
  [ "$rc" -ne 0 ]
  [ "${APPLY_FAILURES[$first]:-0}" = 1 ]
  _sync_record_config_results "$target" merge
  jq -e '.components["config-claude"].state == "failed"' "$AICODING_RESULTS_FILE"
  [ ! -e "$first" ]
}

@test "unverified no-op recovery preserves old evidence without deferring or suppressing the blueprint stamp" {
  _recovery_blueprint
  export BLOCK_DEST="$second"
  aicoding_result_record config-claude failed old managed_config_apply_failed
  local before
  before=$(jq -c '.components["config-claude"]' "$AICODING_RESULTS_FILE")
  _SYNC_PASS_DEFERRED=0
  _sync_reconcile boot
  [ "$(cat "$AICODING_MANIFEST.stamp")" = "$target" ]
  [ "$_SYNC_PASS_DEFERRED" = 0 ]
  [ "${_SYNC_DEFERRED_PROVISION_COMPONENTS[claude]:-0}" = 0 ]
  [ "$(jq -c '.components["config-claude"]' "$AICODING_RESULTS_FILE")" = "$before" ]
  jq -e '.components.config.state == "current"' "$AICODING_RESULTS_FILE"
}
