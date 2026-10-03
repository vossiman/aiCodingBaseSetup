#!/usr/bin/env bats
# Prose guards for the dev-process-lite policy and its two skills.

bats_require_minimum_version 1.5.0

setup() {
  : "${BLUEPRINT_ROOT:?unset, run via tests/bats/run.sh}"
  S="$BLUEPRINT_ROOT/skills"
}

@test "policy: under 150 lines, four numbered sections in order" {
  [ "$(wc -l < "$S/dev-process-lite/policy.md")" -lt 150 ]
  run grep -E '^## ' "$S/dev-process-lite/policy.md"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "## 1. Overseer log" ]
  [ "${lines[1]}" = "## 2. Finish in the run, close what is old" ]
  [ "${lines[2]}" = "## 3. When the overseer comes back to the owner" ]
  [ "${lines[3]}" = "## 4. Routes" ]
  [ "${#lines[@]}" -eq 4 ]
}

@test "policy: names the 120-line log cap and the five log sections" {
  grep -q '120' "$S/dev-process-lite/policy.md"
  local section
  for section in Plan Decisions Deviations "Open questions" Board; do
    grep -q "\*\*$section\*\*" "$S/dev-process-lite/policy.md"
  done
}

@test "policy: no em dash and no template braces in the skill prose" {
  run grep -rlP '\x{2014}' "$S/dev-process-lite" "$S/assess-run" --include='*.md'
  [ "$status" -eq 1 ]
  run grep -rlF '{{' "$S/dev-process-lite" "$S/assess-run" --include='*.md'
  [ "$status" -eq 1 ]
}

@test "skills: frontmatter names match directories and descriptions defer to a project process" {
  local s
  for s in dev-process-lite assess-run; do
    run sed -n '2p' "$S/$s/SKILL.md"
    [ "$output" = "name: $s" ]
    grep -q '^description: .*docs/DEV_PROCESS.md' "$S/$s/SKILL.md"
  done
}

@test "skills: both run detect.sh first" {
  grep -q 'detect.sh' "$S/dev-process-lite/SKILL.md"
  grep -q 'detect.sh' "$S/assess-run/SKILL.md"
}

@test "skills: no shared skill shadows a project skill name" {
  [ ! -e "$S/assess" ]
  [ ! -e "$S/dev-process" ]
}

@test "skills: assess-run states the 120-line cap and the conditional hand-back" {
  grep -q '120' "$S/assess-run/SKILL.md"
  grep -q 'ListAgents' "$S/assess-run/SKILL.md"
  grep -qi 'report only' "$S/assess-run/SKILL.md"
}
