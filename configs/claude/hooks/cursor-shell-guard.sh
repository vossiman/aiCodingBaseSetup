#!/usr/bin/env bash
# cursor-shell-guard.sh: Cursor beforeShellExecution hook.
#
# Managed by the aiCodingBaseSetup blueprint
# (configs/claude/hooks/cursor-shell-guard.sh); aicoding-sync overwrites local
# edits, so change it there, via PR.
#
# A shim with no rules of its own: it hands the command to bw-deny-files.sh,
# the script Claude Code, Codex and pi run, and translates the answer into
# Cursor's format. Cursor's glob deny rules cannot parse wrappers or quoting,
# so this is where Cursor gets the real checks.
set -u

HOOK="$(dirname -- "${BASH_SOURCE[0]}")/bw-deny-files.sh"
allow() { printf '%s\n' '{"permission":"allow"}'; exit 0; }

input=$(cat)
cmd=$(jq -r '.command // empty' <<<"$input" 2>/dev/null) || allow
[[ -n "$cmd" ]] || allow
cwd=$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null) || cwd=""

payload=$(jq -nc --arg c "$cmd" --arg d "$cwd" \
  '{tool_name:"Bash",tool_input:{command:$c}} + (if $d == "" then {} else {cwd:$d} end)')
# The hook resolves relative paths against its own working directory.
out=$(cd -- "${cwd:-.}" 2>/dev/null; printf '%s' "$payload" | bash "$HOOK")

reason=$(jq -r 'select(.hookSpecificOutput.permissionDecision == "deny")
  | .hookSpecificOutput.permissionDecisionReason // "blocked"' <<<"$out" 2>/dev/null)
[[ -n "$reason" ]] || allow
jq -nc --arg r "$reason" '{permission:"deny",user_message:$r,agent_message:$r}'
