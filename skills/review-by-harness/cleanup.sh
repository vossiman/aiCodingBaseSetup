#!/usr/bin/env bash
# Remove what run.sh leaves behind for a PR: the review worktree(s), their
# review-pr<N>-<harness> branches and refs/review-by-harness/pr<N>.
#
# Usage:
#   cleanup.sh <pr-number> [repo-dir] [--harness NAME] [--archive DIR] [--discard]
#   cleanup.sh --prune [repo-dir] [--archive DIR]
#
# A worktree whose fix pass left changes is kept until they are
# incorporated: the PR is merged or closed, or the caller says --discard
# after applying them to the PR branch. --archive copies the driver's
# .review-round/ plus the fix changes to DIR/review-pr<N>-<harness>[-k]
# first; if that fails nothing is removed. --prune is maintenance: it cleans
# every review whose PR is merged or closed and never touches an open PR's.
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
        -h|--help) sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
LOCK_DIR="$(cd "$(git rev-parse --git-common-dir)" && pwd)/review-by-harness"

# The GitHub repo behind origin, where run.sh fetched the pull ref from.
# Plain gh would honour GH_REPO or a set-default that points elsewhere.
GH_REPO_ID=$(git remote get-url origin 2>/dev/null \
    | sed -nE 's#^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)([^/]+/[^/]+)$#\2#p' \
    | sed 's/\.git$//')
pr_state() {
    local repo=()
    [ -z "$GH_REPO_ID" ] || repo=(--repo "$GH_REPO_ID")
    gh pr view "$1" ${repo[@]+"${repo[@]}"} --json state -q .state 2>/dev/null || echo UNKNOWN
}

# lock_take <pr> <harness>: take run.sh's lock on fd 8 until unlock, so no run
# starts on that worktree while cleanup works on it. Fails when a run holds it.
lock_take() {
    command -v flock >/dev/null || return 0
    mkdir -p "$LOCK_DIR"
    exec 8>"$LOCK_DIR/pr$1-$2.lock"
    flock -n 8
}
unlock() { exec 8>&-; }
# no_live_run <pr>: no harness holds a lock for this PR (run.sh takes its lock
# before fetching the shared ref).
no_live_run() {
    command -v flock >/dev/null || return 0
    local l
    for l in "$LOCK_DIR/pr$1-"*.lock; do
        [ -e "$l" ] || continue
        flock -n "$l" true || return 1
    done
}

# review_worktrees <pr>: "<path> <branch>" for every registered review
# worktree of the PR, in whichever checkout of the repo run.sh put it.
review_worktrees() {
    local wt="" br="" line name parent
    { git worktree list --porcelain; echo; } | while IFS= read -r line; do
        case "$line" in
            "worktree "*) wt="${line#worktree }"; br="" ;;
            "branch refs/heads/"*) br="${line#branch refs/heads/}" ;;
            "")
                if [ -n "$wt" ]; then
                    name="${wt##*/}"; parent="${wt%/*}"
                    if [[ "$name" =~ ^review-pr$1-[a-zA-Z0-9_-]+$ ]] &&
                       [ "${parent##*/}" = worktrees ] && [ "$(basename "${parent%/*}")" = .claude ] &&
                       { [ -z "$HARNESS" ] || [ "$name" = "review-pr$1-$HARNESS" ]; }; then
                        echo "$wt ${br:--}"
                    fi
                fi
                wt="" ;;
        esac
    done
}

# driver_round <wt>: .review-round is the driver's, not a PR-tracked path or link.
driver_round() {
    [ -d "$1/.review-round" ] && [ ! -L "$1/.review-round" ] &&
        [ -z "$(git -C "$1" ls-tree --name-only HEAD .review-round)" ]
}
reviewed_head() {  # the PR commit the run started from, else the worktree HEAD
    local f="$1/.review-round/reviewed-head" sha=""
    if driver_round "$1" && [ -f "$f" ] && [ ! -L "$f" ]; then
        sha=$(head -c 64 "$f" | tr -dc '0-9a-f')
    fi
    git -C "$1" rev-parse --verify --quiet "${sha:-HEAD}^{commit}" || git -C "$1" rev-parse HEAD
}

# has_handback <wt>: edits, new files or commits since the reviewed commit.
has_handback() {
    if git -C "$1" diff --quiet "$(reviewed_head "$1")"; then
        [ -n "$(git -C "$1" ls-files --others --exclude-standard)" ]
    fi
}

# archive_round <wt>: copy into a fresh directory outside the checkout; never
# write inside the worktree, whose paths the PR controls.
archive_round() {
    local wt="$1" name dest k=2 rh
    name="${wt##*/}"
    dest="$ARCHIVE/$name"
    while [ -e "$dest" ] || [ -L "$dest" ]; do dest="$ARCHIVE/$name-$k"; k=$((k + 1)); done
    mkdir "$dest" || return 1
    if driver_round "$wt"; then
        cp -RP "$wt/.review-round" "$dest/review-round" || return 1
    else
        echo "### $name: no driver-made .review-round to archive"
    fi
    rh=$(reviewed_head "$wt") || return 1
    echo "$rh" > "$dest/reviewed-head" || return 1
    if has_handback "$wt"; then
        git -C "$wt" --no-pager diff --binary "$rh" > "$dest/handback.diff" || return 1
        git -C "$wt" ls-files -z --others --exclude-standard \
            | tar -C "$wt" --null -T - -cf "$dest/handback-untracked.tar" || return 1
    fi
    echo "### $name: archived to $dest"
}

