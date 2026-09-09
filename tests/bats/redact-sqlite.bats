#!/usr/bin/env bats
# lib/redact-sqlite.py: rewrites secrets-file values inside the SQLite session
# stores (cursor store.db, OpenCode opencode.db). Fixtures are built here with
# dummy values; no real store is read.

bats_require_minimum_version 1.5.0

setup() {
  : "${BLUEPRINT_ROOT:?unset, run via tests/bats/run.sh}"
  PY="$BLUEPRINT_ROOT/lib/redact-sqlite.py"
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  V1="deadbeefcafebabefeedface12345678"
  V2="quickbrownfoxjumpsoverlazydogs99"
  RULES="$(hex "$V1") [REDACTED:OPENROUTER_API_KEY]
$(hex "$V2") [REDACTED:POSTGRES_PASSWORD]
$(hex "$(printf '%s' "$V1" | base64 -w0 | cut -c1-40)") [REDACTED:OPENROUTER_API_KEY]"
}
teardown() { case "${TMPDIR:-}" in */tmp.*) rm -rf "$TMPDIR" ;; esac }

hex() { printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'; }
run_helper() { printf '%s\n' "$RULES" | python3 "$PY" "$@"; }
# leaked DB VALUE: 0 when no scrubbed OpenCode column holds VALUE (credential is opencode's own and keeps it).
leaked() { python3 -c "
import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); n=0
for t,col in [('message','data'),('part','data'),('event','data'),('session','title'),('todo','content'),('session_message','data')]:
    try: n+=c.execute(f'select count(*) from {t} where instr({col},?)>0',(sys.argv[2],)).fetchone()[0]
    except sqlite3.OperationalError: pass
print(n)" "$1" "$2"; }
col() { python3 -c "import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute(sys.argv[2]).fetchone()[0])" "$1" "$2"; }

# make_opencode DB: the OpenCode tables that carry text, WAL mode, and the
# process exits without closing so the plaintext frames stay in the -wal.
make_opencode() {
  python3 - "$1" "$V1" "$V2" <<'EOF'
import sqlite3, sys, json, base64, os
db, v1, v2 = sys.argv[1:]
c = sqlite3.connect(db); c.execute("pragma journal_mode=wal")
c.executescript("""
create table session(id text primary key, title text not null, time_updated integer not null);
create table message(id text primary key, session_id text not null, time_updated integer not null, data text not null);
create table part(id text primary key, message_id text not null, session_id text not null, time_updated integer not null, data text not null);
create table event(id text primary key, aggregate_id text not null, seq integer not null, type text not null, data text not null);
create table todo(session_id text not null, content text not null, position integer not null, primary key(session_id, position));
create table credential(id text primary key, value text not null);
create table session_message(id text primary key, session_id text not null, type text not null, time_updated integer not null, data text not null, seq integer not null);
""")
c.execute("insert into session_message values('sm_1','ses_1','tool',7,?,1)", (json.dumps({"output":"V2 KEY=%s" % v1}),))
c.execute("insert into session values('ses_1', ?, 1)", ('title mentions %s' % v2,))
c.execute("insert into message values('msg_1','ses_1',7,?)", (json.dumps({"role":"user","text":'quoted "%s"' % v1}),))
c.execute("insert into part values('prt_1','msg_1','ses_1',7,?)", (json.dumps({"type":"tool","output":"KEY=%s\nother" % v1}),))
c.execute("insert into part values('prt_2','msg_1','ses_1',7,?)", (json.dumps({"type":"text","text":"b64 " + base64.b64encode(v1.encode()).decode()}),))
c.execute("insert into event values('evt_1','ses_1',1,'message.part.updated.1',?)", (json.dumps({"part":{"output":"KEY=%s" % v1}}),))
c.execute("insert into todo values('ses_1','clean todo',0)")
c.execute("insert into credential values('c1', ?)", (v1,))
c.commit()
os._exit(0)
EOF
}

# make_cursor DB [REF]: three-level Merkle store. root -> {node, other};
# node -> leaf. leaf is JSON holding V1; node is protobuf-shaped bytes holding
# V2 and leaf's digest. REF=raw (32 bytes, the measured form) or hex. Prints
# the id of the untouched sibling.
make_cursor() {
  python3 - "$1" "$V1" "$V2" "${2:-raw}" <<'EOF'
import sqlite3, sys, json, hashlib, os
db, v1, v2, ref = sys.argv[1:]
h = lambda b: hashlib.sha256(b).hexdigest()
def refb(x): return bytes.fromhex(x) if ref == "raw" else x.encode()
leaf = json.dumps({"role": "tool", "content": "KEY=%s" % v1}).encode()
other = b'{"role":"user","content":"clean"}'
node = b"\n\x20" + refb(h(leaf)) + b"\x12" + bytes([len(v2)]) + v2.encode()
root = b"\n\x20" + refb(h(node)) + b"\n\x20" + refb(h(other))
c = sqlite3.connect(db); c.execute("pragma journal_mode=wal")
c.executescript("create table blobs(id text primary key, data blob); create table meta(key text primary key, value text)")
for b in (leaf, other, node, root):
    c.execute("insert into blobs values(?,?)", (h(b), b))
meta = json.dumps({"agentId": "a1", "latestRootBlobId": h(root), "name": "t"})
c.execute("insert into meta values('0', ?)", (meta.encode().hex(),))
c.commit()
print(h(other)); sys.stdout.flush()
os._exit(0)
EOF
}

# check_cursor DB: every id is the sha256 of its data, every child reference
# (raw or hex) resolves, the root resolves. Prints the blob count.
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
for i, d in rows:
    if d.startswith(b"\n\x20"):
        raw, hexref = d[2:34].hex(), d[2:66]
        assert raw in ids or hexref.decode("ascii", "replace") in ids, "child dangling"
print(len(rows))
EOF
}

