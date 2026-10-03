#!/usr/bin/env bash
# PostToolUse on Bash: when the command is a git commit, read docs/SHIP_CHECK.md back to the agent as
# additional context. Fail-open: every path exits 0.

main() {
  local dir="${CLAUDE_PROJECT_DIR:-$PWD}" f
  f="$dir/docs/SHIP_CHECK.md"
  [[ -f "$f" ]] || return 0
  python3 -c 'import json, re, sys
try:
    cmd = json.load(sys.stdin)["tool_input"]["command"]
except Exception:
    sys.exit(0)
if not isinstance(cmd, str):
    sys.exit(0)
pat = re.compile(r"^\s*(?:\w+=\S*\s+)*git(?:\s+(?:-[cC]\s+\S+|--?\S+))*\s+commit(?:\s|$)")
if not any(pat.match(seg) for seg in re.split(r"&&|\|\||;|\||\n", cmd)):
    sys.exit(0)
text = open(sys.argv[1], encoding="utf-8").read()
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": text}}))' "$f"
}

main 2>/dev/null
exit 0
