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
  printf '%s\n' '{"ok":true,"data":{"text":"Claim a ticket before implementation."}}'
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
      ses-parent) handle=11111111-1111-4111-8111-111111111111 ;;
      ses-child) handle=22222222-2222-4222-8222-222222222222 ;;
      *) handle=33333333-3333-4333-8333-333333333333 ;;
    esac
    jq -nc --arg handle "$handle" '{handle:$handle}'
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
    if [ "$tool" = kanban_claim_ticket ] && [ -n "${FAKE_UNSETTLED:-}" ]; then
      printf '%s\n' '{"ok":false,"error":{"code":503,"message":"the board has not confirmed the previous turn'"'"'s stop; retry the claim"}}'
      exit 1
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
const { server: KanbanWorkPlugin } = (await import(pathToFileURL(process.env.PLUGIN_PATH))).default
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
    [.[] | select(.argv[0] == "hook") | .stdin.instanceID] as $instances |
    ($instances | length == 6) and ($instances | unique | length == 1) and
    ($instances[0] | type == "string" and length > 0 and length <= 300)
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
const { server: KanbanWorkPlugin } = (await import(pathToFileURL(process.env.PLUGIN_PATH))).default
const hooks = await KanbanWorkPlugin({ directory: process.env.CHECKOUT })
for (let i = 0; i < 2; i++) {
  const output = { system: ["base"] }
  const original = output.system
  await hooks["experimental.chat.system.transform"]({ sessionID: "ses-parent", model: {} }, output)
  assert.strictEqual(output.system, original)
  assert.equal(output.system[0], "base")
  assert.equal(output.system[1],
    "Claim a ticket before implementation.\n\nKanban work handle: 11111111-1111-4111-8111-111111111111")
}
const absent = { system: ["base"] }
await hooks["experimental.chat.system.transform"]({ model: {} }, absent)
assert.deepEqual(absent.system, ["base"])
JS
  [ "$status" -eq 0 ]
  [ "$(jq -s '[.[] | select(.argv == ["--json","instructions"])] | length' "$BRIDGE_CALLS")" -eq 1 ]
}

@test "OpenCode before leaves Kanban MCP args untouched and after carries exact identity" {
  export INJECTION_MARKER="$HOME/not-created"
  run node --input-type=module <<'JS'
import assert from "node:assert/strict"
import { pathToFileURL } from "node:url"
const { server: KanbanWorkPlugin } = (await import(pathToFileURL(process.env.PLUGIN_PATH))).default
const hooks = await KanbanWorkPlugin({ directory: process.env.CHECKOUT })
const input = { tool: "kanban_claim_ticket", sessionID: "ses-parent", callID: "call-$(touch " + process.env.INJECTION_MARKER + ")" }
const output = { args: { handle: "11111111-1111-4111-8111-111111111111", ticket: "KANBAN-2" } }
const original = output.args
await hooks["tool.execute.before"](input, output)
assert.strictEqual(output.args, original)
assert.deepEqual(output.args, { handle: "11111111-1111-4111-8111-111111111111", ticket: "KANBAN-2" })
await hooks["tool.execute.after"]({ ...input, args: output.args }, { content: [{ type: "text", text: "ok" }] })
JS
  [ "$status" -eq 0 ]
  [ ! -e "$INJECTION_MARKER" ]
  jq -s -e '
    any(.[]; .argv[-1] == "tool.execute.before" and .stdin.sessionID == "ses-parent" and
      (.stdin.callID | startswith("call-$(touch ")) and .stdin.tool == "kanban_claim_ticket") and
    any(.[]; .argv[-1] == "tool.execute.after" and .stdin.sessionID == "ses-parent" and
      ((.stdin | keys | sort) == ["callID","clientVersion","directory","instanceID","sessionID","tool"]))
  ' "$BRIDGE_CALLS"
}

@test "OpenCode missing identity leaves every Kanban tool to the hosted server" {
  run node --input-type=module <<'JS'
import { pathToFileURL } from "node:url"
const { server: KanbanWorkPlugin } = (await import(pathToFileURL(process.env.PLUGIN_PATH))).default
const hooks = await KanbanWorkPlugin({ directory: process.env.CHECKOUT })
await hooks["tool.execute.before"]({ tool: "kanban_list_tickets" }, { args: {} })
await hooks["tool.execute.before"](
  { tool: "kanban_claim_ticket" },
  { args: { handle: "11111111-1111-4111-8111-111111111111", ticket: "KANBAN-2" } },
)
JS
  [ "$status" -eq 0 ]
  [ ! -e "$BRIDGE_CALLS" ]
}

