# redact-sessions: scrub the SQLite session stores (cursor, OpenCode)

Ticket: AICODINGBASESETUP-16. Date: 2026-09-07. Status: design accepted,
implementation on `feat/redact-sessions-sqlite`.

Extends `2026-09-07-redact-sessions-design.md`, which named both stores as
non-goals. Everything not restated here (rule set, quiet period, stamp,
deferred set, reporting, fail-closed rule, triggers) is inherited unchanged.

## 1. Problem

Two of the four CLIs keep their conversation in SQLite rather than text:

- **cursor-agent**: one `store.db` per conversation under
  `~/.cursor/chats/<project>/<conversation>/` (and the same layout under
  `~/.cursor/acp-sessions/`).
- **OpenCode**: one `~/.local/share/opencode/opencode.db` for everything.

Both are host bind mounts shared by every devpod container. A secrets-file
value printed in a cursor or OpenCode session stays in the database
unscrubbed and unreported, so the rotation that the reporting path is meant
to force never happens. Cursor's `agent-transcripts/*.jsonl` copy is already
scrubbed; the store is a second, unscrubbed copy of the same conversation.

## 2. Measured facts (2026-09-07, cursor-agent 2026.09.02, OpenCode 1.18.29)

**Cursor `store.db` is a content-addressed Merkle store.** Schema:
`blobs(id TEXT PRIMARY KEY, data BLOB)` and `meta(key TEXT PRIMARY KEY,
value TEXT)`. Across 34 stores, every one of 5152 blob ids equals the
sha256 hex digest of its `data`. Blobs are either JSON message objects
(`{"role":"tool",...}`), protobuf tree nodes that reference child blobs by
their raw 32-byte digest, or raw text. Tool output appears in both the JSON
leaves and the protobuf blobs (one protobuf blob of 651 KB holds shell
output). The single `meta` row (`key='0'`) is hex-encoded JSON whose
`latestRootBlobId` names the root blob. Consequence: rewriting a blob's
bytes without re-deriving its id and every ancestor's reference leaves a
store whose ids lie about their content. Journal mode is WAL.

**OpenCode `opencode.db` is ordinary row storage.** Conversation text is
JSON in TEXT columns: `message.data`, `part.data`, `event.data` (an event log
that duplicates part text; 172 MB of the 220 MB file), `session.title`,
`todo.content`, `session_input.prompt`, `session_context_epoch.baseline`
and `.snapshot`. Journal mode is WAL. The `credential`, `account` and
`control_account` tables hold OpenCode's own tokens and are never ours to
touch.

**Tooling.** The container has no `sqlite3` CLI. It has python3 with SQLite
3.46.1, and every host that runs `install-host.sh` has python3 too.

**Opening a WAL database, even read-only, creates `-wal` and `-shm`
siblings** and may leave them behind at zero bytes. The scrubber must treat
their presence as normal.

## 3. Goal and non-goals

**Goal.** Every secrets-file value that lands in a cursor store or the
OpenCode database is replaced with `[REDACTED:KEYNAME]`, the store stays
loadable by its CLI, and the hit is reported through the existing log and
pending marker.

**Non-goals.**

- An OpenCode in-process trigger (plugin). OpenCode has no shell hook
  contract. Its database is scrubbed by the sweeps the other harnesses and
  boot/sync already fire, gated by the quiet period. Accepted by the user
  2026-09-07.
- OpenCode's own credentials in `account.json`, `auth.json`,
  `mcp-auth.json` and the `credential`/`account` tables. Not secrets-file
  values; no rule can name them.
- Cursor's `-wal` content while cursor-agent is mid-write. The quiet period
  covers it, same as text files.
- Any database not listed in the roots table below.

## 4. Design

### 4.1 Split of responsibilities

`bin/redact-sessions` keeps everything it owns today: roots, candidates,
quiet period, stamp and rule fingerprint, deferred set, state lock, log and
pending marker. It gains one write mode, `sqlite`, which hands the file to a
new helper:

```
lib/redact-sqlite.py <db-path>      # rules on stdin, hits on stdout
```

Standard library only. `REDACT_SQLITE_BUSY_MS` (default 5000) sets the
lock wait and `REDACT_SESSIONS_PYTHON` (default `python3`) names the
interpreter, both for tests. The helper detects the store kind from the schema
(`blobs`+`meta` means cursor; a `message` table with `part` means OpenCode),
applies the rules inside one transaction, and prints one `KEY count` line
per key it redacted. It never prints a value, never reads the secrets file
(the rules arrive already rendered), and exits non-zero on any failure with
the transaction rolled back.

### 4.2 Rules interface: `pairs` mode

`lib/redact-literal.sh` gets a third mode next to `transcript` and
`sessions`:

```
redact_literal_rules pairs [FILE]
```

Same values, same deduplication, same longest-pattern-first order and the
same marker text as `sessions` mode (raw, JSON-escaped and base64-aligned
forms, floors of 8 and 12 characters, `[REDACTED:A,B]` for shared
patterns). Output is not a sed script: one line per rule, `HEX(PATTERN) SPACE MARKER`,
the pattern's raw bytes hex-encoded and the marker verbatim. Hex keeps the
framing unambiguous for any byte a `.env` value can hold and lets the bash
side keep the rendered set in a variable (bash variables cannot hold NUL),
so the generator runs once per sweep, not once per file. The
fail-closed contract is unchanged: absent file, exit 0 and empty output;
unreadable or partially parsed file, exit 1 and empty output.

The helper applies the pairs as plain byte replacements in the given order.
Because patterns are literal bytes, the same rule set matches TEXT columns
(decoded as UTF-8 by SQLite, so the helper operates on the UTF-8 bytes) and
BLOB columns alike.

### 4.3 Roots

Three lines added to `ROOTS`, write mode `sqlite`:

| Harness | Root | Files |
|---|---|---|
| cursor | `~/.cursor/chats/` | `**/store.db` |
| cursor | `~/.cursor/acp-sessions/` | `**/store.db` |
| OpenCode | `~/.local/share/opencode/opencode.db` | the single file (replaces the placeholder entry with no pattern) |

Candidate selection is unchanged (`find -newer stamp` plus the deferred
set). The **quiet period** for a database is measured against the newest
mtime of the database file and its `-wal` sibling, because a WAL-mode
writer commits into the `-wal` and the main file's mtime moves only at
checkpoint. `--now` ignores the quiet period as it does for text files.

### 4.4 Common database procedure

1. Connect with `busy_timeout` 5000 ms. A writer holding the lock for
   longer means the store is in use; the helper exits 4 and the bash side
   defers the file, exactly like a refused swap.
2. `PRAGMA secure_delete=ON` on the connection, so the cells that an
   `UPDATE` or `DELETE` frees are overwritten with zeros instead of lingering
   in free space of the page.
3. `BEGIN IMMEDIATE`, apply the store-specific rewrite (4.5 or 4.6), count
   hits per key, `COMMIT`.
4. `PRAGMA wal_checkpoint(TRUNCATE)`. The rewrite's new pages are moved into
   the main file and the WAL is truncated to zero, so no frame that carried
   the plaintext (ours or an earlier uncheckpointed write) remains on disk.
   If the checkpoint reports it could not complete (another connection
   holds a read transaction that pins the WAL), the helper still exits 0 for
   the rewrite but prints a `checkpoint-incomplete` line; the bash side logs
   it and puts the file into the deferred set so the next sweep runs the
   checkpoint again. The rows are already redacted at that point; only the
   WAL residue is outstanding.
5. Nothing changed means no transaction was written, no mtime moves, and
   the file is treated as clean.

The state lock (`flock` in `~/.claude/state/redact-sessions/lock`) is held
across the helper call as it is across `_swap`, so two containers cannot
scrub the same store at once. SQLite's own locking protects against the
harness itself, which the state lock cannot see.

### 4.5 OpenCode rewrite

Column list, fixed in the helper:

```
message.data  part.data  event.data  session.title  todo.content
session_input.prompt  session_context_epoch.baseline  session_context_epoch.snapshot
```

A table or column missing from an older or newer schema is skipped with a
log line, not an error, so a schema drift degrades to partial coverage
rather than to no coverage. For each rule `(P, M)` and each column `T.C`:

```sql
SELECT rowid, (length(C) - length(replace(C, :p, ''))) / length(:p), session_id
  FROM T WHERE instr(C, :p) > 0;
UPDATE T SET C = replace(C, :p, :m) WHERE instr(C, :p) > 0;
```

`session_id` is read where the table has one (`session.id` for `session`,
`session_id` elsewhere) so the log line can carry `session=<id>`. Hit
counts are summed per key across columns; the count reported for a key is
the number of replaced occurrences, and because `event.data` duplicates
`part.data`, a value printed once typically reports as two or more. That is
acceptable: the count is a hint, the key name is the actionable part.

`time_updated` columns are left alone. Bumping them would make OpenCode
believe the row changed after the session ended.

### 4.6 Cursor rewrite (Merkle-consistent)

Read `SELECT id, data FROM blobs` into memory (stores are 64 KB to a few
MB). Then:

1. **Leaves.** For every blob whose `data` contains any pattern, apply the
   rules, compute `new_id = sha256(new_data)`, record `old_id -> new_id`,
   and count hits per key (occurrences of each pattern before replacement).
2. **Ancestors, to a fixed point.** While the map grew in the last pass:
   for every blob not yet rewritten whose `data` contains an old id either
   as its raw 32 bytes or as its 64-character lowercase hex, substitute the
   corresponding new id in the same form. Both forms are the same length,
   so protobuf length prefixes and any offsets stay valid. Rehash, record
   the mapping. A blob may be visited once as a leaf and again as an
   ancestor of another leaf; the map is keyed by original id and the
   content used is always the latest rewritten one.
3. **Root.** Decode `meta.value` (hex to UTF-8 JSON). If `latestRootBlobId`
   is in the map, replace it and re-encode. Then assert the final root id
   exists in the new blob set; if not, roll back and exit 5 (the store's
   structure is not what this spec measured, and nothing was written).
4. **Write.** `INSERT OR REPLACE` every rewritten blob under its new id,
   `DELETE` every old id that is no longer referenced, `UPDATE meta`.
   Commit.

An id collision (two distinct blobs rewriting to the same bytes) is a
legitimate dedup in a content-addressed store and needs no handling.
Hex-form references have never been observed in the measured stores; the
substitution is included because it costs one `replace` and turns a silent
dangling reference into a non-issue if a future cursor version writes ids
as text.

`meta.json` and `prompt_history.json` in the same directory are already in
scope as text files. `meta.json` names the conversation, not the root blob,
so it needs no update.

### 4.7 Reporting

The helper's stdout is `KEY count[ session=<id>]` lines. The bash side
turns each into the existing `hit key=... count=... file=... container=...
session=...` log line and `pending_add`. For cursor stores `session` is the
conversation directory name; for OpenCode it is the `session_id` the
helper reported, one log line per key per session.

### 4.8 Failure handling

| Case | Helper | Bash side |
|---|---|---|
| python3 missing | not invoked | one log line per sweep, sqlite roots skipped, files deferred |
| busy database (lock not obtained in 5 s) | exit 4, nothing written | log `busy`, defer |
| unknown schema | exit 5, nothing written | log `unrecognised store`, defer |
| root not resolvable after rewrite | exit 5, rolled back | log, defer |
| any other exception | non-zero, rolled back | log with the exception class, defer |
| checkpoint incomplete after a successful rewrite | exit 0 plus a `checkpoint-incomplete` line | log, defer so the checkpoint is retried |

The hook contract stands: hooks call the scrubber with `|| true` and a
timeout, so none of this blocks a harness.

### 4.9 Install

