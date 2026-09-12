#!/usr/bin/env bats

setup() {
  : "${BLUEPRINT_ROOT:?run via tests/bats/run.sh}"
  export HOME; HOME=$(mktemp -d)
  export PATH="$HOME/bin:$PATH"
  export AICODINGSETUP_SKIP_NETWORK=1
  export CHECKOUT="$HOME/checkout"
  export BRIDGE_CALLS="$HOME/bridge-calls.jsonl"
  export VERSION_LOG="$HOME/version-stdin-bytes"
  export PLUGIN_PATH="$HOME/kanban-work.mjs"
  mkdir -p "$HOME/bin" "$CHECKOUT"
  cp "$BLUEPRINT_ROOT/configs/opencode/plugins/kanban-work.js" "$PLUGIN_PATH"

  cat > "$HOME/bin/opencode" <<'EOF'
#!/bin/sh
wc -c > "$VERSION_LOG"
printf '1.18.30\n'
EOF
  chmod +x "$HOME/bin/opencode"

  cat > "$HOME/bin/fake-kanban-work" <<'EOF'
#!/bin/sh
set -eu
payload=$(sed -n '1p')
argv=$(printf '%s\n' "$@" | jq -R . | jq -sc .)
jq -nc --argjson argv "$argv" --argjson stdin "$payload" \
  '{argv:$argv,stdin:$stdin}' >> "$BRIDGE_CALLS"

if [ "$1 $2" = "--json instructions" ]; then
  printf '%s\n' '{"ok":true,"data":{"text":"Claim a ticket before implementation.","lifecycle_capable":false,"handle":null}}'
  exit 0
fi

event=${5:-}
case "$event" in
  system.transform)
    session=$(jq -r '.sessionID' <<EOF_PAYLOAD
$payload
EOF_PAYLOAD
)
    case "$session" in
      ses-parent) handle=11111111-1111-4111-8111-111111111111; capable=true ;;
      ses-child) handle=22222222-2222-4222-8222-222222222222; capable=true ;;
      *) handle=33333333-3333-4333-8333-333333333333; capable=false ;;
    esac
    jq -nc --arg handle "$handle" --argjson capable "$capable" \
      '{handle:$handle,lifecycle_capable:$capable}'
    ;;
  tool.execute.before)
    tool=$(jq -r '.tool' <<EOF_PAYLOAD
$payload
EOF_PAYLOAD
)
    session=$(jq -r '.sessionID // empty' <<EOF_PAYLOAD
$payload
EOF_PAYLOAD
)
    call=$(jq -r '.callID // empty' <<EOF_PAYLOAD
$payload
EOF_PAYLOAD
)
    if [ -z "$session" ] || [ -z "$call" ]; then
      printf '%s\n' '{"ok":false,"error":{"code":409,"message":"OpenCode lifecycle identity is unavailable; Kanban mutations require a qualified native session"}}'
      exit 1
    fi
    count=$(jq -s --arg call "$call" '[.[] | select(.stdin.callID == $call)] | length' "$BRIDGE_CALLS")
    if [ "$count" -gt 1 ]; then
      printf '%s\n' '{"ok":false,"error":{"code":403,"message":"handle belongs to another native session"}}'
      exit 1
    fi
    if [ "$tool" = kanban_claim_ticket ]; then
      handle=$(jq -r '.args.handle' <<EOF_PAYLOAD
$payload
EOF_PAYLOAD
)
      if [ "$handle" != 11111111-1111-4111-8111-111111111111 ]; then
        printf '%s\n' '{"ok":false,"error":{"code":403,"message":"handle belongs to another native session"}}'
        exit 1
      fi
      jq -c '.args + {operation_id:null} | {args:.}' <<EOF_PAYLOAD
$payload
EOF_PAYLOAD
      exit 0
    fi
    if [ "$tool" = bash ]; then
      command=$(jq -r '.args.command // empty' <<EOF_PAYLOAD
$payload
EOF_PAYLOAD
)
      case "$command" in
        KANBAN_WORK_HANDLE=*|*';'*)
          printf '%s\n' '{"ok":false,"error":{"code":422,"message":"Use the Kanban MCP complete_ticket tool"}}'
          exit 1
          ;;
        kanban-post\ --done*)
          jq -nc --arg command "$command --work-handle 11111111-1111-4111-8111-111111111111" \
            '{args:{command:$command}}'
          exit 0
          ;;
      esac
    fi
    printf '{}\n'
    ;;
  *) printf '{}\n' ;;
