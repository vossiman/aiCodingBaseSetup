#!/bin/bash
# Claude Code Notification hook → agent-notify. Fires when Claude is waiting
# (permission prompt / idle prompt). Fire-and-forget, never exits non-zero.
[ -n "${LLMWIKI_DISTILLER:-}" ] && exit 0
input="$(cat)"
msg="$(printf '%s' "$input" | jq -r '.message // empty' 2>/dev/null)"
[ -n "$msg" ] || exit 0
"$HOME/.local/bin/agent-notify" --source claude --priority high \
  --title "⏸ claude waiting" --body "$(printf '%s' "$msg" | head -c 200)" \
  >/dev/null 2>&1 || true
exit 0
