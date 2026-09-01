// bw-deny-files.ts — pi extension that blocks agent access to secrets.
//
// Managed by the aiCodingBaseSetup blueprint
// (configs/pi/extensions/bw-deny-files.ts); aicoding-sync overwrites local
// edits — change it there, via PR.
//
// This is a SHIM, deliberately. It does not implement any deny rules of its
// own: it pipes the tool call into configs/claude/hooks/bw-deny-files.sh —
// the very same script Claude Code and codex run — and honours the decision
// that comes back. One implementation of the rules, so pi can never drift
// from the other two harnesses. That is also why the 2026-08-31 narrowing
// (a protected path named inside a quoted argument to a non-reader is prose,
// not a read; AICODINGBASESETUP-6) needed no edit here: pi inherits it.
//
// It replaces bw-AICode's vendored extension, which only activated when
// BW_DENY_PATTERNS_FILE was set (i.e. inside the bubblewrap sandbox) and was
// therefore a no-op everywhere else — present in the extensions directory,
// named like a security control, protecting nothing. The Claude Code hook had
// exactly this bug until aiCodingBaseSetup PR #95.

import { spawnSync } from "node:child_process";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const HOOK = "{{HOME}}/.claude/hooks/bw-deny-files.sh";

type ToolEvent = { toolName: string; input: Record<string, unknown> };
type BlockResult = { block: true; reason: string } | undefined;

// pi's tool vocabulary is not Claude Code's, and the hook speaks Claude's.
// Bash-shaped calls carry a command string; everything else that names a file
// is mapped to Read, which is the strictest branch the hook offers for a path.
// A call naming no file is passed through as-is and the hook allows it.
function toHookInput(event: ToolEvent): Record<string, unknown> | undefined {
  const { command, path, file_path: filePath } = event.input;

  if (event.toolName.toLowerCase() === "bash") {
    return typeof command === "string"
      ? { tool_name: "Bash", tool_input: { command } }
      : undefined;
  }

  const target = typeof path === "string" ? path
    : typeof filePath === "string" ? filePath
    : undefined;

  return target ? { tool_name: "Read", tool_input: { file_path: target } } : undefined;
}

export function checkToolCall(event: ToolEvent): BlockResult {
  const payload = toHookInput(event);
  if (!payload) return undefined;

  // Fail OPEN on any hook failure. A guard that throws would surface as an
  // error on every tool call and get switched off; the hook itself takes the
  // same position (see its "malformed input must never make the hook exit
  // non-zero" comment). Failing open is logged by the hook, not silent.
  const result = spawnSync("bash", [HOOK], {
    input: JSON.stringify(payload),
    encoding: "utf8",
    timeout: 5000,
  });
  if (result.status !== 0 || !result.stdout) return undefined;

  let decision;
  try {
    decision = JSON.parse(result.stdout)?.hookSpecificOutput;
  } catch {
    return undefined;
  }

  return decision?.permissionDecision === "deny"
    ? { block: true, reason: String(decision.permissionDecisionReason ?? "blocked") }
    : undefined;
}

export default function (pi: ExtensionAPI) {
  // No sandbox gate. The built-in deny list is always enforced, matching the
  // hook's post-PR-#95 behaviour; BW_DENY_PATTERNS_FILE only ADDS patterns,
  // and the hook reads it itself.
  pi.on("tool_call", async (event) =>
    checkToolCall({ toolName: event.toolName, input: event.input as Record<string, unknown> }),
  );
}
