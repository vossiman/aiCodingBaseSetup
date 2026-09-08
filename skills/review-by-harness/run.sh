#!/usr/bin/env bash
# Deterministic driver: review (and optionally fix) an open PR with an
# external agent harness, then hand the result back for verification.
#
# Everything mechanical lives here — worktree setup, base resolution, output
# layout, handback. The harness-specific parts are in harnesses/<name>.sh and
# the model-facing wording is in prompts/. Nothing here talks to a model.
#
# Usage: run.sh <pr-number> [repo-dir] [--harness auto|claude|codex|cursor] [--model MODEL] [--effort LEVEL] [--review-only]
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PR=""
REPO_ARG="."
HARNESS="auto"
CALLER="${REVIEW_CALLER:-}"
REVIEW_ONLY=0
MODEL_ARG=""
EFFORT_ARG=""

while [ $# -gt 0 ]; do
    case "$1" in
        --harness)     HARNESS="${2:?--harness needs a value}"; shift 2 ;;
        --caller)      CALLER="${2:?--caller needs claude or codex}"; shift 2 ;;
        --model)       MODEL_ARG="${2:?--model needs a value}"; shift 2 ;;
        --effort)      EFFORT_ARG="${2:?--effort needs a value}"; shift 2 ;;
        --review-only) REVIEW_ONLY=1; shift ;;
        -h|--help)
            sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *)  if [ -z "$PR" ]; then PR="$1"; else REPO_ARG="$1"; fi; shift ;;
    esac
done

[ -n "$PR" ] || { echo "usage: run.sh <pr-number> [repo-dir] [--harness auto|claude|codex|cursor] [--review-only]" >&2; exit 2; }

# Explicit --caller wins; otherwise use the runtime marker, never process
# names or a model guess. Unknown callers retain the historical Codex default.
if [ "$HARNESS" = auto ]; then
    if [ -z "$CALLER" ]; then
        if [ -n "${CLAUDECODE:-}" ]; then CALLER=claude
        elif [ -n "${CODEX_THREAD_ID:-}" ]; then CALLER=codex; fi
    fi
    case "$CALLER" in
        codex) HARNESS=claude ;;
        claude|"") HARNESS=codex ;;
        *) echo "unknown caller: $CALLER (use claude or codex)" >&2; exit 2 ;;
    esac
fi
[[ "$HARNESS" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "invalid harness name" >&2; exit 2; }

ADAPTER="$SKILL_DIR/harnesses/$HARNESS.sh"
[ -x "$ADAPTER" ] || { echo "no such harness: $HARNESS (have: $(cd "$SKILL_DIR/harnesses" && ls *.sh | sed 's/\.sh$//' | tr '\n' ' '))" >&2; exit 2; }

# Optional local config: REVIEW_SANDBOX / REVIEW_APPROVAL / REVIEW_MODEL.
# Never tracked — it records a human's decision about how much freedom a
# harness gets on this machine, which is not a property of the repo.
#
# First hit wins. The order exists because the obvious home for this file is
# the worst one: a copy beside the skill dies with every container rebuild and
# every fresh clone, so the same opt-in has to be written again forever.
#
#   $REVIEW_CONFIG               explicit override, for scripts and testing
#   ~/.claude/<name>.env         a HOST bind mount under devpod, so writing it
#                                once survives rebuilds and covers every
#                                container on that host
#   $XDG_CONFIG_HOME/<name>/...  the normal home on a laptop or desktop
#   $SKILL_DIR/config.env        beside the skill; dies with the checkout
#
# Note what the second path means: one file there opts in every devpod
# container on that host, not only this one. They are all the same kind of
# environment (no user namespaces), and the probe below still ignores the file
# wherever a harness can sandbox itself — but it is a host-wide decision, so
# make it deliberately.
for _cfg in \
    "${REVIEW_CONFIG:-}" \
    "$HOME/.claude/review-by-harness.env" \
    "${XDG_CONFIG_HOME:-$HOME/.config}/review-by-harness/config.env" \
    "$SKILL_DIR/config.env"
do
    [ -n "$_cfg" ] && [ -f "$_cfg" ] || continue
    # `set -a` is load-bearing, not decoration: the adapters run as child
    # processes, so a plainly-sourced assignment would stay a shell variable
    # they never see, and every documented override would silently do nothing.
    set -a
    # shellcheck disable=SC1091
    . "$_cfg"
    set +a
    REVIEW_CONFIG_USED="$_cfg"
    break
done
[ -n "${REVIEW_CONFIG_USED:-}" ] && echo "### config: $REVIEW_CONFIG_USED"

# CLI choices override machine config. Always pass and record a concrete model
# rather than inheriting the launching agent's default model accidentally.
[ -z "$MODEL_ARG" ] || REVIEW_MODEL="$MODEL_ARG"
[ -z "$EFFORT_ARG" ] || REVIEW_EFFORT="$EFFORT_ARG"
case "$HARNESS" in
    claude) REVIEW_MODEL="${REVIEW_MODEL:-claude-opus-5}"; REVIEW_EFFORT="${REVIEW_EFFORT:-high}" ;;
    codex) REVIEW_MODEL="${REVIEW_MODEL:-gpt-5.6-sol}"; REVIEW_EFFORT="${REVIEW_EFFORT:-high}" ;;
    cursor)
        REVIEW_MODEL="${REVIEW_MODEL:-cursor-grok-4.6-high-fast}"
        if [ -n "$EFFORT_ARG" ]; then
            echo 'Cursor effort is part of its model selector; use --model with an effort preset or bracket parameters, not --effort.' >&2
            exit 2
        fi
        # A shared Codex/Claude config may carry effort; never imply that
        # Cursor honors a separate flag it does not have.
        unset REVIEW_EFFORT
        ;;
