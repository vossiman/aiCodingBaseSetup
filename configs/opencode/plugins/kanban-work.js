// kanban-work.js: OpenCode plugin that reports session lifecycle to the
// kanban-work bridge and injects the work handle into the system prompt.
//
// Managed by the aiCodingBaseSetup blueprint
// (configs/opencode/plugins/kanban-work.js); aicoding-sync overwrites local
// edits, so change it there, via PR.
//
// One file loads on OpenCode v1 and v2, so the default export carries both
// entry points. A named export would break v2, which allows only the default.

import { spawn } from "node:child_process"
import { randomUUID } from "node:crypto"

const MAX_OUTPUT = 256 * 1024
const BRIDGE_TIMEOUT_MS = 5000
const VERSION_TIMEOUT_MS = 2000
const LIFECYCLE_EVENTS = new Set([
  "session.created",
  "session.compacted",
  "session.idle",
  "session.deleted",
  "session.error",
])

function run(command, args, payload, timeoutMs = BRIDGE_TIMEOUT_MS) {
  return new Promise((resolve, reject) => {
    // Detached, because OpenCode v2 signals its process group on shutdown
    // before the plugin cleanup, which would kill a turn's final stop.
    const child = spawn(command, args, { stdio: ["pipe", "pipe", "pipe"], detached: true })
    const stdout = []
    const stderr = []
    let stdoutSize = 0
    let stderrSize = 0
    let settled = false

    const finish = (error, value) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      if (error) reject(error)
      else resolve(value)
    }
    const collect = (target, chunk, isStdout) => {
      const size = isStdout ? (stdoutSize += chunk.length) : (stderrSize += chunk.length)
      if (size > MAX_OUTPUT) {
        child.kill()
        finish(new Error("Kanban work bridge output exceeded 256 KiB"))
        return
      }
      target.push(chunk)
    }
    child.stdout.on("data", (chunk) => collect(stdout, chunk, true))
    child.stderr.on("data", (chunk) => collect(stderr, chunk, false))
    child.on("error", (error) => finish(error))
    child.on("close", (code) => {
      const output = Buffer.concat(stdout).toString("utf8")
      let value
      try {
        value = JSON.parse(output)
      } catch {
        finish(new Error(code === 0 ? "Kanban work bridge returned invalid JSON" : "Kanban work bridge failed"))
        return
      }
      if (value?.ok === false) {
        finish(new Error(value.error?.message || "Kanban work bridge failed"))
      } else if (code !== 0) {
        finish(new Error("Kanban work bridge failed"))
      } else {
        finish(null, value)
      }
    })
    const timer = setTimeout(() => {
      child.kill()
      finish(new Error("Kanban work bridge timed out"))
    }, timeoutMs)
    child.stdin.on("error", (error) => finish(error))
    child.stdin.end(JSON.stringify(payload))
  })
}

function processVersion(command) {
  return new Promise((resolve) => {
    const child = spawn(command, ["--version"], { stdio: ["pipe", "pipe", "ignore"] })
    const chunks = []
    let size = 0
    let settled = false
    const finish = (value) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      resolve(value)
    }
    child.stdout.on("data", (chunk) => {
      size += chunk.length
      if (size > 1024) {
        child.kill()
        finish(null)
      } else {
        chunks.push(chunk)
      }
    })
    child.on("error", () => finish(null))
    child.on("close", (code) => {
      if (code !== 0) return finish(null)
      // v1 prints "1.19.5", v2 prints "opencode v2.2.7".
      const match = Buffer.concat(chunks)
        .toString("utf8")
        .match(/\bv?(\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?)\b/)
      finish(match?.[1] || null)
    })
    const timer = setTimeout(() => {
      child.kill()
      finish(null)
    }, VERSION_TIMEOUT_MS)
    child.stdin.end()
  })
}

// The bridge speaks v1 event names and payloads. v2 events carry `data`
// instead of `properties` and were renamed. OpenCode 2.2.7 ends a turn with
// session.execution.*, not session.idle (observed with `opencode run`).
const V2_EVENTS = {
  "session.created": "session.created",
  "session.compaction.ended": "session.compacted",
  "session.execution.succeeded": "session.idle",
  "session.execution.interrupted": "session.idle",
  "session.deleted": "session.deleted",
  "session.execution.failed": "session.error",
}

