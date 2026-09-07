# redact-sessions SQLite stores Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `redact-sessions` scrubs secrets-file values out of cursor's `store.db` files and OpenCode's `opencode.db`, keeping both loadable, and reports hits through the existing log and pending marker.

**Architecture:** `bin/redact-sessions` gains a `sqlite` write mode that pipes a hex-per-line rule set into a new stdlib-only helper, `lib/redact-sqlite.py`, which detects the store kind and rewrites it in one transaction. Cursor stores are content-addressed, so the helper rehashes changed blobs and patches ancestor references up to the root pointer. OpenCode rows are rewritten in place under `secure_delete`, then the WAL is checkpointed and truncated.

**Tech Stack:** bash, python3 (sqlite3, hashlib, json from the standard library), bats.

**Spec:** `docs/superpowers/specs/2026-09-07-redact-sessions-sqlite-design.md`

## Global Constraints

- Never print, log or write a secret value anywhere. Fixtures use dummy values only.
- The secrets file is only ever read, by `lib/redact-literal.sh`, in the bash process.
- Standard library only in the helper; no `sqlite3` CLI.
- Every test runs through `bash tests/bats/run.sh`, never bare `bats`.
- Helper exit codes: 0 ok, 1 other failure, 4 busy, 5 unrecognised store or unresolvable root. Nothing is written on any non-zero exit.
- `REDACT_SQLITE_BUSY_MS` (default 5000) and `REDACT_SESSIONS_PYTHON` (default `python3`) exist for tests.

---

### Task 1: `pairs` mode in `lib/redact-literal.sh`

**Files:**
- Modify: `lib/redact-literal.sh` (mode check at the top of `redact_literal_rules`, the `_redact_literal_rule` call at the end)
- Test: `tests/bats/redact-literal.bats`

**Interfaces:**
- Produces: `redact_literal_rules pairs [FILE]` printing `HEX(PATTERN) SP MARKER\n` per rule, same order and markers as `sessions`.

- [ ] **Step 1: Failing tests**

Append to `tests/bats/redact-literal.bats`:

```bash
@test "pairs mode: hex pattern and marker per line, same set and order as sessions" {
  printf 'A_KEY=%s\nB_KEY=%s\n' "$V" 'has"quote_and_more' > "$SECRETS"
  run redact_literal_rules pairs "$SECRETS"
  [ "$status" -eq 0 ]
  # every line is <hex> <marker>
  while IFS=' ' read -r hex marker; do
    [[ "$hex" =~ ^([0-9a-f][0-9a-f])+$ ]]
    [[ "$marker" =~ ^\[REDACTED:[A-Z_,]+\]$ ]]
  done <<< "$output"
  # first line is the longest pattern, decoded it is a real pattern of the sessions script
  local first; first="$(head -1 <<< "$output" | cut -d' ' -f1 | xxd -r -p)"
  run redact_literal_rules sessions "$SECRETS"
  [[ "$output" == *"$(redact_literal_ere_escape "$first")"* ]]
  # the JSON-escaped form of the quoted value is present
  run redact_literal_rules pairs "$SECRETS"
  [[ "$output" == *"$(printf '%s' 'has\"quote_and_more' | xxd -p | tr -d '\n') [REDACTED:B_KEY]"* ]]
  [[ "$output" != *"$V"* ]]
}

@test "pairs mode: same line count as sessions mode" {
  printf 'A_KEY=%s\nB_KEY=%s\n' "$V" "$V" > "$SECRETS"
  local a b
  a="$(redact_literal_rules sessions "$SECRETS" | wc -l)"
  b="$(redact_literal_rules pairs "$SECRETS" | wc -l)"
  [ "$a" -eq "$b" ]
  redact_literal_rules pairs "$SECRETS" | grep -q ' \[REDACTED:A_KEY,B_KEY\]$'
}
```

- [ ] **Step 2: Run, expect failure**

`bash tests/bats/run.sh redact-literal` fails: `pairs` returns 1 (unknown mode).

- [ ] **Step 3: Implement**

In `redact_literal_rules`: `case "$mode" in transcript|sessions|pairs) ;; *) return 1 ;; esac`. Everywhere the body tests `[ "$mode" = sessions ]` (base64 rules, marker with key name) use `[ "$mode" != transcript ]` instead. At the end replace the rule emission with:

```bash
    if [ "$mode" = pairs ]; then
      out+="$(LC_ALL=C printf '%s' "${pats[$i]}" | od -An -v -tx1 | tr -d ' \n') $marker"$'\n'
    else
      rule="$(_redact_literal_rule "${pats[$i]}" "$marker")" || return 1
      out+="$rule"$'\n'
    fi
```

