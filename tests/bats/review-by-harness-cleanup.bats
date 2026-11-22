#!/usr/bin/env bats
# skills/review-by-harness/cleanup.sh removes a review's worktree, branch and
# fetched PR ref once its findings are incorporated, archives .review-round
# on request, and never drops an un-incorporated fix diff or an open PR's
# review during --prune.

bats_require_minimum_version 1.5.0

setup() {
  : "${BLUEPRINT_ROOT:?unset, run via tests/bats/run.sh}"
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR/home"; mkdir -p "$HOME"
  unset REVIEW_CONFIG REVIEW_SANDBOX REVIEW_APPROVAL XDG_CONFIG_HOME

  SKILL="$TMPDIR/skill"
  cp -r "$BLUEPRINT_ROOT/skills/review-by-harness" "$SKILL"
  rm -f "$SKILL/config.env"
  cat > "$SKILL/harnesses/stub.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  review) echo "stub findings" > "$4/review.md" ;;
  fix)    echo "edited by stub" >> "$2/src.txt"; echo "stub fix report" > "$3/fix.md" ;;
esac
STUB
  chmod +x "$SKILL/harnesses/stub.sh"
  printf "REVIEW_SANDBOX='-s danger-full-access'\n" > "$TMPDIR/cfg.env"

  # gh stub: PR state per number from $TMPDIR/state-<N>, default OPEN.
  mkdir -p "$TMPDIR/bin"
  cat > "$TMPDIR/bin/gh" <<GH
#!/bin/sh
n=\$3
case "\$*" in
  *baseRefName*) echo main ;;
  *headRefName*) echo feat ;;
  *title*)       echo "stub pr" ;;
  *state*)       cat "$TMPDIR/state-\$n" 2>/dev/null || echo OPEN ;;
esac
GH
  chmod +x "$TMPDIR/bin/gh"
  export PATH="$TMPDIR/bin:$PATH"

  git init -q --bare -b main "$TMPDIR/origin.git"
  git init -q -b main "$TMPDIR/seed"
  ( cd "$TMPDIR/seed"
    git config user.name t; git config user.email t@t
    echo base > src.txt; git add src.txt; git commit -q -m base
    git remote add origin "$TMPDIR/origin.git"; git push -q origin main
    git switch -q -c feat; echo change >> src.txt; git commit -qam change
    git push -q origin HEAD:refs/pull/1/head HEAD:refs/pull/2/head )
  git clone -q "$TMPDIR/origin.git" "$TMPDIR/repo"
  REPO="$TMPDIR/repo"
}

teardown() { case "${TMPDIR:-}" in */tmp.*) rm -rf "$TMPDIR" ;; esac }

review() { run "$SKILL/run.sh" "$1" "$REPO" --harness stub --review-only; [ "$status" -eq 0 ]; }
review_fix() { REVIEW_CONFIG="$TMPDIR/cfg.env" run "$SKILL/run.sh" "$1" "$REPO" --harness stub; [ "$status" -eq 0 ]; }
gone() {  # gone <pr>: no worktree, branch or ref is left for the PR
  [ ! -e "$REPO/.claude/worktrees/review-pr$1-stub" ]
  if git -C "$REPO" show-ref --verify --quiet "refs/heads/review-pr$1-stub"; then false; fi
  if git -C "$REPO" show-ref --verify --quiet "refs/review-by-harness/pr$1"; then false; fi
}

@test "a review-only round is removed with its branch and ref, and archived on request" {
  review 1
  run "$SKILL/cleanup.sh" 1 "$REPO" --archive "$TMPDIR/runs/reviews"
  [ "$status" -eq 0 ]
  gone 1
  [ "$(cat "$TMPDIR/runs/reviews/review-pr1-stub/review.md")" = "stub findings" ]
  [ -s "$TMPDIR/runs/reviews/review-pr1-stub/reviewed-head" ]
  [ -z "$(git -C "$REPO" worktree list --porcelain | grep review-pr1 || true)" ]
}

@test "a second archive of the same review gets its own directory" {
  review 1
  "$SKILL/cleanup.sh" 1 "$REPO" --archive "$TMPDIR/a"
  review 1
  "$SKILL/cleanup.sh" 1 "$REPO" --archive "$TMPDIR/a"
  [ -f "$TMPDIR/a/review-pr1-stub/review.md" ]
  [ -f "$TMPDIR/a/review-pr1-stub-2/review.md" ]
}

@test "an un-incorporated fix diff on an open PR is kept until --discard" {
  review_fix 1
  run "$SKILL/cleanup.sh" 1 "$REPO" --archive "$TMPDIR/a"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not incorporated"* ]]
  grep -q "edited by stub" "$REPO/.claude/worktrees/review-pr1-stub/src.txt"
  git -C "$REPO" show-ref --verify --quiet refs/review-by-harness/pr1

  run "$SKILL/cleanup.sh" 1 "$REPO" --archive "$TMPDIR/a" --discard
  [ "$status" -eq 0 ]
  gone 1
  grep -q "edited by stub" "$TMPDIR/a/review-pr1-stub/handback.diff"
}

@test "a merged PR's fix diff counts as settled" {
  review_fix 1
  echo MERGED > "$TMPDIR/state-1"
  run "$SKILL/cleanup.sh" 1 "$REPO"
  [ "$status" -eq 0 ]
  gone 1
}

@test "--prune cleans merged and closed PRs, leaves open ones, and drops orphaned refs" {
  review 1
  review 2
  git -C "$REPO" update-ref refs/review-by-harness/pr7 "$(git -C "$REPO" rev-parse origin/main)"
  echo MERGED > "$TMPDIR/state-1"
  echo CLOSED > "$TMPDIR/state-7"
  run "$SKILL/cleanup.sh" --prune "$REPO"
  [ "$status" -eq 0 ]
  gone 1
  if git -C "$REPO" show-ref --verify --quiet refs/review-by-harness/pr7; then false; fi
  [ -d "$REPO/.claude/worktrees/review-pr2-stub" ]
  git -C "$REPO" show-ref --verify --quiet refs/review-by-harness/pr2
  [[ "$output" == *"pr2: OPEN, left alone"* ]]
}

@test "--harness limits cleanup to one reviewer and keeps the shared ref for the other" {
  review 1
  cp "$SKILL/harnesses/stub.sh" "$SKILL/harnesses/other.sh"
  run "$SKILL/run.sh" 1 "$REPO" --harness other --review-only
  [ "$status" -eq 0 ]
  run "$SKILL/cleanup.sh" 1 "$REPO" --harness stub
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.claude/worktrees/review-pr1-stub" ]
  [ -d "$REPO/.claude/worktrees/review-pr1-other" ]
  git -C "$REPO" show-ref --verify --quiet refs/review-by-harness/pr1
  run "$SKILL/cleanup.sh" 1 "$REPO"
  [ "$status" -eq 0 ]
  if git -C "$REPO" show-ref --verify --quiet refs/review-by-harness/pr1; then false; fi
}

@test "PR 1 cleanup leaves PR 12's review alone" {
  ( cd "$TMPDIR/seed"; git push -q origin HEAD:refs/pull/12/head )
  review 1
  review 12
  "$SKILL/cleanup.sh" 1 "$REPO"
  gone 1
  [ -d "$REPO/.claude/worktrees/review-pr12-stub" ]
}
