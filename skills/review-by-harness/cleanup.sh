#!/usr/bin/env bash
# Remove what run.sh leaves behind for a PR: the review worktree(s), their
# review-pr<N>-<harness> branches and refs/review-by-harness/pr<N>.
#
# Usage:
#   cleanup.sh <pr-number> [repo-dir] [--harness NAME] [--archive DIR] [--discard]
#   cleanup.sh --prune [repo-dir] [--archive DIR]
#
# A fix pass's changes (see handback.sh) exist only in the review worktree.
# On an open PR, or when the PR state is unknown, such a worktree is kept
# until the caller says --discard after applying the changes to the PR
# branch. On a merged or closed PR it is archived to --archive DIR, or else
# to <git-common-dir>/review-by-harness/archive/, and then removed; --discard
# skips the default archive. An archive, DIR/review-pr<N>-<harness>[-k],
# holds the driver's .review-round/ plus the fix changes, and a git bundle
# of harness commits when the reviewed commit is unknown. If archiving fails
# nothing is removed. --prune is maintenance: it cleans every review whose
# PR is merged or closed and never touches an open PR's.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=handback.sh
. "$SKILL_DIR/handback.sh"

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
        -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
    ARCHIVE="$(cd -P "$ARCHIVE" && pwd)"
fi

REPO_DIR="$(cd "$REPO_ARG" && git rev-parse --show-toplevel)"
cd "$REPO_DIR"
LOCK_DIR="$(cd "$(git rev-parse --git-common-dir)" && pwd)/review-by-harness"
TAB=$'\t'

# The GitHub repo behind origin, where run.sh fetched the pull ref from.
# Plain gh would honour GH_REPO or a set-default that points elsewhere, so an
# origin that does not resolve leaves every PR state UNKNOWN (left alone).
GH_REPO_ID=${REVIEW_GH_REPO:-$(git remote get-url origin 2>/dev/null \
    | sed -nE 's#^(https://|ssh://)?(git@)?(ssh\.)?github\.com(:443)?[:/]([^/]+/[^/]+)$#\5#p' \
    | sed 's/\.git$//')}
pr_state() {
    [ -n "$GH_REPO_ID" ] || { echo UNKNOWN; return; }
    gh pr view "$1" --repo "$GH_REPO_ID" --json state -q .state 2>/dev/null || echo UNKNOWN
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

# driver_round <wt>: .review-round is the driver's, not a PR-tracked path or link.
driver_round() {
    [ -d "$1/.review-round" ] && [ ! -L "$1/.review-round" ] &&
        [ -f "$1/.review-round/run.json" ] && [ ! -L "$1/.review-round/run.json" ] &&
        [ -z "$(git -C "$1" ls-tree --name-only HEAD .review-round)" ]
}

# review_worktrees <pr>: "<path><TAB><branch>" for every review worktree of
# the PR that run.sh made, in whichever checkout of the repo it put it.
# A lookalike worktree without the driver's scratch directory is reported,
# never returned.
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
                        if [ ! -e "$wt" ] && [ ! -L "$wt" ]; then
                            echo "### $name: registered, but its directory is missing; left alone." >&2
                            echo "### Run 'git worktree prune' to drop the registration (it drops every stale one)." >&2
                        elif driver_round "$wt"; then
                            printf '%s\t%s\n' "$wt" "${br:--}"
                        else
                            echo "### $name: not made by run.sh (no .review-round/run.json), left alone" >&2
                        fi
                    fi
                fi
                wt="" ;;
        esac
    done
}

