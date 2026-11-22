#!/usr/bin/env bash
# Remove what run.sh leaves behind for a PR: the review worktree(s), their
# review-pr<N>-<harness> branches and refs/review-by-harness/pr<N>.
#
# Usage:
#   cleanup.sh <pr-number> [repo-dir] [--harness NAME] [--archive DIR] [--discard]
#   cleanup.sh --prune [repo-dir] [--archive DIR]
#
# A worktree whose fix pass left a diff is kept until that diff is
# incorporated: the PR is merged or closed, or the caller says --discard
# after applying it to the PR branch. --archive copies .review-round/ (with
# the handback diff) to DIR/review-pr<N>-<harness>[-k] first. --prune
# cleans every review worktree and ref whose PR is merged or closed, and
# never touches an open PR's, which may belong to a live session.
set -euo pipefail

PR=""
REPO_ARG="."
HARNESS=""
ARCHIVE=""
DISCARD=0
PRUNE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --harness) HARNESS="${2:?--harness needs a value}"; shift 2 ;;
        --archive) ARCHIVE="${2:?--archive needs a directory}"; shift 2 ;;
        --discard) DISCARD=1; shift ;;
        --prune)   PRUNE=1; shift ;;
        -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *)  if [ "$PRUNE" -eq 0 ] && [ -z "$PR" ]; then PR="$1"; else REPO_ARG="$1"; fi; shift ;;
    esac
done
if [ "$PRUNE" -eq 1 ]; then
    [ -z "$PR" ] && [ -z "$HARNESS" ] && [ "$DISCARD" -eq 0 ] \
        || { echo "--prune takes only [repo-dir] and --archive" >&2; exit 2; }
else
    [[ "$PR" =~ ^[0-9]+$ ]] || { echo "usage: cleanup.sh <pr-number> [repo-dir] [--harness NAME] [--archive DIR] [--discard] | --prune [repo-dir] [--archive DIR]" >&2; exit 2; }
fi
[ -z "$HARNESS" ] || [[ "$HARNESS" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "invalid harness name" >&2; exit 2; }
if [ -n "$ARCHIVE" ]; then
    mkdir -p "$ARCHIVE"
    ARCHIVE="$(cd "$ARCHIVE" && pwd)"
fi

REPO_DIR="$(cd "$REPO_ARG" && git rev-parse --show-toplevel)"
cd "$REPO_DIR"
WT_ROOT="$REPO_DIR/.claude/worktrees"
LOCK_DIR="$(cd "$(git rev-parse --git-common-dir)" && pwd)/review-by-harness"

# lock_review <name>: take run.sh's lock for review-pr<N>-<harness> on fd 8.
lock_review() {
    command -v flock >/dev/null || return 0
    mkdir -p "$LOCK_DIR"
    exec 8>"$LOCK_DIR/${1#review-}.lock"
    flock -n 8
}

pr_state() { gh pr view "$1" --json state -q .state 2>/dev/null || echo UNKNOWN; }

# Registered review worktrees for PR $1 (all harnesses unless --harness).
review_worktrees() {
    git worktree list --porcelain | sed -n 's/^worktree //p' | while read -r wt; do
        [ "${wt%/*}" = "$WT_ROOT" ] || continue
        name="${wt##*/}"
        [[ "$name" =~ ^review-pr$1-[a-zA-Z0-9_-]+$ ]] || continue
        [ -z "$HARNESS" ] || [ "$name" = "review-pr$1-$HARNESS" ] || continue
        echo "$wt"
    done
}

# has_handback <wt>: the fix pass left staged, unstaged or untracked changes.
has_handback() {
    ! git -C "$1" diff --quiet HEAD || [ -n "$(git -C "$1" ls-files --others --exclude-standard)" ]
}

archive_round() {  # archive_round <wt>
    local wt="$1" name dest k=2
    name="${wt##*/}"
    [ -d "$wt/.review-round" ] || { echo "### $name: no .review-round to archive"; return 0; }
    if has_handback "$wt"; then
        git -C "$wt" --no-pager diff HEAD > "$wt/.review-round/handback.diff"
        git -C "$wt" ls-files --others --exclude-standard > "$wt/.review-round/handback-untracked.txt"
    fi
    git -C "$wt" rev-parse HEAD > "$wt/.review-round/reviewed-head"
    dest="$ARCHIVE/$name"
    while [ -e "$dest" ]; do dest="$ARCHIVE/$name-$k"; k=$((k + 1)); done
    cp -R "$wt/.review-round" "$dest"
    echo "### $name: archived to $dest"
}

clean_pr() {  # clean_pr <pr> <state>: returns 1 when something was kept
    local pr="$1" state="$2" wt name kept=0
    while read -r wt; do
        [ -n "$wt" ] || continue
        name="${wt##*/}"
        if ! lock_review "$name"; then
            echo "!!! $name: a review is running in it; left alone."
            kept=1
            continue
        fi
        if has_handback "$wt" && [ "$DISCARD" -eq 0 ] && [ "$state" != MERGED ] && [ "$state" != CLOSED ]; then
            echo "!!! $name: the fix pass left changes that are not incorporated (PR $state)."
            echo "!!! Apply them to the PR branch, then rerun with --discard."
            kept=1
            exec 8>&-
            continue
        fi
        [ -z "$ARCHIVE" ] || archive_round "$wt"
        git worktree remove --force "$wt"
        echo "### $name: worktree removed"
        exec 8>&-
    done < <(review_worktrees "$pr")
    # Branches whose worktree is already gone (removed by hand, or pruned).
    git worktree prune
    while read -r name; do
        [ -n "$name" ] || continue
        [ -z "$HARNESS" ] || [ "$name" = "review-pr$pr-$HARNESS" ] || continue
        [ -d "$WT_ROOT/$name" ] && continue
        git branch -D --quiet "$name" && echo "### $name: branch deleted"
    done < <(git for-each-ref --format='%(refname:short)' "refs/heads/review-pr$pr-*")
    # The fetched PR head is shared by every harness; drop it with the last one.
    if [ -z "$(review_worktrees_any "$pr")" ] && git show-ref --verify --quiet "refs/review-by-harness/pr$pr"; then
        git update-ref -d "refs/review-by-harness/pr$pr"
        echo "### refs/review-by-harness/pr$pr deleted"
    fi
    return "$kept"
}

review_worktrees_any() { HARNESS="" review_worktrees "$1"; }

if [ "$PRUNE" -eq 0 ]; then
    clean_pr "$PR" "$(pr_state "$PR")" || exit 1
    exit 0
fi

# --prune: every PR number that still has a review ref, branch or worktree.
mapfile -t PRS < <({
    git for-each-ref --format='%(refname)' refs/review-by-harness/ | sed -n 's|^refs/review-by-harness/pr\([0-9]*\)$|\1|p'
    git for-each-ref --format='%(refname:short)' 'refs/heads/review-pr*' | sed -n 's/^review-pr\([0-9]*\)-.*/\1/p'
    git worktree list --porcelain | sed -n "s|^worktree $WT_ROOT/review-pr\([0-9]*\)-.*|\1|p"
} | sort -un)
status=0
for pr in "${PRS[@]}"; do
    state=$(pr_state "$pr")
    case "$state" in
        MERGED|CLOSED) clean_pr "$pr" "$state" || status=1 ;;
        *) echo "### pr$pr: $state, left alone" ;;
    esac
done
exit "$status"
