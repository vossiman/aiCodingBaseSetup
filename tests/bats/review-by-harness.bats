#!/usr/bin/env bats
# skills/review-by-harness/run.sh: the harness gets session rules as the
# worktree's AGENTS.md (no tickets, no commits; no writes during review), a
# project's own AGENTS.md stays underneath, and the file is restored before
# the handback so it never looks like a change the harness made.
#
# gh is stubbed; the PR lives in a local bare "origin" as refs/pull/1/head;
# the harness is a stub adapter that records what it saw.

bats_require_minimum_version 1.5.0

setup() {
  : "${BLUEPRINT_ROOT:?unset, run via tests/bats/run.sh}"
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR/home"; mkdir -p "$HOME"
  unset REVIEW_CONFIG REVIEW_SANDBOX REVIEW_APPROVAL XDG_CONFIG_HOME

  # A private copy of the skill with a stub harness added.
  SKILL="$TMPDIR/skill"
  cp -r "$BLUEPRINT_ROOT/skills/review-by-harness" "$SKILL"
  rm -f "$SKILL/config.env"
  cat > "$SKILL/harnesses/stub.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
verb="$1"; wt="$2"
case "$verb" in
  review) out="$4"; cp "$wt/AGENTS.md" "$out/agents-seen-review.md" 2>/dev/null || : > "$out/agents-seen-review.md"
          echo "stub findings" > "$out/review.md" ;;
  fix)    out="$3"; cp "$wt/AGENTS.md" "$out/agents-seen-fix.md" 2>/dev/null || : > "$out/agents-seen-fix.md"
          echo "edited by stub" >> "$wt/src.txt"
          echo "stub fix report" > "$out/fix.md" ;;
esac
STUB
  chmod +x "$SKILL/harnesses/stub.sh"

  # gh stub: answers the four pr-view queries run.sh makes.
  mkdir -p "$TMPDIR/bin"
  cat > "$TMPDIR/bin/gh" <<'GH'
#!/bin/sh
case "$*" in
  *baseRefName*) echo main ;;
  *headRefName*) echo feat ;;
  *title*)       echo "stub pr" ;;
  *state*)       echo OPEN ;;
esac
GH
  chmod +x "$TMPDIR/bin/gh"
  export PATH="$TMPDIR/bin:$PATH"

  # Bare origin with main and a PR head at refs/pull/1/head; REPO is a clone.
  git init -q --bare "$TMPDIR/origin.git"
  git init -q -b main "$TMPDIR/seed"
  ( cd "$TMPDIR/seed"
    git -c user.name=t -c user.email=t@t config user.name t; git config user.email t@t
    echo base > src.txt; git add src.txt; git commit -q -m base
    git remote add origin "$TMPDIR/origin.git"; git push -q origin main
    git switch -q -c feat; echo change >> src.txt; git commit -qam change
    git push -q origin HEAD:refs/pull/1/head )
  git clone -q "$TMPDIR/origin.git" "$TMPDIR/repo"
  REPO="$TMPDIR/repo"
  WT="$REPO/.claude/worktrees/review-pr1-stub"
}

teardown() { case "${TMPDIR:-}" in */tmp.*) rm -rf "$TMPDIR" ;; esac }

# add_project_agents: give the PR head its own tracked AGENTS.md.
add_project_agents() {
  ( cd "$TMPDIR/seed"
    printf '# Project rules\nrun the tests\n' > AGENTS.md; git add AGENTS.md; git commit -qm agents
    git push -q -f origin HEAD:refs/pull/1/head )
}

@test "review pass sees the review rules; no AGENTS.md is left behind in a repo without one" {
  run "$SKILL/run.sh" 1 "$REPO" --harness stub --review-only
  [ "$status" -eq 0 ]
  local seen="$WT/.review-round/agents-seen-review.md"
  grep -q 'Review session rules' "$seen"
  grep -q 'never run `kanban-post`' "$seen"
  grep -q 'Do not write, edit, create or delete files' "$seen"
  [ ! -e "$WT/AGENTS.md" ]
  [[ "$output" == *"stub findings"* ]]
}

@test "a project's own AGENTS.md stays underneath the rules and is restored untouched" {
  add_project_agents
  run "$SKILL/run.sh" 1 "$REPO" --harness stub --review-only
  [ "$status" -eq 0 ]
  local seen="$WT/.review-round/agents-seen-review.md"
  grep -q 'Review session rules' "$seen"
  grep -q 'run the tests' "$seen"
  # rules come first, project text after
  [ "$(grep -n 'Review session rules' "$seen" | cut -d: -f1)" -lt "$(grep -n 'run the tests' "$seen" | cut -d: -f1)" ]
  [ "$(cat "$WT/AGENTS.md")" = "$(printf '# Project rules\nrun the tests')" ]
  git -C "$WT" diff --quiet HEAD -- AGENTS.md
}

@test "fix pass sees the fix rules, and the handback diff never mentions AGENTS.md" {
  add_project_agents
  printf 'REVIEW_SANDBOX=-s\nREVIEW_APPROVAL=--x\n' > "$TMPDIR/cfg.env"
  REVIEW_CONFIG="$TMPDIR/cfg.env" run "$SKILL/run.sh" 1 "$REPO" --harness stub
  [ "$status" -eq 0 ]
  local seen="$WT/.review-round/agents-seen-fix.md"
  grep -q 'Fix session rules' "$seen"
  grep -q 'never run `kanban-post`' "$seen"
  grep -q 'run the tests' "$seen"
  [[ "$output" == *"src.txt"* ]]
  [[ "$output" != *"AGENTS.md"* ]]
  git -C "$WT" diff --quiet HEAD -- AGENTS.md
}

@test "the shipped prompts tell every harness not to file tickets" {
  local d="$BLUEPRINT_ROOT/skills/review-by-harness/prompts"
  grep -q 'kanban-post' "$d/review.md"
  grep -q 'kanban-post' "$d/fix.md"
  grep -q 'kanban-post' "$d/agents-review.md"
  grep -q 'kanban-post' "$d/agents-fix.md"
}
