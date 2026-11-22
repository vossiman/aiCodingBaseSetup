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
  [ "$(cat "$TMPDIR/runs/reviews/review-pr1-stub/review-round/review.md")" = "stub findings" ]
  [ -s "$TMPDIR/runs/reviews/review-pr1-stub/reviewed-head" ]
  [ -z "$(git -C "$REPO" worktree list --porcelain | grep review-pr1 || true)" ]
}

@test "a second archive of the same review gets its own directory" {
  review 1
  "$SKILL/cleanup.sh" 1 "$REPO" --archive "$TMPDIR/a"
  review 1
  "$SKILL/cleanup.sh" 1 "$REPO" --archive "$TMPDIR/a"
  [ -f "$TMPDIR/a/review-pr1-stub/review-round/review.md" ]
  [ -f "$TMPDIR/a/review-pr1-stub-2/review-round/review.md" ]
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

@test "a live review's lock stops a second run and cleanup from touching its worktree" {
  review 1
  lock="$REPO/.git/review-by-harness/pr1-stub.lock"
  [ -f "$lock" ]
  exec 7>"$lock"; flock -n 7
  run "$SKILL/run.sh" 1 "$REPO" --harness stub --review-only
  [ "$status" -eq 1 ]
  [[ "$output" == *"another review of PR #1 with stub is running"* ]]
  run "$SKILL/cleanup.sh" 1 "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"a review is running in it"* ]]
  [ -d "$REPO/.claude/worktrees/review-pr1-stub" ]
  exec 7>&-
  run "$SKILL/cleanup.sh" 1 "$REPO"
  [ "$status" -eq 0 ]
  gone 1
}

@test "a new round refuses to reset a worktree that still holds a fix diff" {
  review_fix 1
  run "$SKILL/run.sh" 1 "$REPO" --harness stub --review-only
  [ "$status" -eq 1 ]
  [[ "$output" == *"holds an earlier fix pass's changes"* ]]
  grep -q "edited by stub" "$REPO/.claude/worktrees/review-pr1-stub/src.txt"
  "$SKILL/cleanup.sh" 1 "$REPO" --archive "$TMPDIR/a" --discard
  review 1
}

@test "a failed archive keeps the worktree and exits non-zero" {
  review 1
  mkdir -p "$TMPDIR/ro"; chmod 500 "$TMPDIR/ro"
  run "$SKILL/cleanup.sh" 1 "$REPO" --archive "$TMPDIR/ro"
  chmod 700 "$TMPDIR/ro"
  [ "$status" -eq 1 ]
  [[ "$output" == *"archiving failed; worktree kept"* ]]
  [ -d "$REPO/.claude/worktrees/review-pr1-stub" ]
}

@test "a PR-tracked .review-round symlink is never written through" {
  ( cd "$TMPDIR/seed"
    ln -s "$TMPDIR/victim" .review-round; git add .review-round; git commit -qm link
    git push -q -f origin HEAD:refs/pull/1/head )
  mkdir "$TMPDIR/victim"; echo keep > "$TMPDIR/victim/reviewed-head"
  run "$SKILL/run.sh" 1 "$REPO" --harness stub --review-only
  [ "$status" -eq 1 ]
  run "$SKILL/cleanup.sh" 1 "$REPO" --archive "$TMPDIR/a"
  [ "$status" -eq 0 ]
  [ "$(cat "$TMPDIR/victim/reviewed-head")" = keep ]
  [ ! -e "$TMPDIR/a/review-pr1-stub/review-round" ]
}

@test "a fix the harness committed is kept like an uncommitted one" {
  sed -i 's|echo "stub fix report"|git -C "$2" -c user.name=t -c user.email=t@t commit -qam fix; echo "stub fix report"|' "$SKILL/harnesses/stub.sh"
  review_fix 1
  git -C "$REPO/.claude/worktrees/review-pr1-stub" diff --quiet HEAD
  run "$SKILL/cleanup.sh" 1 "$REPO"
  [ "$status" -eq 1 ]
  run "$SKILL/run.sh" 1 "$REPO" --harness stub --review-only
  [ "$status" -eq 1 ]
  "$SKILL/cleanup.sh" 1 "$REPO" --archive "$TMPDIR/a" --discard
  grep -q "edited by stub" "$TMPDIR/a/review-pr1-stub/handback.diff"
}

@test "an interrupted fix pass still protects its edits from the next round" {
  sed -i 's|echo "stub fix report" > "$3/fix.md"|exit 1|' "$SKILL/harnesses/stub.sh"
  REVIEW_CONFIG="$TMPDIR/cfg.env" run "$SKILL/run.sh" 1 "$REPO" --harness stub
  [ "$status" -eq 1 ]
  run "$SKILL/run.sh" 1 "$REPO" --harness stub --review-only
  [ "$status" -eq 1 ]
  [[ "$output" == *"holds an earlier fix pass's changes"* ]]
}

@test "new files a fix created are archived with their contents" {
  sed -i 's|echo "stub fix report"|echo fresh > "$2/new.txt"; echo "stub fix report"|' "$SKILL/harnesses/stub.sh"
  review_fix 1
  "$SKILL/cleanup.sh" 1 "$REPO" --archive "$TMPDIR/a" --discard
  [ "$(tar -xOf "$TMPDIR/a/review-pr1-stub/handback-untracked.tar" new.txt)" = fresh ]
}

@test "a lookalike branch with no review worktree is never deleted" {
  git -C "$REPO" branch review-pr1-mine origin/main
  review 1
  "$SKILL/cleanup.sh" 1 "$REPO"
  gone 1
  git -C "$REPO" show-ref --verify --quiet refs/heads/review-pr1-mine
  echo MERGED > "$TMPDIR/state-1"
  run "$SKILL/cleanup.sh" --prune "$REPO"
  git -C "$REPO" show-ref --verify --quiet refs/heads/review-pr1-mine
  [[ "$output" == *"review-pr1-mine: branch without a review worktree"* ]]
}

@test "cleanup run from a linked checkout finds the review made from the main one" {
  review 1
  git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/feat" -b feat-local origin/main
  run "$SKILL/cleanup.sh" 1 "$REPO/.claude/worktrees/feat"
  [ "$status" -eq 0 ]
  gone 1
}
