#!/usr/bin/env bash
# Reports end-of-session facts for /wrapup. Its only write is `git fetch --prune`,
# which refreshes remote-tracking refs so the report is not stale.
# Gaps are data; only a section that could not run gives a non-zero exit.
set -uo pipefail

SESSIONS_DIR="${HOME}/.claude/sessions"
failed=0

usage() {
  printf 'usage: check.sh [repo-path ...]\n'
  printf 'Reports git, PR, worktree, submodule and out/ state. Defaults to the current directory.\n'
}

section() {
  local name=$1 output rc
  shift
  output=$("$@" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '== %s [ok]\n' "$name"
  else
    printf '== %s [FAILED]\n' "$name"
    failed=1
  fi
  [ -n "$output" ] && printf '%s\n' "$output"
  return 0
}

has_origin() { git remote get-url origin >/dev/null 2>&1; }

default_branch() {
  local ref
  ref=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) \
    && { printf '%s\n' "${ref#origin/}"; return; }
  git show-ref --verify --quiet refs/heads/main && { echo main; return; }
  git show-ref --verify --quiet refs/heads/master && { echo master; return; }
  git rev-parse --abbrev-ref HEAD
}

check_fetch() {
  has_origin || { echo "no origin remote"; return 0; }
  timeout 60 git fetch --quiet --prune --no-recurse-submodules origin
}

check_tree() {
  local status
  status=$(git status --porcelain) || return 1
  if [ -n "$status" ]; then printf '%s\n' "$status"; else echo "clean"; fi
}

check_stashes() {
  local stashes
  stashes=$(git stash list) || return 1
  if [ -n "$stashes" ]; then
    echo "note: the stash stack is shared by all worktrees of this repo"
    printf '%s\n' "$stashes"
  else
    echo "none"
  fi
}

check_branches() {
  local base ref upstream track found=0
  base=$(default_branch) || return 1
  while IFS='|' read -r ref upstream track; do
    if [ -z "$upstream" ]; then
      if ! git merge-base --is-ancestor "refs/heads/$ref" "refs/heads/$base" 2>/dev/null; then
        printf 'no upstream: %s\n' "$ref"
        found=1
      fi
    elif [ "$track" = "[gone]" ]; then
      printf 'upstream gone (may be squash-merged): %s\n' "$ref"
      found=1
    elif [[ "$track" == *ahead* ]]; then
      printf 'unpushed: %s %s\n' "$ref" "$track"
      found=1
    fi
  done < <(git for-each-ref --format='%(refname:short)|%(upstream:short)|%(upstream:track)' refs/heads)
  [ "$found" -eq 1 ] || echo "nothing unpushed"
}

check_merged() {
  local base branch current found=0
  base=$(default_branch) || return 1
  current=$(git branch --show-current)
  while IFS= read -r branch; do
    [ "$branch" = "$base" ] && continue
    [ "$branch" = "$current" ] && continue
    printf 'merged into %s: %s\n' "$base" "$branch"
    found=1
  done < <(git for-each-ref --merged "refs/heads/$base" --format='%(refname:short)' refs/heads)
  [ "$found" -eq 1 ] || echo "none"
}

