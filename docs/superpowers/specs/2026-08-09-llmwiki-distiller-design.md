# LLMWiki background distiller — design

Date: 2026-08-09
Status: implemented on branch docs/llmwiki-distiller-spec (pending PR)
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
  - *Revised 2026-08-12:* the untracked-handoff design left notes piling up
    uncommitted across sessions (nine in devMachine alone). The distiller
    now lands notes on the project's default branch itself — docs-only,
    committed via a disposable `git worktree` so the live checkout is never
    touched, no force-push, one retry on race — matching the docs-only
    direct-to-`main` exemption the user granted devMachine (2026-08-09) and
    dvw (2026-08-12). The untracked handoff remains as fallback when the
    project has no remote or the push is refused.
  - *Revised 2026-08-17:* direct push is now **opt-in per repo** via a
    tracked marker file `docs/notes/.llmwiki-direct-push-ok`. The
    2026-08-12 revision had generalized a devMachine/dvw-specific
    exemption to every project; in dataEnv the distiller's push to `main`
    triggered a prod deploy. Default reverts to the untracked handoff
    (accepting the pile-up cost in repos without the marker); repos that
    want notes landed on the default branch (e.g. devMachine, dvw) carry
    the marker.
  - *Revised 2026-08-17, same day (supersedes the marker mechanism):*
    project notes no longer land in the project repo at all. ALL lessons —
    cross-project and project-scoped — are filed in homelab-wiki;
    project-scoped ones on the project's entity page `wiki/<repo>.md`
    (created on first need), under the wiki's supersede-in-place rules.
    Rationale: memory-lanes indexes only the wiki clone
    (`memory-lanes:src/memory_lanes/wiki.py`, recursive `rglob("*.md")`),
    so in-repo notes were invisible to the retrieval read path; and the
    marker design still left un-marked repos accumulating untracked note
    files. The wiki is the only repo the distiller may commit to; the
    untracked in-repo note survives solely as the fallback when the wiki
    itself is unreachable. The `.llmwiki-direct-push-ok` marker mechanism
    is retired (markers removed from devMachine and dvw the same day).
- **Launch gate: transcript delta** (decided 2026-08-09) — after the
  throttle window passes, only launch if the session transcript grew by
  ≥ a threshold since the last distill of that transcript, and pass only
  the new slice to the agent. Git state is deliberately NOT the gate: the
  most wiki-worthy lessons (incidents, network/host facts, tool quirks)
  often produce zero repo changes, while commits can carry none.

## Scheduling model

There is no scheduler, cron, or daemon. Claude Code fires the Stop hook
after every turn of every session on the machine; the script self-gates
(throttle, then transcript delta). Effective behavior: "at the first
turn-end after the window elapses, if enough new conversation
accumulated". No Claude usage on a machine → nothing ever runs there.

## Components

All blueprint-managed in this repo; deployed by `install.sh`/`aicoding-sync`.

### 1. `configs/claude/hooks/llmwiki-distill.sh` (replaces `llmwiki-nudge.sh`)

Registered as the Stop hook in `configs/claude/settings.json` with
`"async": true` so it can never delay stopping.

Behavior, in order:

1. **Recursion guard**: `[ -n "$LLMWIKI_DISTILLER" ] && exit 0`.
2. Parse stdin JSON: `transcript_path`, `cwd`, `session_id` (fall back
   to `$PWD` for cwd). Missing/unreadable transcript → exit 0.
