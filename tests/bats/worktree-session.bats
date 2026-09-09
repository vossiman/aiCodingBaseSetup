#!/usr/bin/env bats
setup() {
  : "${BLUEPRINT_ROOT:?run via tests/bats/run.sh}"
  TEST_DIR=$(mktemp -d)
  export HOME="$TEST_DIR/home"; mkdir -p "$HOME"
  REPO="$TEST_DIR/repo"; git init -q -b main "$REPO"
  git -C "$REPO" -c user.name=t -c user.email=t@t commit --allow-empty -qm base
  HELPER="$BLUEPRINT_ROOT/bin/aicoding-worktree"
  cd "$REPO"
}
teardown() { cd /; rm -rf "$TEST_DIR"; }
@test "branch worktree preserves dirty shared checkout and ignores only worktree directory" {
  echo keep > mine.txt
  run "$HELPER" feat/test
  [ "$status" -eq 0 ]
  [ "$(git branch --show-current)" = main ]
  [ "$(cat mine.txt)" = keep ]
  [ "$(git -C .claude/worktrees/feat/test branch --show-current)" = feat/test ]
  [ "$(git status --short)" = '?? mine.txt' ]
}
@test "already linked worktree is reused for the same branch and refuses a different branch" {
  "$HELPER" feat/test
  cd .claude/worktrees/feat/test
  run "$HELPER" feat/test
  [ "$status" -eq 0 ]
  [ "$output" = "$PWD" ]
  run "$HELPER" feat/other
  [ "$status" -eq 1 ]
  [ "$(git branch --show-current)" = feat/test ]
}
@test "existing path and invalid branch never overwrite files" {
  mkdir -p .claude/worktrees/taken; echo keep > .claude/worktrees/taken/file
  run "$HELPER" taken
  [ "$status" -eq 1 ]
  [ "$(cat .claude/worktrees/taken/file)" = keep ]
  run "$HELPER" ../escape
  [ "$status" -ne 0 ]
}
@test "explicit base is honored and missing base is an error" {
  first=$(git rev-parse HEAD)
  git -c user.name=t -c user.email=t@t commit --allow-empty -qm second
  run "$HELPER" old "$first"
  [ "$status" -eq 0 ]
  [ "$(git -C .claude/worktrees/old rev-parse HEAD)" = "$first" ]
  run "$HELPER" bad no-such-ref
  [ "$status" -ne 0 ]
}
