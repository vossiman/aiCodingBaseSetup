// bw-deny-files.js: OpenCode plugin that runs the shared deny hook.
//
// Managed by the aiCodingBaseSetup blueprint
// (configs/opencode/plugins/bw-deny-files.js); aicoding-sync overwrites local
// edits, so change it there, via PR.
//
// A shim with no rules of its own, like configs/pi/extensions/bw-deny-files.ts:
// each tool call goes to configs/claude/hooks/bw-deny-files.sh, the script
// Claude Code, Codex and pi run, and a deny is thrown back to OpenCode. The
// glob rules in opencode.json stay as a backup for the direct forms.
//
// One file loads on OpenCode v1 and v2, so the default export carries both
// entry points. A named export would break v2, which allows only the default.

import { spawnSync } from "node:child_process"
import os from "node:os"
import path from "node:path"

const HOOK = path.join(os.homedir(), ".claude", "hooks", "bw-deny-files.sh")

// Shell calls (v1 "bash", v2 "shell") carry a command; any other call naming
// a file maps to Read, the strictest branch the hook has for a path.
function toHookInput(tool, args) {
  const a = args && typeof args === "object" ? args : {}
  const name = String(tool).toLowerCase()
  if (name === "bash" || name === "shell") {
    return typeof a.command === "string"
      ? { tool_name: "Bash", tool_input: { command: a.command } }
      : undefined
  }
  const target = [a.filePath, a.file_path, a.path].find((v) => typeof v === "string")
  return target ? { tool_name: "Read", tool_input: { file_path: target } } : undefined
}

// Returns the deny reason, or undefined to allow. Fails open on any hook
// failure, matching the hook and the pi shim; the opencode.json globs remain.
function checkToolCall(tool, args, hook = HOOK, cwd) {
  const payload = toHookInput(tool, args)
  if (!payload) return undefined
  const result = spawnSync("bash", [hook], {
    input: JSON.stringify(payload),
    encoding: "utf8",
    timeout: 5000,
    cwd,
  })
  if (result.status !== 0 || !result.stdout) return undefined
  let decision
  try {
    decision = JSON.parse(result.stdout)?.hookSpecificOutput
  } catch {
    return undefined
  }
  return decision?.permissionDecision === "deny"
    ? String(decision.permissionDecisionReason ?? "blocked")
    : undefined
}

// OpenCode v1 runs `server`, v2 runs `setup`; each ignores the other key.
export default {
  id: "aicoding-bw-deny-files",
  server: async (input) => ({
    "tool.execute.before": async (toolInput, output) => {
      const reason = checkToolCall(toolInput?.tool, output?.args, HOOK, input?.directory)
      if (reason) throw new Error(reason)
    },
  }),
  setup: async (ctx) => {
    await ctx.tool.hook("execute.before", (event) => {
      const reason = checkToolCall(event?.tool, event?.input, HOOK, ctx?.location?.directory)
      if (reason) throw new Error(reason)
    })
  },
  check: checkToolCall,
}
