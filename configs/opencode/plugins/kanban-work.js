import { spawn } from "node:child_process"
import { randomUUID } from "node:crypto"

const MAX_OUTPUT = 256 * 1024
const BRIDGE_TIMEOUT_MS = 5000
const VERSION_TIMEOUT_MS = 2000
const LEGACY_GUIDANCE = "Use the Kanban MCP complete_ticket tool"
const LIFECYCLE_EVENTS = new Set([
  "session.created",
  "session.compacted",
  "session.idle",
  "session.deleted",
  "session.error",
])

function run(command, args, payload, timeoutMs = BRIDGE_TIMEOUT_MS) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ["pipe", "pipe", "pipe"] })
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
      const match = Buffer.concat(chunks)
        .toString("utf8")
        .match(/\b\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?\b/)
      finish(match?.[0] || null)
    })
    const timer = setTimeout(() => {
      child.kill()
      finish(null)
    }, VERSION_TIMEOUT_MS)
    child.stdin.end()
  })
}

function looksLikeLegacyCompletion(args) {
  if (typeof args?.command !== "string") return false
  const command = args.command
  const commandPrefix = /^\s*(?:kanban-post|(?:\.?\.?\/|\/).*kanban-post|[A-Za-z_][A-Za-z0-9_]*=.*\s+kanban-post)(?:\s|$)/
  return commandPrefix.test(command) &&
    /(?:^|\s)--done\b/.test(command) &&
    /(?:^|\s)--evidence\b/.test(command)
}

export const KanbanWorkPlugin = async (input) => {
  const bridgeCommand = process.env.AICODING_KANBAN_WORK || "kanban-work"
  const versionCommand = process.env.AICODING_OPENCODE || "opencode"
  const directory = input.directory
  const instanceID = randomUUID()
  const version = processVersion(versionCommand)
  const parents = new Map()
  let instructions

  const bridge = (args, payload) => run(bridgeCommand, args, payload)
  const hook = async (event, payload) => bridge(
    ["hook", "--harness", "opencode", "--event", event],
    { ...payload, instanceID, clientVersion: await version, directory },
  )
  const withParent = (sessionID, payload) => {
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

  return {
    event: async ({ event }) => {
      const type = event?.type
      if (!LIFECYCLE_EVENTS.has(type)) return
      const properties = event?.properties && typeof event.properties === "object"
        ? event.properties
        : {}
      const sessionID = properties.sessionID
      const payload = withParent(sessionID, {
        eventID: event?.id,
        ...properties,
      })
      await hook(type, payload)
      if (type === "session.created" && typeof properties.info?.parentID === "string") {
        parents.set(sessionID, properties.info.parentID)
      }
      if (type === "session.deleted" && typeof sessionID === "string") {
        parents.delete(sessionID)
      }
    },

    "tool.execute.before": async (toolInput, output) => {
      const tool = toolInput?.tool
      const sessionID = toolInput?.sessionID
      const callID = toolInput?.callID
      const args = output?.args
      if (typeof sessionID !== "string" || !sessionID || typeof callID !== "string" || !callID) {
        if (tool === "bash" && looksLikeLegacyCompletion(args)) throw new Error(LEGACY_GUIDANCE)
        return
      }
      const result = await hook("tool.execute.before", withParent(sessionID, {
        tool,
        sessionID,
        callID,
        args,
      }))
      if (result?.args && args && typeof args === "object") {
        Object.assign(args, result.args)
      }
    },

    "tool.execute.after": async (toolInput) => {
      const { tool, sessionID, callID } = toolInput || {}
      if (typeof sessionID !== "string" || !sessionID || typeof callID !== "string" || !callID) {
        return
      }
      await hook("tool.execute.after", withParent(sessionID, {
        tool,
        sessionID,
        callID,
      }))
    },

    "experimental.chat.system.transform": async (chatInput, output) => {
      const sessionID = chatInput?.sessionID
      if (typeof sessionID !== "string" || !sessionID) return
      const identity = await hook("system.transform", withParent(sessionID, { sessionID }))
      const text = (await canonicalInstructions()).trimEnd()
      const line = `Kanban work handle: ${identity.handle}`
      output.system.push(text ? `${text}\n\n${line}` : line)
    },
  }
}
