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
[ -n "${STUB_FAIL:-}" ] && { echo "stub failure" >&2; exit 1; }
case "$verb" in
  review) out="$4"; cp "$wt/AGENTS.md" "$out/agents-seen-review.md" 2>/dev/null || : > "$out/agents-seen-review.md"
          echo "stub findings" > "$out/review.md" ;;
  fix)    out="$3"; cp "$wt/AGENTS.md" "$out/agents-seen-fix.md" 2>/dev/null || : > "$out/agents-seen-fix.md"
          cp "$wt/AGENTS.override.md" "$out/override-seen-fix.md" 2>/dev/null || true
          echo "edited by stub" >> "$wt/src.txt"
          [ -n "${STUB_EDIT_AGENTS:-}" ] && echo "also run the linter" >> "$wt/AGENTS.md"
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
  git init -q --bare -b main "$TMPDIR/origin.git"
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

@test "a tracked AGENTS.md symlink is replaced for the run and put back; its target is untouched" {
  ( cd "$TMPDIR/seed"
    printf '# Claude rules\nrun the tests\n' > CLAUDE.md; ln -s CLAUDE.md AGENTS.md
    git add CLAUDE.md AGENTS.md; git commit -qm link; git push -q -f origin HEAD:refs/pull/1/head )
  run "$SKILL/run.sh" 1 "$REPO" --harness stub --review-only
  [ "$status" -eq 0 ]
  grep -q 'Review session rules' "$WT/.review-round/agents-seen-review.md"
  grep -q 'run the tests' "$WT/.review-round/agents-seen-review.md"
  [ -L "$WT/AGENTS.md" ]
  [ "$(readlink "$WT/AGENTS.md")" = "CLAUDE.md" ]
  [ "$(cat "$WT/CLAUDE.md")" = "$(printf '# Claude rules\nrun the tests')" ]
  git -C "$WT" diff --quiet HEAD
}

@test "AGENTS.override.md, which codex prefers, gets the rules too and is restored" {
  ( cd "$TMPDIR/seed"
    printf 'override rules\n' > AGENTS.override.md; git add AGENTS.override.md; git commit -qm override
    git push -q -f origin HEAD:refs/pull/1/head )
  printf 'REVIEW_SANDBOX=-s\nREVIEW_APPROVAL=--x\n' > "$TMPDIR/cfg.env"
  REVIEW_CONFIG="$TMPDIR/cfg.env" run "$SKILL/run.sh" 1 "$REPO" --harness stub
  [ "$status" -eq 0 ]
  grep -q 'Fix session rules' "$WT/.review-round/override-seen-fix.md"
  grep -q 'override rules' "$WT/.review-round/override-seen-fix.md"
  [ "$(cat "$WT/AGENTS.override.md")" = "override rules" ]
  [ ! -e "$WT/AGENTS.md" ]
  git -C "$WT" diff --quiet HEAD -- AGENTS.override.md
}

@test "an edit the fix pass makes to AGENTS.md survives restore and shows in the handback" {
  add_project_agents
  printf 'REVIEW_SANDBOX=-s\nREVIEW_APPROVAL=--x\n' > "$TMPDIR/cfg.env"
  STUB_EDIT_AGENTS=1 REVIEW_CONFIG="$TMPDIR/cfg.env" run "$SKILL/run.sh" 1 "$REPO" --harness stub
  [ "$status" -eq 0 ]
  grep -q 'also run the linter' "$WT/AGENTS.md"
  if grep -q 'review-by-harness' "$WT/AGENTS.md"; then false; fi
  [[ "$output" == *"+also run the linter"* ]]
  if [[ "$output" == *"review-by-harness:begin"* ]]; then false; fi
}

@test "a failing adapter still leaves the worktree without the rules" {
  add_project_agents
  STUB_FAIL=1 run "$SKILL/run.sh" 1 "$REPO" --harness stub --review-only
  [ "$status" -ne 0 ]
  [ "$(cat "$WT/AGENTS.md")" = "$(printf '# Project rules\nrun the tests')" ]
  git -C "$WT" diff --quiet HEAD
}