@test "OpenCode surfaces the claim gate's refusal as a tool error" {
  export FAKE_UNSETTLED=1
  run node --input-type=module <<'JS'
import assert from "node:assert/strict"
import { pathToFileURL } from "node:url"
const { server: KanbanWorkPlugin } = (await import(pathToFileURL(process.env.PLUGIN_PATH))).default
const hooks = await KanbanWorkPlugin({ directory: process.env.CHECKOUT })
await assert.rejects(
  hooks["tool.execute.before"](
    { tool: "kanban_claim_ticket", sessionID: "ses-parent", callID: "call-1" },
    { args: { ticket: "KANBAN-2" } },
  ),
  /has not confirmed the previous turn's stop/,
)
JS
  [ "$status" -eq 0 ]
}

@test "OpenCode system transform still injects the handle when instructions are unavailable" {
  cat > "$HOME/bin/fake-no-instructions" <<'EOF'
#!/bin/sh
cat >/dev/null
if [ "$1 $2" = "--json instructions" ]; then
  printf '%s\n' '{"ok":false,"error":{"code":502,"message":"kanban instructions are unavailable"}}'
  exit 1
fi
printf '%s\n' '{"handle":"11111111-1111-4111-8111-111111111111"}'
EOF
  chmod +x "$HOME/bin/fake-no-instructions"
  export AICODING_KANBAN_WORK="$HOME/bin/fake-no-instructions"
  run node --input-type=module <<'JS'
import assert from "node:assert/strict"
import { pathToFileURL } from "node:url"
const { server: KanbanWorkPlugin } = (await import(pathToFileURL(process.env.PLUGIN_PATH))).default
const hooks = await KanbanWorkPlugin({ directory: process.env.CHECKOUT })
const output = { system: [] }
await hooks["experimental.chat.system.transform"]({ sessionID: "ses-parent", model: {} }, output)
assert.deepEqual(output.system, ["Kanban work handle: 11111111-1111-4111-8111-111111111111"])
JS
  [ "$status" -eq 0 ]
}

@test "OpenCode missing identity leaves ordinary legacy CLI commands available" {
  run node --input-type=module <<'JS'
import { pathToFileURL } from "node:url"
const { server: KanbanWorkPlugin } = (await import(pathToFileURL(process.env.PLUGIN_PATH))).default
const hooks = await KanbanWorkPlugin({ directory: process.env.CHECKOUT })
for (const command of [
  'kanban-post "follow-up" --repo aiCodingBaseSetup',
  "kanban-post --comment AICODINGBASESETUP-2 progress",
  "kanban-post --list-tickets",
  "kanban-post --selftest",
]) {
  await hooks["tool.execute.before"]({ tool: "bash" }, { args: { command } })
}
JS
  [ "$status" -eq 0 ]
  [ ! -e "$BRIDGE_CALLS" ]
}

@test "OpenCode does not block or rewrite a kanban-post bash call" {
  run node --input-type=module <<'JS'
import assert from "node:assert/strict"
import { pathToFileURL } from "node:url"
const { server: KanbanWorkPlugin } = (await import(pathToFileURL(process.env.PLUGIN_PATH))).default
const hooks = await KanbanWorkPlugin({ directory: process.env.CHECKOUT })
for (const [id, command] of [["a", "kanban-post --done KANBAN-2 --evidence ok"], ["b", "FOO=1 kanban-post --done KANBAN-2 --evidence ok"]]) {
  const output = { args: { command } }
  await hooks["tool.execute.before"]({ tool: "bash", sessionID: "ses-parent", callID: id }, output)
  assert.deepEqual(output.args, { command })
}
await hooks["tool.execute.before"]({ tool: "bash" }, { args: { command: "kanban-post --done KANBAN-2 --evidence ok" } })
JS
  [ "$status" -eq 0 ]
}