No new files to deploy. `lib/redact-sqlite.py` is resolved relative to
`bin/redact-sessions` through the same `readlink -f` dance that finds
`lib/redact-literal.sh`, so the existing symlink installs
(`install_redact_transcript_symlink` and siblings in `install.sh`,
`lib/sync.sh`, `install-host.sh`) cover it.

## 5. Tests (bats, `tests/bats/redact-sessions.bats`, new section)

Fixtures are built by the tests with python3 and dummy values. No real
store is read.

1. **OpenCode basic.** A db with the OpenCode tables, a value in
   `part.data` and its `event.data` twin, a JSON-escaped variant in
   `message.data`, a base64-embedded form in `part.data`. After `--now`: no
   pattern remains in any column, markers present, `session_id` in the log
   line, key in pending. `time_updated` unchanged.
2. **OpenCode clean.** No pattern present: file bytes and mtime unchanged,
   nothing logged.
3. **OpenCode schema drift.** A db missing the `todo` table: the other
   columns are scrubbed, one log line names the skipped table, exit 0.
4. **Cursor Merkle.** A store with a root node referencing two children by
   raw digest, one child referencing a JSON leaf, the value in the leaf and
   in a protobuf-shaped sibling. After the scrub: every `id` equals
   `sha256(data)`, `latestRootBlobId` resolves, the old ids are gone, the
   untouched child keeps its id, no pattern remains.
5. **Cursor hex references.** Same store with one reference stored as hex
   text: also rewritten and consistent.
6. **Cursor unrecognised.** A `blobs` table whose root is not in the blob
   set: exit 5, file byte-identical, deferred.
7. **WAL residue.** A fixture written in WAL mode with the plaintext still
   in `-wal`: after the scrub the `-wal` is zero bytes and the plaintext is
   absent from both files (`grep -c` on the raw files).
8. **Busy.** A python process holds `BEGIN IMMEDIATE` on the fixture during
   the sweep: helper exits 4, file unchanged, path in the deferred set; the
   next sweep after release scrubs it.
9. **Quiet period on WAL mtime.** Main file old, `-wal` fresh: skipped by
   `--sweep`, scrubbed once the `-wal` is old enough.
10. **`pairs` mode.** Output parses back into the same pattern set and order
    as `sessions` mode for a fixture with a shared value, a value with `"`,
    and a 12-character value.
11. **No python3.** `PATH` without python3: sweep logs once, text roots
    still scrubbed, sqlite roots deferred.

## 6. Verification before merge (manual, recorded in the PR)

- Copy a real cursor store and its directory to scratch, plant a dummy
  secrets-file value into a JSON leaf and a protobuf blob by the same
  Merkle-consistent method the helper uses, scrub it with `--now`, then
  `cursor-agent --resume <conversation>` against the scratch `HOME` and
  confirm the conversation loads and shows the marker.
- Copy `opencode.db` to a scratch `HOME`, plant a dummy value into a
  `part.data` row and its event, scrub, run `opencode` against that `HOME`
  and open the session.
- Run a real `--sweep` on this machine with the quiet period at zero while
  no cursor-agent or OpenCode process runs, and confirm the log shows the
  new roots inspected and `checkpoint` lines absent.

## 7. Risks accepted

- A cursor-agent that verifies blob ids and also caches them in memory
  could, if it is running against the store during the scrub, write a
  parent that still names an old id. The quiet period is the guard; the
  residual is the same mid-session window the text path accepts.
- `event.data` is an append-only event log in OpenCode's model. Rewriting
  historical events is a deliberate violation of that model; OpenCode does
  not replay events to rebuild `message`/`part` (they are written directly),
  so the projection and the log stay consistent with each other after the
  scrub.
- `secure_delete` zeros freed cells and freed pages, which is what removes
  the plaintext. It does not compact the file. A `VACUUM` would, at the
  cost of rewriting 220 MB per hit under an exclusive lock for seconds, and
  buys nothing for redaction; not done.
- Rules are byte-literal, so a value whose UTF-8 bytes were transcoded
  (Latin-1 in a blob, UTF-16 anywhere) is not matched. No measured store
  stores text in anything but UTF-8.