Update the header comment's mode list.

- [ ] **Step 4: Run, expect pass** (`bash tests/bats/run.sh redact-literal`)

- [ ] **Step 5: Commit** `feat(redact-literal): pairs mode, hex pattern per line for the sqlite helper`

---

### Task 2: `lib/redact-sqlite.py`, OpenCode store

**Files:**
- Create: `lib/redact-sqlite.py`
- Test: `tests/bats/redact-sqlite.bats` (new file)

**Interfaces:**
- Consumes: pairs on stdin (Task 1 format).
- Produces: `python3 lib/redact-sqlite.py DB` → stdout lines `hit KEY N session=ID`, `skipped-table NAME`, `checkpoint-incomplete`; exit codes per Global Constraints.

- [ ] **Step 1: Failing tests**

`tests/bats/redact-sqlite.bats`:

```bash
#!/usr/bin/env bats
# lib/redact-sqlite.py: rewrites secrets-file values inside the SQLite session
# stores. Fixtures are built here with dummy values.

bats_require_minimum_version 1.5.0

setup() {
  : "${BLUEPRINT_ROOT:?unset, run via tests/bats/run.sh}"
  PY="$BLUEPRINT_ROOT/lib/redact-sqlite.py"
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  V1="deadbeefcafebabefeedface12345678"
  V2="quickbrownfoxjumpsoverlazydogs99"
  # pairs for two keys: raw, JSON-escaped is identical, so raw only plus a
  # base64 core; enough for these tests
  hex() { printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'; }
  RULES="$(hex "$V1") [REDACTED:OPENROUTER_API_KEY]
$(hex "$V2") [REDACTED:POSTGRES_PASSWORD]
$(hex "$(printf '%s' "$V1" | base64 -w0 | cut -c1-40)") [REDACTED:OPENROUTER_API_KEY]"
}
teardown() { case "${TMPDIR:-}" in */tmp.*) rm -rf "$TMPDIR" ;; esac }

run_helper() { printf '%s\n' "$RULES" | python3 "$PY" "$@"; }

# make_opencode DB: the OpenCode tables that carry text, in WAL mode.
make_opencode() {
  python3 - "$1" "$V1" "$V2" <<'EOF'
import sqlite3, sys, json, base64
db, v1, v2 = sys.argv[1:]
c = sqlite3.connect(db); c.execute("pragma journal_mode=wal")
c.executescript("""
create table session(id text primary key, title text not null, time_updated integer not null);
create table message(id text primary key, session_id text not null, time_updated integer not null, data text not null);
create table part(id text primary key, message_id text not null, session_id text not null, time_updated integer not null, data text not null);
create table event(id text primary key, aggregate_id text not null, seq integer not null, type text not null, data text not null);
create table todo(session_id text not null, content text not null, position integer not null, primary key(session_id, position));
create table credential(id text primary key, value text not null);
""")
c.execute("insert into session values('ses_1', 'title mentions %s' % v2, 1)")
c.execute("insert into message values('msg_1','ses_1',7,?)", (json.dumps({"role":"user","text":'quoted "%s"' % v1}),))
c.execute("insert into part values('prt_1','msg_1','ses_1',7,?)", (json.dumps({"type":"tool","output":"KEY=%s\nother" % v1}),))
c.execute("insert into part values('prt_2','msg_1','ses_1',7,?)", (json.dumps({"type":"text","text":"b64 " + base64.b64encode(v1.encode()).decode()}),))
c.execute("insert into event values('evt_1','ses_1',1,'message.part.updated.1',?)", (json.dumps({"part":{"output":"KEY=%s" % v1}}),))
c.execute("insert into todo values('ses_1','clean todo',0)")
c.execute("insert into credential values('c1', ?)", (v1,))
c.commit()
# leave the plaintext in the WAL: no checkpoint
c.close()
EOF
}

col() { python3 -c "import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute(sys.argv[2]).fetchone()[0])" "$1" "$2"; }

@test "opencode: values replaced in every text column, counts per key and session" {
  make_opencode "$HOME/opencode.db"
  run --separate-stderr run_helper "$HOME/opencode.db"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hit OPENROUTER_API_KEY 4 session=ses_1"* ]]
  [[ "$output" == *"hit POSTGRES_PASSWORD 1 session=ses_1"* ]]
  if grep -q "$V1" "$HOME/opencode.db"; then false; fi
  if grep -q "$V2" "$HOME/opencode.db"; then false; fi
  [ "$(col "$HOME/opencode.db" "select count(*) from part where data like '%[REDACTED:OPENROUTER_API_KEY]%'")" -eq 2 ]
  [ "$(col "$HOME/opencode.db" "select time_updated from message")" -eq 7 ]
  [[ "$output" != *"$V1"* ]]; [[ "$stderr" != *"$V1"* ]]
}

@test "opencode: credential table is never touched" {
  make_opencode "$HOME/opencode.db"
  run_helper "$HOME/opencode.db"
  [ "$(col "$HOME/opencode.db" "select value from credential")" = "$V1" ]
}

@test "opencode: WAL is truncated to zero after the rewrite" {
  make_opencode "$HOME/opencode.db"
  [ -s "$HOME/opencode.db-wal" ]
  grep -q "$V1" "$HOME/opencode.db-wal"
  run_helper "$HOME/opencode.db"
  [ ! -s "$HOME/opencode.db-wal" ]
}

@test "opencode: clean database is not written" {
  make_opencode "$HOME/opencode.db"
  RULES="$(hex nothingmatchesthis99) [REDACTED:X]"
  local before; before="$(stat -c '%Y %s' "$HOME/opencode.db")"
  sleep 1.1
  run run_helper "$HOME/opencode.db"
  [ "$status" -eq 0 ]; [ -z "$output" ]
  [ "$(stat -c '%Y %s' "$HOME/opencode.db")" = "$before" ]
}

@test "opencode: a missing table is skipped and reported, the rest is scrubbed" {
  make_opencode "$HOME/opencode.db"
  python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('drop table todo'); c.commit()" "$HOME/opencode.db"
  run run_helper "$HOME/opencode.db"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped-table todo"* ]]
  if grep -q "$V1" "$HOME/opencode.db"; then false; fi
}

@test "busy database: exit 4, nothing written" {
  make_opencode "$HOME/opencode.db"
  python3 -c "import sqlite3,sys,time; c=sqlite3.connect(sys.argv[1]); c.execute('begin immediate'); time.sleep(3)" "$HOME/opencode.db" &
  local holder=$!; sleep 0.5
  REDACT_SQLITE_BUSY_MS=300 run run_helper "$HOME/opencode.db"
  [ "$status" -eq 4 ]
  wait "$holder"
  grep -q "$V1" "$HOME/opencode.db" || grep -q "$V1" "$HOME/opencode.db-wal"
}

@test "unknown schema: exit 5" {
  python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('create table t(x)'); c.commit()" "$HOME/other.db"
  run run_helper "$HOME/other.db"
  [ "$status" -eq 5 ]
}
```