@test "OpenCode failed tools have no invented after and first-observed sessions stay explicit" {
  run node --input-type=module <<'JS'
import { pathToFileURL } from "node:url"
const { server: KanbanWorkPlugin } = (await import(pathToFileURL(process.env.PLUGIN_PATH))).default
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

@test "OpenCode plugin instances use distinct stable adapter contexts" {
  run node --input-type=module <<'JS'
import { pathToFileURL } from "node:url"
const { server: KanbanWorkPlugin } = (await import(pathToFileURL(process.env.PLUGIN_PATH))).default
const first = await KanbanWorkPlugin({ directory: process.env.CHECKOUT })
const second = await KanbanWorkPlugin({ directory: process.env.CHECKOUT })
for (const hooks of [first, second]) {
  await hooks.event({ event: {
    id: "evt-created", type: "session.created", properties: {
      sessionID: "ses-parent",
      info: {
        id: "ses-parent", slug: "parent", projectID: "global",
        directory: process.env.CHECKOUT, title: "Parent", version: "1.18.30",
        time: { created: 1, updated: 1 },
      },
    },
  } })
  await hooks["experimental.chat.system.transform"](
    { sessionID: "ses-parent", model: {} }, { system: [] },
  )
}
JS
  [ "$status" -eq 0 ]
  jq -s -e '
    [.[] | select(.argv[0] == "hook") | .stdin.instanceID] as $instances |
    ($instances | length == 4) and ($instances | unique | length == 2)
  ' "$BRIDGE_CALLS"
  jq -s -e '
    [.[] | select(.argv[0] == "hook") | .stdin.instanceID] |
    group_by(.) | all(.[]; length == 2)
  ' "$BRIDGE_CALLS"
}

# A stand-in for the OpenCode v2 plugin context (@opencode/plugin 2.2.7
# promise/plugin.d.ts): tool and session hooks, and an event stream.
write_v2_context() {
  cat > "$HOME/v2-context.mjs" <<'JS'
import fs from "node:fs"
export function v2Context(directory, events = []) {
  const hooks = {}
  const disposed = []
  let drained
  const done = new Promise((resolve) => { drained = resolve })
  const register = (domain) => async (name, callback) => {
    hooks[`${domain}.${name}`] = callback
    return { dispose: async () => { disposed.push(`${domain}.${name}`) } }
  }
  const ctx = {
    location: { directory },
    tool: { hook: register("tool") },
    session: { hook: register("session") },
    event: {
      subscribe: async function* ({ types, signal }) {
        ctx.subscribedTypes = types
        for (const event of events) yield event
        drained()
        await new Promise((resolve) => signal.addEventListener("abort", resolve))
      },
    },
  }
  return { ctx, hooks, disposed, done }
}
export function v2Events(file, directory) {
  return fs.readFileSync(file, "utf8").trim().split("\n").map((line) =>
    JSON.parse(line.replaceAll('"/checkout"', JSON.stringify(directory))))
}
JS
}

@test "OpenCode plugin is a single default export with v1 and v2 entry points" {
  run node --input-type=module <<'JS'
import assert from "node:assert/strict"
import { pathToFileURL } from "node:url"
const module = await import(pathToFileURL(process.env.PLUGIN_PATH))
assert.deepEqual(Object.keys(module), ["default"])
assert.equal(module.default.id, "aicoding-kanban-work")
assert.equal(typeof module.default.server, "function")
assert.equal(typeof module.default.setup, "function")
JS
  [ "$status" -eq 0 ]
}

@test "OpenCode v2 events reach the bridge in the v1 shape it validates" {
  write_v2_context
  run node --input-type=module <<'JS'
import assert from "node:assert/strict"
import { pathToFileURL } from "node:url"
const plugin = (await import(pathToFileURL(process.env.PLUGIN_PATH))).default
const { v2Context, v2Events } = await import(pathToFileURL(process.env.HOME + "/v2-context.mjs"))
const events = v2Events(process.env.BLUEPRINT_ROOT + "/tests/fixtures/opencode/kanban-events-v2.jsonl", process.env.CHECKOUT)
const { ctx, disposed, done } = v2Context(process.env.CHECKOUT, events)
const cleanup = await plugin.setup(ctx)
await done
assert.deepEqual([...ctx.subscribedTypes].sort(), [
  "session.compaction.ended", "session.created", "session.deleted",
  "session.execution.failed", "session.execution.interrupted", "session.execution.succeeded",
])
await cleanup()
assert.deepEqual(disposed.sort(), ["session.context", "tool.execute.after", "tool.execute.before"])
JS
  [ "$status" -eq 0 ]
  jq -s -e '
    [.[] | select(.argv[0] == "hook") | [.argv[-1], .stdin.eventID]] == [
      ["session.created","evt_created_parent"],
      ["session.created","evt_created_child"],
      ["session.compacted","evt_compacted"],
      ["session.idle","evt_succeeded"],
      ["session.idle","evt_interrupted"],
      ["session.deleted","evt_deleted_child"],
      ["session.error","evt_failed"]
    ]
  ' "$BRIDGE_CALLS"
  jq -s -e --arg dir "$CHECKOUT" '
    any(.[]; .stdin.eventID == "evt_created_parent" and
      .stdin.info == {id:"ses-parent",directory:$dir} and .stdin.directory == $dir) and
    any(.[]; .stdin.eventID == "evt_created_child" and
      .stdin.info == {id:"ses-child",directory:$dir,parentID:"ses-parent"}) and
    any(.[]; .stdin.eventID == "evt_deleted_child" and .stdin.sessionID == "ses-child" and
      .stdin.info == {id:"ses-child",parentID:"ses-parent"} and .stdin.parentSessionID == "ses-parent") and
    any(.[]; .stdin.eventID == "evt_failed" and .stdin.sessionID == "ses-parent")
  ' "$BRIDGE_CALLS"
}

@test "OpenCode v2 keeps streaming events after the bridge refuses one" {
  write_v2_context
  cat > "$HOME/bin/fake-refuse-created" <<'SH'
#!/bin/sh
payload=$(sed -n '1p')
jq -nc --arg event "${5:-}" --argjson stdin "$payload" '{argv:[$event],stdin:$stdin}' >> "$BRIDGE_CALLS"
if [ "${5:-}" = session.created ]; then
  printf '%s\n' '{"ok":false,"error":{"code":409,"message":"refused"}}'
  exit 1
fi
printf '{}\n'
SH
  chmod +x "$HOME/bin/fake-refuse-created"
  export AICODING_KANBAN_WORK="$HOME/bin/fake-refuse-created"
  run node --input-type=module <<'JS'
import { pathToFileURL } from "node:url"
const plugin = (await import(pathToFileURL(process.env.PLUGIN_PATH))).default
const { v2Context, v2Events } = await import(pathToFileURL(process.env.HOME + "/v2-context.mjs"))
const events = v2Events(process.env.BLUEPRINT_ROOT + "/tests/fixtures/opencode/kanban-events-v2.jsonl", process.env.CHECKOUT)
const { ctx, done } = v2Context(process.env.CHECKOUT, events)
const cleanup = await plugin.setup(ctx)
await done
await cleanup()
JS
  [ "$status" -eq 0 ]
  [[ "$output" == *"kanban-work: session.created: refused"* ]]
  jq -s -e 'any(.[]; .argv[0] == "session.error")' "$BRIDGE_CALLS"
}

@test "OpenCode v2 tool hooks carry the call id and surface the claim gate's refusal" {
  write_v2_context
  export FAKE_UNSETTLED=1
  printf '#!/bin/sh\nprintf "opencode v2.2.7\\n"\n' > "$HOME/bin/opencode"
  run node --input-type=module <<'JS'
import assert from "node:assert/strict"
import { pathToFileURL } from "node:url"
const plugin = (await import(pathToFileURL(process.env.PLUGIN_PATH))).default
const { v2Context } = await import(pathToFileURL(process.env.HOME + "/v2-context.mjs"))
const { ctx, hooks } = v2Context(process.env.CHECKOUT)
const cleanup = await plugin.setup(ctx)
const call = { tool: "shell", sessionID: "ses-parent", agent: "build", messageID: "msg-1", id: "call-1", input: { command: "ls" } }
await hooks["tool.execute.before"](call)
await hooks["tool.execute.after"]({ ...call, status: "error", error: { message: "boom" } })
await hooks["tool.execute.before"]({ tool: "kanban_list_tickets", input: {} })
await assert.rejects(
  hooks["tool.execute.before"]({ ...call, tool: "kanban_claim_ticket", id: "call-2" }),
  /has not confirmed the previous turn's stop/,
)
await cleanup()
JS
  [ "$status" -eq 0 ]
  jq -s -e '
    [.[] | select(.argv[0] == "hook") | [.argv[-1], .stdin.tool, .stdin.callID]] == [
      ["tool.execute.before","shell","call-1"],
      ["tool.execute.after","shell","call-1"],
      ["tool.execute.before","kanban_claim_ticket","call-2"]
    ]
  ' "$BRIDGE_CALLS"
  jq -s -e 'all(.[] | select(.argv[0] == "hook"); .stdin.clientVersion == "2.2.7")' "$BRIDGE_CALLS"
}

@test "OpenCode v2 context hook appends the handle as a system part" {
  write_v2_context
  run node --input-type=module <<'JS'
import assert from "node:assert/strict"
import { pathToFileURL } from "node:url"
const plugin = (await import(pathToFileURL(process.env.PLUGIN_PATH))).default
const { v2Context } = await import(pathToFileURL(process.env.HOME + "/v2-context.mjs"))
const { ctx, hooks } = v2Context(process.env.CHECKOUT)
const cleanup = await plugin.setup(ctx)
for (let i = 0; i < 2; i++) {
  const request = { sessionID: "ses-parent", model: {}, system: [{ type: "text", text: "base" }], messages: [], options: {} }
  const original = request.system
  await hooks["session.context"](request)
  assert.strictEqual(request.system, original)
  assert.deepEqual(request.system, [
    { type: "text", text: "base" },
    { type: "text", text: "Claim a ticket before implementation.\n\nKanban work handle: 11111111-1111-4111-8111-111111111111" },
  ])
}
const absent = { model: {}, system: [], messages: [], options: {} }
await hooks["session.context"](absent)
assert.deepEqual(absent.system, [])
await cleanup()
JS
  [ "$status" -eq 0 ]
  [ "$(jq -s '[.[] | select(.argv == ["--json","instructions"])] | length' "$BRIDGE_CALLS")" -eq 1 ]
}
