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

@test "reviewer defaults: routes table and prose name the same families" {
  local routes="$BLUEPRINT_ROOT/skills/dev-process-lite/routes.default.json" f
  [ "$(jq -r '.routes.claude.reviewer.harness + "/" + .routes.claude.reviewer.family' "$routes")" = "codex/sol" ]
  [ "$(jq -r '.routes.codex.reviewer.harness + "/" + .routes.codex.reviewer.family' "$routes")" = "claude/opus" ]
  for f in configs/claude/CLAUDE.md configs/codex/AGENTS.md skills/review-by-harness/SKILL.md; do
    grep -q 'the Sol family for Codex' "$BLUEPRINT_ROOT/$f"
    grep -q 'the Opus family for Claude' "$BLUEPRINT_ROOT/$f"
    grep -q 'routes.sh' "$BLUEPRINT_ROOT/$f"
    run grep -nE 'gpt-5\.6-sol`\)|\(`claude-opus-5`\)' "$BLUEPRINT_ROOT/$f"
    [ "$status" -eq 1 ]
  done
}

@test "reviewer defaults: adapters default to current models" {
  grep -q 'MODEL="${REVIEW_MODEL:-opus}"' "$BLUEPRINT_ROOT/skills/review-by-harness/harnesses/claude.sh"
  grep -q 'MODEL="${REVIEW_MODEL:-gpt-6.1-sol}"' "$BLUEPRINT_ROOT/skills/review-by-harness/harnesses/codex.sh"
  grep -q 'MODEL="${REVIEW_MODEL:-grok-4.7-high-fast}"' "$BLUEPRINT_ROOT/skills/review-by-harness/harnesses/cursor.sh"
}
