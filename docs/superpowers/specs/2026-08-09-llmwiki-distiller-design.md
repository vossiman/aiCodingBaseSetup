# LLMWiki background distiller — design

Date: 2026-08-09
Status: approved-pending-review
Replaces: the Stop-hook nudge (`configs/claude/hooks/llmwiki-nudge.sh`)

## Problem

The current LLMWiki Stop hook injects `additionalContext` at end of turn.
Per Claude Code hook semantics, that output **forces another model turn**:
every time the 15-minute throttle elapses, the main session gets re-woken
after it already answered and produces an extra visible reply ("nothing
durable to file…" or an unprompted wiki detour). The spam is structural —
it is the model's response to the injected context, not hook stdout, so
`suppressOutput` cannot fix it.

## Decision

Replace the in-band nudge with an **out-of-band background distiller**:
the Stop hook (async, still throttled) fire-and-forgets a headless Claude
run of a globally registered agent that reviews the session transcript and
files durable lessons itself. The main conversation never sees any of it.

Decisions made during brainstorming (2026-08-09):

- **Model: Sonnet** — better judgment on what counts as "durable" than
  Haiku; cost accepted at the 15-minute cadence.
- **Cadence: keep the 15-minute per-project throttle** (tunable via
  `LLMWIKI_NUDGE_INTERVAL`, default 900 s, same state files as today).
- **Project-file writes: additive notes only** — the distiller may create
  new timestamped files under the project's `docs/notes/`, but never edits
  `CLAUDE.md` or any existing file, and never commits in the project repo.
  Wiki writes remain fully autonomous (homelab-wiki governance allows
  commit+push to its `main`).

## Components

All blueprint-managed in this repo; deployed by `install.sh`/`aicoding-sync`.

### 1. `configs/claude/hooks/llmwiki-distill.sh` (replaces `llmwiki-nudge.sh`)

Registered as the Stop hook in `configs/claude/settings.json` with
`"async": true` so it can never delay stopping.

Behavior, in order:

1. **Recursion guard**: `[ -n "$LLMWIKI_DISTILLER" ] && exit 0`.
2. Parse stdin JSON: `transcript_path`, `cwd` (fall back to `$PWD`).
   Missing/unreadable transcript → exit 0.
3. **Throttle**: identical to today — per-project-root slug state file
   under `~/.cache/aicoding/llmwiki-nudge/`; exit 0 inside the window,
   otherwise stamp `now` and continue. (Keep the existing state dir so
   deploys don't reset throttling.)
4. **Launch the distiller**:

   ```bash
   LLMWIKI_DISTILLER=1 claude -p \
     --agent llmwiki-distiller \
     --settings '{"disableAllHooks": true}' \
     "Review the session transcript at <transcript_path> (project root: <root>). File durable lessons per your instructions; if nothing durable emerged, do nothing." \
     >> ~/.cache/aicoding/llmwiki-distill.log 2>&1
   ```

   `disableAllHooks` is the primary recursion guard (the child fires no
   hooks at all); the env var is belt-and-suspenders.
5. Always `exit 0` — a broken distiller must never block stopping.

### 2. `configs/claude/agents/llmwiki-distiller.md` (new, → `~/.claude/agents/`)

Frontmatter: `name: llmwiki-distiller`, `model: sonnet`, description, and a
tool allowlist limited to Read/Grep/Glob/Bash/Write (no Task/Agent).

Instructions (summary):

- Read the transcript JSONL; identify **durable lessons** using the same
  taxonomy as the global CLAUDE.md rule.
- **Cross-project facts** (hosts, network, ports, backups, incidents, tool
  identities) → `~/homelab-wiki`, following its `AGENTS.md`: clone if
  missing, pull first, edit the owning page, commit+push to `main`. On
  push rejection: `pull --rebase` and retry once, then give up and log.
- **Project-internal lessons** → create a new file
  `docs/notes/YYYY-MM-DD-<slug>.md` in the project root. Never edit
  existing files, never touch `CLAUDE.md`, never commit — the untracked
  file surfaces naturally in the user's next `git status`.
- Don't record what code, git history, or docs already show.
- Nothing durable → exit without writes. End with a one-line summary
  (lands in the log file).

### 3. `configs/claude/settings.json`

- Stop hook entry: point at `llmwiki-distill.sh`, add `"async": true`.
- Remove/rename handled by the managed-files deploy (verify
  `provision-managed-files.sh` removes the old `llmwiki-nudge.sh` or at
  least that the stale file is harmless once unregistered).

## Error handling

- Hook: every failure path exits 0; launch failures land in
  `~/.cache/aicoding/llmwiki-distill.log`.
- Missing `claude` CLI or auth in the hook context: log one line, exit 0.
- Concurrent distillers from parallel sessions: throttle is per project,
  so cross-project overlap is possible; wiki conflicts are handled by the
  pull-first + rebase-retry rule above. No global lock (accepted risk —
  worst case one push retry fails and is logged).

## Testing

Manual, before the PR merges (exercise via
`aicoding-sync --blueprint "$PWD/devpod/aicoding" --dry-run` then apply):

1. Feed the hook crafted stdin JSON → verify throttle honored, state file
   stamped, distiller launched, `exit 0` always.
2. Recursion: run the hook with `LLMWIKI_DISTILLER=1` → immediate exit;
   confirm the child run fires no hooks (`disableAllHooks`).
3. Agent dry-run against a fixture transcript containing (a) a wiki-worthy
   fact, (b) a project-internal lesson, (c) nothing durable — verify wiki
   commit, additive note file, and no-op respectively.
4. Confirm Stop in a live session returns instantly (async).

## Out of scope

- Other agent CLIs (codex etc.) — the four-CLI workflow contract in
  homelab-wiki's `AGENTS.md` is unchanged; this remains a Claude-only
  reliability bonus, same as the nudge it replaces.
- SessionEnd handling, incremental "only since last distill" transcript
  slicing (future option: reuse the throttle timestamp to scope the
  review window and cut token cost).

## Risks / open items

- `"async": true` hook support and `--agent`/`--settings` flags assume a
  current Claude Code; verify the pinned devbox version supports them
  during implementation.
- Child-process lifetime after the async hook exits is not explicitly
  documented; if runs get reaped early in practice, fall back to
  `setsid`+`nohup` inside the script.
- Sonnet over very long transcripts costs real tokens each window; the
  incremental-slicing option above is the mitigation if it gets noisy.