# archive_round <wt> <pr> <dir> <handback-state>: build in a temporary
# sibling, publish by rename only when every step worked, and never write
# inside the worktree.
archive_round() {
    local wt="$1" pr="$2" dir="$3" hb="$4" name dest tmp k=2 rh
    name="${wt##*/}"
    mkdir -p "$dir" && dir="$(cd -P "$dir" && pwd)" || return 1
    case "$dir/" in "$(cd -P "$wt" && pwd)/"*)
        echo "!!! $name: the archive directory is inside the worktree being removed"; return 1 ;;
    esac
    tmp=$(mktemp -d "$dir/.$name.XXXXXX") || return 1
    if ! {
        cp -RP "$wt/.review-round" "$tmp/review-round" &&
        if rh=$(reviewed_head "$wt" "$pr"); then echo "$rh" > "$tmp/reviewed-head"
        else rh=$(git -C "$wt" rev-parse HEAD) && echo "unknown; diff is against HEAD $rh" > "$tmp/reviewed-head"; fi &&
        if [ "$hb" != none ]; then
            git -C "$wt" --no-pager diff --binary --no-ext-diff --no-textconv --no-color "$rh" -- . ':(exclude).review-round' > "$tmp/handback.diff" &&
            handback_files_z "$wt" | tar -C "$wt" --null -T - -cf "$tmp/handback-untracked.tar"
        fi &&
        if [ "$hb" = unknown ]; then handback_bundle "$wt" "$tmp/handback.bundle"; fi
    }; then
        rm -rf "$tmp"; return 1
    fi
    dest="$dir/$name"
    while [ -e "$dest" ] || [ -L "$dest" ]; do dest="$dir/$name-$k"; k=$((k + 1)); done
    mv "$tmp" "$dest" || { rm -rf "$tmp"; return 1; }
    echo "### $name: archived to $dest"
}

clean_pr() {  # clean_pr <pr> <state>: returns 1 when something was kept or failed
    local pr="$1" state="$2" wt br name h hb dir kept=0
    while IFS="$TAB" read -r wt br; do
        [ -n "$wt" ] || continue
        name="${wt##*/}"; h="${name#review-pr"$pr"-}"
        if ! lock_take "$pr" "$h"; then
            echo "!!! $name: a review is running in it; left alone."
            kept=1; continue
        fi
        hb=$(handback_state "$wt" "$pr")
        dir="$ARCHIVE"
        if [ "$hb" != none ] && [ "$DISCARD" -eq 0 ]; then
            if [ "$state" != MERGED ] && [ "$state" != CLOSED ]; then
                if [ "$hb" = unknown ]; then
                    echo "!!! $name: the reviewed commit is unknown, so its changes may not be incorporated (PR $state)."
                else
                    echo "!!! $name: the fix pass left changes that are not incorporated (PR $state)."
                fi
                echo "!!! Apply them to the PR branch, then rerun with --discard."
                kept=1; unlock; continue
            fi
            # Merged or closed is no proof the fix landed: keep a copy.
            [ -n "$dir" ] || dir="$LOCK_DIR/archive"
        fi
        if [ -n "$dir" ] && ! archive_round "$wt" "$pr" "$dir" "$hb"; then
            echo "!!! $name: archiving failed; worktree kept."
            kept=1; unlock; continue
        fi
        if ! git worktree remove --force "$wt"; then
            kept=1; unlock; continue
        fi
        echo "### $name: worktree removed"
        # Only the branch run.sh made for this worktree, never a lookalike.
        if [ "$br" = "$name" ]; then
            if git branch -D --quiet "$br"; then echo "### $br: branch deleted"
            else echo "!!! $br: branch deletion failed"; kept=1; fi
        fi
        unlock
    done < <(review_worktrees "$pr")
    # The fetched PR head is shared by every harness: drop it with the last
    # review, under the per-PR lock run.sh holds from fetch to worktree add.
    if command -v flock >/dev/null; then
        exec 6>"$LOCK_DIR/pr$pr.lock"
        flock -w 60 6 || { echo "!!! pr$pr: ref lock busy; ref kept"; exec 6>&-; return 1; }
    fi
    if [ -z "$(HARNESS="" review_worktrees "$pr" 2>/dev/null)" ] &&
       git show-ref --verify --quiet "refs/review-by-harness/pr$pr"; then
        if git update-ref -d "refs/review-by-harness/pr$pr"; then
            echo "### refs/review-by-harness/pr$pr deleted"
        else
            echo "!!! refs/review-by-harness/pr$pr: deletion failed"; kept=1
        fi
    fi
    exec 6>&-
    return "$kept"
}

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
    git worktree list --porcelain | grep -qxF "branch refs/heads/$br" && continue
    echo "### $br: branch without a review worktree, left for manual cleanup"
done
exit "$status"
