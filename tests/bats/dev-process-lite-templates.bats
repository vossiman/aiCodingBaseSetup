#!/usr/bin/env bats
# Project templates for the lite process: routes, PR template, ignore rules,
# AGENTS.md section, and the new-project instruction that renames dot- files.

bats_require_minimum_version 1.5.0

setup() {
  : "${BLUEPRINT_ROOT:?unset, run via tests/bats/run.sh}"
  T="$BLUEPRINT_ROOT/templates/project"
}

@test "templates: routes.json is a byte copy of the default routes" {
  cmp -s "$BLUEPRINT_ROOT/skills/dev-process-lite/routes.default.json" "$T/dot-dev-process/routes.json.tpl"
}

@test "templates: PR template has the three sections in order, blueprint adopts it" {
  run grep -E '^## ' "$T/dot-github/pull_request_template.md.tpl"
  [ "${lines[0]}" = "## Change" ]
  [ "${lines[1]}" = "## Validation" ]
  [ "${lines[2]}" = "## Independent review" ]
  [ "${#lines[@]}" -eq 3 ]
  cmp -s "$T/dot-github/pull_request_template.md.tpl" "$BLUEPRINT_ROOT/.github/pull_request_template.md"
}

@test "templates: gitignore keeps worktrees and run journals out" {
  grep -qx '.claude/worktrees/' "$T/dot-gitignore.tpl"
  grep -qx '.claude/dev-process-runs/' "$T/dot-gitignore.tpl"
}

@test "templates: AGENTS.md explains the process files" {
  local f="$T/AGENTS.md.tpl"
  grep -q '^### Development process$' "$f"
  grep -q 'dev-process-lite' "$f"
  grep -q '.dev-process/routes.json' "$f"
  grep -q 'docs/DEV_PROCESS.md' "$f"
  grep -q 'docs/REQUIREMENTS.md' "$f"
  grep -q 'docs/SHIP_CHECK.md' "$f"
}

@test "templates: new-project instructions rename every dot- prefix" {
  local f
  for f in configs/claude/CLAUDE.md configs/codex/AGENTS.md; do
    grep -q 'every `dot-` prefix' "$BLUEPRINT_ROOT/$f"
  done
}

@test "templates: automatic injection is scoped to Claude Code, other agents read the files" {
  local f="$T/AGENTS.md.tpl"
  grep -q 'Claude Code injects' "$f"
  grep -q 'Other agents read' "$f"
}
