#!/usr/bin/env bash
# Claude Code adapter. Preserve user/managed hooks, including the secrets guard.
# Contract: review <worktree> <base-ref> <outdir> | fix <worktree> <outdir>
set -euo pipefail
MODEL="${REVIEW_MODEL:-opus}"
EFFORT="${REVIEW_EFFORT:-high}"
verb="$1"
wt="$2"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The review has only file-reading tools; MCP tools and shell cannot mutate
# the repository or publish findings. dontAsk overrides a permissive user mode.
common=(-p --model "$MODEL" --effort "$EFFORT" --output-format text
        --strict-mcp-config --mcp-config '{"mcpServers":{}}')
case "$verb" in
  review)
    base="$3"; out="$4"
    git -C "$wt" --no-pager diff "$base"...HEAD > "$out/diff.patch"
    ( cd "$wt" && claude "${common[@]}" --permission-mode dontAsk \
        --tools Read,Glob,Grep --allowedTools Read Glob Grep \
        --append-system-prompt "$(cat "$here/../prompts/agents-review.md")" \
        "$(cat "$here/../prompts/review.md")

Read .review-round/diff.patch and surrounding source to review the changes.
The base ref is $base. Return findings, not a plan." \
        </dev/null > "$out/review.md" 2> "$out/review.err" )
    ;;
  fix)
    out="$3"
    # Shell commands are sandboxed by default, without an escape hatch.
    # Existing full-access Codex opt-in also expresses the host/container
    # decision for Claude. Cursor's --force alone does not opt Claude in.
    settings='{"sandbox":{"enabled":true,"failIfUnavailable":true,"allowUnsandboxedCommands":false}}'
    if ! unshare -Ur true 2>/dev/null; then
      if [[ "${REVIEW_SANDBOX:-}" != '-s danger-full-access' ]]; then
        echo 'Claude fix needs user namespaces or REVIEW_SANDBOX="-s danger-full-access".' >&2
        exit 1
      fi
      settings='{"sandbox":{"enabled":false}}'
    fi
    ( cd "$wt" && claude "${common[@]}" --permission-mode acceptEdits \
        --tools Read,Glob,Grep,Edit,Write,Bash \
        --allowedTools Read Glob Grep Edit Write Bash --settings "$settings" \
        --append-system-prompt "$(cat "$here/../prompts/agents-fix.md")" \
        "$(cat "$here/../prompts/fix.md")" \
        </dev/null > "$out/fix.md" 2> "$out/fix.err" )
    ;;
  *) echo "unknown verb: $verb" >&2; exit 2 ;;
esac
