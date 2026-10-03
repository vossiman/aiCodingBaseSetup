#!/usr/bin/env bats
# The global "Dev process" paragraph is byte-identical in the three managed
# instruction files, from its heading to the next heading.

bats_require_minimum_version 1.5.0

setup() {
  : "${BLUEPRINT_ROOT:?unset, run via tests/bats/run.sh}"
}

section() {
  awk '/^## Dev process$/ {on=1; print; next} on && /^## / {exit} on {print}' "$1"
}

@test "global rule: identical Dev process section in claude, codex and cursor texts" {
  local c x u
  c=$(section "$BLUEPRINT_ROOT/configs/claude/CLAUDE.md")
  x=$(section "$BLUEPRINT_ROOT/configs/codex/AGENTS.md")
  u=$(section "$BLUEPRINT_ROOT/configs/cursor/skills/aicoding-estate/SKILL.md")
  [ -n "$c" ]
  [ "$c" = "$x" ]
  [ "$c" = "$u" ]
}

@test "global rule: names the project document first and both skills" {
  local c
  c=$(section "$BLUEPRINT_ROOT/configs/claude/CLAUDE.md")
  [[ "$c" == *'A repo with `docs/DEV_PROCESS.md` follows that document and its own skills.'* ]]
  [[ "$c" == *'`dev-process-lite`'* ]]
  [[ "$c" == *'`assess-run`'* ]]
  [ "$(grep -c . <<<"$c")" -le 8 ]
}
