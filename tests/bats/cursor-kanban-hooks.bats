#!/usr/bin/env bats

setup() {
  : "${BLUEPRINT_ROOT:?run via tests/bats/run.sh}"
  export HOME; HOME=$(mktemp -d)
  export XDG_STATE_HOME="$HOME/state"
  export AICODINGSETUP_SKIP_NETWORK=1
  export KANBAN_URL="http://127.0.0.1:8765"
  export KANBAN_TEST_TOKEN="fixture-only-token"
  export PATH="$HOME/bin:$PATH"
  mkdir -p "$HOME/bin" "$HOME/.local/bin" "$HOME/checkout"
  ln -s "$BLUEPRINT_ROOT/bin/kanban-work" "$HOME/.local/bin/kanban-work"
  cat > "$HOME/bin/kanban-mcp" <<'EOF'
#!/bin/sh
printf 'Kanban workflow fixture\n'
EOF
  chmod +x "$HOME/bin/kanban-mcp"
  MATRIX="$HOME/qualified.json"
  printf '%s\n' '{"clients":{"cursor":{"versions":["2026.09.10-fd3934a"]}}}' > "$MATRIX"
  export AICODING_KANBAN_QUALIFIED_CLIENTS="$MATRIX"
  HOOK="$BLUEPRINT_ROOT/configs/claude/hooks/kanban-work-hook.sh"
}

teardown() { rm -rf "$HOME"; }

cursor_payload() {
  local event=$1 conversation=$2 generation=$3 extra=${4:-'{}'}
  jq -nc --arg event "$event" --arg conv "$conversation" --arg gen "$generation" \
    --arg root "$HOME/checkout" --arg version '2026.09.10-fd3934a' --argjson extra "$extra" \
    '{conversation_id:$conv,generation_id:$gen,cursor_version:$version,
      hook_event_name:$event,workspace_roots:[$root],cwd:$root} + $extra'
}

run_cursor_hook() {
  local event=$1 payload=$2
  run bash "$HOOK" cursor "$event" <<<"$payload"
}

start_cursor_session() {
  local conversation=$1 generation=$2
  local payload
  payload=$(cursor_payload sessionStart "$conversation" "$generation" \
    "{\"session_id\":\"$conversation\",\"is_background_agent\":false,\"composer_mode\":\"agent\"}")
  run_cursor_hook sessionStart "$payload"
  [ "$status" -eq 0 ]
  CURSOR_HANDLE=$(jq -r '.env.KANBAN_WORK_HANDLE' <<<"$output")
  [ -n "$CURSOR_HANDLE" ]
  payload=$(cursor_payload beforeSubmitPrompt "$conversation" "$generation" \
    '{"prompt":"fixture","attachments":[]}')
  run_cursor_hook beforeSubmitPrompt "$payload"
  [ "$status" -eq 0 ]
}

@test "Cursor config uses generic lifecycle hooks and no duplicate MCP execution hooks" {
  run python3 - "$BLUEPRINT_ROOT/configs/cursor/hooks.json" <<'PY'
import json, sys
hooks = json.load(open(sys.argv[1], encoding="utf-8"))["hooks"]
required = {"sessionStart", "beforeSubmitPrompt", "preToolUse", "postToolUse",
            "postToolUseFailure", "stop", "sessionEnd", "subagentStart",
            "subagentStop", "preCompact"}
assert required <= set(hooks)
assert "beforeMCPExecution" not in hooks
assert "afterMCPExecution" not in hooks
assert any(h.get("failClosed") is True for h in hooks["preToolUse"])
for event in required:
    assert any(f"cursor {event}" in h["command"] for h in hooks[event])
PY
  [ "$status" -eq 0 ]
}

