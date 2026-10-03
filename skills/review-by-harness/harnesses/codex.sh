#!/usr/bin/env bash
# Harness adapter: OpenAI codex CLI.
# Contract: review <worktree> <base-ref> <outdir> | fix <worktree> <outdir>
set -euo pipefail

MODEL="${REVIEW_MODEL:-gpt-5.6-sol}"
EFFORT="${REVIEW_EFFORT:-high}"

# Codex's own sandbox is bubblewrap. The devpod host denies unprivileged user
# namespaces, so it starts there only because the image ships bwrap setuid
# root; run.sh probes bwrap and drops any override where it works. Where it
# does not, the fix pass needs REVIEW_SANDBOX set by a human, never by this file.
SANDBOX="${REVIEW_SANDBOX:--s workspace-write}"

# The reviewer prompt inlines whole diffs; keep it out of the memory router.
export MEMORY_HINT=off
verb="$1"
wt="$2"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$verb" in
  review)
    base="$3"
    out="$4"
    # `codex exec review --base` refuses a custom prompt, and the built-in
    # instructions alone dismiss docs-only diffs. Name the range in the
    # prompt instead, so the shared review instructions apply.
    prompt="Review the changes from $base to HEAD in this repository (run \`git diff $base...HEAD\` to see them).

$(cat "$here/../prompts/review.md")"
    ( cd "$wt" && codex exec review \
        -m "$MODEL" -c model_reasoning_effort="$EFFORT" \
        --json -o "$out/review.md" \
        "$prompt" \
        </dev/null >"$out/review.jsonl" 2>"$out/review.err" )
    ;;
  fix)
    out="$3"
    # shellcheck disable=SC2086  # SANDBOX is deliberately word-split.
    ( cd "$wt" && codex exec $SANDBOX \
        -m "$MODEL" -c model_reasoning_effort="$EFFORT" \
        -o "$out/fix.md" \
        "$(cat "$here/../prompts/fix.md")" \
        </dev/null >"$out/fix.jsonl" 2>"$out/fix.err" )
    ;;
  *)
    echo "unknown verb: $verb" >&2
    exit 2
    ;;
esac