@test "every shipped skill counts as managed, so install.sh never reports it as unmanaged" {
  # The 2026-09-08 host install flagged review-by-harness as "not managed by
  # this installer" because MANAGED_SKILLS was a hand-kept list.
  run bash -c '
    SCRIPT_DIR="$1"
    . "$SCRIPT_DIR/lib/provision-managed-files.sh"
    printf "%s\n" "${MANAGED_SKILLS[@]}"
  ' _ "$BLUEPRINT_ROOT"
  [ "$status" -eq 0 ]
  for d in "$BLUEPRINT_ROOT"/skills/*/; do
    grep -qx "$(basename "$d")" <<<"$output"
  done
  grep -qx review-by-harness <<<"$output"
}

@test "auto selects Claude for Codex caller and restores Claude instructions" {
  cp "$SKILL/harnesses/stub.sh" "$SKILL/harnesses/claude.sh"
  ( cd "$TMPDIR/seed"
    printf 'Claude project rules\n' > CLAUDE.md
    git add CLAUDE.md; git commit -qm claude; git push -q -f origin HEAD:refs/pull/1/head )
  run "$SKILL/run.sh" 1 "$REPO" --caller codex --review-only
  [ "$status" -eq 0 ]
  [[ "$output" == *'harness: claude'* ]]
  [ "$(cat "$REPO/.claude/worktrees/review-pr1-claude/CLAUDE.md")" = 'Claude project rules' ]
}

@test "auto selects Codex for Claude caller and explicit reviewer wins" {
  cp "$SKILL/harnesses/stub.sh" "$SKILL/harnesses/codex.sh"
  run "$SKILL/run.sh" 1 "$REPO" --caller claude --review-only
  [ "$status" -eq 0 ]
  [[ "$output" == *'harness: codex'* ]]
  run "$SKILL/run.sh" 1 "$REPO" --caller codex --harness stub --review-only
  [ "$status" -eq 0 ]
  [[ "$output" == *'harness: stub'* ]]
}

@test "review-only detects a reviewer writing instead of claiming no changes" {
  sed -i '/echo "stub findings"/s/echo "stub findings"/echo bad >> "$wt\/src.txt"; echo "stub findings"/' "$SKILL/harnesses/stub.sh"
  run "$SKILL/run.sh" 1 "$REPO" --harness stub --review-only
  [ "$status" -eq 1 ]
  [[ "$output" == *'review-only harness changed'* ]]
}

@test "CLI model and effort override shared config and reach both passes" {
  sed -i '/verb="$1"/a printf "%s:%s\\n" "${REVIEW_MODEL:-}" "${REVIEW_EFFORT:-}" >> "$MODEL_LOG"' "$SKILL/harnesses/stub.sh"
  export MODEL_LOG="$TMPDIR/models"
  printf 'REVIEW_MODEL=wrong\nREVIEW_EFFORT=low\nREVIEW_SANDBOX=-s\n' > "$TMPDIR/model.env"
  REVIEW_CONFIG="$TMPDIR/model.env" run "$SKILL/run.sh" 1 "$REPO" --harness stub --model fable --effort high
  [ "$status" -eq 0 ]
  [ "$(cat "$MODEL_LOG")" = "$(printf 'fable:high\nfable:high')" ]
  [[ "$output" == *'requested model: fable   effort: high'* ]]
  [ "$(jq -r .model "$WT/.review-round/run.json")" = fable ]
  [ "$(jq -r .effort "$WT/.review-round/run.json")" = high ]
}

@test "Cursor separate effort is refused instead of ignored" {
  run "$SKILL/run.sh" 1 "$REPO" --harness cursor --model custom --effort high --review-only
  [ "$status" -eq 2 ]
  [[ "$output" == *'Cursor effort is part of its model selector'* ]]
}

@test "review preserves instruction files with missing or multiple trailing newlines" {
  cp "$SKILL/harnesses/stub.sh" "$SKILL/harnesses/claude.sh"
  for suffix in '' $'\n\n\n'; do
    ( cd "$TMPDIR/seed"
      printf 'project rules%s' "$suffix" > AGENTS.md
      printf 'Claude rules%s' "$suffix" > CLAUDE.md
      git add AGENTS.md CLAUDE.md; git commit -qm endings
      git push -q -f origin HEAD:refs/pull/1/head )
    run "$SKILL/run.sh" 1 "$REPO" --harness claude --model opus --review-only
    [ "$status" -eq 0 ]
    cmp "$TMPDIR/seed/AGENTS.md" "$REPO/.claude/worktrees/review-pr1-claude/AGENTS.md"
    cmp "$TMPDIR/seed/CLAUDE.md" "$REPO/.claude/worktrees/review-pr1-claude/CLAUDE.md"
  done
}

@test "Claude instruction symlink receives one rules block and is restored" {
  cp "$SKILL/harnesses/stub.sh" "$SKILL/harnesses/claude.sh"
  sed -i '/verb="$1"/a cp "$wt/CLAUDE.md" "$wt/.review-round/claude-seen.md"' "$SKILL/harnesses/claude.sh"
  ( cd "$TMPDIR/seed"
    printf 'project rules\n' > AGENTS.md; ln -s AGENTS.md CLAUDE.md
    git add AGENTS.md CLAUDE.md; git commit -qm claude-link
    git push -q -f origin HEAD:refs/pull/1/head )
  run "$SKILL/run.sh" 1 "$REPO" --harness claude --model opus --review-only
  [ "$status" -eq 0 ]
  local cw="$REPO/.claude/worktrees/review-pr1-claude"
  [ "$(grep -c 'review-by-harness:begin' "$cw/.review-round/claude-seen.md")" -eq 1 ]
  [ "$(readlink "$cw/CLAUDE.md")" = AGENTS.md ]
  git -C "$cw" diff --quiet HEAD
}