@test "opencode: values replaced in every text column, counts per key and session" {
  make_opencode "$HOME/opencode.db"
  run --separate-stderr run_helper "$HOME/opencode.db"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hit OPENROUTER_API_KEY 1 session=ses_1"* ]]
  [[ "$output" == *"hit POSTGRES_PASSWORD 1 session=ses_1"* ]]
  [ "$(grep -c 'hit OPENROUTER_API_KEY' <<< "$output")" -eq 5 ]
  [ "$(col "$HOME/opencode.db" "select count(*) from session_message where instr(data,'[REDACTED:OPENROUTER_API_KEY]')>0")" -eq 1 ]
  [ "$(leaked "$HOME/opencode.db" "$V1")" -eq 0 ]
  [ "$(leaked "$HOME/opencode.db" "$V2")" -eq 0 ]
  # V2 lives only in a scrubbed column, so the raw file must be free of it
  # (secure_delete zeroed the old cell; the checkpoint moved the page in)
  if grep -q "$V2" "$HOME/opencode.db"; then false; fi
  if grep -q "$V2" "$HOME/opencode.db-wal"; then false; fi
  [ "$(col "$HOME/opencode.db" "select count(*) from part where data like '%[REDACTED:OPENROUTER_API_KEY]%'")" -eq 2 ]
  [ "$(col "$HOME/opencode.db" "select time_updated from message")" -eq 7 ]
  [[ "$output" != *"$V1"* ]]; [[ "$stderr" != *"$V1"* ]]
}

@test "opencode: credential table is never touched" {
  make_opencode "$HOME/opencode.db"
  run_helper "$HOME/opencode.db"
  [ "$(col "$HOME/opencode.db" "select value from credential")" = "$V1" ]
}

@test "opencode: WAL holding the plaintext is truncated to zero after the rewrite" {
  make_opencode "$HOME/opencode.db"
  [ -s "$HOME/opencode.db-wal" ]
  grep -q "$V1" "$HOME/opencode.db-wal"
  run_helper "$HOME/opencode.db"
  [ ! -s "$HOME/opencode.db-wal" ]
}

@test "opencode: clean database is not written" {
  make_opencode "$HOME/opencode.db"
  python3 -c "import sqlite3,sys; sqlite3.connect(sys.argv[1]).execute('pragma wal_checkpoint(truncate)')" "$HOME/opencode.db"
  RULES="$(hex nothingmatchesthis99) [REDACTED:X]"
  local before; before="$(stat -c '%Y %s' "$HOME/opencode.db")"
  sleep 1.1
  run run_helper "$HOME/opencode.db"
  [ "$status" -eq 0 ]; [[ "$output" != *hit* ]]
  [ "$(stat -c '%Y %s' "$HOME/opencode.db")" = "$before" ]
}

