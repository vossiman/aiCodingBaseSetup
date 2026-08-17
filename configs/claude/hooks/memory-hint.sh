#!/usr/bin/env bash
# UserPromptSubmit hook: stdin is Claude Code's hook JSON; stdout becomes
# extra model context. Every failure path exits 0 silently - a broken memory
# router must never break a prompt.
set -u
command -v jq >/dev/null 2>&1 || exit 0
prompt=$(jq -r '.prompt // empty' 2>/dev/null) || exit 0
[ -n "$prompt" ] || exit 0
hint="$HOME/.local/bin/memory-hint"
[ -x "$hint" ] || exit 0
printf '%s' "$prompt" | "$hint" --client hook:claude-code 2>/dev/null || true
exit 0