- [ ] **Step 2: Run, expect failure** (`bash tests/bats/run.sh redact-sqlite`: helper missing)

- [ ] **Step 3: Implement the helper**

```python
#!/usr/bin/env python3
"""redact-sqlite: rewrite secrets-file values inside a SQLite session store.

Usage: redact-sqlite.py DB      rules on stdin, one "HEX(PATTERN) MARKER" per line

Called by bin/redact-sessions for roots in `sqlite` write mode; see
docs/superpowers/specs/2026-09-07-redact-sessions-sqlite-design.md.
Stdout: "hit KEY N [session=ID]", "skipped-table T", "checkpoint-incomplete".
Exit: 0 ok, 1 failure, 4 busy, 5 unrecognised store or unresolvable root.
Nothing is written on a non-zero exit. Never prints a value.
"""
import hashlib
import json
import os
import sqlite3
import sys
from collections import Counter

EXIT_BUSY, EXIT_SCHEMA = 4, 5

# OpenCode: (table, column, column naming the session)
OPENCODE_COLUMNS = [
    ("message", "data", "session_id"),
    ("part", "data", "session_id"),
    ("event", "data", "aggregate_id"),
    ("session", "title", "id"),
    ("todo", "content", "session_id"),
    ("session_input", "prompt", "session_id"),
    ("session_context_epoch", "baseline", "session_id"),
    ("session_context_epoch", "snapshot", "session_id"),
]


def read_rules(stream):
    rules = []
    for line in stream.read().splitlines():
        if not line.strip():
            continue
        hexpat, _, marker = line.partition(" ")
        rules.append((bytes.fromhex(hexpat), marker.encode()))
    return rules


def keys_of(marker):
    m = marker.decode()
    return m[len("[REDACTED:"):-1].split(",") if m.startswith("[REDACTED:") else []


def apply_rules(data, rules, hits):
    for pat, marker in rules:
        n = data.count(pat)
        if n:
            for k in keys_of(marker):
                hits[k] += n
            data = data.replace(pat, marker)
    return data


def sha256(b):
    return hashlib.sha256(b).hexdigest()


def tables(conn):
    return {r[0] for r in conn.execute("select name from sqlite_master where type='table'")}


def columns(conn, table):
    return {r[1] for r in conn.execute(f'pragma table_info("{table}")')}


def scrub_opencode(conn, rules, out):
    present = tables(conn)
    for table, col, sess in OPENCODE_COLUMNS:
        if table not in present or col not in columns(conn, table):
            out.append(f"skipped-table {table}")
            continue
        where = " or ".join("instr(\"%s\", ?) > 0" % col for _ in rules)
        params = [p.decode("utf-8", "surrogateescape") for p, _ in rules]
        rows = conn.execute(
            f'select rowid, "{col}", "{sess}" from "{table}" where {where}', params
        ).fetchall()
        for rowid, text, sid in rows:
            hits = Counter()
            new = apply_rules(text.encode("utf-8", "surrogateescape"), rules, hits)
            if not hits:
                continue
            conn.execute(
                f'update "{table}" set "{col}" = ? where rowid = ?',
                (new.decode("utf-8", "surrogateescape"), rowid),
            )
            for k, n in hits.items():
                out.append(f"hit {k} {n} session={sid}")


def scrub_cursor(conn, rules, out):
    blobs = {i: bytes(d) if d is not None else b"" for i, d in conn.execute("select id, data from blobs")}
    hits = Counter()
    leaf = {i: apply_rules(d, rules, hits) for i, d in blobs.items()}
    if not hits:
        return
    mapping = {i: sha256(leaf[i]) for i in blobs if leaf[i] != blobs[i]}
    final = dict(leaf)
    # Ancestors reference children by raw digest (or hex). Recompute every
    # blob from its rule-applied content under the current mapping until the
    # mapping stops changing: depth of the tree many passes at most.
    while True:
        changed = False
        for i, d in leaf.items():
            nd = d
            for old, new in mapping.items():
                if old == i:
                    continue
                nd = nd.replace(bytes.fromhex(old), bytes.fromhex(new)).replace(old.encode(), new.encode())
            final[i] = nd
            if nd != blobs[i]:
                nid = sha256(nd)
                if mapping.get(i) != nid:
                    mapping[i] = nid
                    changed = True
        if not changed:
            break
    new_ids = {mapping.get(i, i) for i in blobs}
    for key, value in conn.execute("select key, value from meta").fetchall():
        try:
            text = bytes.fromhex(value).decode("utf-8")
            meta = json.loads(text)
        except (ValueError, UnicodeDecodeError):
            continue
        root = meta.get("latestRootBlobId")
        for old, new in mapping.items():
            text = text.replace(old, new)
        if root is not None and mapping.get(root, root) not in new_ids:
            raise LookupError("root blob not resolvable after rewrite")
        conn.execute("update meta set value = ? where key = ?", (text.encode().hex(), key))
    for old, new in mapping.items():
        conn.execute("insert or replace into blobs(id, data) values (?, ?)", (new, final[old]))
    for old in mapping:
        if old not in new_ids:
            conn.execute("delete from blobs where id = ?", (old,))
    for k, n in hits.items():
        out.append(f"hit {k} {n}")


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    db = sys.argv[1]
    rules = read_rules(sys.stdin)
    if not rules:
        return 0
    busy_ms = int(os.environ.get("REDACT_SQLITE_BUSY_MS", "5000"))
    out = []
    conn = sqlite3.connect(db, timeout=busy_ms / 1000, isolation_level=None)
    try:
        conn.execute("pragma secure_delete = on")
        present = tables(conn)
        if {"blobs", "meta"} <= present:
            kind = scrub_cursor
        elif {"message", "part"} <= present:
            kind = scrub_opencode
        else:
            return EXIT_SCHEMA
        conn.execute("begin immediate")
        try:
            kind(conn, rules, out)
        except BaseException:
            conn.execute("rollback")
            raise
        wrote = conn.total_changes > 0
        conn.execute("commit")
        if wrote:
            busy, _log, _ckpt = conn.execute("pragma wal_checkpoint(truncate)").fetchone()
            if busy:
                out.append("checkpoint-incomplete")
    except sqlite3.OperationalError as e:
        if "locked" in str(e) or "busy" in str(e):
            return EXIT_BUSY
        print(f"redact-sqlite: {type(e).__name__}", file=sys.stderr)
        return 1
    except LookupError:
        return EXIT_SCHEMA
    finally:
        conn.close()
    sys.stdout.write("".join(l + "\n" for l in out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

`chmod +x lib/redact-sqlite.py`.

- [ ] **Step 4: Run, expect pass** (`bash tests/bats/run.sh redact-sqlite`)

- [ ] **Step 5: Commit** `feat(redact-sqlite): helper that rewrites OpenCode text columns under secure_delete`

---

### Task 3: cursor Merkle rewrite tests

**Files:**
- Test: `tests/bats/redact-sqlite.bats`
- Modify: `lib/redact-sqlite.py` only if a test exposes a defect.

- [ ] **Step 1: Tests**

```bash
# make_cursor DB: three-level Merkle store. root -> {node, other}; node -> leaf.
# leaf is JSON holding V1; node is protobuf-shaped bytes holding V2 and leaf's digest.
make_cursor() {
  python3 - "$1" "$V1" "$V2" "${3:-raw}" <<'EOF'
import sqlite3, sys, json, hashlib
db, v1, v2, ref = sys.argv[1:]
h = lambda b: hashlib.sha256(b).hexdigest()
leaf = json.dumps({"role": "tool", "content": "KEY=%s" % v1}).encode()
other = b'{"role":"user","content":"clean"}'
def refb(x): return bytes.fromhex(x) if ref == "raw" else x.encode()
node = b"\n\x20" + refb(h(leaf)) + b"\x12" + bytes([len(v2)]) + v2.encode()
root = b"\n\x20" + refb(h(node)) + b"\n\x20" + refb(h(other))
c = sqlite3.connect(db); c.execute("pragma journal_mode=wal")
c.executescript("create table blobs(id text primary key, data blob); create table meta(key text primary key, value text)")
for b in (leaf, other, node, root):
    c.execute("insert into blobs values(?,?)", (h(b), b))
meta = json.dumps({"agentId": "a1", "latestRootBlobId": h(root), "name": "t"})
c.execute("insert into meta values('0', ?)", (meta.encode().hex(),))
c.commit(); c.close()
print(h(other))
EOF
}

