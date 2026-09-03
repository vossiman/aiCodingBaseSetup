#!/usr/bin/env bash
# Harness adapter: OpenAI codex CLI.
# Contract: review <worktree> <base-ref> <outdir> | fix <worktree> <outdir>
set -euo pipefail

MODEL="${REVIEW_MODEL:-gpt-5.6-sol}"
EFFORT="${REVIEW_EFFORT:-high}"

# Codex's own sandbox is bubblewrap, and bubblewrap cannot start in this
# devcontainer: the host kernel sets apparmor_restrict_unprivileged_userns=1,
# so `bwrap --unshare-user` dies with "setting up uid map: Permission denied"
# and every codex tool call fails. Verified 2026-08-27; see the SKILL.md
# section "Why the fix pass needs a sandbox override".
#
# The caller therefore has to choose a sandbox mode explicitly. This adapter
# does NOT pick a permissive one for you: the default below keeps codex's
# sandbox on, which means the fix pass will FAIL in this container until you
# override it. That is intentional — the decision to run a harness without its
# own sandbox belongs to a human, not to this file.
#
# To run the fix pass here, set REVIEW_SANDBOX to a full-access mode, or fix
# the container (start it with apparmor=unconfined) and change nothing.
SANDBOX="${REVIEW_SANDBOX:--s workspace-write}"

verb="$1"
wt="$2"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$verb" in
  review)
    base="$3"
    out="$4"
    # `codex exec review --base` refuses a custom prompt argument, so codex's
    # own review instructions are what run here. prompts/review.md is used by
    # harnesses that have no built-in review mode.
    ( cd "$wt" && codex exec review --base "$base" \
        -m "$MODEL" -c model_reasoning_effort="$EFFORT" \
        --json -o "$out/review.md" \
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
