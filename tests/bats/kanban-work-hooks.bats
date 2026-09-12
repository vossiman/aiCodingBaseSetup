#!/usr/bin/env bats

setup() {
  : "${BLUEPRINT_ROOT:?run via tests/bats/run.sh}"
  export HOME; HOME=$(mktemp -d)
  mkdir -p "$HOME/.local/bin"
  HOOK="$BLUEPRINT_ROOT/configs/claude/hooks/kanban-work-hook.sh"
  cat > "$HOME/.local/bin/kanban-work" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$HOME/argv.log"
cat > "$HOME/stdin.log"
printf '{"hookSpecificOutput":{"permissionDecision":"allow"}}\n'
EOF
  chmod +x "$HOME/.local/bin/kanban-work"
}

teardown() { rm -rf "$HOME"; }

@test "shared wrapper forwards fixed harness/event arguments and untouched JSON stdin" {
  payload='{"session_id":"native-a","tool_input":{"command":"$(touch /tmp/never-run)"}}'
  run bash "$HOOK" claude PreToolUse <<<"$payload"
  [ "$status" -eq 0 ]
  [ "$output" = '{"hookSpecificOutput":{"permissionDecision":"allow"}}' ]
  mapfile -t argv < "$HOME/argv.log"
  [ "${argv[*]}" = "hook --harness claude --event PreToolUse" ]
  [ "$(cat "$HOME/stdin.log")" = "$payload" ]
  [ ! -e /tmp/never-run ]
}

@test "Claude config routes lifecycle events through the shared wrapper" {
  run python3 - "$BLUEPRINT_ROOT/configs/claude/settings.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    hooks = json.load(stream)["hooks"]
required = {
    "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
    "PostToolUseFailure", "Stop", "StopFailure", "SessionEnd",
    "SubagentStart", "SubagentStop",
}
assert required <= set(hooks)
for event in required:
    commands = [hook["command"] for group in hooks[event] for hook in group["hooks"]]
    expected = f'kanban-work-hook.sh" claude {event}'
    assert any(expected in command for command in commands), (event, commands)
PY
  [ "$status" -eq 0 ]
}
