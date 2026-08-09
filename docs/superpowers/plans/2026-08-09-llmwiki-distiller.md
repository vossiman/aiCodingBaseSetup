# LLMWiki Background Distiller Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the spammy in-band LLMWiki Stop-hook nudge with an async, gated launcher that fire-and-forgets a headless distiller agent.

**Architecture:** A Stop hook script (`llmwiki-distill.sh`, registered with `"async": true`) self-gates on a per-project 15-min throttle plus a per-session transcript-delta check, then spawns `claude -p --agent llmwiki-distiller` on only the new transcript slice with all hooks disabled in the child. The agent files cross-project lessons to homelab-wiki autonomously and project lessons as additive `docs/notes/` files only. Spec: `docs/superpowers/specs/2026-08-09-llmwiki-distiller-design.md`.

**Tech Stack:** bash, jq, bats (run ONLY via `tests/bats/run.sh`), Claude Code hooks/agents.

## Global Constraints

- Work in worktree `/var/tmp/aicoding-wt-llmwiki`, branch `docs/llmwiki-distiller-spec`. Never touch the shared checkout at `/workspaces/devmachine/devpod/aicoding`.
- The hook must ALWAYS `exit 0` — a broken distiller must never block stopping.
- Tunables and defaults (exact): `LLMWIKI_NUDGE_INTERVAL` = 900 s, `LLMWIKI_MIN_DELTA_BYTES` = 4096.
- State dir stays `~/.cache/aicoding/llmwiki-nudge` (existing deployments keep their throttle state).
- Throttle timestamp and offset are stamped ONLY when a distiller actually launches.
- Recursion guards (both): `LLMWIKI_DISTILLER=1` env check in the hook, `--settings '{"disableAllHooks": true}'` on the child.
- Blueprint config files use `{{HOME}}` placeholders, never `$HOME`.
- Run tests only through `tests/bats/run.sh` (e.g. `tests/bats/run.sh llmwiki-distill`), never bare `bats`.
- `main` is protected — commits stay on this branch; integration is via PR at the end.

---

### Task 1: Hook script `llmwiki-distill.sh` + bats tests

**Files:**
- Create: `configs/claude/hooks/llmwiki-distill.sh`
- Create: `tests/bats/llmwiki-distill.bats`
- Delete: `configs/claude/hooks/llmwiki-nudge.sh`

**Interfaces:**
- Consumes: Stop-hook stdin JSON with `transcript_path`, `session_id`, `cwd`.
- Produces: launches `claude -p --agent llmwiki-distiller --settings '{"disableAllHooks": true}' "<prompt>"` with `LLMWIKI_DISTILLER=1` in its environment; prompt names a slice file copied to `$HOME/.cache/aicoding/llmwiki-nudge/slices/<session_id>.jsonl`. Task 2's agent name (`llmwiki-distiller`) and Task 3's settings entry (`llmwiki-distill.sh`) must match these exact names.

- [ ] **Step 1: Write the failing tests**

Create `tests/bats/llmwiki-distill.bats`:

```bash
#!/usr/bin/env bats
#
# Unit tests for configs/claude/hooks/llmwiki-distill.sh — the async Stop-hook
# launcher for the background LLMWiki distiller. `claude` is stubbed: it
# records its argv to $HOME/claude-args and snapshots the slice file (the real
# hook deletes the slice after the run). Time and transcripts are plain files
# under a temp HOME, so tests never touch real state.

setup() {
  : "${BLUEPRINT_ROOT:?unset — run via tests/bats/run.sh}"
  HOOK="$BLUEPRINT_ROOT/configs/claude/hooks/llmwiki-distill.sh"
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  unset LLMWIKI_DISTILLER LLMWIKI_NUDGE_INTERVAL LLMWIKI_MIN_DELTA_BYTES

  mkdir -p "$TMPDIR/stubs"
  cat > "$TMPDIR/stubs/claude" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" > "$HOME/claude-args"
printf '%s\n' "${LLMWIKI_DISTILLER:-}" > "$HOME/claude-env-guard"
cp "$HOME"/.cache/aicoding/llmwiki-nudge/slices/* "$HOME/slice-copy" 2>/dev/null || true
exit "${CLAUDE_STUB_EXIT:-0}"
STUB
  chmod +x "$TMPDIR/stubs/claude"
  export PATH="$TMPDIR/stubs:$PATH"

  STATE_DIR="$HOME/.cache/aicoding/llmwiki-nudge"
}

teardown() { case "${TMPDIR:-}" in */tmp.*) rm -rf "$TMPDIR" ;; esac }

# mktranscript <path> <bytes> [char] — deterministic transcript of exact size.
mktranscript() {
  head -c "$2" /dev/zero | tr '\0' "${3:-x}" > "$1"
}

# hookjson <transcript> <session_id> — minimal Stop-hook stdin payload.
hookjson() {
  jq -nc --arg t "$1" --arg s "$2" --arg c "$TMPDIR" \
    '{transcript_path:$t, session_id:$s, cwd:$c}'
}

launched() { [ -f "$HOME/claude-args" ]; }

@test "llmwiki-distill: recursion guard exits silently" {
  mktranscript "$TMPDIR/t.jsonl" 8192
  LLMWIKI_DISTILLER=1 run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s1)"
  [ "$status" -eq 0 ]
  ! launched
}

@test "llmwiki-distill: missing transcript is a no-op" {
  run bash "$HOOK" <<< "$(hookjson "$TMPDIR/absent.jsonl" s1)"
  [ "$status" -eq 0 ]
  ! launched
}

@test "llmwiki-distill: first eligible stop launches with agent, settings, env guard" {
  mktranscript "$TMPDIR/t.jsonl" 8192
  run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s1)"
  [ "$status" -eq 0 ]
  launched
  grep -qx -- '--agent' "$HOME/claude-args"
  grep -qx 'llmwiki-distiller' "$HOME/claude-args"
  grep -q 'disableAllHooks' "$HOME/claude-args"
  grep -qx '1' "$HOME/claude-env-guard"
  # full transcript sliced (offset 0)
  [ "$(wc -c < "$HOME/slice-copy")" -eq 8192 ]
  # state stamped: offset == size, throttle file exists
  [ "$(cat "$STATE_DIR/offsets/s1")" -eq 8192 ]
  slug_file=$(ls "$STATE_DIR" | grep -v offsets | grep -v slices | head -1)
  [ -n "$slug_file" ]
}

@test "llmwiki-distill: inside throttle window does not launch" {
  mktranscript "$TMPDIR/t.jsonl" 8192
  run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s1)"
  launched
  rm -f "$HOME/claude-args"
  mktranscript "$TMPDIR/t.jsonl" 65536   # plenty of delta, but window not elapsed
  run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s1)"
  [ "$status" -eq 0 ]
  ! launched
}

@test "llmwiki-distill: below-threshold delta skips AND leaves throttle unstamped" {
  mktranscript "$TMPDIR/t.jsonl" 8192
  export LLMWIKI_NUDGE_INTERVAL=0        # window always elapsed
  run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s1)"
  launched
  rm -f "$HOME/claude-args"
  slug_file=$(ls "$STATE_DIR" | grep -v offsets | grep -v slices | head -1)
  stamp_before=$(cat "$STATE_DIR/$slug_file")
  mktranscript "$TMPDIR/t.jsonl" 9000    # +808 bytes < 4096 default threshold
  sleep 1
  run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s1)"
  [ "$status" -eq 0 ]
  ! launched
  [ "$(cat "$STATE_DIR/$slug_file")" -eq "$stamp_before" ]
}

@test "llmwiki-distill: slice contains only bytes past the stored offset" {
  export LLMWIKI_NUDGE_INTERVAL=0
  { head -c 4096 /dev/zero | tr '\0' 'A'; head -c 8192 /dev/zero | tr '\0' 'B'; } \
    > "$TMPDIR/t.jsonl"
  mkdir -p "$STATE_DIR/offsets"
  printf '4096' > "$STATE_DIR/offsets/s1"
  run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s1)"
  [ "$status" -eq 0 ]
  launched
  [ "$(wc -c < "$HOME/slice-copy")" -eq 8192 ]
  ! grep -q 'A' "$HOME/slice-copy"
  [ "$(cat "$STATE_DIR/offsets/s1")" -eq 12288 ]
}

@test "llmwiki-distill: offset larger than transcript resets to full slice" {
  export LLMWIKI_NUDGE_INTERVAL=0
  mktranscript "$TMPDIR/t.jsonl" 8192
  mkdir -p "$STATE_DIR/offsets"
  printf '999999' > "$STATE_DIR/offsets/s1"
  run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s1)"
  [ "$status" -eq 0 ]
  launched
  [ "$(wc -c < "$HOME/slice-copy")" -eq 8192 ]
}

@test "llmwiki-distill: claude failure still exits 0 and cleans the slice" {
  mktranscript "$TMPDIR/t.jsonl" 8192
  CLAUDE_STUB_EXIT=7 run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s1)"
  [ "$status" -eq 0 ]
  launched
  [ -z "$(ls -A "$STATE_DIR/slices" 2>/dev/null)" ]
}

@test "llmwiki-distill: missing claude CLI is a no-op that leaves state unstamped" {
  mktranscript "$TMPDIR/t.jsonl" 8192
  PATH="/usr/bin:/bin" run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s1)"
  [ "$status" -eq 0 ]
  ! launched
  [ ! -f "$STATE_DIR/offsets/s1" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `tests/bats/run.sh llmwiki-distill`
Expected: FAIL — hook script does not exist yet.

- [ ] **Step 3: Write the hook script**

Create `configs/claude/hooks/llmwiki-distill.sh`:

```bash
#!/bin/bash
# Async Stop-hook launcher for the background LLMWiki distiller.
# Replaces llmwiki-nudge.sh: injecting additionalContext forced an extra
# visible model turn every firing; instead we fire-and-forget a headless
# distiller agent over only the NEW transcript bytes. Design:
# docs/superpowers/specs/2026-08-09-llmwiki-distiller-design.md
#
# Tunables:
#   LLMWIKI_NUDGE_INTERVAL   seconds between launches per project (default 900)
#   LLMWIKI_MIN_DELTA_BYTES  minimum new transcript bytes to launch (default 4096)
# Never exits non-zero — a broken distiller must never block stopping.

