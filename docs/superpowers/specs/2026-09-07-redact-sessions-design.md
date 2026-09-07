# redact-sessions: scrub secret values out of agent transcripts on disk

Ticket: AICODINGBASESETUP-15. Date: 2026-09-07. Status: implemented on
`feat/redact-sessions` (PR #139).

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
text transcript file on this machine is replaced with `[REDACTED:KEYNAME]`
in the file, and the hit is reported so the credential gets rotated. This
holds regardless of which tool, subagent, or encoding put it there, and for
every CLI that keeps text transcripts (Claude Code, codex, cursor's JSON
files). The two SQLite stores are named in the non-goals.

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
- SQLite session stores (cursor's `store.db`, OpenCode's `opencode.db`)
  were out of scope for this spec; they are covered by
  `2026-09-07-redact-sessions-sqlite-design.md` (AICODINGBASESETUP-16).
  Cursor's `prompt_history.json` and `meta.json` siblings are in scope here.

## 3. Design

### 3.1 One script: `bin/redact-sessions`

Installed as `~/.local/bin/redact-sessions`, same pattern as
`redact-transcript`. Two modes:

```
redact-sessions --sweep        # scrub every quiet transcript under the known roots
redact-sessions --now FILE...  # scrub exactly these files, ignoring the quiet period
redact-sessions --ack KEY      # clear KEY from the pending-hit marker after rotation
```

Sweep and `--now` share the per-file procedure (3.3). `--sweep` walks the
roots in 3.2 and applies it to each file that has been quiet long enough
(3.4) and is either newer than the last sweep stamp or in the deferred set
(3.5).

### 3.2 Scan roots

One array near the top of the script, so a new harness is one added line:

| Harness | Root | Files |
|---|---|---|
| Claude Code | `~/.claude/projects/` | `**/*.jsonl`, which includes `<project>/<session>/subagents/*.jsonl` |
| codex | `~/.codex/sessions/` | `**/*.jsonl` |
| codex | `~/.codex/archived_sessions/` | `*.jsonl`, rollouts codex moves here when a thread is archived |
| Claude Code, codex | `~/.claude/history.jsonl`, `~/.codex/history.jsonl` | the prompt histories, single files, rewritten in place |
| cursor | `~/.cursor/projects/` | `*/agent-transcripts/**/*.jsonl`, the full conversation transcripts (found by codex's PR review; the chats dir alone holds only metadata) |
| cursor | `~/.cursor/chats/` | `**/prompt_history.json`, `**/meta.json` |
| cursor, OpenCode | `~/.cursor/chats/`, `~/.cursor/acp-sessions/`, `~/.local/share/opencode/opencode.db` | `**/store.db` and the single OpenCode database, write mode `sqlite`; see the sqlite spec |

All four roots are host bind mounts shared by every devpod container on the
host (`devcontainer.json`, `mounts`). That fact drives sections 3.4 to 3.6:
a file may be written by a process the scrubber cannot see, and state the
scrubber keeps must be visible from every container.

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
     so `"` and `\` inside a value appear as `\"` and `\\`). It is emitted
     before the raw rule, so a value beginning with `"` or `\` cannot leave
     a dangling escape in front of the marker.
   - patterns are deduplicated across keys (identical values, or distinct
     values sharing a base64 core) with the marker naming every key, and
     ordered longest pattern first, so a pattern that contains another is
     replaced whole and every key involved is reported.
   - lengths are byte lengths (`LC_ALL=C`): base64 groups bytes, and a
     non-ASCII value has more bytes than characters.
   - the three base64 alignments of `V`. A base64 character encodes six
     bits, so a character at either edge of `V`'s encoding can also carry
     bits from the neighbouring byte in a larger blob. For each offset
     `k` in 0, 1, 2: encode `k` filler bytes followed by `V`, drop the
     leading characters that contain any filler bits (0, 2 or 3 characters
     for `k` = 0, 1, 2), drop any trailing `=`, and then drop the last
     character too whenever `(k + len(V)) % 3 != 0`, because that character
     mixes `V`'s final bits with the next byte's. What remains is the run of
     characters fully determined by `V` at that alignment, and it matches
     wherever `V` sits inside any larger blob. This is the Dokploy
     notification case. Values shorter than 12 characters get no base64
     rules: the aligned core is too short to be unique. URL-safe base64
     (`-_` alphabet) gets the same three rules with the two characters
     translated.
   - replacement text is `[REDACTED:K]`. The key name is what makes a hit
     actionable; the value never appears anywhere. Two keys holding the
     same value share one marker, `[REDACTED:A,B]`, and both are reported;
     otherwise the first rule would consume every occurrence and the second
     key would never be flagged.
2. Count matches before rewriting (`grep -c` per rule against the file).
   Zero matches: leave the file untouched, do not change its mtime.
3. Non-zero: write the redacted content to a temp file in the same
   directory, `chmod --reference` the original, then check-and-swap: if the
   original's size and mtime still equal what was read in step 2, `mv` the
   temp file over it; otherwise discard the temp file and retry once from
   step 2. Rename is atomic on the same filesystem, so a reader never sees a
   half-written file, and the check shrinks the lost-append window to the
   gap between the stat and the rename.
4. Report the hit (3.6).

The scrubber reads the secrets file itself, in its own process, exactly as
`redact-transcript` already does. The ticket asked for fingerprints instead
of plaintext in the hook; that is not possible, because a fingerprint cannot
locate a value inside arbitrary text. The process boundary is the guarantee:
the scrubber is not the agent, it never prints a value, and the deny hook
does not apply to it because it is not a tool call.

### 3.4 Live-file safety

The harnesses append to a transcript for the whole session, and open-file
detection cannot tell the scrubber when that is happening:

- Claude Code does not keep the file open. `lsof` on a running session's
  transcript returns nothing (checked 2026-09-07); each append reopens the
  path. A path-based appender survives a rename, because its next write
  opens the new inode.
- The roots are shared across containers with separate PID namespaces, so
  `lsof` and `/proc` in one container never see a writer in another.

So there is no "is it open" test. Safety comes from two rules instead:

1. **Check-and-swap** (3.3 step 3). The rename only lands if the file is
   byte-for-byte what was read. An append that races the scrubber makes the
   swap fail, and the retry picks the append up.
2. **Quiet period.** The sweep only touches files whose mtime is older than
   `REDACT_QUIET_SECONDS` (default 120). A file that is being written every
   few seconds is left for the next run; the session's own end-of-session
   trigger (3.5) handles it with the quiet period set to zero, because that
   harness has just told us it is done.

**Measured 2026-09-07 (codex 0.153.4):** codex keeps its rollout file open
for the whole run, with `O_APPEND` set (`/proc/<pid>/fdinfo` flags
`02102002`). A rename would strand its later records on the unlinked inode.
So the write mode is per root: Claude Code and cursor files are replaced by
rename; codex files are rewritten in place (truncate and write the same
inode), which an `O_APPEND` writer follows correctly, its next record landing
after the scrubbed content. The cost is that an in-place rewrite is not
atomic for a concurrent reader; codex does not read its rollout mid-session,
and the window is milliseconds. Cursor: `cursor-agent` 2026.09.02
does not hold its transcript open either (`lsof` over 50 one-second samples
of a live run showed only sockets), so its files use rename.

In-place residual: the state lock does not cover the harness's own writer.
The rewrite therefore truncates and then appends the replacement in one
`write()` with `O_APPEND`, so a record codex appends in the same instant
lands whole, before or after ours, instead of being overwritten. A record
that slips into the gap between the truncate and our append is out of order
but intact; the scrubber compares the resulting size with what it wrote and
logs the case.

Consequence: a value printed mid-session stays in the file until that
session ends or goes quiet. That window is accepted. It is the same window
the distiller already lives with, and the alternative (a per-harness
in-process hook) is the design this spec rejects.

### 3.5 Triggers

No systemd user instance runs in the devcontainer, so there is no timer.
Every in-scope CLI gets its own end-of-turn trigger, so a container used by
only one of them still scrubs. Boot and sync cover crashed sessions.

| When | What runs | Why |
|---|---|---|
| Claude Code `Stop` (async, after `llmwiki-distill.sh`) | `redact-sessions --sweep` | Catches every quiet file, including subagent files whose agents have finished |
| Claude Code `SessionEnd` | `redact-sessions --now <transcript_path>` then `--sweep` | `--now` ignores the quiet period for the named file: the harness has said it is done |
| codex `Stop` and `SessionEnd`, managed hooks in `requirements.toml` next to the deny hook | the same hook script; on `Stop` a codex rollout is scrubbed `--now` in place (its `O_APPEND` writer follows), then a sweep | a sweep alone would defer the live rollout forever, since every `notify` fires right after an append (codex PR review, round 2) |
| codex `SessionStart`, managed hook | `redact-sessions-pending.sh` | codex adds SessionStart stdout as developer context, so the rotation warning reaches codex-only sessions |
| codex `notify` (already wired to `agent-notify`) | `codex-turn-done`: `agent-notify` then a background sweep | kept as a belt-and-braces trigger; the managed hooks above do the real work |
| cursor `stop` hook (`~/.cursor/hooks.json`, managed by the blueprint) | `redact-sessions --sweep` | Same role as Claude Code's Stop |
| `on-start.sh` (container boot) and `aicoding-sync` | `--sweep` | Crashed sessions, files touched from another container |

Every trigger returns at once: the hook script detaches its work into its
own session (`setsid`) and exits 0, so a slow or failing scrub never blocks
a harness and codex's short SessionEnd budget is never an issue.

**Sweep bookkeeping.** The sweep keeps a stamp `redact-sessions.stamp` in
the shared state dir (3.6) and inspects files with mtime newer than the
stamp. The stamp only means "inspected under the rules of that time", so
next to it lives a digest of the rendered rule set and of the roots table,
salted with the machine's `secrets-check` salt and kept per host name (the
salt is container-local); when the secrets file changes (a key added or
rotated) or a release adds a root, the digest differs and the next sweep
rescans everything. Without the roots in the digest, files under a new root
sat behind the stamp forever (found deploying the sqlite roots,
AICODINGBASESETUP-23). With no secrets file there are no rules, and the sweep
neither scrubs nor advances the stamp, so a file that appears later still
sees every old transcript. Files it skips (quiet period not reached, swap failed twice) go into
`redact-sessions.deferred`, one path per line, and the next sweep inspects
the deferred set first regardless of the stamp. A file leaves the deferred
set when it has been scrubbed or found clean. Without this, a file skipped
once would fall behind the stamp forever, because closing a file does not
change its mtime.

The distiller's slice tee keeps calling `redact-transcript` on its own copy.
Ordering between the two Stop hooks does not matter: both redact.

### 3.6 Reporting

A silent scrub hides the evidence that a rotation is due. Every hit produces:

All scrubber state lives in `~/.claude/state/redact-sessions/`. That
directory is on the shared `~/.claude` mount, so a hit found by container A
in a file written by container B is visible to a session opened in either,
and survives A being deleted. `~/.local/state` is container-local and is
not used. Each hit produces:

1. A line in `redact-sessions.log` there:
   `<iso-date> hit key=<K> count=<n> file=<path> container=<hostname>` plus
   `session=<id>` when the path yields one. Never the value.
2. A pending-hit marker `redact-sessions.pending` holding the unacknowledged
   key names, one per line, appended under `flock` because two containers
   can sweep at once.
3. Surfacing: the existing `SessionStart` hook slot gets a small script that
   prints the pending marker into the next session's context (plain text
   for Claude Code; cursor parses hook stdout as JSON and injects only
   `additional_context`, so its hooks.json passes `--cursor` to get that
   form) as an
   instruction to tell the user which keys need rotating. It does not clear
   the marker; the user clears it with `redact-sessions --ack KEY` once the
   rotation is done, so the warning repeats in every new session on every
   container until someone acts. This reaches the human through whatever
   agent they open next, in any harness that runs the SessionStart contract
   (Claude Code and codex do; cursor gets it through its `sessionStart`
   hook).

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
- `configs/codex/config.toml`'s `notify` line points at the wrapper from
  3.5 instead of `agent-notify` directly; `configs/codex/requirements.toml`
  registers SessionStart, Stop and SessionEnd, and
  `ensure_codex_managed_hooks` copies all three hook scripts into the
  managed dir, root-owned like the deny hook.
- `install-host.sh` installs the same symlinks as the container installer.
- `configs/cursor/` gains a managed `hooks.json` with `stop` and
  `sessionStart` entries, deployed like the other cursor files.
- `on-start.sh` runs `redact-sessions --sweep` after the secrets file mount
  is confirmed.

## 4. Tests (bats, `tests/bats/redact-sessions.bats`)

Fixtures use dummy values only. `HOME` is a temp dir with a fake secrets
file, fake transcript trees for all three roots, and no real session files.

1. Incident 1: a JSONL line carrying `docker compose config` style output
   with a value inline. Value gone, `[REDACTED:OPENROUTER_API_KEY]` present,
   surrounding text byte-identical.
2. Incident 2: a value embedded in a base64 blob at each of the three
   alignments, both with the value ending on a 3-byte boundary and not. All
   six redacted; an unrelated base64 blob and a blob that shares only the
   value's edge characters are untouched.
3. Incident 3: a subagent transcript under `subagents/` containing three
   values from an env file dump. All three keys reported, each with its own
   name.
4. JSON-escaped variant: a value containing `"` appears as `\"` in the file
   and is still caught.
5. Clean file: content, mtime and inode unchanged, nothing logged.
6. Quiet period: a fixture with a fresh mtime is skipped by `--sweep`,
   listed in the deferred set, and scrubbed by the next sweep once its mtime
   is old enough; `--now` on the same file scrubs it immediately.
6b. Racing append: a line is appended to the fixture between the read and
    the rename (simulated by a hook the test injects); the first swap is
    refused, the retry scrubs the file, and the appended line survives.
7. Atomic rewrite: mode bits preserved, no temp file left behind.
8. Fail-closed: unreadable secrets file exits 3, no fixture modified,
   pending marker written.
9. Sweep stamp: a second `--sweep` with no newer files inspects nothing
   (asserted through the log); a deferred file is inspected even though it
   is older than the stamp.
10. Reporting: log line format, pending marker content under the shared
    state dir, the SessionStart hook prints the keys and leaves the marker,
    `--ack KEY` removes exactly that key.
10b. Two sweeps in parallel over the same tree (simulating two containers)
     produce one scrub and no corrupted file or marker.
11. Short value (7 chars) is not redacted; 11-char value gets literal rules
    but no base64 rules.

## 5. Open questions resolved

- **Why not the PostToolUse rewrite hook as well?** Covered in section 2.
  Adding it later is compatible with this design; nothing here depends on
  its absence.
- **Why key names in the marker, given they reveal which key exists?** The
  key name is public knowledge (it is in `.secrets.env.example`); the value
  is the secret. A marker without the name cannot drive a rotation.
- **Why no open-file check?** Section 3.4: Claude Code never holds the
  file open, and other containers' writers are invisible anyway.
- **Why not scrub the file while the session runs?** It does, once the file
  has been quiet for the configured period. Section 3.4.

## 6. Risks accepted

- A value rotated before its transcript was scrubbed is gone from the
  secrets file, so no rule can find the old copy, and the file keeps it
  (found by codex review round 4). Keeping old rule sets would mean
  persisting retired secrets, which is worse. The order the reporting path
  drives is the safe one: the scrub finds and reports the value, then the
  key is rotated. Rotating on your own initiative means running
  `redact-sessions --sweep` with the quiet period set to zero first.

- A value printed and then read back by the same session inside the
  live-file window is not scrubbed until the session ends. Reporting still
  fires at that point.
- A secrets-file value that also occurs legitimately in a transcript (a
  short password that is also a common word) gets redacted everywhere. The
  8-character floor makes this rare; it is the same trade the transcript
  redactor already makes.
- Base64 rules do not cover values split across an encoded line boundary
  (MIME-wrapped base64) or double-encoded values. Logged as a known gap in
  the script header.
