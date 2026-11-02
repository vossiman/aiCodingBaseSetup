#!/usr/bin/env bats
# Facts reported by the /wrapup script, against throwaway git repos.

CHECK="$BATS_TEST_DIRNAME/../../skills/wrapup/check.sh"

setup() {
  WORK=$(mktemp -d)
  export HOME="$WORK/home"
  mkdir -p "$HOME/.claude/sessions" "$WORK/bin"
  export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
  git config --global user.name test
  git config --global user.email test@example.com
  git config --global init.defaultBranch main
  git config --global protocol.file.allow always
  cat > "$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
[ "${GH_STUB_STATUS:-0}" -eq 0 ] || exit "$GH_STUB_STATUS"
while [ "$#" -gt 0 ]; do
  [ "$1" = --jq ] && { printf '%s' "${GH_STUB_JSON:-[]}" | jq -r "$2"; exit; }
  shift
done
EOF
  chmod +x "$WORK/bin/gh"
  export PATH="$WORK/bin:$PATH"

  git init -q --bare "$WORK/origin.git"
  git clone -q "$WORK/origin.git" "$WORK/repo" 2>/dev/null
  git -C "$WORK/repo" commit -q --allow-empty -m first
  git -C "$WORK/repo" push -q -u origin main
  REPO="$WORK/repo"
  cd "$REPO" || return 1
}

teardown() {
  cd /
  rm -rf "$WORK"
}

@test "a clean repo exits zero and reports nothing to do" {
  run bash "$CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean"* ]]
  [[ "$output" == *"nothing unpushed"* ]]
}

@test "a dirty tree is reported" {
  echo x > new.txt
  run bash "$CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"?? new.txt"* ]]
}

@test "a stash is reported" {
  echo x > tracked.txt
  git add tracked.txt
  git stash push -q -m planted
  run bash "$CHECK"
  [[ "$output" == *"planted"* ]]
}

@test "an unpushed commit is reported" {
  git commit -q --allow-empty -m local
  run bash "$CHECK"
  [[ "$output" == *"unpushed: main [ahead 1]"* ]]
}

@test "a branch with no upstream and its own commits is reported" {
  git switch -q -c feat/x
  git commit -q --allow-empty -m local
  git switch -q main
  run bash "$CHECK"
  [[ "$output" == *"no upstream: feat/x"* ]]
}

@test "a merged local branch is reported" {
  git branch feat/merged
  run bash "$CHECK"
  [[ "$output" == *"merged into main: feat/merged"* ]]
}

@test "a branch whose remote was deleted is reported" {
  git switch -q -c feat/gone
  git commit -q --allow-empty -m local
  git push -q -u origin feat/gone
  git switch -q main
  git push -q origin --delete feat/gone
  run bash "$CHECK"
  [[ "$output" == *"upstream gone (may be squash-merged): feat/gone"* ]]
}

@test "a worktree with no live session is unknown, one with a live session is foreign" {
  git worktree add -q "$WORK/wt-unknown" -b wt-unknown
  git worktree add -q "$WORK/wt-foreign" -b wt-foreign
  printf '{"pid":%s,"cwd":"%s"}\n' "$$" "$WORK/wt-foreign" > "$HOME/.claude/sessions/1.json"
  run bash "$CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"wt-unknown owner=unknown"* ]]
  [[ "$output" == *"wt-foreign owner=foreign"* ]]
}

@test "a dead session does not make a worktree foreign" {
  git worktree add -q "$WORK/wt-dead" -b wt-dead
  printf '{"pid":999999,"cwd":"%s"}\n' "$WORK/wt-dead" > "$HOME/.claude/sessions/1.json"
  run bash "$CHECK"
  [[ "$output" == *"wt-dead owner=unknown"* ]]
}

@test "a submodule with local changes is reported" {
  git init -q "$WORK/sub"
  git -C "$WORK/sub" commit -q --allow-empty -m first
  git submodule --quiet add "$WORK/sub" sub
  git commit -q -m "add submodule"
  git -C sub commit -q --allow-empty -m local
  echo x > sub/new.txt
  run bash "$CHECK"
  [[ "$output" == *"sub dirty=1 commits_not_on_remote=1"* ]]
}

@test "files in out are listed" {
  mkdir out
  echo x > out/report.txt
  run bash "$CHECK"
  [[ "$output" == *"out/report.txt"* ]]
}

@test "a section that cannot run gives a non-zero exit and names the section" {
  git remote set-url origin "$WORK/missing.git"
  run bash "$CHECK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"== fetch [FAILED]"* ]]
}

@test "a failing gh is a failed check on a GitHub repo" {
  mkdir "$WORK/github.com"
  git clone -q --bare "$WORK/origin.git" "$WORK/github.com/origin.git"
  git remote set-url origin "$WORK/github.com/origin.git"
  GH_STUB_STATUS=1 run bash "$CHECK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"== open-prs [FAILED]"* ]]
}

@test "an open PR is reported with its check counts" {
  mkdir "$WORK/github.com"
  git clone -q --bare "$WORK/origin.git" "$WORK/github.com/origin.git"
  git remote set-url origin "$WORK/github.com/origin.git"
  export GH_STUB_JSON='[{"number":7,"title":"t","url":"u","isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"FAILURE","status":"COMPLETED"},{"conclusion":"","status":"IN_PROGRESS"},{"conclusion":"SUCCESS","status":"COMPLETED"}]}]'
  run bash "$CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"#7 t u draft=false mergeable=MERGEABLE failing_checks=1 pending_checks=1"* ]]
}

@test "a worktree of a submodule lists the submodule checkout, not its git dir" {
  git init -q "$WORK/sub"
  git -C "$WORK/sub" commit -q --allow-empty -m first
  git submodule --quiet add "$WORK/sub" sub
  git commit -q -m "add submodule"
  git -C sub worktree add -q "$WORK/sub-wt" -b sub-wt
  run bash "$CHECK" "$WORK/sub-wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$(realpath "$REPO/sub") owner=unknown"* ]]
  if [[ "$output" == *".git/modules"* ]]; then false; fi
}

@test "a path that is not a repo fails" {
  mkdir "$WORK/plain"
  run bash "$CHECK" "$WORK/plain"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a git repository"* ]]
}

@test "several repos are all reported" {
  git clone -q "$WORK/origin.git" "$WORK/second" 2>/dev/null
  run bash "$CHECK" "$REPO" "$WORK/second"
  [ "$status" -eq 0 ]
  [[ "$output" == *"#### $REPO"* ]]
  [[ "$output" == *"#### $WORK/second"* ]]
}