# Recursion guard: never act inside a distiller-spawned session.
[ -n "$LLMWIKI_DISTILLER" ] && exit 0

THRESHOLD_SECONDS="${LLMWIKI_NUDGE_INTERVAL:-900}"
MIN_DELTA="${LLMWIKI_MIN_DELTA_BYTES:-4096}"

input="$(cat)"

transcript="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)"
[ -f "$transcript" ] || exit 0
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
case "$session_id" in (''|*[!a-zA-Z0-9_-]*) exit 0 ;; esac
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[ -z "$cwd" ] && cwd="$PWD"

# Throttle is per project root so parallel sessions in different repos don't
# starve each other; non-git dirs fall back to the cwd itself.
root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)"
[ -z "$root" ] && root="$cwd"
slug="$(printf '%s' "$root" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
[ -z "$slug" ] && slug="global"

state_dir="$HOME/.cache/aicoding/llmwiki-nudge"
mkdir -p "$state_dir/offsets" "$state_dir/slices" 2>/dev/null

state_file="$state_dir/$slug"
now="$(date +%s)"
last=0
[ -f "$state_file" ] && last="$(cat "$state_file" 2>/dev/null || echo 0)"
case "$last" in (*[!0-9]*|'') last=0 ;; esac
[ "$(( now - last ))" -lt "$THRESHOLD_SECONDS" ] && exit 0

# Transcript-delta gate. Offsets are per transcript (sessions each have their
# own file, the throttle is per project). Offset > size means the transcript
# was rewritten/compacted — start over from zero.
offset_file="$state_dir/offsets/$session_id"
offset=0
[ -f "$offset_file" ] && offset="$(cat "$offset_file" 2>/dev/null || echo 0)"
case "$offset" in (*[!0-9]*|'') offset=0 ;; esac
size="$(stat -c %s "$transcript" 2>/dev/null || echo 0)"
[ "$offset" -gt "$size" ] && offset=0
[ "$(( size - offset ))" -lt "$MIN_DELTA" ] && exit 0

command -v claude >/dev/null 2>&1 || exit 0