check_prs() {
  local branch url
  url=$(git remote get-url origin 2>/dev/null) || { echo "no origin remote"; return 0; }
  case "$url" in
    *github.com*) ;;
    *) echo "origin is not GitHub"; return 0 ;;
  esac
  branch=$(git branch --show-current)
  [ -n "$branch" ] || { echo "detached HEAD"; return 0; }
  command -v gh >/dev/null || { echo "gh is not installed"; return 1; }
  local prs
  prs=$(timeout 30 gh pr list --head "$branch" --state open \
    --json number,title,url,isDraft,mergeable,statusCheckRollup \
    --jq '.[]
      | ([.statusCheckRollup[]? | select(.conclusion == "FAILURE" or .conclusion == "TIMED_OUT" or .conclusion == "CANCELLED")] | length) as $failing
      | ([.statusCheckRollup[]? | select((.status // "COMPLETED") != "COMPLETED")] | length) as $pending
      | "#\(.number) \(.title) \(.url) draft=\(.isDraft) mergeable=\(.mergeable) failing_checks=\($failing) pending_checks=\($pending)"') || return 1
  if [ -n "$prs" ]; then printf '%s\n' "$prs"; else echo "none on $branch"; fi
}

live_session_cwds() {
  local file pid cwd
  for file in "$SESSIONS_DIR"/*.json; do
    [ -f "$file" ] || continue
    pid=$(jq -r '.pid // empty' "$file" 2>/dev/null) || continue
    cwd=$(jq -r '.cwd // empty' "$file" 2>/dev/null) || continue
    [ -n "$pid" ] && [ -n "$cwd" ] || continue
    kill -0 "$pid" 2>/dev/null || continue
    realpath -m -- "$cwd"
  done
}

# A submodule's main worktree is listed by its path under .git/modules.
worktree_root() {
  local path=$1 configured
  if [ ! -e "$path/.git" ] && configured=$(git -C "$path" config core.worktree 2>/dev/null); then
    realpath -m -- "$path/$configured"
  else
    realpath -m -- "$path"
  fi
}

check_worktrees() {
  command -v jq >/dev/null || { echo "jq is not installed"; return 1; }
  local here path sessions dirty owner count
  here=$(realpath -- "$(git rev-parse --show-toplevel)") || return 1
  sessions=$(live_session_cwds)
  while IFS= read -r path; do
    path=$(worktree_root "$path")
    count=$(printf '%s\n' "$sessions" | grep -cxF -- "$path")
    if [ "$path" = "$here" ]; then
      owner="current"
      [ "$count" -gt 1 ] && owner="current, shared with $((count - 1)) other live session(s)"
    elif [ "$count" -gt 0 ]; then
      owner="foreign"
    else
      owner="unknown"
    fi
    if [ -d "$path" ]; then
      dirty=$(git -C "$path" status --porcelain | wc -l)
    else
      dirty="missing"
    fi
    printf '%s owner=%s dirty=%s\n' "$path" "$owner" "$dirty"
  done < <(git worktree list --porcelain | sed -n 's/^worktree //p')
}

check_submodules() {
  [ -f .gitmodules ] || { echo "none"; return 0; }
  local path rest prefix dirty local_commits
  while read -r prefix path rest; do
    case "$prefix" in -*) continue ;; esac
    dirty=$(git -C "$path" status --porcelain | wc -l)
    local_commits=$(git -C "$path" rev-list --count HEAD --not --remotes)
    printf '%s dirty=%s commits_not_on_remote=%s\n' "$path" "$dirty" "$local_commits"
  done < <(git submodule status)
}

check_out() {
  [ -d out ] || { echo "no out/"; return 0; }
  local files
  files=$(find out -type f | LC_ALL=C sort)
  [ -n "$files" ] || { echo "empty"; return 0; }
  printf '%s\n' "$files"
  du -sh out
}

check_repo() {
  local repo=$1 root
  printf '#### %s\n' "$repo"
  if ! root=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null); then
    printf '== repo [FAILED]\nnot a git repository\n'
    failed=1
    return
  fi
  cd "$root" || { failed=1; return; }
  printf 'branch: %s\n' "$(git branch --show-current || true)"
  section fetch check_fetch
  section tree check_tree
  section stashes check_stashes
  section branches check_branches
  section merged-branches check_merged
  section open-prs check_prs
  section worktrees check_worktrees
  section submodules check_submodules
  section out check_out
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

[ "$#" -gt 0 ] || set -- "$PWD"
start=$PWD
for repo in "$@"; do
  cd "$start" || exit 1
  check_repo "$repo"
done
exit "$failed"
