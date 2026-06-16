#!/usr/bin/env node
// Register a directory as a paseo project (idempotent — dedups by directory,
// no agent started) so the pod's repo shows up in the paseo app sidebar.
//
// Uses the bundled @getpaseo/cli daemon client (connectToDaemon → openProject).
// That's an internal path of the installed CLI, so this is deliberately
// FAIL-OPEN: any error (CLI layout changed, daemon not up, no node) exits 0 so
// it can never block pod boot. If it no-ops, the project can still be added
// from the app. Caller sets PASEO_HOME to target the right per-pod daemon.
//
// Usage: aicoding-paseo-open-project <project-dir>
import { execSync } from "node:child_process";
import { existsSync } from "node:fs";

const cwd = process.argv[2];
if (!cwd) process.exit(0);

let root;
try {
  root = execSync("npm root -g", { encoding: "utf8" }).trim();
} catch {
  process.exit(0);
}
const clientPath = `${root}/@getpaseo/cli/dist/utils/client.js`;
if (!existsSync(clientPath)) process.exit(0);

try {
  const { connectToDaemon } = await import(`file://${clientPath}`);
  const client = await connectToDaemon();
  try {
    await client.openProject(cwd);
  } finally {
    try {
      await client.close?.();
    } catch {
      /* ignore */
    }
  }
} catch {
  /* fail-open */
}
process.exit(0);