# Stamp only now — gated-out stops must not push the window, and a slow agent
# run must not double-fire.
printf '%s' "$now"  > "$state_file"  2>/dev/null
printf '%s' "$size" > "$offset_file" 2>/dev/null
find "$state_dir/offsets" -type f -mtime +30 -delete 2>/dev/null

# Copy the new bytes out — the live transcript keeps growing under the agent.
slice="$state_dir/slices/$session_id.jsonl"
tail -c +"$(( offset + 1 ))" "$transcript" > "$slice" 2>/dev/null \
  || { rm -f "$slice"; exit 0; }

log="$HOME/.cache/aicoding/llmwiki-distill.log"
{
  printf '%s launch project=%s session=%s bytes=%s-%s\n' \
    "$(date -Is)" "$slug" "$session_id" "$offset" "$size"
  LLMWIKI_DISTILLER=1 claude -p \
    --agent llmwiki-distiller \
    --settings '{"disableAllHooks": true}' \
    "Review the new session activity in $slice (project root: $root; this is the tail of a longer Claude Code session transcript in JSONL format). Follow your instructions: file durable lessons; if nothing durable emerged, do nothing."
  printf '%s done session=%s exit=%s\n' "$(date -Is)" "$session_id" "$?"
} >> "$log" 2>&1
rm -f "$slice"

exit 0
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `tests/bats/run.sh llmwiki-distill`
Expected: all 9 tests PASS.

- [ ] **Step 5: Delete the old nudge script**

```bash
git rm configs/claude/hooks/llmwiki-nudge.sh
```

(Reference-cleanup in `lib/` and `configs/claude/settings.json` happens in Task 3 — the repo grep for `llmwiki-nudge` goes to zero there, not here.)

- [ ] **Step 6: Commit**

```bash
git add configs/claude/hooks/llmwiki-distill.sh tests/bats/llmwiki-distill.bats
git commit -m "feat(llmwiki): async distiller launcher hook replaces in-band nudge"
```

---

### Task 2: Agent definition `llmwiki-distiller.md`

**Files:**
- Create: `configs/claude/agents/llmwiki-distiller.md`
- Modify: `tests/bats/llmwiki-distill.bats` (append sanity tests)

