"""File-backed native execution, permit, claim, and delivery registry."""

from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import tempfile
import threading
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from uuid import UUID, uuid5

from .schema import BridgeError, MAX_OPAQUE, validate_local_handle


PERMIT_TTL = timedelta(seconds=60)
ENDED_RETENTION = timedelta(days=7)
CONSUMED_PERMIT_RETENTION = timedelta(hours=1)
MAX_QUEUE_ROWS = 1024
OPERATION_NAMESPACE = UUID("91f57c8e-a13b-4874-9e20-52abf3eac150")


def _utc(value: datetime | None = None) -> datetime:
    value = value or datetime.now(UTC)
    if value.tzinfo is None:
        value = value.replace(tzinfo=UTC)
    return value.astimezone(UTC)


def _stamp(value: datetime | None = None) -> str:
    return _utc(value).isoformat(timespec="microseconds")


def _parse(value: str) -> datetime:
    return datetime.fromisoformat(value)


def _opaque(value, name: str, *, optional=False):
    if optional and value is None:
        return None
    if not isinstance(value, str) or not value.strip() or len(value) > MAX_OPAQUE:
        raise BridgeError(422, f"{name} must be a bounded nonempty identifier")
    return value


@dataclass(frozen=True)
class NativeIdentity:
    harness: str
    native_session_id: str
    subagent_id: str | None
    run_generation: str

    @property
    def key(self) -> str:
        return json.dumps([self.harness, self.native_session_id, self.subagent_id, self.run_generation],
                          separators=(",", ":"))


@dataclass(frozen=True)
class Execution:
    handle: str
    harness: str
    native_session_id: str
    subagent_id: str | None
    run_generation: str
    checkout: str
    lifecycle_capable: bool
    state: str
    work_session_id: str | None
    label: str | None
    repo: str | None
    sequence: int
    cache_trusted: bool
    created_at: datetime
    ended_at: datetime | None

    @property
    def identity(self) -> NativeIdentity:
        return NativeIdentity(self.harness, self.native_session_id, self.subagent_id, self.run_generation)


@dataclass(frozen=True)
class Permit:
    permit_id: int
    handle: str
    tool: str
    digest: str
    native_call_id: str
    run_generation: str
    operation_id: str
    created_at: datetime


@dataclass(frozen=True)
class QueueEvent:
    handle: str
    run_generation: str
    kind: str
    payload: str
    created_at: datetime


SCHEMA = """
CREATE TABLE executions (
  handle TEXT PRIMARY KEY,
  identity_key TEXT NOT NULL UNIQUE,
  harness TEXT NOT NULL,
  native_session_id TEXT NOT NULL,
  subagent_id TEXT,
  run_generation TEXT NOT NULL,
  checkout TEXT NOT NULL,
  lifecycle_capable INTEGER NOT NULL,
  state TEXT NOT NULL,
  backend_session_id TEXT,
  label TEXT,
  repo TEXT,
  sequence INTEGER NOT NULL DEFAULT 0,
  cache_trusted INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  ended_at TEXT,
  end_handoff TEXT
);
CREATE TABLE permits (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  handle TEXT NOT NULL REFERENCES executions(handle) ON DELETE CASCADE,
  identity_key TEXT NOT NULL,
  native_call_id TEXT NOT NULL,
  run_generation TEXT NOT NULL,
  tool TEXT NOT NULL,
  digest TEXT NOT NULL,
  operation_id TEXT NOT NULL,
  created_at TEXT NOT NULL,
  consumed_at TEXT,
  UNIQUE(identity_key, native_call_id)
);
CREATE INDEX permits_lookup ON permits(handle, tool, consumed_at, id);
CREATE TABLE claims (
  claim_id TEXT PRIMARY KEY,
  handle TEXT NOT NULL REFERENCES executions(handle) ON DELETE CASCADE,
  run_generation TEXT NOT NULL,
  ticket_ref TEXT NOT NULL,
  ticket_id TEXT,
  active INTEGER NOT NULL,
  checkpoint TEXT,
  handoff TEXT,
  updated_at TEXT NOT NULL
);
CREATE UNIQUE INDEX one_active_claim_per_execution ON claims(handle) WHERE active = 1;
CREATE TABLE operations (
  operation_id TEXT PRIMARY KEY,
  handle TEXT NOT NULL REFERENCES executions(handle) ON DELETE CASCADE,
  run_generation TEXT NOT NULL,
  kind TEXT NOT NULL,
  digest TEXT NOT NULL,
  claim_id TEXT,
  state TEXT NOT NULL,
  last_error_class TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE TABLE queue (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  handle TEXT NOT NULL REFERENCES executions(handle) ON DELETE CASCADE,
  run_generation TEXT NOT NULL,
  kind TEXT NOT NULL,
  payload TEXT NOT NULL,
  created_at TEXT NOT NULL
);
"""


