#!/usr/bin/env bash
# Harness adapter: Cursor CLI (cursor-agent).
# Contract: review <worktree> <base-ref> <outdir> | fix <worktree> <outdir>
set -euo pipefail

MODEL="${REVIEW_MODEL:-cursor-grok-4.6-high-fast}"

# --trust is required for ANY non-interactive run: without it cursor-agent
# stops on "Workspace Trust Required" and writes no output at all. It only
# says "this directory may be operated on"; it does not by itself let the
# agent run commands without approval.
#
# The fix pass additionally needs an approval mode that lets the agent edit
# without a human at the keyboard. As with the codex adapter, this file does
# not choose that for you — set REVIEW_APPROVAL to --force or --yolo if you
# want the fix pass to run unattended.
APPROVAL="${REVIEW_APPROVAL:-}"

verb="$1"
wt="$2"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$verb" in
  review)
    base="$3"
    out="$4"
    # cursor-agent has no built-in review verb, so the diff is materialised
    # and handed to it, and the pass runs read-only via --mode ask.
    #
    # NOT --mode plan: it is read-only too, but on a real review prompt it
    # returns an empty result (1 byte after ~5 minutes) while short prompts
    # and tool-using prompts both answer fine — plan mode appears to emit a
    # plan artifact rather than printed text. --mode ask returns the prose.
    # Verified 2026-08-28 against the same prompt and diff.
    ( cd "$wt" && git --no-pager diff "$base"...HEAD >"$out/diff.patch" )
    ( cd "$wt" && cursor-agent -p --trust --mode ask --model "$MODEL" \
        --output-format text \
        "$(cat "$here/../prompts/review.md")

The diff under review is in .review-round/diff.patch (base: $base). Read it,
and read whatever surrounding source you need to judge it." \
        </dev/null >"$out/review.md" 2>"$out/review.err" )
    ;;
  fix)
    out="$3"
    # shellcheck disable=SC2086  # APPROVAL is deliberately word-split.
    ( cd "$wt" && cursor-agent -p --trust $APPROVAL --model "$MODEL" \
        --output-format text \
        "$(cat "$here/../prompts/fix.md")" \
        </dev/null >"$out/fix.md" 2>"$out/fix.err" )
    ;;
  *)
    echo "unknown verb: $verb" >&2
    exit 2
    ;;
esac
