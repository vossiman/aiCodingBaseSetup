#!/usr/bin/env bats

setup() {
  : "${BLUEPRINT_ROOT:?run via tests/bats/run.sh}"
  TEST_SCRATCH=$(mktemp -d)
}

teardown() {
  rm -rf "$TEST_SCRATCH"
}

@test "design skill: committed bundle matches its source pin and has no escaping paths" {
  run python3 "$BLUEPRINT_ROOT/tools/update-design-skill.py" --check
  [ "$status" -eq 0 ]
}

@test "design skill: refresh rejects dirty sources and survives failed exports" {
  run python3 "$BLUEPRINT_ROOT/tests/test_design_skill_source.py"
  [ "$status" -eq 0 ]
}

@test "design skill: normal managed deployment installs portable bundle byte-for-byte" {
  export HOME="$TEST_SCRATCH/home" AICODING_BLUEPRINT_CLONE="$BLUEPRINT_ROOT"
  export AICODING_STATE_DIR="$TEST_SCRATCH/state"
  mkdir -p "$HOME"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  managed_config_apply >/dev/null
  local rel
  while IFS= read -r rel; do
    [[ "$rel" == dataprospectors-design/* ]] || continue
    cmp -s "$BLUEPRINT_ROOT/skills/$rel" "$HOME/.claude/skills/$rel"
  done < <(enumerate_skill_files "$BLUEPRINT_ROOT/skills")
  [ -f "$HOME/.claude/skills/dataprospectors-design/modules/consumption.md" ]
  [ -f "$HOME/.claude/skills/dataprospectors-design/references/native-theme.css" ]
  [ -f "$HOME/.claude/skills/dataprospectors-design/SOURCE.json" ]
}