3. **Throttle**: per-project-root slug state file under
   `~/.cache/aicoding/llmwiki-nudge/` as today, but the timestamp is
   stamped **only when a distiller actually launches** (step 5), so
   gated-out stops don't push the window forward. Exit 0 inside the
   window. (Keep the existing state dir so deploys don't reset it.)
4. **Transcript-delta gate**: offsets are per *transcript* (sessions
   each have their own file, while the throttle is per project), stored
   as `~/.cache/aicoding/llmwiki-nudge/offsets/<session_id>` holding the
   byte size at last distill (absent → 0). Compare against the current
   size (`stat -c %s`); if the delta is below the threshold
   (`LLMWIKI_MIN_DELTA_BYTES`, default 4096), exit 0 without stamping.
   Prune offset files older than ~30 days opportunistically.
5. **Create the slice, then launch the distiller**, stamping the throttle
   and offset only after slice creation succeeds — a slice-write failure
   or a gated-out stop must not push the window forward, and a slow
   agent run must not double-fire:

   ```bash
   slice="$state_dir/slices/$session_id.jsonl"
   tail -c +$((offset + 1)) "$transcript_path" > "$slice" || exit 0

   printf '%s' "$now"  > "$state_file"
   printf '%s' "$size" > "$offset_file"

   LLMWIKI_DISTILLER=1 claude -p \
     --agent llmwiki-distiller \
     --settings '{"disableAllHooks": true, "permissions": {"allow": ["Write", "Bash(git:*)", "Bash(mkdir:*)"]}}' \
     "Review the new session activity in <slice> (project root: <root>; this is the tail of a longer session). File durable lessons per your instructions; if nothing durable emerged, do nothing." \
     >> ~/.cache/aicoding/llmwiki-distill.log 2>&1
   rm -f "$slice"
   ```

   `disableAllHooks` is the primary recursion guard (the child fires no
   hooks at all); the env var is belt-and-suspenders. The slice copy is
   needed because the live transcript keeps growing under the agent. The
   `permissions.allow` grant is required in headless mode: without it, the
   child's Write/Bash calls hit denial prompts it can never answer, and the
   feature is silently inert. It is scoped to exactly the agent's write
   policy (wiki git ops, project file writes, `mkdir` for `docs/notes/`) —
   never a broad `Bash(*)` grant, never `--dangerously-skip-permissions`.
6. Always `exit 0` — a broken distiller must never block stopping.

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

## Deployment scope & multi-machine behavior

Deployment is per user home on whatever machine runs `aicoding-install`
or `aicoding-sync` (devpod, WSL, Mint, …), via the managed inventory in
`lib/blueprint-deploy.sh`: hook → `~/.claude/hooks/`, agent →
`~/.claude/agents/`, Stop entry merged into the **global**
`~/.claude/settings.json`. That means the distiller is active for every
Claude Code session on that machine, in any repo or folder — not just
aicoding-scaffolded projects (non-git dirs fall back to cwd for the
throttle slug).

Machines are fully independent: each has its own throttle/offset state
and log under `~/.cache/aicoding/`, its own `~/homelab-wiki` clone
(created on first wiki-worthy lesson), its own transcripts under
`~/.claude/projects/`. The same repo on two machines gets two
independent windows; concurrent wiki pushes are absorbed by the
pull-first + rebase-retry rule.

Per-machine prerequisites: an authenticated `claude` CLI and git
credentials capable of pushing homelab-wiki. Where either is missing the
design degrades safely — the run fails into the log, the interactive
session is never affected.

Debug checklist on any machine: `~/.claude/hooks/llmwiki-distill.sh`,
`~/.claude/agents/llmwiki-distiller.md`, the Stop entry in
`~/.claude/settings.json`, state in `~/.cache/aicoding/llmwiki-nudge/`
(+ `offsets/`), log at `~/.cache/aicoding/llmwiki-distill.log`.

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

1. Feed the hook crafted stdin JSON → verify throttle honored, delta
   gate skips below-threshold growth (and doesn't stamp the throttle),
   offset/throttle stamped on launch, slice contains only new bytes,
   `exit 0` always.
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
- SessionEnd handling (a final distill when a session ends; the delta
  gate makes turn-end coverage good enough to start with).
- Machine-level coordination (shared state across devpod/WSL/Mint);
  per-machine independence is accepted by design.

## Risks / open items

- `"async": true` hook support and `--agent`/`--settings` flags assume a
  current Claude Code; verify the pinned devbox version supports them
  during implementation.
- Child-process lifetime after the async hook exits is not explicitly
  documented; if runs get reaped early in practice, fall back to
  `setsid`+`nohup` inside the script.
- Transcript JSONL format is an internal Claude Code detail; the slice
  is raw JSONL and the agent must tolerate format drift (its
  instructions say "extract lessons from whatever structure you find").
- A transcript that gets compacted/rewritten in place could shrink below
  the stored offset; guard with `offset > size → treat offset as 0`.
- The Stop hook entry sets a generous `"timeout": 600` for the async
  distiller run, but whether the async child actually survives a
  multi-minute run to completion (vs. being reaped early by the harness)
  is not verifiable in bats — that remains a post-deploy live check: look
  for a matching `done ... exit=` line in `~/.cache/aicoding/llmwiki-distill.log`
  after a long-running session stops.