# check_cursor DB: every id is the sha256 of its data, the root resolves.
check_cursor() {
  python3 - "$1" <<'EOF'
import sqlite3, sys, json, hashlib
c = sqlite3.connect(sys.argv[1])
rows = c.execute("select id, data from blobs").fetchall()
ids = {i for i, _ in rows}
for i, d in rows:
    assert hashlib.sha256(d).hexdigest() == i, "id mismatch"
meta = json.loads(bytes.fromhex(c.execute("select value from meta").fetchone()[0]))
assert meta["latestRootBlobId"] in ids, "root dangling"
print(len(rows))
EOF
}

@test "cursor: leaf and node redacted, every id rehashed, root resolves, count is 4 blobs" {
  local other; other="$(make_cursor "$HOME/store.db")"
  run --separate-stderr run_helper "$HOME/store.db"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hit OPENROUTER_API_KEY 1"* ]]
  [[ "$output" == *"hit POSTGRES_PASSWORD 1"* ]]
  if grep -q "$V1" "$HOME/store.db"; then false; fi
  if grep -q "$V2" "$HOME/store.db"; then false; fi
  [ "$(check_cursor "$HOME/store.db")" -eq 4 ]
  # the untouched sibling keeps its id
  [ "$(col "$HOME/store.db" "select count(*) from blobs where id='$other'")" -eq 1 ]
  [[ "$stderr" != *"$V1"* ]]
}

