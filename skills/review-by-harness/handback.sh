# shellcheck shell=bash
# The one handback check shared by run.sh (rerun guard, reporting) and
# cleanup.sh. Sourced, never run. A fix pass's work lives only in the review
# worktree until the commissioning agent copies it onto the PR branch.
#
# Handback, compared with the reviewed commit: a tracked diff (which covers
# commits the harness made), untracked files that are not ignored, and
# ignored files under out/. The driver's own .review-round/ never counts.

# reviewed_head <wt> [pr]: the PR commit the review started from. Older runs
# recorded none; then the fetched ref stands in only while HEAD still equals
# it. Fails when the commit cannot be established.
reviewed_head() {
    local f="$1/.review-round/reviewed-head" sha="" head
    if [ -f "$f" ] && [ ! -L "$f" ]; then
        sha=$(head -c 64 "$f" | tr -dc '0-9a-f') || sha=""
        [ -z "$sha" ] || { git -C "$1" rev-parse --verify --quiet "$sha^{commit}" && return; }
    fi
    [ -n "${2:-}" ] || return 1
    head=$(git -C "$1" rev-parse --verify --quiet HEAD) || return 1
    [ "$(git -C "$1" rev-parse --verify --quiet "refs/review-by-harness/pr$2^{commit}" || true)" = "$head" ] || return 1
    echo "$head"
}

# handback_files <wt>: new files of the handback, one per line.
handback_files() {
    git -C "$1" ls-files --others --exclude-standard -- . ':(exclude).review-round' &&
        git -C "$1" ls-files --others --ignored --exclude-standard -- out/
}

# handback_files_z <wt>: the same list, NUL-separated, for tar.
handback_files_z() {
    git -C "$1" ls-files -z --others --exclude-standard -- . ':(exclude).review-round' &&
        git -C "$1" ls-files -z --others --ignored --exclude-standard -- out/
}

# handback_state <wt> [pr]: prints none, present or unknown. Callers treat
# unknown like present. Always succeeds, so it is safe under errexit.
handback_state() {
    local rh files
    rh=$(reviewed_head "$1" "${2:-}") || { echo unknown; return 0; }
    if ! git -C "$1" diff --quiet "$rh" -- . ':(exclude).review-round' 2>/dev/null; then
        echo present; return 0
    fi
    files=$(handback_files "$1" 2>/dev/null) || { echo unknown; return 0; }
    if [ -n "$files" ]; then echo present; else echo none; fi
}

# handback_bundle <wt> <file>: bundle the commits on the worktree's HEAD that
# no remote-tracking or fetched PR ref holds. Writes nothing when there are none.
handback_bundle() {
    local n
    n=$(git -C "$1" rev-list --count HEAD --not --remotes --glob='refs/review-by-harness/*') || return 1
    [ "$n" -eq 0 ] && return 0
    git -C "$1" bundle create --quiet "$2" HEAD --not --remotes --glob='refs/review-by-harness/*'
}