function createWork(directory) {
  const bridgeCommand = process.env.AICODING_KANBAN_WORK || "kanban-work"
  const versionCommand = process.env.AICODING_OPENCODE || "opencode"
  const instanceID = randomUUID()
  const version = processVersion(versionCommand)
  const parents = new Map()
  const seen = new Set()
  let instructions

  const bridge = (args, payload) => run(bridgeCommand, args, payload)
  const hook = async (event, payload) => bridge(
    ["hook", "--harness", "opencode", "--event", event],
    { ...payload, instanceID, clientVersion: await version, directory },
  )
  const withParent = (sessionID, payload) => {
    if (typeof sessionID === "string" && sessionID) seen.add(sessionID)
    const parentSessionID = parents.get(sessionID)
    return parentSessionID ? { ...payload, parentSessionID } : payload
  }
  // The server instructions, fetched once; an unreachable board leaves only
  // the handle line, and the next plugin load tries again.
  const canonicalInstructions = async () => {
    if (!instructions) {
      instructions = bridge(["--json", "instructions"], {})
        .then((value) => (typeof value?.data?.text === "string" ? value.data.text : ""))
        .catch(() => "")
    }
    return instructions
  }
  const hasCall = (sessionID, callID) =>
    typeof sessionID === "string" && sessionID && typeof callID === "string" && callID

  return {
    parentOf: (sessionID) => parents.get(sessionID),
    knows: (sessionID) => seen.has(sessionID),

    lifecycle: async (type, eventID, properties) => {
      if (!LIFECYCLE_EVENTS.has(type)) return
      const sessionID = properties.sessionID
      await hook(type, withParent(sessionID, { eventID, ...properties }))
      if (type === "session.created" && typeof properties.info?.parentID === "string") {
        parents.set(sessionID, properties.info.parentID)
      }
      if (type === "session.deleted" && typeof sessionID === "string") {
        parents.delete(sessionID)
        seen.delete(sessionID)
      }
    },

    toolBefore: async (tool, sessionID, callID) => {
      if (!hasCall(sessionID, callID)) return
      await hook("tool.execute.before", withParent(sessionID, { tool, sessionID, callID }))
    },

    toolAfter: async (tool, sessionID, callID) => {
      if (!hasCall(sessionID, callID)) return
      await hook("tool.execute.after", withParent(sessionID, { tool, sessionID, callID }))
    },

    // The system text carrying the work handle, or undefined without a session.
    systemText: async (sessionID) => {
      if (typeof sessionID !== "string" || !sessionID) return undefined
      const identity = await hook("system.transform", withParent(sessionID, { sessionID }))
      const text = (await canonicalInstructions()).trimEnd()
      const line = `Kanban work handle: ${identity.handle}`
      return text ? `${text}\n\n${line}` : line
    },
  }
}

// Rebuilds the v1 properties the bridge validates from a v2 event. v2 drops
// `info` from session.deleted, so the parent comes from session.created.
function v1Properties(type, data, work, directory) {
  const sessionID = data.sessionID
  if (type === "session.created") {
    const info = { id: sessionID, directory: data.location?.directory || directory }
    if (typeof data.parentID === "string") info.parentID = data.parentID
    return { sessionID, info }
  }
  if (type === "session.deleted") {
    const info = { id: sessionID }
    const parentID = work.parentOf(sessionID)
    if (parentID) info.parentID = parentID
    return { sessionID, info }
  }
  return { ...data }
}

async function pumpEvents(ctx, work, directory, signal, state) {
  const types = Object.keys(V2_EVENTS)
  for await (const event of ctx.event.subscribe({ types, signal })) {
    const type = V2_EVENTS[event?.type]
    if (!type) continue
    const data = event.data && typeof event.data === "object" ? event.data : {}
    // One server streams every location's events to every location's plugin.
    // Execution events carry no location, so only a session this instance
    // has already seen is ours; anything else would start a stray session.
    const location = event.location?.directory || data.location?.directory
    if (location ? location !== directory : !work.knows(data.sessionID)) continue
    const call = work.lifecycle(type, event.id, v1Properties(type, data, work, directory))
    state.inflight = call.catch(() => {})
    try {
      await call
    } catch (error) {
      // One refused event must not end the subscription for the rest.
      console.error(`kanban-work: ${type}: ${error?.message || error}`)
    }
  }
}

// OpenCode v1 runs `server`, v2 runs `setup`; each ignores the other key.
export default {
  id: "aicoding-kanban-work",
  server: async (input) => {
    const work = createWork(input.directory)
    return {
      event: async ({ event }) => {
        const properties = event?.properties && typeof event.properties === "object"
          ? event.properties
          : {}
        await work.lifecycle(event?.type, event?.id, properties)
      },
      "tool.execute.before": async (toolInput) =>
        work.toolBefore(toolInput?.tool, toolInput?.sessionID, toolInput?.callID),
      "tool.execute.after": async (toolInput) =>
        work.toolAfter(toolInput?.tool, toolInput?.sessionID, toolInput?.callID),
      "experimental.chat.system.transform": async (chatInput, output) => {
        const text = await work.systemText(chatInput?.sessionID)
        if (text) output.system.push(text)
      },
    }
  },
  setup: async (ctx) => {
    const directory = ctx?.location?.directory
    const work = createWork(directory)
    const registrations = await Promise.all([
      ctx.tool.hook("execute.before", (event) =>
        work.toolBefore(event?.tool, event?.sessionID, event?.id)),
      // A failed call also ends the bridge's tool operation; v1 fired no after for it.
      ctx.tool.hook("execute.after", (event) =>
        work.toolAfter(event?.tool, event?.sessionID, event?.id)),
      ctx.session.hook("context", async (request) => {
        const text = await work.systemText(request?.sessionID)
        if (text) request.system.push({ type: "text", text })
      }),
    ])
    const abort = new AbortController()
    const state = { inflight: Promise.resolve() }
    pumpEvents(ctx, work, directory, abort.signal, state).catch((error) => {
      if (!abort.signal.aborted) console.error(`kanban-work: event stream ended: ${error?.message || error}`)
    })
    return async () => {
      abort.abort()
      // `opencode run` shuts down right after the turn ends; let its stop land.
      await state.inflight
      await Promise.all(registrations.map((registration) => registration.dispose()))
    }
  },
}