@test "opencode: a missing table is skipped and reported, the rest is scrubbed" {
  make_opencode "$HOME/opencode.db"
  python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('drop table todo'); c.commit()" "$HOME/opencode.db"
  run run_helper "$HOME/opencode.db"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped-table todo"* ]]
  [ "$(leaked "$HOME/opencode.db" "$V1")" -eq 0 ]
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

@test "cursor: leaf and node redacted, every id rehashed, root resolves, sibling untouched" {
  local other; other="$(make_cursor "$HOME/store.db")"
  run --separate-stderr run_helper "$HOME/store.db"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hit OPENROUTER_API_KEY 1"* ]]
  [[ "$output" == *"hit POSTGRES_PASSWORD 1"* ]]
  if grep -q "$V1" "$HOME/store.db"; then false; fi
  if grep -q "$V2" "$HOME/store.db"; then false; fi
  [ "$(check_cursor "$HOME/store.db")" -eq 4 ]
  [ "$(col "$HOME/store.db" "select count(*) from blobs where id='$other'")" -eq 1 ]
  [ "$(col "$HOME/store.db" "select count(*) from blobs where instr(cast(data as text), '[REDACTED:OPENROUTER_API_KEY]') > 0")" -eq 1 ]
  [[ "$stderr" != *"$V1"* ]]
}

@test "cursor: hex-text references are rewritten too" {
  make_cursor "$HOME/store.db" hex > /dev/null
  run_helper "$HOME/store.db"
  [ "$(check_cursor "$HOME/store.db")" -eq 4 ]
  if grep -q "$V1" "$HOME/store.db"; then false; fi
}

@test "cursor: unresolvable root after rewrite exits 5 and writes nothing" {
  make_cursor "$HOME/store.db" > /dev/null
  python3 -c "
import sqlite3,sys,json; c=sqlite3.connect(sys.argv[1])
c.execute('update meta set value=?', (json.dumps({'latestRootBlobId':'ab'*32}).encode().hex(),)); c.commit()
c.execute('pragma wal_checkpoint(truncate)')" "$HOME/store.db"
  local before; before="$(sha256sum "$HOME/store.db")"
  run run_helper "$HOME/store.db"
  [ "$status" -eq 5 ]
  [ "$(sha256sum "$HOME/store.db")" = "$before" ]
  grep -q "$V1" "$HOME/store.db"
}

@test "cursor: WAL truncated after rewrite" {
  make_cursor "$HOME/store.db" > /dev/null
  [ -s "$HOME/store.db-wal" ]
  run_helper "$HOME/store.db"
  [ ! -s "$HOME/store.db-wal" ]
}

@test "opencode: WAL residue with already-clean rows is still checkpointed away" {
  # rows once held the value and were rewritten, but the checkpoint never ran
  # (a busy reader on the earlier run): the -wal still carries the plaintext
  python3 - "$HOME/opencode.db" "$V1" <<'PYEOF'
import sqlite3, sys, os
db, v1 = sys.argv[1:]
c = sqlite3.connect(db); c.execute("pragma journal_mode=wal")
c.executescript("create table message(id text primary key, session_id text, time_updated integer, data text); create table part(id text primary key, message_id text, session_id text, time_updated integer, data text)")
c.execute("insert into part values('p','m','s',1,?)", ("KEY=" + v1,)); c.commit()
c.execute("update part set data='[REDACTED:OPENROUTER_API_KEY]'"); c.commit()
os._exit(0)
PYEOF
  grep -q "$V1" "$HOME/opencode.db-wal"
  run run_helper "$HOME/opencode.db"
  [ "$status" -eq 0 ]; [[ "$output" != *hit* ]]
  [ ! -s "$HOME/opencode.db-wal" ]
  if grep -q "$V1" "$HOME/opencode.db"; then false; fi
}

@test "cursor: protobuf blobs keep their length so varint field prefixes stay valid" {
  make_cursor "$HOME/store.db" > /dev/null
  local before; before="$(col "$HOME/store.db" "select length(data) from blobs where instr(cast(data as text), '$V2') > 0")"
  run_helper "$HOME/store.db"
  python3 - "$HOME/store.db" "$before" "$V2" <<'PYEOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1]); want = int(sys.argv[2]); v2 = sys.argv[3]
rows = [d for (d,) in c.execute("select data from blobs") if d.startswith(b"\n\x20") and b"\x12" in d]
node = [d for d in rows if b"[REDACTED:POSTGRES_PASSWORD]" in d]
assert len(node) == 1, rows
d = node[0]
assert len(d) == want, (len(d), want)
i = d.index(b"\x12"); n = d[i + 1]
assert n == len(v2) and len(d[i + 2:]) == n, "length prefix no longer matches payload"
assert d[i + 2:] == b"[REDACTED:POSTGRES_PASSWORD]" + b"*" * (n - len("[REDACTED:POSTGRES_PASSWORD]"))
PYEOF
  # JSON leaves keep the full, unpadded marker
  [ "$(col "$HOME/store.db" "select count(*) from blobs where substr(cast(data as text),1,1)='{' and instr(cast(data as text), '[REDACTED:OPENROUTER_API_KEY]\"') > 0")" -eq 1 ]
}

@test "cursor: a pattern shorter than its marker gets the short same-length form" {
  make_cursor "$HOME/store.db" > /dev/null
  # 8-byte pattern inside the protobuf node (a piece of V2), one key
  RULES="$(hex "${V2:0:8}") [REDACTED:POSTGRES_PASSWORD]"
  run_helper "$HOME/store.db"
  [ "$(col "$HOME/store.db" "select count(*) from blobs where instr(cast(data as text), '[R:POST]') > 0")" -eq 1 ]
  [ "$(check_cursor "$HOME/store.db")" -eq 4 ]
}

@test "cursor: a value in the meta row (conversation name) is redacted and reported" {
  make_cursor "$HOME/store.db" > /dev/null
  python3 - "$HOME/store.db" "$V2" <<'PYEOF'
import sqlite3, sys, json
c = sqlite3.connect(sys.argv[1]); m = json.loads(bytes.fromhex(c.execute("select value from meta").fetchone()[0]))
m["name"] = "pasted " + sys.argv[2]; c.execute("update meta set value=?", (json.dumps(m).encode().hex(),)); c.commit()
PYEOF
  run run_helper "$HOME/store.db"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hit POSTGRES_PASSWORD 2"* ]]
  local name; name="$(python3 -c "import sqlite3,sys,json; print(json.loads(bytes.fromhex(sqlite3.connect(sys.argv[1]).execute('select value from meta').fetchone()[0]))['name'])" "$HOME/store.db")"
  [ "$name" = "pasted [REDACTED:POSTGRES_PASSWORD]" ]
  [ "$(check_cursor "$HOME/store.db")" -eq 4 ]
}

@test "cursor: an unparseable meta row exits 5 and writes nothing" {
  make_cursor "$HOME/store.db" > /dev/null
  python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute(\"update meta set value='not hex, not json'\"); c.commit(); c.execute('pragma wal_checkpoint(truncate)')" "$HOME/store.db"
  local before; before="$(sha256sum "$HOME/store.db")"
  run run_helper "$HOME/store.db"
  [ "$status" -eq 5 ]
  [ "$(sha256sum "$HOME/store.db")" = "$before" ]
}

@test "cursor: a meta row lacking the root pointer exits 5" {
  make_cursor "$HOME/store.db" > /dev/null
  python3 -c "import sqlite3,sys,json; c=sqlite3.connect(sys.argv[1]); c.execute('update meta set value=?', (json.dumps({'name':'x'}).encode().hex(),)); c.commit()" "$HOME/store.db"
  run run_helper "$HOME/store.db"
  [ "$status" -eq 5 ]
  grep -q "$V1" "$HOME/store.db"
}

@test "opencode: a renamed session column still lets the text column be scrubbed" {
  make_opencode "$HOME/opencode.db"
  python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('alter table part rename column session_id to sid'); c.commit()" "$HOME/opencode.db"
  run run_helper "$HOME/opencode.db"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hit OPENROUTER_API_KEY 1 session=-"* ]]
  [ "$(col "$HOME/opencode.db" "select count(*) from part where instr(data,'[REDACTED:OPENROUTER_API_KEY]')>0")" -eq 2 ]
}

@test "a rule with an empty pattern is dropped: nothing written, no hit" {
  local db="$HOME/opencode.db"
  make_opencode "$db"
  python3 -c "import sqlite3,sys; sqlite3.connect(sys.argv[1]).execute('pragma wal_checkpoint(truncate)')" "$db"
  cp "$db" "$db.before"
  run --separate-stderr bash -c "printf ' [REDACTED:EMPTY]\n' | python3 '$PY' '$db'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"empty rule ignored"* ]]
  cmp -s "$db" "$db.before"
  [ "$(leaked "$db" "$V1")" -gt 0 ]
}

@test "a non-database file exits 1 with a one-line reason on stderr, no traceback" {
  printf 'not a database\n' > "$HOME/store.db"
  run --separate-stderr run_helper "$HOME/store.db"
  [ "$status" -eq 1 ]
  [[ "$stderr" == "redact-sqlite: "* ]]
  [[ "$stderr" != *"Traceback"* ]]
}