esac
EOF
  chmod +x "$HOME/bin/fake-kanban-work"
  export AICODING_KANBAN_WORK="$HOME/bin/fake-kanban-work"
  export AICODING_OPENCODE="$HOME/bin/opencode"
}

teardown() { rm -rf "$HOME"; }

@test "OpenCode plugin maps native lifecycle fixtures and preserves parent identity" {
  run node --input-type=module <<'JS'
import fs from "node:fs"
import { pathToFileURL } from "node:url"
const { KanbanWorkPlugin } = await import(pathToFileURL(process.env.PLUGIN_PATH))
const hooks = await KanbanWorkPlugin({ directory: process.env.CHECKOUT })
for (const line of fs.readFileSync(process.env.BLUEPRINT_ROOT + "/tests/fixtures/opencode/kanban-events.jsonl", "utf8").trim().split("\n")) {
  const item = JSON.parse(line)
  if (item.event.properties.info) item.event.properties.info.directory = process.env.CHECKOUT
  await hooks.event(item)
}
JS
  [ "$status" -eq 0 ]
  jq -s -e '
    map(select(.argv == ["hook","--harness","opencode","--event","session.created"])) | length == 2
  ' "$BRIDGE_CALLS"
  jq -s -e '
    any(.[]; .stdin.info.parentID == "ses-parent" and .stdin.sessionID == "ses-child") and
    any(.[]; .argv[-1] == "session.error" and (.stdin.sessionID? == null))
  ' "$BRIDGE_CALLS"
  [ "$(cat "$VERSION_LOG")" -eq 0 ]
}

@test "OpenCode system transform mutates the existing array and caches canonical instructions" {
  run node --input-type=module <<'JS'
import assert from "node:assert/strict"
import { pathToFileURL } from "node:url"
const { KanbanWorkPlugin } = await import(pathToFileURL(process.env.PLUGIN_PATH))
const hooks = await KanbanWorkPlugin({ directory: process.env.CHECKOUT })
for (let i = 0; i < 2; i++) {
  const output = { system: ["base"] }
  const original = output.system
  await hooks["experimental.chat.system.transform"]({ sessionID: "ses-parent", model: {} }, output)
  assert.strictEqual(output.system, original)
  assert.equal(output.system[0], "base")
  assert.match(output.system.join("\n"), /Kanban work session handle: 11111111/)
  assert.match(output.system.join("\n"), /Claim a ticket before implementation/)
  assert.match(output.system.join("\n"), /Lifecycle mutations: available/)
}
const absent = { system: ["base"] }
await hooks["experimental.chat.system.transform"]({ model: {} }, absent)
assert.deepEqual(absent.system, ["base"])
JS
  [ "$status" -eq 0 ]
  [ "$(jq -s '[.[] | select(.argv == ["--json","instructions"])] | length' "$BRIDGE_CALLS")" -eq 1 ]
}

@test "OpenCode before mutates existing MCP args and successful after carries exact identity" {
  export INJECTION_MARKER="$HOME/not-created"
  run node --input-type=module <<'JS'
import assert from "node:assert/strict"
import { pathToFileURL } from "node:url"
const { KanbanWorkPlugin } = await import(pathToFileURL(process.env.PLUGIN_PATH))
const hooks = await KanbanWorkPlugin({ directory: process.env.CHECKOUT })
const input = { tool: "kanban_claim_ticket", sessionID: "ses-parent", callID: "call-$(touch " + process.env.INJECTION_MARKER + ")" }
const output = { args: { handle: "11111111-1111-4111-8111-111111111111", ticket: "KANBAN-2" } }
const original = output.args
await hooks["tool.execute.before"](input, output)
assert.strictEqual(output.args, original)
assert.equal(output.args.operation_id, null)
await hooks["tool.execute.after"]({ ...input, args: output.args }, { content: [{ type: "text", text: "ok" }] })
JS
  [ "$status" -eq 0 ]
  [ ! -e "$INJECTION_MARKER" ]
  jq -s -e '
    any(.[]; .argv[-1] == "tool.execute.before" and .stdin.sessionID == "ses-parent" and
      (.stdin.callID | startswith("call-$(touch ")) and .stdin.tool == "kanban_claim_ticket") and
    any(.[]; .argv[-1] == "tool.execute.after" and .stdin.sessionID == "ses-parent" and
      ((.stdin | keys | sort) == ["callID","clientVersion","directory","sessionID","tool"]))
  ' "$BRIDGE_CALLS"
}

