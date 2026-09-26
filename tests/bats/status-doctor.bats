#!/usr/bin/env bats

setup() {
  : "${BLUEPRINT_ROOT:?run via tests/bats/run.sh}"
  TMP=$(mktemp -d)
  export HOME="$TMP/home" AICODING_STATE_DIR="$TMP/state" AICODING_DATA_DIR="$TMP/data"
  export AICODING_RESULTS_FILE="$TMP/state/update-results.json"
  export AICODING_SHARED_CONSUMERS_FILE="$TMP/consumer-versions.json"
  export AICODING_SELF_CONTAINER_ID=aaaaaaaaaaaa1111
  export PYTHONDONTWRITEBYTECODE=1
  mkdir -p "$HOME" "$AICODING_STATE_DIR"
  BIN="$BLUEPRINT_ROOT/bin/aicoding-status"
  . "$BLUEPRINT_ROOT/lib/update-results.sh"
}

teardown() { rm -rf "$TMP"; }

_fleet() {
  mkdir -p "$HOME/.claude"
  local now; now=$(date +%s)
  jq -n --argjson now "$now" '{
    schema: 1, generated_at: $now, newest_container_started_at: ($now - 100),
    roots: [{shared_root: "'"$HOME"'/.claude", inventory_complete: false, expires_at: ($now + 300),
      consumers: [
        {id: "aaaaaaaaaaaa1111", components: {claude: {}, codex: {}, cursor: {}, "mcp-context7": {}, "mcp-playwright": {}, "mcp-kanban": {}}},
        {id: "bbbbbbbbbbbb2222", components: {claude: {}, codex: {}, cursor: {}, "mcp-context7": {}, "mcp-playwright": {}}},
        {id: "cccccccccccc3333", components: {}},
        {id: "dddddddddddd4444", components: {}}
      ]}]}' > "$AICODING_SHARED_CONSUMERS_FILE"
}

@test "doctor with no blockers exits 0" {
  aicoding_result_record claude current 2.1.50 installed 2.1.50
  run "$BIN" --doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"No recorded blockers"* ]]
  [[ "$output" != *"claude:"* ]]
}

@test "doctor ignores a missing fleet proof for an ordinary local config directory" {
  mkdir -p "$HOME/.claude"
  run "$BIN" --doctor
  [ "$status" -eq 0 ]
  [[ "$output" != *"Fleet proof"* ]]
}

@test "doctor reports a missing fleet proof for a configured shared root" {
  mkdir -p "$HOME/.claude"
  export AICODING_SHARED_CONFIG_ROOTS="$HOME/.claude"
  run "$BIN" --doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"Fleet proof: missing"* ]]
}

@test "doctor reports a missing fleet proof when a fleet blocker was recorded" {
  aicoding_result_record config-claude blocked abc claude_consumers_incompatible
  run "$BIN" --doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"Fleet proof: missing"* ]]
}

@test "doctor explains a catalogued blocker and exits 1" {
  aicoding_result_record mcp-registration-claude-kanban blocked abc registration_not_selected
  run "$BIN" --doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"mcp-registration-claude-kanban: blocked (registration_not_selected)"* ]]
  [[ "$output" == *"Why: This MCP is not registered in Claude"* ]]
  [[ "$output" == *"Fix: "* ]]
}

@test "doctor explains a reason through its family pattern" {
  aicoding_result_record bw-AICode blocked abc go_runtime_unavailable
  run "$BIN" --doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"Why: A runtime this component needs"* ]]
}

@test "doctor prefers an exact entry over a matching pattern" {
  aicoding_result_record mcp-kanban failed abc python_runtime_unavailable
  run "$BIN" --doctor
  [[ "$output" == *"Why: \`python3\` is missing"* ]]
}

@test "doctor reports an uncatalogued reason without failing" {
  aicoding_result_record claude failed 2.1.50 something_brand_new
  run "$BIN" --doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"not in the doctor catalog"* ]]
}

@test "doctor lists fleet containers grouped by what they miss" {
  _fleet
  run "$BIN" --doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"1 of 4 containers pass"* ]]
  [[ "$output" == *"2 probed nothing"*"cccccccccccc"*"dddddddddddd"* ]]
  [[ "$output" == *"1 missing mcp-kanban: bbbbbbbbbbbb"* ]]
  [[ "$output" != *"aaaaaaaaaaaa (this container)"*"missing"* ]]
}

@test "doctor stays quiet about the fleet when the proof is complete" {
  _fleet
  jq '.roots[0].inventory_complete = true | .roots[0].consumers = [.roots[0].consumers[0]]' \
    "$AICODING_SHARED_CONSUMERS_FILE" > "$TMP/f" && mv "$TMP/f" "$AICODING_SHARED_CONSUMERS_FILE"
  run "$BIN" --doctor
  [ "$status" -eq 0 ]
  [[ "$output" != *"Fleet"* ]]
}

@test "doctor never writes state" {
  aicoding_result_record claude failed 2.1.50 installer_download_failed
  before=$(find "$TMP" -type f -newer "$AICODING_RESULTS_FILE" | wc -l)
  sleep 1
  run "$BIN" --doctor
  after=$(find "$TMP" -type f -newer "$AICODING_RESULTS_FILE" | wc -l)
  [ "$before" -eq "$after" ]
}

@test "help lists --doctor" {
  run "$BIN" --help
  [[ "$output" == *"--doctor"* ]]
}
