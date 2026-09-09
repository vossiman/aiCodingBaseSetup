#!/usr/bin/env python3
"""redact-sqlite: rewrite secrets-file values inside a SQLite session store.

Usage: redact-sqlite.py DB      rules on stdin, one "HEX(PATTERN) MARKER" per line

Called by bin/redact-sessions for roots in `sqlite` write mode. Spec:
docs/superpowers/specs/2026-09-07-redact-sessions-sqlite-design.md.

Two store kinds, detected from the schema:
  cursor    blobs(id, data) + meta: content-addressed, id == sha256(data),
            tree nodes reference children by raw digest. Changed blobs are
            rehashed and every ancestor is patched up to the root pointer.
            Only JSON blobs get the full marker; protobuf and other blobs
            get a same-length marker, because a length-delimited protobuf
            field carries its byte length in a varint prefix that a longer
            or shorter payload would falsify.
  OpenCode  message/part/event/... text columns rewritten row by row.

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

# (table, text column, column naming the session)
OPENCODE_COLUMNS = [
    ("message", "data", "session_id"),
    ("part", "data", "session_id"),
    ("session_message", "data", "session_id"),
    ("event", "data", "aggregate_id"),
    ("session", "title", "id"),
    ("session", "summary_diffs", "id"),
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
        pat = bytes.fromhex(hexpat)
        # An empty pattern matches between every byte: count() would report
        # len+1 hits and replace() would splice the marker into every blob.
        if not pat or not marker:
            print("redact-sqlite: empty rule ignored", file=sys.stderr)
            continue
        rules.append((pat, marker.encode()))
    return rules


def keys_of(marker):
    m = marker.decode()
    return m[len("[REDACTED:"):-1].split(",") if m.startswith("[REDACTED:") else []


def fit_marker(marker, n):
    """A marker of exactly n bytes: the full one padded, or a shortened form."""
    if len(marker) <= n:
        return marker + b"*" * (n - len(marker))
    keys = b",".join(k.encode() for k in keys_of(marker))
    short = b"[R:" + keys[: max(n - 4, 0)] + b"]"
    return short if len(short) == n else b"*" * n


def apply_rules(data, rules, hits, same_length=False):
    for pat, marker in rules:
        n = data.count(pat)
        if n:
            for k in keys_of(marker):
                hits[k] += n
            data = data.replace(pat, fit_marker(marker, len(pat)) if same_length else marker)
    return data


def sha256(b):
    return hashlib.sha256(b).hexdigest()


def tables(conn):
    return {r[0] for r in conn.execute("select name from sqlite_master where type='table'")}


def columns(conn, table):
    return {r[1] for r in conn.execute('pragma table_info("%s")' % table)}


def as_text(b):
    return b.decode("utf-8", "surrogateescape")


def as_bytes(s):
    return s.encode("utf-8", "surrogateescape")


def scrub_opencode(conn, rules, out):
    present = tables(conn)
    for table, col, sess in OPENCODE_COLUMNS:
        cols = columns(conn, table) if table in present else set()
        if col not in cols:
            out.append("skipped-table %s" % table)
            continue
        # A renamed session column must not fail the SELECT (that would roll
        # back everything and defer the store forever); it just costs the id.
        sess_expr = '"%s"' % sess if sess in cols else "'-'"
        where = " or ".join('instr("%s", ?) > 0' % col for _ in rules)
        params = [as_text(p) for p, _ in rules]
        rows = conn.execute(
            'select rowid, "%s", %s from "%s" where %s' % (col, sess_expr, table, where), params
        ).fetchall()
        for rowid, text, sid in rows:
            hits = Counter()
            new = apply_rules(as_bytes(text), rules, hits)
            if not hits:
                continue
            conn.execute('update "%s" set "%s" = ? where rowid = ?' % (table, col), (as_text(new), rowid))
            for k, n in hits.items():
                out.append("hit %s %d session=%s" % (k, n, sid))


def decode_meta(value):
    """meta.value is hex-encoded JSON (measured); accept plain JSON too.
    Returns (json_text, is_hex, dict) or raises LookupError."""
    for is_hex in (True, False):
        try:
            text = bytes.fromhex(value).decode("utf-8") if is_hex else value
            meta = json.loads(text)
        except (ValueError, UnicodeDecodeError, TypeError):
            continue
        if isinstance(meta, dict):
            return text, is_hex, meta
    raise LookupError("meta row is neither hex JSON nor JSON")


def scrub_cursor(conn, rules, out):
    blobs = {i: bytes(d) if d is not None else b"" for i, d in conn.execute("select id, data from blobs")}
    hits = Counter()
    leaf = {i: apply_rules(d, rules, hits, same_length=not d.startswith(b"{")) for i, d in blobs.items()}
    # The meta row is user-visible metadata (conversation name, cwd) and can
    # carry a value too; it is JSON text, so the full marker applies.
    metas = []
    for key, value in conn.execute("select key, value from meta").fetchall():
        text, is_hex, meta = decode_meta(value)
        new_text = as_text(apply_rules(as_bytes(text), rules, hits))
        metas.append((key, new_text, is_hex, meta.get("latestRootBlobId")))
    if not hits:
        return
    if not any(root is not None for _, _, _, root in metas):
        raise LookupError("no meta row names a root blob")
    mapping = {i: sha256(leaf[i]) for i in blobs if leaf[i] != blobs[i]}
    final = dict(leaf)
    # Ancestors reference children by raw digest (or hex text). Recompute
    # every blob from its rule-applied content under the current mapping until
    # the mapping stops changing: at most tree-depth passes.
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
    for key, text, is_hex, root in metas:
        if root is not None and mapping.get(root, root) not in new_ids:
            raise LookupError("root blob not resolvable after rewrite")
        for old, new in mapping.items():
            text = text.replace(old, new)
        conn.execute("update meta set value = ? where key = ?", (text.encode().hex() if is_hex else text, key))
    for old, new in mapping.items():
        conn.execute("insert or replace into blobs(id, data) values (?, ?)", (new, final[old]))
    for old in mapping:
        if old not in new_ids:
            conn.execute("delete from blobs where id = ?", (old,))
    for k, n in hits.items():
        out.append("hit %s %d" % (k, n))


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
            scrub = scrub_cursor
        elif {"message", "part"} <= present:
            scrub = scrub_opencode
        else:
            return EXIT_SCHEMA
        conn.execute("begin immediate")
        try:
            scrub(conn, rules, out)
        except BaseException:
            conn.execute("rollback")
            raise
        wrote = conn.total_changes > 0
        conn.execute("commit")
        # Checkpoint after a rewrite, and also whenever the WAL still holds
        # frames: a checkpoint refused as busy on an earlier run leaves the
        # rows redacted but the plaintext frames on disk, and the retry finds
        # nothing left to change.
        wal = db + "-wal"
        if wrote or (os.path.exists(wal) and os.path.getsize(wal) > 0):
            busy, _log, _ckpt = conn.execute("pragma wal_checkpoint(truncate)").fetchone()
            if busy:
                out.append("checkpoint-incomplete")
    except sqlite3.DatabaseError as e:
        if "locked" in str(e) or "busy" in str(e):
            return EXIT_BUSY
        print("redact-sqlite: %s" % type(e).__name__, file=sys.stderr)
        return 1
    except LookupError:
        return EXIT_SCHEMA
    finally:
        conn.close()
    sys.stdout.write("".join(l + "\n" for l in out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