@test "OpenCode missing identity leaves reads available and blocks mutations before bridge execution" {
  run node --input-type=module <<'JS'
import assert from "node:assert/strict"
import { pathToFileURL } from "node:url"
const { KanbanWorkPlugin } = await import(pathToFileURL(process.env.PLUGIN_PATH))
const hooks = await KanbanWorkPlugin({ directory: process.env.CHECKOUT })
await hooks["tool.execute.before"]({ tool: "kanban_list_tickets" }, { args: {} })
await assert.rejects(
  hooks["tool.execute.before"](
    { tool: "kanban_claim_ticket" },
    { args: { handle: "11111111-1111-4111-8111-111111111111", ticket: "KANBAN-2" } },
  ),
  /OpenCode lifecycle identity is unavailable/,
)
JS
  [ "$status" -eq 0 ]
  [ ! -e "$BRIDGE_CALLS" ]
}

@test "OpenCode shell rewrite is exact while unsafe peer replay and unrelated commands are safe" {
  run node --input-type=module <<'JS'
import assert from "node:assert/strict"
import { pathToFileURL } from "node:url"
const { KanbanWorkPlugin } = await import(pathToFileURL(process.env.PLUGIN_PATH))
const hooks = await KanbanWorkPlugin({ directory: process.env.CHECKOUT })
const input = { tool: "bash", sessionID: "ses-parent", callID: "legacy" }
const output = { args: { command: "kanban-post --done KANBAN-2 --evidence ok", description: "keep" } }
const original = output.args
await hooks["tool.execute.before"](input, output)
assert.strictEqual(output.args, original)
assert.equal(output.args.command, "kanban-post --done KANBAN-2 --evidence ok --work-handle 11111111-1111-4111-8111-111111111111")
assert.equal(output.args.description, "keep")
await assert.rejects(hooks["tool.execute.before"](input, { args: { command: "kanban-post --done KANBAN-2 --evidence ok" } }), /another native session/)
await assert.rejects(hooks["tool.execute.before"](
  { tool: "bash", sessionID: "ses-parent", callID: "unsafe" },
  { args: { command: "kanban-post --done KANBAN-2 --evidence ok; echo bad" } },
), /Kanban MCP complete_ticket/)
const ordinary = { args: { command: "git status --short" } }
await hooks["tool.execute.before"](
  { tool: "bash", sessionID: "ses-parent", callID: "ordinary" }, ordinary,
)
assert.deepEqual(ordinary.args, { command: "git status --short" })
await assert.rejects(hooks["tool.execute.before"](
  { tool: "kanban_claim_ticket", sessionID: "ses-parent", callID: "peer" },
  { args: { handle: "22222222-2222-4222-8222-222222222222", ticket: "KANBAN-2" } },
), /another native session/)
JS
  [ "$status" -eq 0 ]
}

@test "OpenCode failed tools have no invented after and first-observed sessions stay explicit" {
  run node --input-type=module <<'JS'
import { pathToFileURL } from "node:url"
const { KanbanWorkPlugin } = await import(pathToFileURL(process.env.PLUGIN_PATH))
const hooks = await KanbanWorkPlugin({ directory: process.env.CHECKOUT })
await hooks["tool.execute.before"](
  { tool: "read", sessionID: "ses-resumed", callID: "failed-call" },
  { args: { filePath: "missing" } },
)
await hooks.event({ event: {
  id: "evt-idle-resumed", type: "session.idle", properties: { sessionID: "ses-resumed" },
} })
await hooks.event({ event: {
  id: "evt-error-missing", type: "session.error",
  properties: { error: { name: "UnknownError", data: { message: "boom" } } },
} })
JS
  [ "$status" -eq 0 ]
  jq -s -e '
    any(.[]; .argv[-1] == "tool.execute.before" and .stdin.callID == "failed-call") and
    ([.[] | select(.argv[-1] == "tool.execute.after")] | length == 0) and
    any(.[]; .argv[-1] == "session.error" and (.stdin.sessionID? == null))
  ' "$BRIDGE_CALLS"
}
