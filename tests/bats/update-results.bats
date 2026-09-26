#!/usr/bin/env bats

setup() {
  : "${BLUEPRINT_ROOT:?run via tests/bats/run.sh}"
  export TMP; TMP=$(mktemp -d)
  export HOME="$TMP"
  export AICODING_STATE_DIR="$TMP/state"
  . "$BLUEPRINT_ROOT/lib/update-results.sh"
}

teardown() { rm -rf "$TMP"; }

@test "result record keeps the last success when a later attempt fails" {
  aicoding_result_record codex updated 0.150.0 installed 0.150.0
  local succeeded
  succeeded=$(jq -r '.components.codex.succeeded_at' "$AICODING_STATE_DIR/update-results.json")

  aicoding_result_record codex failed 0.151.0 validation_failed

  jq -e '.schema == 1' "$AICODING_STATE_DIR/update-results.json"
  jq -e '.components.codex.state == "failed"' "$AICODING_STATE_DIR/update-results.json"
  jq -e '.components.codex.target_version == "0.151.0"' "$AICODING_STATE_DIR/update-results.json"
  jq -e '.components.codex.successful_version == "0.150.0"' "$AICODING_STATE_DIR/update-results.json"
  [ "$(jq -r '.components.codex.succeeded_at' "$AICODING_STATE_DIR/update-results.json")" = "$succeeded" ]
}

@test "result writers serialize and preserve unrelated component receipts" {
  aicoding_result_record aicoding current aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa current aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa &
  local p1=$!
  aicoding_result_record dvw blocked bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb missing_adapter &
  local p2=$!
  wait "$p1"; wait "$p2"

  jq -e '.components.aicoding.state == "current"' "$AICODING_STATE_DIR/update-results.json"
  jq -e '.components.dvw.state == "blocked"' "$AICODING_STATE_DIR/update-results.json"
}

@test "result reason rejects config contents and records a short generic reason" {
  run aicoding_result_record codex failed 0.151.0 $'line one\nsecret=value'
  [ "$status" -ne 0 ]
  [ ! -e "$AICODING_STATE_DIR/update-results.json" ]
}

@test "result record reports an atomic replace failure" {
  mv() { return 9; }
  run aicoding_result_record codex failed 0.151.0 validation_failed
  [ "$status" -eq 9 ]
  [ ! -e "$AICODING_STATE_DIR/update-results.json" ]
}

@test "result detail is kept on failures and dropped by the next record" {
  aicoding_result_record config-codex failed abc managed_config_apply_failed "" \
    $'invalid_provenance_cache: initial/cache_entry_writable:0664:aicoding.git/HEAD\x01'
  jq -e '.components["config-codex"].detail == "invalid_provenance_cache: initial/cache_entry_writable:0664:aicoding.git/HEAD?"' \
    "$AICODING_STATE_DIR/update-results.json"
  aicoding_result_record config-codex failed abc managed_config_apply_failed
  jq -e '.components["config-codex"] | has("detail") | not' "$AICODING_STATE_DIR/update-results.json"
  aicoding_result_record config-codex blocked abc partial_config_blocked "" "why"
  aicoding_result_record config-codex current abc reconciliation_verified abc "ignored"
  jq -e '.components["config-codex"] | has("detail") | not' "$AICODING_STATE_DIR/update-results.json"
}