esac
export REVIEW_MODEL REVIEW_EFFORT


# Does this machine let a harness sandbox itself? Bubblewrap needs unprivileged
# user namespaces, and `unshare -Ur` is the cheapest honest proxy for that.
#
# This matters because the same skill runs on very different machines. In the
# devpod container userns is blocked, so a harness can only work unconfined. On
# a laptop or desktop it usually works fine — and there, running a harness
# unconfined would give up real protection for nothing.
if unshare -Ur true 2>/dev/null; then
    # Prefer the harness's own sandbox whenever it is available, and ignore a
    # config.env that says otherwise: such a file is an opt-in for a machine
    # that CANNOT sandbox, and it must not silently follow you onto one that
    # can (a synced dotfile, a copied checkout, a rebuilt container).
    if [ -n "${REVIEW_SANDBOX:-}${REVIEW_APPROVAL:-}" ]; then
        echo "### note: this machine supports user namespaces, so the harness"
        echo "###       sandboxes itself — ignoring the overrides in config.env"
    fi
    unset REVIEW_SANDBOX REVIEW_APPROVAL
    echo "### sandbox: harness-native"
else
    echo "### sandbox: UNAVAILABLE on this machine (no unprivileged user namespaces)"
    if [ "$REVIEW_ONLY" -eq 0 ] && [ -z "${REVIEW_SANDBOX:-}${REVIEW_APPROVAL:-}" ]; then
        echo "!!! refusing to run the fix pass: the harness cannot sandbox itself"
        echo "!!! here, and nothing in config.env says you accept that."
        echo "!!! Use --review-only (safe, needs no override), or read the"
        echo "!!! \"Which passes actually run here\" section of SKILL.md and opt in."
        exit 1
    fi
    if [ "$REVIEW_ONLY" -eq 0 ]; then
        echo "### WARNING: the harness runs UNCONFINED, by your config.env opt-in."
        echo "###          Its only limits are the throwaway worktree and a prompt."
    fi
fi

REPO_DIR="$(cd "$REPO_ARG" && git rev-parse --show-toplevel)"
cd "$REPO_DIR"

BASE=$(gh pr view "$PR" --json baseRefName -q .baseRefName)
HEAD_REF=$(gh pr view "$PR" --json headRefName -q .headRefName)
TITLE=$(gh pr view "$PR" --json title -q .title)

WT="$REPO_DIR/.claude/worktrees/review-pr$PR-$HARNESS"
OUT="$WT/.review-round"

# Always re-fetch and reset: a PR head moves, and reviewing a stale commit
# produces findings about code that is no longer there. (Seen 2026-08-27: two
# runs minutes apart reviewed different commits and disagreed entirely.)
git worktree remove --force "$WT" 2>/dev/null || true
# refs/pull/N/head, not origin/<headRefName>: for a PR from a fork the head ref
# is only the fork branch's short name, so fetching it from origin either fails
# or — worse — silently reviews an unrelated base-repo branch that happens to
# share the name. The pull ref is the PR's actual head in every case.
git fetch origin "refs/pull/$PR/head:refs/review-by-harness/pr$PR" --force --quiet
git fetch origin "$BASE" --quiet
git worktree add --force -B "review-pr$PR-$HARNESS" "$WT" "refs/review-by-harness/pr$PR" >/dev/null
# The PR controls every checked-out path. Never accept its scratch directory
# (or a symlink/file in its place): even a real directory can contain report
# symlinks that redirect our writes. mkdir without -p claims a fresh directory
# atomically and refuses all pre-existing paths, including dangling symlinks.
if ! mkdir -m 700 "$OUT"; then
    echo "!!! refusing pre-existing review scratch path: $OUT" >&2
    exit 1
