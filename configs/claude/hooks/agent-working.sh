#!/bin/bash
# UserPromptSubmit hook (Claude Code and codex) -> agent-notify --clear. A new
# turn means the agent is no longer waiting, so drop this window's @waiting
# flag. Fire-and-forget, never exits non-zero.
[ -n "${LLMWIKI_DISTILLER:-}" ] && exit 0
cat >/dev/null
"$HOME/.local/bin/agent-notify" --clear >/dev/null 2>&1 || true
exit 0