class Store:
    def __init__(self, path: str | Path | None = None):
        if path is None:
            state = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state"))
            path = state / "aicoding" / "kanban-work.sqlite3"
        self.path = Path(path)
        self._lock = threading.RLock()
        self._ensure_file()
        self._connection = self._connect(self.path)
        self._connection.execute("PRAGMA journal_mode=WAL")
        self._connection.execute("PRAGMA foreign_keys=ON")
        self._recheck_modes()
        self.cleanup()

    @staticmethod
    def _connect(path: Path):
        return sqlite3.connect(path, timeout=30, isolation_level=None, check_same_thread=False)

    def _ensure_file(self):
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.path.parent, 0o700)
        if self.path.exists():
            os.chmod(self.path, 0o600)
            return
        fd, temporary = tempfile.mkstemp(prefix=f".{self.path.name}.", dir=self.path.parent)
        os.close(fd)
        temp_path = Path(temporary)
        os.chmod(temp_path, 0o600)
        connection = None
        try:
            connection = self._connect(temp_path)
            connection.executescript(SCHEMA)
            connection.close()
            connection = None
            try:
                os.link(temp_path, self.path)
            except FileExistsError:
                pass
        finally:
            if connection is not None:
                connection.close()
            temp_path.unlink(missing_ok=True)
        os.chmod(self.path, 0o600)

    def _recheck_modes(self):
        os.chmod(self.path.parent, 0o700)
        os.chmod(self.path, 0o600)

    def close(self):
        self._connection.close()

    @contextmanager
    def _immediate(self):
        with self._lock:
            self._connection.execute("BEGIN IMMEDIATE")
            try:
                yield self._connection
            except BaseException:
                self._connection.rollback()
                raise
            else:
                self._connection.commit()

    @staticmethod
    def _execution(row) -> Execution | None:
        if row is None:
            return None
        return Execution(
            handle=row[0], harness=row[1], native_session_id=row[2], subagent_id=row[3],
            run_generation=row[4], checkout=row[5], lifecycle_capable=bool(row[6]), state=row[7],
            work_session_id=row[8], label=row[9], repo=row[10], sequence=row[11],
            cache_trusted=bool(row[12]), created_at=_parse(row[13]),
            ended_at=_parse(row[14]) if row[14] else None,
        )

    def get_execution(self, handle: str) -> Execution | None:
        row = self._connection.execute(
            "SELECT handle,harness,native_session_id,subagent_id,run_generation,checkout,"
            "lifecycle_capable,state,backend_session_id,label,repo,sequence,cache_trusted,created_at,ended_at "
            "FROM executions WHERE handle=?", (handle,)
        ).fetchone()
        return self._execution(row)

    def execution_for_identity(self, identity: NativeIdentity) -> Execution | None:
        row = self._connection.execute(
            "SELECT handle,harness,native_session_id,subagent_id,run_generation,checkout,"
            "lifecycle_capable,state,backend_session_id,label,repo,sequence,cache_trusted,created_at,ended_at "
            "FROM executions WHERE identity_key=?", (identity.key,)
        ).fetchone()
        return self._execution(row)

    def start_execution(self, harness: str, native_session_id: str, subagent_id: str | None,
                        run_generation: str, handle: str, checkout: str,
                        lifecycle_capable: bool, *, now: datetime | None = None) -> Execution:
        identity = NativeIdentity(_opaque(harness, "harness"),
                                  _opaque(native_session_id, "native_session_id"),
                                  _opaque(subagent_id, "subagent_id", optional=True),
                                  _opaque(run_generation, "run_generation"))
        validate_local_handle(handle)
        if not isinstance(checkout, str) or not os.path.isabs(checkout):
            raise BridgeError(422, "checkout must be an absolute path")
        if type(lifecycle_capable) is not bool:
            raise BridgeError(422, "lifecycle_capable must be a boolean")
        stamp = _stamp(now)
        try:
            with self._immediate() as db:
                db.execute(
                    "INSERT INTO executions(handle,identity_key,harness,native_session_id,subagent_id,"
                    "run_generation,checkout,lifecycle_capable,state,created_at,updated_at) "
                    "VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                    (handle, identity.key, harness, native_session_id, subagent_id, run_generation,
                     checkout, int(lifecycle_capable), "minted", stamp, stamp),
                )
        except sqlite3.IntegrityError:
            existing = self.execution_for_identity(identity)
            if existing and existing.handle == handle:
                return existing
            raise BridgeError(409, "native execution or handle is already registered") from None
        return self.get_execution(handle)

    def permit_call(self, identity: NativeIdentity, native_call_id: str, tool: str,
                    normalized_args: bytes, now: datetime) -> Permit:
        _opaque(native_call_id, "native_call_id")
        try:
            args = json.loads(normalized_args)
            handle = args["handle"]
        except (ValueError, TypeError, KeyError):
            raise BridgeError(422, "normalized arguments are invalid") from None
        digest = hashlib.sha256(normalized_args).hexdigest()
        operation_id = args.get("operation_id") or str(uuid5(
            OPERATION_NAMESPACE, f"{identity.key}\0{native_call_id}\0{tool}"
        ))
        stamp = _stamp(now)
        try:
            with self._immediate() as db:
                owner = db.execute(
                    "SELECT identity_key,lifecycle_capable,state,run_generation FROM executions WHERE handle=?",
                    (handle,),
                ).fetchone()
                if owner is None:
                    raise BridgeError(403, "handle was not minted by a native hook")
                if owner[0] != identity.key or owner[3] != identity.run_generation:
                    raise BridgeError(403, "handle belongs to another native session")
                if not owner[1]:
                    raise BridgeError(409, "native client version lacks qualified lifecycle support")
                if owner[2] == "ended":
                    recorded_end = db.execute(
                        "SELECT 1 FROM operations WHERE operation_id=? AND handle=? "
                        "AND run_generation=? AND kind='end_session' AND digest=? AND state!='rejected'",
                        (operation_id, handle, identity.run_generation, digest),
                    ).fetchone()
                    if tool != "end_work_session" or recorded_end is None:
                        raise BridgeError(409, "native execution has ended")
                cursor = db.execute(
                    "INSERT INTO permits(handle,identity_key,native_call_id,run_generation,tool,digest,operation_id,created_at) "
                    "VALUES(?,?,?,?,?,?,?,?)",
                    (handle, identity.key, native_call_id, identity.run_generation, tool, digest, operation_id, stamp),
                )
                permit_id = cursor.lastrowid
        except sqlite3.IntegrityError:
            raise BridgeError(409, "native tool call already minted a permit") from None
        return Permit(permit_id, handle, tool, digest, native_call_id, identity.run_generation,
                      operation_id, _utc(now))

    def consume_permit(self, handle: str, tool: str, normalized_args: bytes, now: datetime) -> Permit:
        digest = hashlib.sha256(normalized_args).hexdigest()
        expired = False
        with self._immediate() as db:
            row = db.execute(
                "SELECT id,digest,native_call_id,run_generation,operation_id,created_at FROM permits "
                "WHERE handle=? AND tool=? AND digest=? AND consumed_at IS NULL ORDER BY id DESC LIMIT 1",
                (handle, tool, digest),
            ).fetchone()
            if row is None:
                if db.execute(
                    "SELECT 1 FROM permits WHERE handle=? AND tool=? AND consumed_at IS NULL LIMIT 1",
                    (handle, tool),
                ).fetchone() is not None:
                    raise BridgeError(403, "native pre-call permit digest does not match arguments")
                raise BridgeError(403, "missing or already consumed native pre-call permit")
            permit_id, expected, native_call_id, run_generation, operation_id, created_at = row
            created = _parse(created_at)
            if _utc(now) >= created + PERMIT_TTL:
                db.execute("UPDATE permits SET consumed_at=? WHERE id=?", (_stamp(now), permit_id))
                expired = True
            else:
                changed = db.execute(
                    "UPDATE permits SET consumed_at=? WHERE id=? AND consumed_at IS NULL",
                    (_stamp(now), permit_id),
                ).rowcount
                if changed != 1:
                    raise BridgeError(403, "missing or already consumed native pre-call permit")
        if expired:
            raise BridgeError(403, "native pre-call permit expired")
        return Permit(permit_id, handle, tool, expected, native_call_id, run_generation,
                      operation_id, created)

    def has_permit(self, handle: str, tool: str, normalized_args: bytes) -> bool:
        digest = hashlib.sha256(normalized_args).hexdigest()
        return self._connection.execute(
            "SELECT 1 FROM permits WHERE handle=? AND tool=? AND digest=? AND consumed_at IS NULL",
            (handle, tool, digest),
        ).fetchone() is not None

    def has_any_permit(self) -> bool:
        return self._connection.execute("SELECT 1 FROM permits WHERE consumed_at IS NULL LIMIT 1").fetchone() is not None

    def allocate_sequence(self, handle: str) -> int:
        with self._immediate() as db:
            if db.execute("UPDATE executions SET sequence=sequence+1 WHERE handle=?", (handle,)).rowcount != 1:
                raise BridgeError(404, "unknown work handle")
            return db.execute("SELECT sequence FROM executions WHERE handle=?", (handle,)).fetchone()[0]

    def record_bound(self, handle: str, work_session_id: str, repo: str, label: str,
                     checkout: str | None = None):
        _opaque(work_session_id, "work_session_id")
        _opaque(repo, "repo")
        _opaque(label, "label")
        with self._immediate() as db:
            fields = "backend_session_id=?,repo=?,label=?,state='bound',cache_trusted=1,updated_at=?"
            values = [work_session_id, repo, label, _stamp()]
            if checkout is not None:
                fields += ",checkout=?"
                values.append(checkout)
            values.append(handle)
            if db.execute(f"UPDATE executions SET {fields} WHERE handle=?", values).rowcount != 1:
                raise BridgeError(404, "unknown work handle")

    def set_claim(self, handle: str, claim_id: str, ticket_ref: str, ticket_id: str | None = None):
        _opaque(claim_id, "claim_id")
        _opaque(ticket_ref, "ticket")
        _opaque(ticket_id, "ticket_id", optional=True)
        with self._immediate() as db:
            generation = db.execute(
                "SELECT run_generation FROM executions WHERE handle=?", (handle,)
            ).fetchone()
            if generation is None:
                raise BridgeError(404, "unknown work handle")
            db.execute("UPDATE claims SET active=0,updated_at=? WHERE handle=? AND active=1", (_stamp(), handle))
            db.execute(
                "INSERT INTO claims(claim_id,handle,run_generation,ticket_ref,ticket_id,active,updated_at) "
                "VALUES(?,?,?,?,?,1,?) "
                "ON CONFLICT(claim_id) DO UPDATE SET handle=excluded.handle,ticket_ref=excluded.ticket_ref,"
                "run_generation=excluded.run_generation,ticket_id=excluded.ticket_id,active=1,updated_at=excluded.updated_at",
                (claim_id, handle, generation[0], ticket_ref, ticket_id, _stamp()),
            )

    def active_claim(self, handle: str) -> dict | None:
        row = self._connection.execute(
            "SELECT claim_id,ticket_ref,ticket_id FROM claims WHERE handle=? AND active=1", (handle,)
        ).fetchone()
        return None if row is None else {"id": row[0], "ticket": row[1], "ticket_id": row[2]}

    def claim(self, handle: str, claim_id: str) -> dict | None:
        row = self._connection.execute(
            "SELECT claim_id,ticket_ref,ticket_id,active FROM claims WHERE handle=? AND claim_id=?",
            (handle, claim_id),
        ).fetchone()
        return None if row is None else {
            "id": row[0], "ticket": row[1], "ticket_id": row[2], "active": bool(row[3])
        }

    def owns_claim(self, handle: str, claim_id: str, run_generation: str) -> bool:
        return self._connection.execute(
            "SELECT 1 FROM claims WHERE handle=? AND claim_id=? AND run_generation=?",
            (handle, claim_id, run_generation),
        ).fetchone() is not None

    def operation(self, handle: str, operation_id: str) -> dict | None:
        row = self._connection.execute(
            "SELECT run_generation,kind,digest,claim_id,state,last_error_class "
            "FROM operations WHERE handle=? AND operation_id=?", (handle, operation_id)
        ).fetchone()
        if row is None:
            return None
        return {"run_generation": row[0], "kind": row[1], "digest": row[2],
                "claim_id": row[3], "state": row[4], "last_error_class": row[5]}

    def begin_operation(self, handle: str, run_generation: str, operation_id: str,
                        kind: str, normalized_args: bytes, claim_id: str | None = None) -> dict:
        digest = hashlib.sha256(normalized_args).hexdigest()
        stamp = _stamp()
        with self._immediate() as db:
            row = db.execute(
                "SELECT handle,run_generation,kind,digest,claim_id,state,last_error_class "
                "FROM operations WHERE operation_id=?", (operation_id,)
            ).fetchone()
            if row is not None:
                if (row[0] != handle or row[1] != run_generation or row[2] != kind
                        or row[3] != digest or row[4] != claim_id):
                    raise BridgeError(409, "operation_id was already used for different work")
                return {"run_generation": row[1], "kind": row[2], "digest": row[3],
                        "claim_id": row[4], "state": row[5], "last_error_class": row[6],
                        "existing": True}
            db.execute(
                "INSERT INTO operations(operation_id,handle,run_generation,kind,digest,claim_id,state,created_at,updated_at) "
                "VALUES(?,?,?,?,?,?,'pending',?,?)",
                (operation_id, handle, run_generation, kind, digest, claim_id, stamp, stamp),
            )
        return {"run_generation": run_generation, "kind": kind, "digest": digest,
                "claim_id": claim_id, "state": "pending", "last_error_class": None,
                "existing": False}

    def finish_operation(self, handle: str, operation_id: str, state: str,
                         error_class: str | None = None):
        if state not in {"succeeded", "rejected", "ambiguous"}:
            raise BridgeError(422, "invalid operation state")
        if error_class is not None:
            error_class = type(error_class).__name__ if not isinstance(error_class, str) else error_class
            error_class = error_class[:100]
        with self._immediate() as db:
            if db.execute(
                "UPDATE operations SET state=?,last_error_class=?,updated_at=? "
                "WHERE handle=? AND operation_id=?",
                (state, error_class, _stamp(), handle, operation_id),
            ).rowcount != 1:
                raise BridgeError(404, "operation record is missing")

    def mark_untrusted(self, handle: str, backend_session_id: str | None = None):
        if backend_session_id is not None:
            _opaque(backend_session_id, "work_session_id")
        with self._immediate() as db:
            if backend_session_id is None:
                db.execute("UPDATE executions SET cache_trusted=0,updated_at=? WHERE handle=?",
                           (_stamp(), handle))
            else:
                db.execute("UPDATE executions SET cache_trusted=0,backend_session_id=?,updated_at=? WHERE handle=?",
                           (backend_session_id, _stamp(), handle))

    def refresh_authoritative(self, handle: str, session: dict, ticket: dict | None,
                              *, checkout: str | None = None):
        execution = self.get_execution(handle)
        if execution is None:
            raise BridgeError(404, "unknown work handle")
        if not isinstance(session, dict):
            raise BridgeError(502, "get_session returned an invalid session object")
        session_id = _opaque(session.get("id"), "work_session_id")
        if execution.work_session_id is not None and session_id != execution.work_session_id:
            raise BridgeError(502, "authoritative session identity changed unexpectedly")
        for actual, expected, name in (
            (session.get("harness"), execution.harness, "harness"),
            (session.get("native_session_id"), execution.native_session_id, "native_session_id"),
            (session.get("subagent_id"), execution.subagent_id, "subagent_id"),
            (session.get("run_generation"), execution.run_generation, "run_generation"),
        ):
            if actual != expected:
                raise BridgeError(502, f"authoritative session {name} does not match native identity")
        label = _opaque(session.get("label"), "label")
        repo = _opaque(session.get("repo"), "repo")
        if type(session.get("lifecycle_capable")) is not bool:
            raise BridgeError(502, "authoritative session lifecycle capability is invalid")
        if session["lifecycle_capable"] != execution.lifecycle_capable:
            raise BridgeError(502, "authoritative session lifecycle capability changed unexpectedly")
        claims = session.get("claims")
        if not isinstance(claims, list) or len(claims) > 1:
            raise BridgeError(502, "authoritative session claims are invalid")
        active = None
        if claims:
            claim = claims[0]
            if not isinstance(claim, dict):
                raise BridgeError(502, "authoritative claim is invalid")
            active = (_opaque(claim.get("id"), "claim_id"),
                      _opaque(claim.get("ticket_id"), "ticket_id"))
            if claim.get("work_session_id") != session_id:
                raise BridgeError(502, "authoritative claim belongs to another session")
            if claim.get("released_at") is not None:
                raise BridgeError(502, "authoritative active claim is already released")
        ticket_ref = None
        if ticket is not None:
            if not isinstance(ticket, dict):
                raise BridgeError(502, "get_ticket returned an invalid ticket object")
            ticket_ref = _opaque(ticket.get("key"), "ticket")
            ticket_id = _opaque(ticket.get("id"), "ticket_id")
            for field in ("title", "status", "swimlane", "position", "done_at",
                          "doing_source", "doing_actor", "work_claim"):
                if field not in ticket:
                    raise BridgeError(502, f"authoritative ticket is missing {field}")
            projected = ticket.get("work_claim")
            projected_id = projected.get("id") if isinstance(projected, dict) else None
            if active and (ticket_id != active[1] or projected_id != active[0]):
                raise BridgeError(502, "authoritative ticket claim does not match session")
            if not active and projected_id is not None:
                raise BridgeError(502, "authoritative ticket still has an active claim")
        with self._immediate() as db:
            db.execute("UPDATE claims SET active=0,updated_at=? WHERE handle=? AND active=1",
                       (_stamp(), handle))
            if active:
                checkpoint = claims[0].get("latest_checkpoint")
                handoff = claims[0].get("handoff")
                if checkpoint is not None and (not isinstance(checkpoint, str) or len(checkpoint) > 10_000):
                    raise BridgeError(502, "authoritative checkpoint is invalid")
                if handoff is not None and (not isinstance(handoff, str) or len(handoff) > 10_000):
                    raise BridgeError(502, "authoritative handoff is invalid")
                db.execute(
                    "INSERT INTO claims(claim_id,handle,run_generation,ticket_ref,ticket_id,active,checkpoint,handoff,updated_at) "
                    "VALUES(?,?,?,?,?,1,?,?,?) ON CONFLICT(claim_id) DO UPDATE SET handle=excluded.handle,"
                    "run_generation=excluded.run_generation,ticket_ref=excluded.ticket_ref,"
                    "ticket_id=excluded.ticket_id,active=1,checkpoint=excluded.checkpoint,"
                    "handoff=excluded.handoff,updated_at=excluded.updated_at",
                    (active[0], handle, execution.run_generation, ticket_ref or active[1], active[1],
                     checkpoint, handoff, _stamp()),
                )
            state = "ended" if session.get("ended_at") is not None else "bound"
            fields = ("backend_session_id=?,label=?,repo=?,lifecycle_capable=?,state=?,cache_trusted=1,"
                      "ended_at=?,updated_at=?")
            values = [session_id, label, repo, int(session["lifecycle_capable"]), state,
                      _stamp() if state == "ended" else None, _stamp()]
            if checkout is not None:
                fields += ",checkout=?"
                values.append(checkout)
            values.append(handle)
            db.execute(f"UPDATE executions SET {fields} WHERE handle=?", values)

    def lookup(self, handle: str) -> dict:
        execution = self.get_execution(handle)
        if execution is None:
            raise BridgeError(404, "unknown work handle")
        claim = self.active_claim(handle)
        if claim:
            claim = {"id": claim["id"], "ticket": claim["ticket"]}
        return {
            "handle": execution.handle,
            "state": execution.state,
            "harness": execution.harness,
            "run_generation": execution.run_generation,
            "label": execution.label,
            "repo": execution.repo,
            "lifecycle_capable": execution.lifecycle_capable,
            "work_session_id": execution.work_session_id,
            "active_claim": claim,
        }

    def mark_ended(self, handle: str, ended_at: datetime, handoff: str | None = None):
        with self._immediate() as db:
            db.execute("UPDATE executions SET state='ended',ended_at=?,end_handoff=?,updated_at=? WHERE handle=?",
                       (_stamp(ended_at), handoff, _stamp(ended_at), handle))

    def enqueue(self, event: QueueEvent) -> None:
        _opaque(event.kind, "queue kind")
        with self._immediate() as db:
            generation = db.execute(
                "SELECT run_generation,state FROM executions WHERE handle=?", (event.handle,)
            ).fetchone()
            if generation is None:
                raise BridgeError(404, "unknown work handle")
            if generation[0] != event.run_generation:
                raise BridgeError(409, "queued event belongs to another run generation")
            if event.kind == "activity" and (
                generation[1] == "ended" or db.execute(
                    "SELECT 1 FROM queue WHERE handle=? AND run_generation=? AND kind='end' LIMIT 1",
                    (event.handle, event.run_generation),
                ).fetchone() is not None
            ):
                return
            if event.kind == "end":
                db.execute(
                    "DELETE FROM queue WHERE handle=? AND run_generation=? AND kind='activity'",
                    (event.handle, event.run_generation),
                )
            count = db.execute("SELECT count(*) FROM queue").fetchone()[0]
            if count >= MAX_QUEUE_ROWS:
                row = db.execute("SELECT id FROM queue WHERE kind='activity' ORDER BY id LIMIT 1").fetchone()
                if row:
                    db.execute("DELETE FROM queue WHERE id=?", (row[0],))
                else:
                    return
            db.execute("INSERT INTO queue(handle,run_generation,kind,payload,created_at) VALUES(?,?,?,?,?)",
                       (event.handle, event.run_generation, event.kind, event.payload,
                        _stamp(event.created_at)))

    def cleanup(self, now: datetime | None = None):
        cutoff = _stamp(_utc(now) - ENDED_RETENTION)
        permit_cutoff = _stamp(_utc(now) - CONSUMED_PERMIT_RETENTION)
        with self._immediate() as db:
            db.execute("DELETE FROM permits WHERE consumed_at IS NOT NULL AND consumed_at<?", (permit_cutoff,))
            db.execute(
                "DELETE FROM executions WHERE ended_at IS NOT NULL AND ended_at<? "
                "AND NOT EXISTS(SELECT 1 FROM queue WHERE queue.handle=executions.handle)", (cutoff,)
            )

    def schema_columns(self) -> list[str]:
        result = []
        for table in ("executions", "permits", "claims", "operations", "queue"):
            result.extend(row[1] for row in self._connection.execute(f"PRAGMA table_info({table})"))
        return result
