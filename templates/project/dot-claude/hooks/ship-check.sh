#!/usr/bin/env bash
# PostToolUse on git commit: read docs/SHIP_CHECK.md back to the agent as
# additional context. Fail-open: every path exits 0.

main() {
  local dir="${CLAUDE_PROJECT_DIR:-$PWD}" f
  f="$dir/docs/SHIP_CHECK.md"
  [[ -f "$f" ]] || return 0
  python3 -c 'import json, sys
text = open(sys.argv[1], encoding="utf-8").read()
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": text}}))' "$f"
}

main 2>/dev/null
exit 0
