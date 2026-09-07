# redact-sessions: scrub secret values out of agent transcripts on disk

Ticket: AICODINGBASESETUP-15. Date: 2026-09-07. Status: draft, awaiting review.

## 1. Problem

Three leaks in two days (2026-08-27, 2026-09-04 twice) had one shape: a real
credential reached an agent transcript through a fresh copy of the value in a
place no deny rule named. `docker compose config` interpolated a key into its
output; a Dokploy build-failure notification carried the app env
base64-encoded; a helper script wrote real tokens into a scratch env dir and a
subagent printed the files.

Every guard we have is a denylist of locations: the secrets file, `printenv`,
`gh auth token`, the credential helper, the MCP configs. A denylist of
locations loses each time the value moves, and deploy tooling moves values
constantly. We will not enumerate every case.

The durable harm in each incident was the persisted transcript: it sits on a
host bind mount shared by every devpod container, it is read by the wiki
distiller, and it survives the session. The scrubber attacks that copy.

## 2. Goal and non-goals

**Goal.** Every value from `~/.aicodingsetup/.secrets.env` that lands in any
agent transcript file on this machine is replaced with `[REDACTED:KEYNAME]`
in the file, and the hit is reported so the credential gets rotated. This
holds regardless of which CLI, tool, subagent, or encoding put it there.

**Non-goals, stated so nobody expects them.**

- Preventing the model from seeing the value. A hit is still a burned
  credential and still needs a rotation. A hook that rewrites tool results
  before the model sees them exists only in Claude Code (`updatedToolOutput`
  on PostToolUse). It was considered and dropped: it does not exist for codex
  or cursor, and a second mechanism per harness is exactly the elaborate
  setup we are avoiding. The reporting path is what makes the scrubber
  sufficient on its own.
- Terminal scrollback, tmux history, the Anthropic-side conversation, and
  the Logfire query log of `memory_search` prompts.
- Secret-shaped tokens that are not in the secrets file. The pattern and
  entropy layers of `redact-transcript` stay reserved for material leaving
  the machine (distiller tee, transcript harvester). Running them over
  session files would eat docker image digests, container ids and similar
  things a resumed session needs to read, and their hits would not be
  actionable anyway because no key name can be attached to them.
- Values shorter than 8 characters (the existing literal-layer floor).
- Cursor's SQLite chat store (`~/.cursor/chats/*/*/store.db`). It is not a
  text file, and rewriting SQLite content in place is out of scope. Its
  `prompt_history.json` siblings are in scope.

## 3. Design

### 3.1 One script: `bin/redact-sessions`

Installed as `~/.local/bin/redact-sessions`, same pattern as
`redact-transcript`. Two modes:

```
redact-sessions FILE...        # scrub exactly these files
redact-sessions --sweep        # scrub every settled transcript under the known roots
```

Both modes share the same per-file procedure (3.3). `--sweep` walks the
roots in 3.2 and applies the procedure to each file that is not open for
writing (3.4) and whose mtime is newer than the last sweep stamp.

### 3.2 Scan roots

One array near the top of the script, so a new harness is one added line:

| Harness | Root | Files |
|---|---|---|
| Claude Code | `~/.claude/projects/` | `**/*.jsonl`, which includes `<project>/<session>/subagents/*.jsonl` |
| codex | `~/.codex/sessions/` | `**/*.jsonl` |
| cursor | `~/.cursor/chats/` | `**/prompt_history.json`, `**/meta.json` |

Subagent transcripts are covered by the glob, not by any special handling.
Two of the three incidents were printed by subagents; that is the point.

### 3.3 Per-file procedure