fi
jq -n --arg harness "$HARNESS" --arg model "${REVIEW_MODEL:-adapter-default}" \
    --arg effort "${REVIEW_EFFORT:-model-defined}" \
    '{harness:$harness, model:$model, effort:$effort}' > "$OUT/run.json"
# Keep the harness's own scratch out of the diff we hand back. A linked
# worktree's gitdir has no info/ directory until something creates it, and
# --git-path resolves per-worktree paths correctly where --git-dir does not.
EXCLUDE="$(git -C "$WT" rev-parse --git-path info/exclude)"
mkdir -p "$(dirname "$EXCLUDE")"
grep -qxF '.review-round/' "$EXCLUDE" 2>/dev/null \
    || echo '.review-round/' >> "$EXCLUDE"

START_HEAD=$(git -C "$WT" rev-parse HEAD)

# Session rules for the harness, prepended to the worktree's instruction
# files. Every harness reads a repo-root AGENTS.md ahead of its global
# instructions (codex prefers AGENTS.override.md when one exists), and the
# global ones tell agents to file work they find on the board; a reviewer
# that obeys that files tickets for findings the author is about to fix
# (seen on aiCodingBaseSetup#139: four tickets in one review pass).
#
# The block sits between markers so restore can strip exactly it and keep
# any edit the fix pass legitimately made to the file underneath. A file
# that is a symlink (AGENTS.md -> CLAUDE.md is common) is replaced by a
# regular file for the run and put back from git, since writing through the
# link would edit its target. Restore also runs from an EXIT trap, so a
# failing adapter cannot leave the rules behind in the retained worktree.
AGENTS_FILES=(AGENTS.md)
[ "$HARNESS" = claude ] && AGENTS_FILES+=(CLAUDE.md)
if [ -e "$WT/AGENTS.override.md" ] || [ -L "$WT/AGENTS.override.md" ]; then
    AGENTS_FILES+=(AGENTS.override.md)
fi
RB_BEGIN='<!-- review-by-harness:begin -->'
RB_END='<!-- review-by-harness:end -->'
validate_instruction_paths() {
    # Resolve links without reading their contents. Python also gives us a
    # portable atomic replacement below (mv treats directory targets specially).
    python3 - "$WT" "${AGENTS_FILES[@]}" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1]).resolve()
for name in sys.argv[2:]:
    path = root / name
    try:
        if not path.exists() and not path.is_symlink():
            continue
        target = path.resolve(strict=True)
        if root not in target.parents or not target.is_file():
            raise ValueError("must resolve to a regular file inside the worktree")
    except (OSError, RuntimeError, ValueError) as exc:
        sys.exit(f"!!! refusing unsafe instruction path {name}: {exc}")
PY
}
_agents_kind() {  # _agents_kind <name>: tracked | untracked | absent
    if git -C "$WT" cat-file -e "HEAD:$1" 2>/dev/null; then echo tracked
    elif [ -e "$WT/$1" ] || [ -L "$WT/$1" ]; then echo untracked
    else echo absent; fi
}
install_agents() {  # install_agents <review|fix>
    local f kind staged
    validate_instruction_paths
    for f in "${AGENTS_FILES[@]}"; do
        kind="$(_agents_kind "$f")"
        if [ -L "$WT/$f" ]; then
            [ -L "$OUT/$f.orig" ] || cp -P "$WT/$f" "$OUT/$f.orig"
        fi
        [ -e "$OUT/$f.kind" ] || echo "$kind" > "$OUT/$f.kind"
        staged=$(mktemp "$OUT/$f.XXXXXX")
        if [ -f "$WT/$f" ] && [ ! -L "$WT/$f" ]; then
            # Portable mode preservation; chmod --reference is GNU-specific.
            cp -p "$WT/$f" "$staged"
        fi
        # Stream the body: command substitution strips trailing newlines and
        # would make the unchanged-worktree check blame our own normalization
        # on the reviewer. Stage beside the output, then replace a symlink
        # rather than writing through it. Strip our block in either case.
        { echo "$RB_BEGIN"; cat "$SKILL_DIR/prompts/agents-$1.md"; echo "$RB_END"
          if [ -f "$WT/$f" ]; then
              sed "/^$RB_BEGIN\$/,/^$RB_END\$/d" "$WT/$f"
          fi
        } > "$staged"
        # Same-filesystem rename is atomic: interruption leaves either the
        # original or complete injected file for the EXIT restoration trap.
        python3 -c 'import os, sys; os.replace(sys.argv[1], sys.argv[2])' "$staged" "$WT/$f"
    done
}
restore_agents() {
    local f kind
    validate_instruction_paths || return 1
    for f in "${AGENTS_FILES[@]}"; do
        # An interrupted install may not have reached every instruction file.
        [ -f "$OUT/$f.kind" ] || continue
        kind="$(cat "$OUT/$f.kind" 2>/dev/null || echo absent)"
        if [ -L "$OUT/$f.orig" ] || [ -e "$OUT/$f.orig" ]; then
            # Was a symlink: put the link back, tracked from git, untracked from the copy.
            rm -f "$WT/$f"
            if [ "$kind" = tracked ]; then git -C "$WT" checkout --quiet -- "$f"
            else cp -P "$OUT/$f.orig" "$WT/$f"; fi
            continue
        fi
        [ -f "$WT/$f" ] || continue
        sed -i "/^$RB_BEGIN\$/,/^$RB_END\$/d" "$WT/$f"
        if [ "$kind" = absent ] && [ ! -s "$WT/$f" ]; then rm -f "$WT/$f"; continue; fi
        # A harness that staged the file staged the rules too; unstage so the
        # handback (diff against HEAD) shows the working copy, rules gone.
        [ "$kind" = tracked ] && git -C "$WT" reset --quiet -- "$f" 2>/dev/null || true
    done
}
trap restore_agents EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