@test "Cursor generic preToolUse denies a peer handle before Kanban MCP execution" {
  start_cursor_session conv-a gen-a
  local own_handle=$CURSOR_HANDLE
  start_cursor_session conv-peer gen-peer
  local peer_handle=$CURSOR_HANDLE payload
  payload=$(cursor_payload preToolUse conv-a gen-a \
    "{\"tool_use_id\":\"call-7\",\"tool_name\":\"MCP:claim_ticket\",\"tool_input\":{\"handle\":\"$peer_handle\",\"ticket\":\"KANBAN-2\"}}")
  run_cursor_hook preToolUse "$payload"
  [ "$status" -eq 0 ]
  jq -e '.permission == "deny" and (.agent_message|contains("bound Cursor session"))' <<<"$output"
  [ "$own_handle" != "$peer_handle" ]
}

@test "Cursor generic preToolUse mints one exact permit and replay is denied" {
  start_cursor_session conv-a gen-a
  local payload
  payload=$(cursor_payload preToolUse conv-a gen-a \
    "{\"tool_use_id\":\"call-7\",\"tool_name\":\"MCP:claim_ticket\",\"tool_input\":{\"handle\":\"$CURSOR_HANDLE\",\"ticket\":\"KANBAN-2\"}}")
  run_cursor_hook preToolUse "$payload"
  [ "$status" -eq 0 ]
  jq -e '.permission == "allow"' <<<"$output"
  run_cursor_hook preToolUse "$payload"
  [ "$status" -eq 0 ]
  jq -e '.permission == "deny"' <<<"$output"
}

@test "Cursor shell preToolUse rewrites exact legacy completion and rejects unsafe variants" {
  start_cursor_session conv-a gen-a
  python3 - "$XDG_STATE_HOME/aicoding/kanban-work.sqlite3" "$CURSOR_HANDLE" <<'PY'
import sys
from lib.kanban_work.store import Store
s = Store(sys.argv[1])
s.record_bound(sys.argv[2], "backend-session", "kanban", "worker")
s.set_claim(sys.argv[2], "22222222-2222-4222-8222-222222222222", "KANBAN-2")
s.close()
PY
  local payload
  payload=$(cursor_payload preToolUse conv-a gen-a \
    "{\"tool_use_id\":\"legacy\",\"tool_name\":\"Shell\",\"tool_input\":{\"command\":\"kanban-post --done KANBAN-2 --evidence ok\",\"working_directory\":\"$HOME/checkout\"}}")
  run_cursor_hook preToolUse "$payload"
  [ "$status" -eq 0 ]
  jq -e --arg h "$CURSOR_HANDLE" '.permission == "allow" and
    (.updated_input.command == ("kanban-post --done KANBAN-2 --evidence ok --work-handle " + $h))' <<<"$output"

  payload=$(cursor_payload preToolUse conv-a gen-a \
    '{"tool_use_id":"compound","tool_name":"Shell","tool_input":{"command":"kanban-post --done KANBAN-2 --evidence ok; echo bad"}}')
  run_cursor_hook preToolUse "$payload"
  jq -e '.permission == "deny"' <<<"$output"

  payload=$(cursor_payload preToolUse conv-a gen-a \
    '{"tool_use_id":"ordinary","tool_name":"Shell","tool_input":{"command":"git status --short"}}')
  run_cursor_hook preToolUse "$payload"
  jq -e '.permission == "allow" and (has("updated_input")|not)' <<<"$output"
}

@test "Cursor documented subagentStop does not invent a child identity" {
  start_cursor_session conv-a gen-a
  local payload
  payload=$(cursor_payload subagentStart conv-a gen-a \
    '{"subagent_id":"child-1","subagent_type":"generalPurpose","task":"inspect",
      "parent_conversation_id":"conv-a","tool_call_id":"task-1",
      "subagent_model":"fixture","is_parallel_worker":false}')
  run_cursor_hook subagentStart "$payload"
  [ "$status" -eq 0 ]
  payload=$(cursor_payload subagentStop conv-a gen-a \
    '{"subagent_type":"generalPurpose","status":"completed","task":"inspect",
      "description":"inspect","summary":"done","duration_ms":1,"message_count":1,
      "tool_call_count":0,"loop_count":0,"modified_files":[],"agent_transcript_path":null}')
  run_cursor_hook subagentStop "$payload"
  [ "$status" -eq 0 ]
  [ "$output" = '{}' ]
}