1. Build the literal redaction script from the secrets file. This is
   `redact-transcript`'s `_ml_literal_script`, refactored so both binaries
   share it (a sourced `lib/redact-literal.sh` or an internal
   `redact-transcript --literal-only --with-key-names --with-base64`
   invocation; the plan decides, the behaviour is fixed here). The rule set
   per key `K` with value `V` (length >= 8):
   - `V` verbatim.
   - the JSON-escaped form of `V`, when it differs (transcripts are JSONL,
     so `"` and `\` inside a value appear as `\"` and `\\`).
   - the three base64 alignments of `V`. Encode `V`, `xV`, `xxV` (any
     padding prefix), strip the first 2 or 3 leading characters and any
     trailing `=`, and match the remaining run. This finds `V` inside any
     larger base64 blob, which is the Dokploy notification case. Values
     shorter than 12 characters get no base64 rules: the aligned core is too
     short to be unique.
   - replacement text is `[REDACTED:K]`. The key name is what makes a hit
     actionable; the value never appears anywhere.
2. Count matches before rewriting (`grep -c` per rule against the file).
   Zero matches: leave the file untouched, do not change its mtime.
3. Non-zero: write the redacted content to a temp file in the same
   directory, `chmod --reference` the original, then `mv` it over the
   original. Rename is atomic on the same filesystem, so a reader never sees
   a half-written file.
4. Report the hit (3.6).

The scrubber reads the secrets file itself, in its own process, exactly as
`redact-transcript` already does. The ticket asked for fingerprints instead
of plaintext in the hook; that is not possible, because a fingerprint cannot
locate a value inside arbitrary text. The process boundary is the guarantee:
the scrubber is not the agent, it never prints a value, and the deny hook
does not apply to it because it is not a tool call.

### 3.4 Live-file safety

The harnesses append to a transcript for the whole session. Rewriting an
open file loses appends made between read and rename. So a file is only
rewritten when no process holds it open for writing: `lsof -F` on the path,
falling back to a `/proc/*/fd` scan when `lsof` is absent. Any doubt counts
as open; the file is skipped and picked up by a later run.

Consequence: a value printed mid-session stays in the file until that
session's Stop or SessionEnd fires, or until the next sweep after the
session dies. That window is accepted. It is the same window the distiller
already lives with, and the alternative (a per-harness in-process hook) is
the design this spec rejects.

### 3.5 Triggers

No systemd user instance runs in the devcontainer, so there is no timer.
Every trigger is a hook or a boot step that already exists:

| When | What runs | Why |
|---|---|---|
| Claude Code `Stop` (async, after `llmwiki-distill.sh`) | `redact-sessions --sweep` | The session's own file is usually still open; the sweep catches everything settled, including subagent files whose agents have finished |
| Claude Code `SessionEnd` | `redact-sessions <transcript_path>` then `--sweep` | The main file is now closed |
| codex `notify` / `SessionEnd` hook, if the installed version fires one; otherwise nothing extra | `--sweep` | codex files are also caught by every Claude Code trigger and by boot |
| `on-start.sh` (container boot) and `aicoding-sync` | `--sweep` | Crashed sessions, other CLIs, files touched from another container |

The sweep keeps a stamp file `~/.local/state/aicoding/redact-sessions.stamp`
and only inspects files with mtime newer than the stamp, so repeated sweeps
from busy sessions cost a directory walk, not a full rescan.

The distiller's slice tee keeps calling `redact-transcript` on its own copy.
Ordering between the two Stop hooks does not matter: both redact.

### 3.6 Reporting

A silent scrub hides the evidence that a rotation is due. Every hit produces:

1. A line in `~/.local/state/aicoding/redact-sessions.log`:
   `<iso-date> hit key=<K> count=<n> file=<path>` plus `session=<id>` when
   the path yields one. Never the value.
2. A pending-hit marker `~/.local/state/aicoding/redact-sessions.pending`
   holding the unacknowledged key names.
3. Surfacing: the existing `SessionStart` hook slot gets a small script that
   prints the pending marker into the next session's context as an
   instruction to tell the user which keys need rotating, then clears it.
   This reaches the human through whatever agent they open next, in any
   harness that runs the SessionStart contract (Claude Code and codex do).

Push notification through the notify hub (apprise) is deferred: it needs a
credential of its own inside the scrubber, which is the wrong direction for
this component. Tracked as a follow-up ticket, not built here.

### 3.7 Fail-closed rule

Same as `redact-transcript`: secrets file absent means nothing to scrub,
exit 0. Secrets file present but unreadable or partially parsed (rule count
differs from the independent line count) means exit 3, touch no file, and
write one log line plus the pending marker `SECRETS_FILE_UNREADABLE`. A
scrub that silently ran with half the rules would pass unredacted files as
clean.

Any other failure inside the per-file step (temp write fails, rename fails)
leaves the original in place and logs it. The script never exits non-zero
from a hook path in a way that blocks the harness: hooks call it with
`|| true` and a timeout, and the exit code lives in the log.

### 3.8 Install

- `install.sh` and `lib/sync.sh` symlink `bin/redact-sessions` and the
  SessionStart surfacing hook, mirroring `install_redact_transcript_symlink`.
- `configs/claude/settings.json` gains the Stop, SessionEnd and SessionStart
  entries; `MANAGED_HOOKS` and `blueprint-deploy.sh` list the new hook file.
- `configs/codex/requirements.toml` gains the equivalent hook entry if codex
  0.153 exposes a session-end event; verified during implementation, not
  assumed. If it does not, codex coverage is boot plus Claude Code triggers,
  and the spec says so in a one-line note.
- `on-start.sh` runs `redact-sessions --sweep` after the secrets file mount
  is confirmed.

## 4. Tests (bats, `tests/bats/redact-sessions.bats`)

Fixtures use dummy values only. `HOME` is a temp dir with a fake secrets
file, fake transcript trees for all three roots, and no real session files.

1. Incident 1: a JSONL line carrying `docker compose config` style output
   with a value inline. Value gone, `[REDACTED:OPENROUTER_API_KEY]` present,
   surrounding text byte-identical.
2. Incident 2: a value embedded in a base64 blob at each of the three
   alignments. All three redacted; an unrelated base64 blob untouched.
3. Incident 3: a subagent transcript under `subagents/` containing three
   values from an env file dump. All three keys reported, each with its own
   name.
4. JSON-escaped variant: a value containing `"` appears as `\"` in the file
   and is still caught.
5. Clean file: content, mtime and inode unchanged, nothing logged.
6. Open file: a background `sleep` holding the fixture open for writing;
   the file is skipped, logged as skipped, and scrubbed on the next run
   after the holder exits.
7. Atomic rewrite: mode bits preserved, no temp file left behind.
8. Fail-closed: unreadable secrets file exits 3, no fixture modified,
   pending marker written.
9. Sweep stamp: a second `--sweep` with no newer files inspects nothing
   (asserted through the log).
10. Reporting: log line format, pending marker content, and the
    SessionStart hook prints the keys then clears the marker.
11. Short value (7 chars) is not redacted; 11-char value gets literal rules
    but no base64 rules.

## 5. Open questions resolved

- **Why not the PostToolUse rewrite hook as well?** Covered in section 2.
  Adding it later is compatible with this design; nothing here depends on
  its absence.
- **Why key names in the marker, given they reveal which key exists?** The
  key name is public knowledge (it is in `.secrets.env.example`); the value
  is the secret. A marker without the name cannot drive a rotation.
- **Why not scrub the file while the session runs?** Section 3.4.

## 6. Risks accepted

- A value printed and then read back by the same session inside the
  live-file window is not scrubbed until the session ends. Reporting still
  fires at that point.
- A secrets-file value that also occurs legitimately in a transcript (a
  short password that is also a common word) gets redacted everywhere. The
  8-character floor makes this rare; it is the same trade the transcript
  redactor already makes.
- Base64 rules do not cover URL-safe base64 or values split across an
  encoded line boundary. Logged as a known gap in the script header.