echo "### PR #$PR  $TITLE"
echo "### $HEAD_REF -> $BASE  @ $(git -C "$WT" rev-parse --short HEAD)"
echo "### harness: $HARNESS   worktree: $WT"
echo "### requested model: ${REVIEW_MODEL:-adapter-default}   effort: ${REVIEW_EFFORT:-model-defined}"

# A merged (or already-fast-forwarded) PR has no diff against its base. Left
# unchecked, the harness gets an empty patch, answers with nothing, and the
# run looks like a clean review instead of a no-op. Seen on memory-lanes#44,
# which merged between two runs.
if git -C "$WT" diff --quiet "origin/$BASE...HEAD"; then
    STATE=$(gh pr view "$PR" --json state -q .state)
    echo "!!! no diff against origin/$BASE — nothing to review (PR state: $STATE)"
    [ "$STATE" = "MERGED" ] && echo "!!! this PR is already merged"
    exit 1
fi

echo "### phase A: review"
install_agents review
"$ADAPTER" review "$WT" "origin/$BASE" "$OUT" || {
    echo "!!! review failed"; tail -20 "$OUT/review.err" 2>/dev/null; exit 1; }
echo "--- findings ---"
cat "$OUT/review.md"

restore_agents

if [ "$REVIEW_ONLY" -eq 1 ]; then
    if ! git -C "$WT" diff --quiet "$START_HEAD" ||
       [ -n "$(git -C "$WT" ls-files --others --exclude-standard)" ] ||
       [ "$(git -C "$WT" rev-parse HEAD)" != "$START_HEAD" ]; then
        echo "!!! review-only harness changed the worktree; inspect $WT"
        git -C "$WT" --no-pager diff "$START_HEAD"
        git -C "$WT" status --short
        exit 1
    fi
    echo "### review-only: no fix pass, verified worktree unchanged"
    echo "### END"
    exit 0
fi

echo "### phase B: fix"
install_agents fix
"$ADAPTER" fix "$WT" "$OUT" || {
    echo "!!! fix failed"; tail -20 "$OUT/fix.err" 2>/dev/null
    echo "### (if this is a bubblewrap/uid-map error, see SKILL.md:"
    echo "###  the harness needs a sandbox override you have not set)"
    exit 1; }
echo "--- fix report ---"
cat "$OUT/fix.md"

# Handback. The report above is the harness's own account of what it did; the
# diff below is what it actually did. They are not the same thing, and only
# the second one is evidence.
#
# `git diff` alone is NOT enough here, and getting this wrong would quietly
# break the one step the whole design rests on: it shows unstaged changes to
# tracked files only. A harness that stages an edit, adds a new file, or
# commits despite being told not to would produce a handback that looks clean.
# So: diff against HEAD (staged + unstaged), list untracked, and check whether
# HEAD itself moved.
restore_agents
echo "### diff produced (verify this before trusting the report above)"
git -C "$WT" --no-pager diff HEAD
echo "### files touched"
git -C "$WT" --no-pager diff HEAD --stat

UNTRACKED=$(git -C "$WT" ls-files --others --exclude-standard)
if [ -n "$UNTRACKED" ]; then
    echo "### untracked files the harness created"
    printf '%s\n' "$UNTRACKED"
fi

NOW_HEAD=$(git -C "$WT" rev-parse HEAD)
if [ "$NOW_HEAD" != "$START_HEAD" ]; then
    echo "### WARNING: the harness moved HEAD despite being told not to commit"
    echo "### was $START_HEAD, now $NOW_HEAD"
    git -C "$WT" --no-pager log --oneline "$START_HEAD..$NOW_HEAD"
fi
echo "### END"