clean_pr() {  # clean_pr <pr> <state>: returns 1 when something was kept
    local pr="$1" state="$2" wt br name h kept=0
    while read -r wt br; do
        [ -n "$wt" ] || continue
        name="${wt##*/}"; h="${name#review-pr"$pr"-}"
        if ! lock_take "$pr" "$h"; then
            echo "!!! $name: a review is running in it; left alone."
            kept=1; continue
        fi
        if has_handback "$wt" && [ "$DISCARD" -eq 0 ] && [ "$state" != MERGED ] && [ "$state" != CLOSED ]; then
            echo "!!! $name: the fix pass left changes that are not incorporated (PR $state)."
            echo "!!! Apply them to the PR branch, then rerun with --discard."
            kept=1; unlock; continue
        fi
        if [ -n "$ARCHIVE" ] && ! archive_round "$wt"; then
            echo "!!! $name: archiving failed; worktree kept."
            kept=1; unlock; continue
        fi
        if ! git worktree remove --force "$wt"; then
            kept=1; unlock; continue
        fi
        echo "### $name: worktree removed"
        # Only the branch run.sh made for this worktree, never a lookalike.
        if [ "$br" = "$name" ] && git branch -D --quiet "$br"; then
            echo "### $br: branch deleted"
        fi
        unlock
    done < <(review_worktrees "$pr")
    # The fetched PR head is shared by every harness: drop it with the last review.
    if [ -z "$(HARNESS="" review_worktrees "$pr")" ] && no_live_run "$pr" &&
       git show-ref --verify --quiet "refs/review-by-harness/pr$pr"; then
        git update-ref -d "refs/review-by-harness/pr$pr"
        echo "### refs/review-by-harness/pr$pr deleted"
    fi
    return "$kept"
}

git worktree prune
if [ "$PRUNE" -eq 0 ]; then
    clean_pr "$PR" "$(pr_state "$PR")" || exit 1
    exit 0
fi

PRS=$({
    git for-each-ref --format='%(refname)' refs/review-by-harness/ | sed -n 's|^refs/review-by-harness/pr\([0-9]*\)$|\1|p'
    git worktree list --porcelain | sed -n 's|^worktree .*/\.claude/worktrees/review-pr\([0-9]*\)-.*|\1|p'
} | sort -un)
status=0
for pr in $PRS; do
    state=$(pr_state "$pr")
    case "$state" in
        MERGED|CLOSED) clean_pr "$pr" "$state" || status=1 ;;
        *) echo "### pr$pr: $state, left alone" ;;
    esac
done
for br in $(git for-each-ref --format='%(refname:short)' 'refs/heads/review-pr*'); do
    git worktree list --porcelain | grep -qx "branch refs/heads/$br" && continue
    echo "### $br: branch without a review worktree, left for manual cleanup"
done
exit "$status"