**Interfaces:**
- Consumes: launched by Task 1's hook as `claude -p --agent llmwiki-distiller`; the prompt supplies the slice path and project root.
- Produces: agent name `llmwiki-distiller` (must match the hook's `--agent` argument exactly); deployed to `~/.claude/agents/llmwiki-distiller.md` by Task 3's inventory row.

- [ ] **Step 1: Write the failing sanity tests**

Append to `tests/bats/llmwiki-distill.bats`:

```bash
@test "llmwiki-distiller agent: frontmatter name/model match the hook contract" {
  AGENT_DEF="$BLUEPRINT_ROOT/configs/claude/agents/llmwiki-distiller.md"
  [ -f "$AGENT_DEF" ]
  head -1 "$AGENT_DEF" | grep -qx -- '---'
  grep -qx 'name: llmwiki-distiller' "$AGENT_DEF"
  grep -qx 'model: sonnet' "$AGENT_DEF"
}

@test "llmwiki-distiller agent: encodes write-policy guardrails" {
  AGENT_DEF="$BLUEPRINT_ROOT/configs/claude/agents/llmwiki-distiller.md"
  grep -q 'homelab-wiki' "$AGENT_DEF"
  grep -q 'docs/notes/' "$AGENT_DEF"
  grep -qi 'never edit CLAUDE.md' "$AGENT_DEF"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `tests/bats/run.sh llmwiki-distill -f 'agent'`
Expected: FAIL — agent file does not exist.

- [ ] **Step 3: Write the agent definition**

Create `configs/claude/agents/llmwiki-distiller.md`:

```markdown
---
name: llmwiki-distiller
description: Background knowledge distiller. Reviews a slice of a Claude Code session transcript and files durable lessons to homelab-wiki or the project's docs/notes/. Launched headless by the llmwiki-distill Stop hook; never invoked interactively.
model: sonnet
tools: Read, Grep, Glob, Bash, Write
---

You are the LLMWiki distiller. You receive a path to a JSONL slice of a
Claude Code session transcript and the project root it belongs to. Your only
job: extract durable lessons and file them in the right place. You run
headless — nobody reads your output live; your writes ARE the deliverable.

## What counts as durable

A fact someone would need again in a month: environment quirks, incidents
and their root causes, host/network/port facts, backup locations, tool
identities and auth paths, hard-won workflow gotchas. NOT: routine code
changes, session narration, anything already recorded in the project's
code, git history, docs, or the wiki itself — check before writing.

## Where lessons go

**Cross-project facts** (hosts, network, ports, backups, incidents, tool
identities) → `~/homelab-wiki`:
1. If `~/homelab-wiki` is missing: `git clone https://github.com/vossiman/homelab-wiki ~/homelab-wiki`.
2. Read its `AGENTS.md` and follow it. Always `git pull` first.
3. Edit the page that owns the topic (don't create parallel pages).
4. Commit and push to `main` autonomously — that repo's governance allows it.
5. If the push is rejected: `git pull --rebase` and retry ONCE, then give up
   and state the failure in your final message.

**Project-internal lessons** → create a NEW file
`<project-root>/docs/notes/YYYY-MM-DD-<short-slug>.md` (create `docs/notes/`
if absent). Additive only: never edit CLAUDE.md, never modify or delete any
existing file in the project, never `git add`/`commit`/`push` in the project
repo. The untracked file surfacing in `git status` is the intended handoff.

## Reading the slice

The slice is raw Claude Code JSONL and may start mid-record; its format may
drift between versions. Extract lessons from whatever structure you find —
user messages, assistant text, and command outputs carry the signal. Do not
fail on parse errors; skip malformed lines.

## Discipline

- Nothing durable in the slice → write nothing, touch nothing.
- Prefer one tight paragraph per lesson over transcript dumps.
- End with a one-line summary of what you filed (or "nothing durable") —
  it lands in the launcher's log file.
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `tests/bats/run.sh llmwiki-distill`
Expected: all 11 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add configs/claude/agents/llmwiki-distiller.md tests/bats/llmwiki-distill.bats
git commit -m "feat(llmwiki): distiller agent definition (sonnet, additive-notes-only)"
```

---

### Task 3: Blueprint wiring — settings, inventory, managed-hooks list

**Files:**
- Modify: `configs/claude/settings.json` (Stop hook entry, ~line 26-36)
- Modify: `lib/blueprint-deploy.sh` (managed inventory, ~line 366)
- Modify: `lib/provision-managed-files.sh` (MANAGED_HOOKS, ~line 74)
- Modify: `tests/bats/blueprint-deploy.bats` (append inventory/settings asserts)

**Interfaces:**
- Consumes: file names from Task 1 (`llmwiki-distill.sh`) and Task 2 (`llmwiki-distiller.md`).
- Produces: deploy destinations `$HOME/.claude/hooks/llmwiki-distill.sh` and `$HOME/.claude/agents/llmwiki-distiller.md`; the dropped nudge row makes reconcile's existing `to_remove` bucket delete the stale deployed file on next sync (no extra code needed — `lib/blueprint-deploy.sh:700`).

- [ ] **Step 1: Write the failing tests**

Append to `tests/bats/blueprint-deploy.bats` (same pattern as the existing inventory tests around line 558):

```bash
@test "managed_inventory_overwrite: llmwiki distill hook + distiller agent rows, nudge row gone" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run managed_inventory_overwrite
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "$HOME/.claude/hooks/llmwiki-distill.sh|overwrite|configs/claude/hooks/llmwiki-distill.sh"
  echo "$output" | grep -qF "$HOME/.claude/agents/llmwiki-distiller.md|overwrite|configs/claude/agents/llmwiki-distiller.md"
  ! echo "$output" | grep -q 'llmwiki-nudge'
}

@test "claude settings fragment: Stop hook is the async distill launcher" {
  jq -e '.hooks.Stop[0].hooks[0].async == true' "$BLUEPRINT_ROOT/configs/claude/settings.json"
  jq -re '.hooks.Stop[0].hooks[0].command' "$BLUEPRINT_ROOT/configs/claude/settings.json" \
    | grep -qF '{{HOME}}/.claude/hooks/llmwiki-distill.sh'
  ! grep -q 'llmwiki-nudge' "$BLUEPRINT_ROOT/configs/claude/settings.json"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `tests/bats/run.sh blueprint-deploy -f 'llmwiki|Stop hook is the async'`
Expected: both new tests FAIL (old rows/command still present).

- [ ] **Step 3: Apply the three wiring edits**

In `configs/claude/settings.json`, replace the Stop block:

```json
"Stop": [
  {
    "hooks": [
      {
        "type": "command",
        "command": "bash \"{{HOME}}/.claude/hooks/llmwiki-distill.sh\"",
        "async": true
      }
    ]
  }
]
```

In `lib/blueprint-deploy.sh` `managed_inventory_overwrite()`, replace the row
`$HOME/.claude/hooks/llmwiki-nudge.sh|overwrite|configs/claude/hooks/llmwiki-nudge.sh` with:

```
$HOME/.claude/hooks/llmwiki-distill.sh|overwrite|configs/claude/hooks/llmwiki-distill.sh
$HOME/.claude/agents/llmwiki-distiller.md|overwrite|configs/claude/agents/llmwiki-distiller.md
```

In `lib/provision-managed-files.sh`, update the list:

```bash
MANAGED_HOOKS=("custom-statusline.js" "bw-deny-files.sh" "check-archived-docs.sh" "llmwiki-distill.sh")
```

- [ ] **Step 4: Run tests to verify they pass, plus repo-wide reference check**

Run: `tests/bats/run.sh blueprint-deploy llmwiki-distill`
Expected: PASS.

Run: `grep -rn "llmwiki-nudge" --include="*.sh" --include="*.json" . | grep -v docs/superpowers | grep -v '\.git/'`
Expected: only the state-dir path `~/.cache/aicoding/llmwiki-nudge` inside `configs/claude/hooks/llmwiki-distill.sh` (kept deliberately so existing throttle state survives).

- [ ] **Step 5: Commit**

```bash
git add configs/claude/settings.json lib/blueprint-deploy.sh lib/provision-managed-files.sh tests/bats/blueprint-deploy.bats
git commit -m "feat(llmwiki): wire distill hook + agent into blueprint deploy, drop nudge"
```

---

### Task 4: Full suite, spec status, live smoke test

**Files:**
- Modify: `docs/superpowers/specs/2026-08-09-llmwiki-distiller-design.md:4` (status line)

**Interfaces:**
- Consumes: everything above.
- Produces: a branch ready for PR review.

- [ ] **Step 1: Run the full bats suite**

Run: `tests/bats/run.sh`
Expected: 0 failures. If pre-existing tests reference the removed nudge (they didn't at plan time — verified by grep), fix forward, don't skip.

- [ ] **Step 2: Live smoke test of the version-sensitive assumptions**

The spec flags `"async": true` and `--agent`/`--settings` support as risks. Verify against the installed CLI (do NOT rely on memory):

```bash
claude --help 2>&1 | grep -E -- '--agent|--settings'
claude -p --agent llmwiki-distiller --settings '{"disableAllHooks": true}' \
  "Reply with the single word OK and do nothing else." || echo "AGENT-FLAG-UNSUPPORTED"
```

Expected: both flags documented; the run prints OK (agent is not deployed yet — if the CLI errors with "unknown agent", deploy the worktree blueprint first: `aicoding-sync --blueprint /var/tmp/aicoding-wt-llmwiki`). If a flag is unsupported by the pinned CLI version, STOP and surface it — the design depends on it.

- [ ] **Step 3: Update spec status**

In `docs/superpowers/specs/2026-08-09-llmwiki-distiller-design.md` change line 4:

```markdown
Status: implemented on branch docs/llmwiki-distiller-spec (pending PR)
```

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-08-09-llmwiki-distiller-design.md
git commit -m "docs(spec): llmwiki distiller — mark implemented"
```

- [ ] **Step 5: Verify branch is PR-ready**

```bash
git log --oneline origin/main..HEAD
git status --short
```

Expected: the spec commits plus the three implementation commits; clean tree. Do NOT push or open the PR without the user — `main` is protected and merging needs their sign-off.