@test "cursor: hex-text references are rewritten too" {
  make_cursor "$HOME/store.db" "" hex > /dev/null
  run_helper "$HOME/store.db"
  [ "$(check_cursor "$HOME/store.db")" -eq 4 ]
  if grep -q "$V1" "$HOME/store.db"; then false; fi
}

@test "cursor: unresolvable root after rewrite exits 5 and writes nothing" {
  make_cursor "$HOME/store.db" > /dev/null
  python3 -c "
import sqlite3,sys,json; c=sqlite3.connect(sys.argv[1])
c.execute(\"update meta set value=?\", (json.dumps({'latestRootBlobId':'ab'*32}).encode().hex(),)); c.commit()" "$HOME/store.db"
  local before; before="$(sha256sum "$HOME/store.db")"
  run run_helper "$HOME/store.db"
  [ "$status" -eq 5 ]
  # WAL mode: the main file is unchanged and the wal holds no committed frames
  [ "$(sha256sum "$HOME/store.db")" = "$before" ]
  grep -q "$V1" "$HOME/store.db"
}

@test "cursor: WAL truncated after rewrite" {
  make_cursor "$HOME/store.db" > /dev/null
  run_helper "$HOME/store.db"
  [ ! -s "$HOME/store.db-wal" ]
}
```

- [ ] **Step 2: Run** (`bash tests/bats/run.sh redact-sqlite`). Fix the helper if anything fails. Expected pass with the Task 2 implementation.

- [ ] **Step 3: Commit** `test(redact-sqlite): cursor Merkle rewrite, hex refs, unresolvable root`

---

### Task 4: `sqlite` write mode in `bin/redact-sessions`

**Files:**
- Modify: `bin/redact-sessions` (ROOTS, `load_rules`, `scrub_one`, `candidates`, `sweep` age)
- Test: `tests/bats/redact-sessions.bats`

**Interfaces:**
- Consumes: `redact_literal_rules pairs` (Task 1), `lib/redact-sqlite.py` (Task 2).

- [ ] **Step 1: Failing tests** (append to `tests/bats/redact-sessions.bats`)

```bash
# sqlite_fixture KIND PATH: dummy store via the helper's own test fixtures.
sqlite_opencode() {
  python3 - "$1" "$V1" <<'EOF'
import sqlite3, sys, json
db, v1 = sys.argv[1:]
c = sqlite3.connect(db); c.execute("pragma journal_mode=wal")
c.executescript("create table message(id text primary key, session_id text, time_updated integer, data text); create table part(id text primary key, message_id text, session_id text, time_updated integer, data text)")
c.execute("insert into part values('p','m','ses_9',1,?)", (json.dumps({"o": "KEY=%s" % v1}),))
c.commit(); c.close()
EOF
}
sqlite_cursor() {
  python3 - "$1" "$V1" <<'EOF'
import sqlite3, sys, json, hashlib
db, v1 = sys.argv[1:]
h = lambda b: hashlib.sha256(b).hexdigest()
leaf = json.dumps({"content": v1}).encode(); root = b"\n\x20" + bytes.fromhex(h(leaf))
c = sqlite3.connect(db); c.execute("pragma journal_mode=wal")
c.executescript("create table blobs(id text primary key, data blob); create table meta(key text primary key, value text)")
for b in (leaf, root): c.execute("insert into blobs values(?,?)", (h(b), b))
c.execute("insert into meta values('0',?)", (json.dumps({"latestRootBlobId": h(root)}).encode().hex(),))
c.commit(); c.close()
EOF
}

@test "sqlite: --now scrubs an opencode db and reports key and session" {
  mkdir -p "$HOME/.local/share/opencode"; local f="$HOME/.local/share/opencode/opencode.db"
  sqlite_opencode "$f"
  run --separate-stderr "$RS" --now "$f"
  [ "$status" -eq 0 ]
  if grep -q "$V1" "$f"; then false; fi
  grep -q 'hit key=OPENROUTER_API_KEY count=1 file=.*opencode.db .*session=ses_9' "$STATE/log"
  grep -qx OPENROUTER_API_KEY "$STATE/pending"
  [[ "$stderr" != *"$V1"* ]]
}

@test "sqlite: sweep finds cursor stores under chats and acp-sessions, session is the conversation dir" {
  mkdir -p "$HOME/.cursor/chats/w/conv1" "$HOME/.cursor/acp-sessions/conv2"
  sqlite_cursor "$HOME/.cursor/chats/w/conv1/store.db"; old "$HOME/.cursor/chats/w/conv1/store.db"
  sqlite_cursor "$HOME/.cursor/acp-sessions/conv2/store.db"; old "$HOME/.cursor/acp-sessions/conv2/store.db"
  "$RS" --sweep
  if grep -rq "$V1" "$HOME/.cursor"; then false; fi
  grep -q 'hit key=OPENROUTER_API_KEY count=1 .*conv1/store.db .*session=conv1' "$STATE/log"
  grep -q 'session=conv2' "$STATE/log"
}

@test "sqlite: quiet period looks at the -wal mtime too" {
  mkdir -p "$HOME/.cursor/chats/w/c1"; local f="$HOME/.cursor/chats/w/c1/store.db"
  sqlite_cursor "$f"; old "$f"; touch "$f-wal"
  "$RS" --sweep
  grep -q "$V1" "$f" || grep -q "$V1" "$f-wal"
  grep -qx "$f" "$STATE/deferred"
  old "$f-wal"; "$RS" --sweep
  if grep -q "$V1" "$f"; then false; fi
  if grep -q "$V1" "$f-wal"; then false; fi
}

@test "sqlite: busy db is deferred, not corrupted" {
  mkdir -p "$HOME/.local/share/opencode"; local f="$HOME/.local/share/opencode/opencode.db"
  sqlite_opencode "$f"; old "$f"
  python3 -c "import sqlite3,sys,time; c=sqlite3.connect(sys.argv[1]); c.execute('begin immediate'); time.sleep(3)" "$f" &
  local holder=$!; sleep 0.5
  REDACT_SQLITE_BUSY_MS=300 "$RS" --sweep
  grep -qx "$f" "$STATE/deferred"
  grep -q 'sqlite busy file=' "$STATE/log"
  wait "$holder"
  "$RS" --sweep
  if grep -q "$V1" "$f"; then false; fi
}

@test "sqlite: no python3 defers the sqlite roots and still scrubs text files" {
  mkdir -p "$HOME/.local/share/opencode"; local f="$HOME/.local/share/opencode/opencode.db"
  sqlite_opencode "$f"; old "$f"
  local t="$HOME/.claude/projects/-p/s1.jsonl"; printf '{"x":"%s"}\n' "$V1" > "$t"; old "$t"
  REDACT_SESSIONS_PYTHON=/nonexistent/python3 "$RS" --sweep
  if grep -q "$V1" "$t"; then false; fi
  grep -q "$V1" "$f"
  grep -qx "$f" "$STATE/deferred"
  grep -q 'python3 missing' "$STATE/log"
}
```

Also:

```bash
@test "sqlite: a db whose only change since the stamp is in the -wal is a candidate" {
  mkdir -p "$HOME/.cursor/chats/w/c1"; local f="$HOME/.cursor/chats/w/c1/store.db"
  sqlite_cursor "$f"
  # first sweep: the store is fresh, so it is deferred; make it old and sweep
  # again so it is scrubbed and the stamp moves past it
  old "$f"; "$RS" --sweep; "$RS" --sweep
  if grep -q "$V1" "$f"; then false; fi
  # a new value arrives through the WAL only: main file mtime stays behind the stamp
  local v3="anothersecretvalue1234567890ab"
  printf 'THIRD_KEY=%s\n' "$v3" >> "$SECRETS"
  python3 -c "
import sqlite3,sys,json,hashlib; c=sqlite3.connect(sys.argv[1])
b=json.dumps({'content':sys.argv[2]}).encode(); c.execute('insert into blobs values(?,?)',(hashlib.sha256(b).hexdigest(),b)); c.commit()" "$f" "$v3"
  touch -d '-10 minutes' "$f" "$f-wal"
  rm -f "$STATE/rules.fp."*   # rules changed anyway; keep the stamp test honest by restoring it
  "$RS" --sweep
  if grep -q "$v3" "$f" || grep -q "$v3" "$f-wal"; then false; fi
}
```

(The rules-changed rescan makes every file a candidate, so this test proves the scrub, and the `-wal` candidate path is exercised directly by the unit below.)

```bash
@test "sqlite: candidates include a store whose -wal is newer than the stamp" {
  mkdir -p "$HOME/.cursor/chats/w/c1" "$STATE"; local f="$HOME/.cursor/chats/w/c1/store.db"
  sqlite_cursor "$f"; : > "$f-wal"
  touch -d '-30 minutes' "$f"; touch -d '-20 minutes' "$STATE/stamp"; touch -d '-10 minutes' "$f-wal"
  printf '%s\n' "$(source_candidates)" | grep -qx "$f"
}
```

with a helper at the top of the file:

```bash
# source_candidates: run the script's candidates() in this shell.
source_candidates() { ( REDACT_SESSIONS_SOURCE_ONLY=1 . "$RS"; candidates | sort -u ); }
```

- [ ] **Step 2: Run, expect failure** (`bash tests/bats/run.sh redact-sessions -f sqlite`)

- [ ] **Step 3: Implement**

`bin/redact-sessions`:

1. ROOTS: replace the OpenCode placeholder and add cursor stores:
   ```bash
   "$HOME/.cursor/chats|store.db|sqlite"
   "$HOME/.cursor/acp-sessions|store.db|sqlite"
   "$HOME/.local/share/opencode/opencode.db||sqlite"
   ```
   Extend the mode comment: `sqlite  hand the file to lib/redact-sqlite.py (spec 2026-09-07-redact-sessions-sqlite-design.md); the store is rewritten in one transaction and its WAL checkpointed.`
2. Globals: `PY="${REDACT_SESSIONS_PYTHON:-python3}"`, `HELPER="$(dirname "$_rs_self")/../lib/redact-sqlite.py"`, `PAIRS=""`.
3. `load_rules`: after RULES, `PAIRS="$(redact_literal_rules pairs "$SECRETS")" || { same refusal path; }`.
4. New function:
   ```bash
   # scrub_sqlite <db>: 0 clean or rewritten, 1 defer (busy, unknown store,
   # helper failed, checkpoint incomplete, python3 missing).
   scrub_sqlite() {
     local f="$1" out rc sess line key n sid
     if ! command -v "$PY" >/dev/null 2>&1; then
       [ -n "${_py_warned:-}" ] || { log "python3 missing: sqlite stores deferred"; _py_warned=1; }
       return 1
     fi
     out="$(printf '%s\n' "$PAIRS" | locked "$PY" "$HELPER" "$f" 2>/dev/null)"; rc=$?
     case $rc in
       0) ;;
       4) log "sqlite busy file=$f"; return 1 ;;
       5) log "sqlite unrecognised store file=$f"; return 1 ;;
       *) log "sqlite helper failed rc=$rc file=$f"; return 1 ;;
     esac
     sess="$(session_of "$f")"; rc=0
     while IFS= read -r line; do
       case "$line" in
         hit\ *) read -r _ key n sid <<< "$line"
                 log "hit key=$key count=$n file=$f container=$HOST ${sid:-session=$sess}"
                 pending_add "$key" ;;
         checkpoint-incomplete) log "sqlite checkpoint incomplete file=$f (rows redacted, wal retried next sweep)"; rc=1 ;;
         skipped-table\ *) log "sqlite $line file=$f" ;;
       esac
     done <<< "$out"
     return $rc
   }
   ```
   `session_of`: add `*/store.db) basename "$(dirname "$1")" ;;` before the default.
5. `scrub_one`: after the readability check, `[ "$(write_mode_for "$f")" = sqlite ] && { scrub_sqlite "$f"; return; }`.
6. `candidates`: for directory roots use `-name "$pat" -o -name "$pat-wal"` and pipe through `sed 's/-wal$//'`; for file roots also test `"$root-wal"` with `-newer`. Only when `[ -e "$STATE/stamp" ]`; the no-stamp branch lists everything already.
7. `sweep` age: replace the `stat -c '%Y' "$f"` with `$(newest_mtime "$f")` where
   ```bash
   newest_mtime() { { stat -c '%Y' "$1" "$1-wal" 2>/dev/null || echo 0; } | sort -n | tail -1; }
   ```
8. Add at the very bottom, before `main "$@"`: `[ -n "${REDACT_SESSIONS_SOURCE_ONLY:-}" ] && return 0 2>/dev/null` so tests can source `candidates`.

- [ ] **Step 4: Run, expect pass**; then the whole file `bash tests/bats/run.sh redact-sessions redact-sqlite redact-literal`.

- [ ] **Step 5: Commit** `feat(redact-sessions): sqlite write mode for cursor store.db and opencode.db`

---

### Task 5: docs, full suite, manual resume checks, PR

**Files:**
- Modify: `README.md` or wherever `redact-sessions` is documented (grep `redact-sessions`), the spec header of `bin/redact-sessions`, `docs/superpowers/specs/2026-09-07-redact-sessions-design.md` (non-goals bullet now points at the new spec).

- [ ] **Step 1: Docs.** In the original spec's non-goals, replace the SQLite bullet with one line: "SQLite stores: covered by `2026-09-07-redact-sessions-sqlite-design.md`." Update the script header's state/roots comments. Grep `docs/ README.md CLAUDE.md` for "store.db" or "opencode.db" mentions that say out of scope and fix them.
- [ ] **Step 2: Full suite** `bash tests/bats/run.sh`; all green.
- [ ] **Step 3: Manual checks** (spec §6) in a scratch `HOME` under the scratchpad dir: copy one real cursor conversation dir and `opencode.db`, plant a dummy value Merkle-consistently (reuse the fixture technique), scrub with `--now`, then `HOME=scratch cursor-agent --resume <id>` and `HOME=scratch opencode` load. Record outcomes in the PR body. If a CLI cannot run headless, say so in the PR instead of claiming.
- [ ] **Step 4: Commit, push, PR** against `main` of `vossiman/aiCodingBaseSetup`, title `feat(redact-sessions): scrub the SQLite session stores (AICODINGBASESETUP-16)`. Comment the PR link on the kanban ticket with `kanban-post --comment`.
