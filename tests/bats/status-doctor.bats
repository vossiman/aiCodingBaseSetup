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
        {id: "aaaaaaaaaaaa1111", components: {claude: {}, codex: {}, cursor: {}, "mcp-context7": {}, "mcp-playwright": {}}},
        {id: "bbbbbbbbbbbb2222", components: {claude: {}, codex: {}, cursor: {}, "mcp-context7": {}}},
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

@test "doctor warns about a missing fleet proof for a configured shared root without failing" {
  mkdir -p "$HOME/.claude"
  export AICODING_SHARED_CONFIG_ROOTS="$HOME/.claude"
  run "$BIN" --doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"Fleet proof (warning only): missing"* ]]
  [[ "$output" == *"do not wait for this"* ]]
}

@test "doctor explains a catalogued blocker and exits 1" {
  aicoding_result_record bw-AICode failed abc activation_failed
  run "$BIN" --doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"bw-AICode: failed (activation_failed)"* ]]
  [[ "$output" == *"Why: The new release was staged but could not be switched to active."* ]]
  [[ "$output" == *"Fix: "* ]]
}

@test "doctor lists an info-kind record as a note, not a blocker, and exits 0" {
  aicoding_result_record mcp-registration-claude-context7 blocked abc registration_not_selected
  run "$BIN" --doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"No recorded blockers"* ]]
  local notes="${output#*Notes (nothing to fix unless you want the feature)}"
  [ "$notes" != "$output" ]
  [[ "$notes" == *"mcp-registration-claude-context7: blocked (registration_not_selected)"* ]]
  [[ "$notes" == *"Why: This MCP is not registered in Claude"* ]]
}

@test "doctor keeps notes visible next to real blockers and still exits 1" {
  aicoding_result_record mcp-registration-claude-playwright blocked abc registration_not_selected
  aicoding_result_record bw-AICode failed abc activation_failed
  run "$BIN" --doctor
  [ "$status" -eq 1 ]
  local blockers="${output#*Blockers}"
  blockers="${blockers%%Notes (*}"
  [[ "$blockers" == *"bw-AICode: failed"* ]]
  [[ "$blockers" != *"mcp-registration-claude-playwright"* ]]
  [[ "${output#*Notes (}" == *"mcp-registration-claude-playwright: blocked (registration_not_selected)"* ]]
}

@test "doctor explains a reason through its family pattern" {
  aicoding_result_record bw-AICode blocked abc go_runtime_unavailable
  run "$BIN" --doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"Why: A runtime this component needs"* ]]
}

@test "doctor prefers an exact entry over a matching pattern" {
  aicoding_result_record mcp-context7 failed abc python_runtime_unavailable
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
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 of 4 containers pass"* ]]
  [[ "$output" == *"2 probed nothing"*"cccccccccccc"*"dddddddddddd"* ]]
  [[ "$output" == *"1 missing mcp-playwright: bbbbbbbbbbbb"* ]]
  [[ "$output" != *"aaaaaaaaaaaa (this container)"*"missing"* ]]
}

@test "doctor stays quiet about the fleet when the proof is complete" {
  _fleet
  jq '.roots[0].inventory_complete = true | .roots[0].consumers = [.roots[0].consumers[0]]
      | .roots[0].consumers[0].components |= with_entries(.value = {version: "1.0.0", config_compatible: true})
      | .roots[0].consumers[0].components.codex.version = "0.158.0"' \
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

@test "doctor and status drop a tool-verification blocker once that tool succeeded later" {
  jq -n '{schema:1,components:{
    "provision-claude":{state:"blocked",reason:"claude_update_not_verified",attempted_at:"2026-09-28T10:44:44Z"},
    claude:{state:"updated",reason:"installed",successful_version:"2.1.283",succeeded_at:"2026-09-28T10:45:38Z"},
    "provision-codex":{state:"blocked",reason:"codex_update_not_verified",attempted_at:"2026-09-28T10:44:44Z"},
    codex:{state:"updated",reason:"installed",successful_version:"0.158.0",succeeded_at:"2026-09-28T10:40:00Z"}}}' \
    > "$AICODING_RESULTS_FILE"
  run "$BIN" --doctor
  [[ "$output" != *"provision-claude"* ]]
  [[ "$output" == *"provision-codex"* ]]
  run "$BIN"
  [[ "$(sed -n '/Unresolved recorded blockers/,$p' <<< "$output")" != *"provision-claude"* ]]
}

@test "doctor prints a blocker's recorded detail" {
  aicoding_result_record config-claude blocked target mcp_exact_version_staging_unavailable "" \
    "mcp-context7: blocked exact_package_not_staged"
  run "$BIN" --doctor
  [[ "$output" == *"Detail: mcp-context7: blocked exact_package_not_staged"* ]]
}

@test "provision actionability follows the recorded MCP cause" {
  local report="$BLUEPRINT_ROOT/lib/status-report.py"
  aicoding_result_record config-codex blocked target mcp_exact_version_staging_unavailable "" \
    "mcp-context7: blocked offline_exact_package_not_ready"
  run python3 "$report" --provision-actionable
  [ "$status" -eq 1 ]
  aicoding_result_record config-codex blocked target mcp_exact_version_staging_unavailable "" \
    "mcp-context7: failed build_failed"
  run python3 "$report" --provision-actionable
  [ "$status" -eq 0 ]
  aicoding_result_record config-codex blocked target mcp_exact_version_staging_unavailable "" \
    "mcp-context7: active launcher invalid"
  run python3 "$report" --provision-actionable
  [ "$status" -eq 0 ]
}

@test "a retired fleet-gate blocker left on disk is neither listed nor badged" {
  aicoding_result_record mcp-registration-claude-context7 blocked abc claude_consumers_incompatible
  aicoding_result_record provision-codex blocked "" codex_shared_consumers_incompatible
  run "$BIN" --doctor
  [ "$status" -eq 0 ]
  [[ "$output" != *"consumers_incompatible"* ]]
  run python3 "$BLUEPRINT_ROOT/lib/status-report.py" --provision-actionable
  [ "$status" -eq 1 ]
}

@test "doctor warns when a complete fleet reports an incompatible consumer" {
  _fleet
  jq '.roots[0].inventory_complete = true
      | .roots[0].consumers = [.roots[0].consumers[0]]
      | .roots[0].consumers[0].components = {
          claude: {version: "2.1.0", config_compatible: true},
          codex: {version: "0.140.0", config_compatible: true},
          cursor: {version: "2026.09.26", config_compatible: false},
          "mcp-context7": {version: "4.1.1", config_compatible: true},
          "mcp-playwright": {version: "0.0.82", config_compatible: true}}' \
    "$AICODING_SHARED_CONSUMERS_FILE" > "$TMP/f" && mv "$TMP/f" "$AICODING_SHARED_CONSUMERS_FILE"
  run "$BIN" --doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"Fleet proof (warning only): incompatible"*"aaaaaaaaaaaa"* ]]
  [[ "$output" == *"codex 0.140.0 older than 0.148.0"* ]]
  [[ "$output" == *"cursor config incompatible"* ]]
}
