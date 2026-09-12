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
from uuid import UUID, uuid4, uuid5

from .schema import BridgeError, MAX_OPAQUE, validate_local_handle


PERMIT_TTL = timedelta(seconds=60)
ENDED_RETENTION = timedelta(days=7)
CONSUMED_PERMIT_RETENTION = timedelta(hours=1)
NATIVE_EVENT_RETENTION = timedelta(days=7)
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


@dataclass(frozen=True)
class QueueRow:
    row_id: int
    handle: str
    run_generation: str
    kind: str
    payload: dict
    operation_id: str
    claim_id: str | None
    observed_at: datetime | None
    sequence: int | None
    attempts: int
    last_error_class: str | None
    claim_token: str | None = None


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
  end_handoff TEXT,
  latest_end_operation_id TEXT,
  latest_end_payload TEXT,
  latest_end_claim_id TEXT,
  end_intent_created_at TEXT,
  end_delivered_at TEXT,
  last_activity_at TEXT
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
  latest_release_operation_id TEXT,
  latest_release_payload TEXT,
  release_intent_created_at TEXT,
  release_delivered_at TEXT,
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
  operation_id TEXT,
  claim_id TEXT,
  observed_at TEXT,
  sequence INTEGER,
  attempts INTEGER NOT NULL DEFAULT 0,
  last_error_class TEXT,
  claim_token TEXT,
  claimed_at TEXT,
  created_at TEXT NOT NULL
);
CREATE UNIQUE INDEX queue_operation ON queue(handle,run_generation,kind,operation_id)
  WHERE operation_id IS NOT NULL;
CREATE TABLE native_events (
  harness TEXT NOT NULL,
  native_event_id TEXT NOT NULL,
  event_name TEXT NOT NULL,
  handle TEXT,
  run_generation TEXT,
  state TEXT NOT NULL,
  result TEXT,
  created_at TEXT NOT NULL,
  completed_at TEXT,
  PRIMARY KEY(harness,native_event_id)
);
CREATE TABLE tool_operations (
  handle TEXT NOT NULL REFERENCES executions(handle) ON DELETE CASCADE,
  run_generation TEXT NOT NULL,
  native_call_id TEXT NOT NULL,
  claim_id TEXT,
  active INTEGER NOT NULL,
  started_at TEXT NOT NULL,
  latest_native_event_at TEXT NOT NULL,
  last_activity_at TEXT,
  PRIMARY KEY(handle,run_generation,native_call_id)
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
        self._migrate()
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

    def _migrate(self):
        """Add lifecycle-delivery columns to registries created by Task 2."""
        additions = {
            "executions": {
                "latest_end_operation_id": "TEXT",
                "latest_end_payload": "TEXT",
                "latest_end_claim_id": "TEXT",
                "end_intent_created_at": "TEXT",
                "end_delivered_at": "TEXT",
                "last_activity_at": "TEXT",
            },
            "claims": {
                "latest_release_operation_id": "TEXT",
                "latest_release_payload": "TEXT",
                "release_intent_created_at": "TEXT",
                "release_delivered_at": "TEXT",
            },
            "queue": {
                "operation_id": "TEXT",
                "claim_id": "TEXT",
                "observed_at": "TEXT",
                "sequence": "INTEGER",
                "attempts": "INTEGER NOT NULL DEFAULT 0",
                "last_error_class": "TEXT",
                "claim_token": "TEXT",
                "claimed_at": "TEXT",
            },
            "native_events": {
                "completed_at": "TEXT",
            },
        }
        with self._immediate() as db:
            for table, columns in additions.items():
                existing = {row[1] for row in db.execute(f"PRAGMA table_info({table})")}
                for name, declaration in columns.items():
                    if name not in existing:
                        db.execute(f"ALTER TABLE {table} ADD COLUMN {name} {declaration}")
            db.execute(
                "CREATE UNIQUE INDEX IF NOT EXISTS queue_operation "
                "ON queue(handle,run_generation,kind,operation_id) WHERE operation_id IS NOT NULL"
            )
            db.execute(
                "CREATE TABLE IF NOT EXISTS native_events ("
                "harness TEXT NOT NULL,native_event_id TEXT NOT NULL,event_name TEXT NOT NULL,"
                "handle TEXT,run_generation TEXT,state TEXT NOT NULL,result TEXT,created_at TEXT NOT NULL,"
                "completed_at TEXT,"
                "PRIMARY KEY(harness,native_event_id))"
            )
            db.execute(
                "CREATE TABLE IF NOT EXISTS tool_operations ("
                "handle TEXT NOT NULL REFERENCES executions(handle) ON DELETE CASCADE,"
                "run_generation TEXT NOT NULL,native_call_id TEXT NOT NULL,claim_id TEXT,"
                "active INTEGER NOT NULL,started_at TEXT NOT NULL,latest_native_event_at TEXT NOT NULL,"
                "last_activity_at TEXT,PRIMARY KEY(handle,run_generation,native_call_id))"
            )
            db.execute(
                "UPDATE native_events SET completed_at=created_at "
                "WHERE state='done' AND completed_at IS NULL"
            )

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

    def executions_for_native(self, harness: str, native_session_id: str,
                              subagent_id: str | None) -> list[Execution]:
        """Return generations for one native actor, newest first."""
        _opaque(harness, "harness")
        _opaque(native_session_id, "native_session_id")
        _opaque(subagent_id, "subagent_id", optional=True)
        rows = self._connection.execute(
            "SELECT handle,harness,native_session_id,subagent_id,run_generation,checkout,"
            "lifecycle_capable,state,backend_session_id,label,repo,sequence,cache_trusted,created_at,ended_at "
            "FROM executions WHERE harness=? AND native_session_id=? AND subagent_id IS ? "
            "ORDER BY created_at DESC,rowid DESC",
            (harness, native_session_id, subagent_id),
        ).fetchall()
        return [self._execution(row) for row in rows]

    def current_execution(self, harness: str, native_session_id: str,
                          subagent_id: str | None) -> Execution | None:
        """Resolve the current generation for a trusted native ingress event."""
        executions = self.executions_for_native(harness, native_session_id, subagent_id)
        return next((execution for execution in executions if execution.state != "ended"),
                    executions[0] if executions else None)

    def active_child_executions(self, harness: str, native_session_id: str) -> list[Execution]:
        """Return live child actors for one native parent session."""
        _opaque(harness, "harness")
        _opaque(native_session_id, "native_session_id")
        rows = self._connection.execute(
            "SELECT handle,harness,native_session_id,subagent_id,run_generation,checkout,"
            "lifecycle_capable,state,backend_session_id,label,repo,sequence,cache_trusted,created_at,ended_at "
            "FROM executions WHERE harness=? AND native_session_id=? AND subagent_id IS NOT NULL "
            "AND state!='ended' ORDER BY created_at,rowid",
            (harness, native_session_id),
        ).fetchall()
        return [self._execution(row) for row in rows]

    def has_active_tool_operations(self, handle: str, run_generation: str) -> bool:
        return self._connection.execute(
            "SELECT 1 FROM tool_operations WHERE handle=? AND run_generation=? AND active=1 LIMIT 1",
            (handle, run_generation),
        ).fetchone() is not None

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

    @staticmethod
    def _admit_queue(db, handle: str, run_generation: str, kind: str, payload: dict,
                     operation_id: str, claim_id: str | None, observed_at: datetime | None,
                     sequence: int | None, created_at: datetime) -> bool:
        if db.execute(
            "SELECT 1 FROM queue WHERE handle=? AND run_generation=? AND kind=? AND operation_id=?",
            (handle, run_generation, kind, operation_id),
        ).fetchone():
            return True
        count = db.execute("SELECT count(*) FROM queue").fetchone()[0]
        if count >= MAX_QUEUE_ROWS:
            oldest_activity = db.execute(
                "SELECT id FROM queue WHERE kind='activity' ORDER BY id LIMIT 1"
            ).fetchone()
            if oldest_activity is None:
                return False
            db.execute("DELETE FROM queue WHERE id=?", (oldest_activity[0],))
        db.execute(
            "INSERT INTO queue(handle,run_generation,kind,payload,operation_id,claim_id,"
            "observed_at,sequence,created_at) VALUES(?,?,?,?,?,?,?,?,?)",
            (handle, run_generation, kind,
             json.dumps(payload, sort_keys=True, separators=(",", ":")), operation_id,
             claim_id, _stamp(observed_at) if observed_at else None, sequence, _stamp(created_at)),
        )
        return True

    def enqueue_activity(self, handle: str, run_generation: str, claim_id: str,
                         sequence: int, observed_at: datetime, operation_id: str, *,
                         created_at: datetime | None = None) -> bool:
        _opaque(operation_id, "operation_id")
        with self._immediate() as db:
            execution = db.execute(
                "SELECT run_generation,state,latest_end_operation_id,backend_session_id "
                "FROM executions WHERE handle=?", (handle,)
            ).fetchone()
            if execution is None:
                raise BridgeError(404, "unknown work handle")
            if execution[0] != run_generation:
                raise BridgeError(409, "queued event belongs to another run generation")
            if execution[1] == "ended" or execution[2] is not None:
                return False
            owner = db.execute(
                "SELECT 1 FROM claims WHERE handle=? AND claim_id=? AND run_generation=? AND active=1",
                (handle, claim_id, run_generation),
            ).fetchone()
            if owner is None:
                return False
            payload = {
                "work_session_id": execution[3], "claim_id": claim_id,
                "observed_at": _stamp(observed_at), "sequence": sequence,
            }
            return self._admit_queue(
                db, handle, run_generation, "activity", payload, operation_id,
                claim_id, observed_at, sequence, created_at or observed_at,
            )

    def maybe_enqueue_activity(self, handle: str, run_generation: str, observed_at: datetime,
                               operation_id: str, *, force: bool = False) -> int | None:
        with self._immediate() as db:
            execution = db.execute(
                "SELECT run_generation,state,latest_end_operation_id,backend_session_id,last_activity_at "
                "FROM executions WHERE handle=?", (handle,)
            ).fetchone()
            if execution is None:
                raise BridgeError(404, "unknown work handle")
            if execution[0] != run_generation or execution[1] == "ended" or execution[2] is not None:
                return None
            claim = db.execute(
                "SELECT claim_id FROM claims WHERE handle=? AND run_generation=? AND active=1",
                (handle, run_generation),
            ).fetchone()
            if claim is None or execution[3] is None:
                return None
            last = _parse(execution[4]) if execution[4] else None
            if not force and last is not None and _utc(observed_at) < last + timedelta(seconds=60):
                return None
            db.execute(
                "UPDATE executions SET sequence=sequence+1,last_activity_at=?,updated_at=? WHERE handle=?",
                (_stamp(observed_at), _stamp(observed_at), handle),
            )
            sequence = db.execute(
                "SELECT sequence FROM executions WHERE handle=?", (handle,)
            ).fetchone()[0]
            payload = {
                "work_session_id": execution[3], "claim_id": claim[0],
                "observed_at": _stamp(observed_at), "sequence": sequence,
            }
            admitted = self._admit_queue(
                db, handle, run_generation, "activity", payload, operation_id,
                claim[0], observed_at, sequence, observed_at,
            )
            return sequence if admitted else None

    def persist_release_intent(self, handle: str, run_generation: str, claim_id: str,
                               operation_id: str, handoff: str, reason: str,
                               observed_at: datetime, *, feedback_target: str | None = None,
                               swimlane: str | None = None) -> bool:
        if reason not in {"paused", "feedback", "stopped"}:
            raise BridgeError(422, "invalid release reason")
        payload = {
            "handoff": handoff, "reason": reason,
            "feedback_target": feedback_target, "swimlane": swimlane,
        }
        with self._immediate() as db:
            return self._persist_release_intent(
                db, handle, run_generation, claim_id, operation_id, payload, observed_at
            )

    def _persist_release_intent(self, db, handle: str, run_generation: str, claim_id: str,
                                operation_id: str, payload: dict,
                                observed_at: datetime) -> bool:
        execution = db.execute(
            "SELECT run_generation,backend_session_id FROM executions WHERE handle=?", (handle,)
        ).fetchone()
        claim = db.execute(
            "SELECT run_generation FROM claims WHERE handle=? AND claim_id=?",
            (handle, claim_id),
        ).fetchone()
        if execution is None:
            raise BridgeError(404, "unknown work handle")
        if execution[0] != run_generation or claim is None or claim[0] != run_generation:
            raise BridgeError(409, "release intent belongs to another run generation or claim")
        db.execute(
            "UPDATE claims SET handoff=?,latest_release_operation_id=?,latest_release_payload=?,"
            "release_intent_created_at=?,release_delivered_at=NULL,updated_at=? WHERE claim_id=?",
            (payload["handoff"], operation_id,
             json.dumps(payload, sort_keys=True, separators=(",", ":")),
             _stamp(observed_at), _stamp(observed_at), claim_id),
        )
        wire = {**payload, "work_session_id": execution[1], "claim_id": claim_id}
        return self._admit_queue(
            db, handle, run_generation, "release", wire, operation_id,
            claim_id, observed_at, None, observed_at,
        )

    def persist_end_intent(self, handle: str, run_generation: str, operation_id: str,
                           handoff: str | None, observed_at: datetime,
                           claim_id: str | None = None) -> bool:
        payload = {"handoff": handoff}
        with self._immediate() as db:
            return self._persist_end_intent(
                db, handle, run_generation, operation_id, payload, observed_at, claim_id
            )

    def _persist_end_intent(self, db, handle: str, run_generation: str, operation_id: str,
                            payload: dict, observed_at: datetime,
                            claim_id: str | None) -> bool:
        execution = db.execute(
            "SELECT run_generation,backend_session_id FROM executions WHERE handle=?", (handle,)
        ).fetchone()
        if execution is None:
            raise BridgeError(404, "unknown work handle")
        if execution[0] != run_generation:
            raise BridgeError(409, "end intent belongs to another run generation")
        if claim_id is not None and db.execute(
            "SELECT 1 FROM claims WHERE handle=? AND run_generation=? AND claim_id=?",
            (handle, run_generation, claim_id),
        ).fetchone() is None:
            raise BridgeError(409, "end intent claim belongs to another run generation")
        db.execute(
            "UPDATE executions SET state='ended',ended_at=?,end_handoff=?,"
            "latest_end_operation_id=?,latest_end_payload=?,latest_end_claim_id=?,end_intent_created_at=?,"
            "end_delivered_at=NULL,updated_at=? WHERE handle=?",
            (_stamp(observed_at), payload["handoff"], operation_id,
             json.dumps(payload, sort_keys=True, separators=(",", ":")),
             claim_id, _stamp(observed_at), _stamp(observed_at), handle),
        )
        db.execute(
            "UPDATE tool_operations SET active=0,latest_native_event_at=? "
            "WHERE handle=? AND run_generation=? AND active=1",
            (_stamp(observed_at), handle, run_generation),
        )
        db.execute(
            "DELETE FROM queue WHERE handle=? AND run_generation=? AND kind='activity'",
            (handle, run_generation),
        )
        wire = {**payload, "work_session_id": execution[1]}
        return self._admit_queue(
            db, handle, run_generation, "end", wire, operation_id,
            claim_id, observed_at, None, observed_at,
        )

    def ingest_critical_native_event(self, harness: str, native_event_id: str,
                                     event_name: str, handle: str, run_generation: str,
                                     operation_id: str, observed_at: datetime,
                                     default_handoff: str) -> dict:
        """Atomically journal stop/end together with their durable local intent."""
        if event_name not in {"stop", "end"}:
            raise BridgeError(422, "critical native event must be stop or end")
        with self._immediate() as db:
            journal = db.execute(
                "SELECT event_name,handle,run_generation,state,result FROM native_events "
                "WHERE harness=? AND native_event_id=?", (harness, native_event_id),
            ).fetchone()
            if journal is not None:
                if (journal[0] != event_name or journal[1] != handle
                        or journal[2] != run_generation):
                    raise BridgeError(409, "native_event_id was reused for another event")
                if journal[3] == "done" and journal[4] is not None:
                    return json.loads(journal[4])
            else:
                db.execute(
                    "INSERT INTO native_events(harness,native_event_id,event_name,handle,run_generation,"
                    "state,created_at) VALUES(?,?,?,?,?,'processing',?)",
                    (harness, native_event_id, event_name, handle, run_generation,
                     _stamp(observed_at)),
                )
            execution = db.execute(
                "SELECT harness,run_generation,state,latest_end_operation_id "
                "FROM executions WHERE handle=?", (handle,),
            ).fetchone()
            if execution is None or execution[0] != harness or execution[1] != run_generation:
                result = {"status": "dropped_old_generation", "handle": handle,
                          "run_generation": run_generation}
            elif execution[2] == "ended" or execution[3] is not None:
                if event_name == "end" and execution[3] == operation_id:
                    result = {"status": "observed", "handle": handle,
                              "run_generation": run_generation,
                              "operation_id": operation_id}
                else:
                    result = {"status": "dropped_ended_generation", "handle": handle,
                              "run_generation": run_generation}
            else:
                claim = db.execute(
                    "SELECT claim_id,checkpoint FROM claims WHERE handle=? "
                    "AND run_generation=? AND active=1",
                    (handle, run_generation),
                ).fetchone()
                handoff = (claim[1] if claim else None) or default_handoff
                if event_name == "stop":
                    db.execute(
                        "UPDATE tool_operations SET active=0,latest_native_event_at=? "
                        "WHERE handle=? AND run_generation=? AND active=1",
                        (_stamp(observed_at), handle, run_generation),
                    )
                    if claim is not None:
                        self._persist_release_intent(
                            db, handle, run_generation, claim[0], operation_id,
                            {"handoff": handoff, "reason": "stopped",
                             "feedback_target": None, "swimlane": None},
                            observed_at,
                        )
                        recorded_operation = operation_id
                    else:
                        recorded_operation = None
                else:
                    self._persist_end_intent(
                        db, handle, run_generation, operation_id, {"handoff": handoff},
                        observed_at, claim[0] if claim else None,
                    )
                    recorded_operation = operation_id
                result = {"status": "observed", "handle": handle,
                          "run_generation": run_generation,
                          "operation_id": recorded_operation}
            db.execute(
                "UPDATE native_events SET state='done',result=?,completed_at=? "
                "WHERE harness=? AND native_event_id=?",
                (json.dumps(result, sort_keys=True, separators=(",", ":")),
                 _stamp(observed_at), harness, native_event_id),
            )
        return result

    def begin_native_event(self, harness: str, native_event_id: str, event_name: str,
                           handle: str | None, run_generation: str | None,
                           observed_at: datetime) -> dict | None:
        for value, name in ((harness, "harness"), (native_event_id, "native_event_id"),
                            (event_name, "event_name")):
            _opaque(value, name)
        try:
            with self._immediate() as db:
                db.execute(
                    "INSERT INTO native_events(harness,native_event_id,event_name,handle,run_generation,"
                    "state,created_at) VALUES(?,?,?,?,?,'processing',?)",
                    (harness, native_event_id, event_name, handle, run_generation,
                     _stamp(observed_at)),
                )
            return None
        except sqlite3.IntegrityError:
            row = self._connection.execute(
                "SELECT event_name,handle,run_generation,state,result FROM native_events "
                "WHERE harness=? AND native_event_id=?", (harness, native_event_id),
            ).fetchone()
            if row is None or row[0] != event_name:
                raise BridgeError(409, "native_event_id was reused for another event") from None
            if handle is not None and row[1] is not None and row[1] != handle:
                raise BridgeError(409, "native_event_id was reused for another handle") from None
            if run_generation is not None and row[2] is not None and row[2] != run_generation:
                raise BridgeError(409, "native_event_id was reused for another generation") from None
            if row[3] != "done" or row[4] is None:
                return None
            return json.loads(row[4])

    def finish_native_event(self, harness: str, native_event_id: str, result: dict,
                            completed_at: datetime | None = None):
        encoded = json.dumps(result, sort_keys=True, separators=(",", ":"))
        with self._immediate() as db:
            if db.execute(
                "UPDATE native_events SET state='done',result=?,completed_at=? "
                "WHERE harness=? AND native_event_id=?",
                (encoded, _stamp(completed_at), harness, native_event_id),
            ).rowcount != 1:
                raise BridgeError(404, "native event reservation is missing")

    def native_event(self, harness: str, native_event_id: str) -> dict | None:
        row = self._connection.execute(
            "SELECT event_name,handle,run_generation,state,result,created_at,completed_at "
            "FROM native_events WHERE harness=? AND native_event_id=?",
            (harness, native_event_id),
        ).fetchone()
        if row is None:
            return None
        return {
            "event_name": row[0], "handle": row[1], "run_generation": row[2],
            "state": row[3], "result": json.loads(row[4]) if row[4] else None,
            "created_at": _parse(row[5]),
            "completed_at": _parse(row[6]) if row[6] else None,
        }

    def abandon_native_event(self, harness: str, native_event_id: str):
        with self._immediate() as db:
            db.execute(
                "DELETE FROM native_events WHERE harness=? AND native_event_id=? AND state='processing'",
                (harness, native_event_id),
            )

    def start_tool_operation(self, handle: str, run_generation: str, native_call_id: str,
                             observed_at: datetime, activity_operation_id: str) -> int | None:
        _opaque(native_call_id, "native_call_id")
        execution = self.get_execution(handle)
        if execution is None:
            raise BridgeError(404, "unknown work handle")
        if execution.run_generation != run_generation:
            return None
        claim = self.active_claim(handle)
        with self._immediate() as db:
            inserted = db.execute(
                "INSERT OR IGNORE INTO tool_operations(handle,run_generation,native_call_id,claim_id,active,"
                "started_at,latest_native_event_at) VALUES(?,?,?,?,1,?,?)",
                (handle, run_generation, native_call_id, (claim or {}).get("id"),
                 _stamp(observed_at), _stamp(observed_at)),
            ).rowcount
        if inserted != 1:
            return None
        return self.maybe_enqueue_activity(
            handle, run_generation, observed_at, activity_operation_id
        )

    def finish_tool_operation(self, handle: str, run_generation: str, native_call_id: str,
                              observed_at: datetime, activity_operation_id: str) -> int | None:
        _opaque(native_call_id, "native_call_id")
        with self._immediate() as db:
            changed = db.execute(
                "UPDATE tool_operations SET active=0,latest_native_event_at=? "
                "WHERE handle=? AND run_generation=? AND native_call_id=? AND active=1",
                (_stamp(observed_at), handle, run_generation, native_call_id),
            ).rowcount
        if changed != 1:
            return None
        return self.maybe_enqueue_activity(
            handle, run_generation, observed_at, activity_operation_id
        )

    def close_tool_operations(self, handle: str, run_generation: str, observed_at: datetime):
        with self._immediate() as db:
            db.execute(
                "UPDATE tool_operations SET active=0,latest_native_event_at=? "
                "WHERE handle=? AND run_generation=? AND active=1",
                (_stamp(observed_at), handle, run_generation),
            )

    def tool_operation(self, handle: str, native_call_id: str) -> dict | None:
        row = self._connection.execute(
            "SELECT run_generation,claim_id,active,started_at,latest_native_event_at,last_activity_at "
            "FROM tool_operations WHERE handle=? AND native_call_id=?",
            (handle, native_call_id),
        ).fetchone()
        if row is None:
            return None
        return {
            "run_generation": row[0], "claim_id": row[1], "active": bool(row[2]),
            "started_at": _parse(row[3]), "latest_native_event_at": _parse(row[4]),
            "last_activity_at": _parse(row[5]) if row[5] else None,
        }

    def mark_tool_activity(self, handle: str, run_generation: str, native_call_id: str,
                           observed_at: datetime):
        with self._immediate() as db:
            db.execute(
                "UPDATE tool_operations SET last_activity_at=? WHERE handle=? AND run_generation=? "
                "AND native_call_id=? AND active=1",
                (_stamp(observed_at), handle, run_generation, native_call_id),
            )

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
            prior = db.execute(
                "SELECT claim_id FROM claims WHERE handle=? AND active=1", (handle,)
            ).fetchone()
            db.execute("UPDATE claims SET active=0,updated_at=? WHERE handle=? AND active=1", (_stamp(), handle))
            db.execute(
                "INSERT INTO claims(claim_id,handle,run_generation,ticket_ref,ticket_id,active,updated_at) "
                "VALUES(?,?,?,?,?,1,?) "
                "ON CONFLICT(claim_id) DO UPDATE SET handle=excluded.handle,ticket_ref=excluded.ticket_ref,"
                "run_generation=excluded.run_generation,ticket_id=excluded.ticket_id,active=1,updated_at=excluded.updated_at",
                (claim_id, handle, generation[0], ticket_ref, ticket_id, _stamp()),
            )
            if prior is None or prior[0] != claim_id:
                db.execute("UPDATE executions SET last_activity_at=NULL WHERE handle=?", (handle,))

    def active_claim(self, handle: str) -> dict | None:
        row = self._connection.execute(
            "SELECT claim_id,ticket_ref,ticket_id,checkpoint,handoff,run_generation "
            "FROM claims WHERE handle=? AND active=1", (handle,)
        ).fetchone()
        return None if row is None else {
            "id": row[0], "ticket": row[1], "ticket_id": row[2],
            "checkpoint": row[3], "handoff": row[4], "run_generation": row[5],
        }

    def claim(self, handle: str, claim_id: str) -> dict | None:
        row = self._connection.execute(
            "SELECT claim_id,ticket_ref,ticket_id,active,latest_release_operation_id,"
            "latest_release_payload,release_intent_created_at,release_delivered_at "
            "FROM claims WHERE handle=? AND claim_id=?",
            (handle, claim_id),
        ).fetchone()
        return None if row is None else {
            "id": row[0], "ticket": row[1], "ticket_id": row[2], "active": bool(row[3]),
            "latest_release_operation_id": row[4],
            "latest_release_payload": json.loads(row[5]) if row[5] else None,
            "release_intent_created_at": _parse(row[6]) if row[6] else None,
            "release_delivered_at": _parse(row[7]) if row[7] else None,
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
            locked_execution = db.execute(
                "SELECT latest_end_operation_id,ended_at FROM executions WHERE handle=?",
                (handle,),
            ).fetchone()
            if locked_execution is None:
                raise BridgeError(404, "unknown work handle")
            prior_claim = db.execute(
                "SELECT claim_id FROM claims WHERE handle=? AND active=1", (handle,)
            ).fetchone()
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
            prior_claim_id = prior_claim[0] if prior_claim else None
            current_claim_id = active[0] if active else None
            if prior_claim_id != current_claim_id:
                db.execute("UPDATE executions SET last_activity_at=NULL WHERE handle=?", (handle,))
            state = "ended" if session.get("ended_at") is not None or locked_execution[0] else "bound"
            fields = ("backend_session_id=?,label=?,repo=?,lifecycle_capable=?,state=?,cache_trusted=1,"
                      "ended_at=?,updated_at=?")
            values = [session_id, label, repo, int(session["lifecycle_capable"]), state,
                      locked_execution[1] or (
                          _stamp() if state == "ended" else None
                      ), _stamp()]
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
            claim = {
                "id": claim["id"], "ticket": claim["ticket"],
                **({"ticket_id": claim["ticket_id"]} if claim.get("ticket_id") else {}),
            }
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
                "SELECT run_generation,state,latest_end_operation_id FROM executions WHERE handle=?",
                (event.handle,)
            ).fetchone()
            if generation is None:
                raise BridgeError(404, "unknown work handle")
            if generation[0] != event.run_generation:
                raise BridgeError(409, "queued event belongs to another run generation")
            if event.kind == "activity" and (
                generation[1] == "ended" or generation[2] is not None or db.execute(
                    "SELECT 1 FROM queue WHERE handle=? AND run_generation=? "
                    "AND kind IN ('end','end_session') LIMIT 1",
                    (event.handle, event.run_generation),
                ).fetchone() is not None
            ):
                return
            if event.kind in {"end", "end_session"}:
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
            db.execute(
                "INSERT INTO queue(handle,run_generation,kind,payload,created_at) VALUES(?,?,?,?,?)",
                (event.handle, event.run_generation, event.kind, event.payload,
                 _stamp(event.created_at)),
            )

    @staticmethod
    def _queue_row(row) -> QueueRow:
        payload = json.loads(row[4])
        kind = {"release": "release_ticket", "end": "end_session"}.get(row[3], row[3])
        return QueueRow(
            row_id=row[0], handle=row[1], run_generation=row[2], kind=kind,
            payload=payload, operation_id=row[5], claim_id=row[6],
            observed_at=_parse(row[7]) if row[7] else None, sequence=row[8],
            attempts=row[9], last_error_class=row[10], claim_token=row[11],
        )

    def pending_queue(self, handle: str | None = None) -> list[QueueRow]:
        query = (
            "SELECT id,handle,run_generation,kind,payload,operation_id,claim_id,observed_at,"
            "sequence,attempts,last_error_class,claim_token FROM queue"
        )
        params = ()
        if handle is not None:
            query += " WHERE handle=?"
            params = (handle,)
        query += " ORDER BY id"
        return [self._queue_row(row) for row in self._connection.execute(query, params)]

    def queue_count(self) -> int:
        return self._connection.execute("SELECT count(*) FROM queue").fetchone()[0]

    def clear_queue(self):
        with self._immediate() as db:
            db.execute("DELETE FROM queue")

    def claim_queue_row(self, now: datetime) -> QueueRow | None:
        token = str(uuid4())
        stale = _stamp(_utc(now) - timedelta(seconds=60))
        with self._immediate() as db:
            row = db.execute(
                "SELECT id FROM queue WHERE claim_token IS NULL OR claimed_at<? ORDER BY id LIMIT 1",
                (stale,),
            ).fetchone()
            if row is None:
                return None
            if db.execute(
                "UPDATE queue SET claim_token=?,claimed_at=? WHERE id=? "
                "AND (claim_token IS NULL OR claimed_at<?)",
                (token, _stamp(now), row[0], stale),
            ).rowcount != 1:
                return None
            claimed = db.execute(
                "SELECT id,handle,run_generation,kind,payload,operation_id,claim_id,observed_at,"
                "sequence,attempts,last_error_class,claim_token FROM queue WHERE id=?", (row[0],)
            ).fetchone()
        return self._queue_row(claimed)

    def finish_queue_row(self, row: QueueRow, *, success: bool,
                         error_class: str | None = None):
        with self._immediate() as db:
            if success:
                db.execute(
                    "DELETE FROM queue WHERE id=? AND claim_token=?", (row.row_id, row.claim_token)
                )
                return
            error = (error_class or "DeliveryError")[:100]
            db.execute(
                "UPDATE queue SET attempts=attempts+1,last_error_class=?,claim_token=NULL,claimed_at=NULL "
                "WHERE id=? AND claim_token=?", (error, row.row_id, row.claim_token),
            )

    def reconstruct_intents(self, now: datetime) -> int:
        inserted = 0
        with self._immediate() as db:
            releases = db.execute(
                "SELECT c.handle,c.run_generation,c.claim_id,c.latest_release_operation_id,"
                "c.latest_release_payload,e.backend_session_id,c.release_intent_created_at "
                "FROM claims c JOIN executions e ON e.handle=c.handle "
                "WHERE c.latest_release_operation_id IS NOT NULL AND c.release_delivered_at IS NULL "
                "ORDER BY c.release_intent_created_at,c.claim_id"
            ).fetchall()
            for handle, generation, claim_id, operation_id, payload, session_id, created in releases:
                wire = json.loads(payload)
                wire.update({"work_session_id": session_id, "claim_id": claim_id})
                if self._admit_queue(
                    db, handle, generation, "release", wire, operation_id, claim_id,
                    _parse(created), None, _parse(created),
                ):
                    inserted += 1
            ends = db.execute(
                "SELECT handle,run_generation,latest_end_operation_id,latest_end_payload,latest_end_claim_id,"
                "backend_session_id,end_intent_created_at FROM executions "
                "WHERE latest_end_operation_id IS NOT NULL AND end_delivered_at IS NULL "
                "ORDER BY end_intent_created_at,handle"
            ).fetchall()
            for handle, generation, operation_id, payload, claim_id, session_id, created in ends:
                wire = json.loads(payload)
                wire["work_session_id"] = session_id
                if self._admit_queue(
                    db, handle, generation, "end", wire, operation_id, claim_id,
                    _parse(created), None, _parse(created),
                ):
                    inserted += 1
        return inserted

    def execution_intent(self, handle: str) -> dict:
        row = self._connection.execute(
            "SELECT latest_end_operation_id,latest_end_payload,latest_end_claim_id,"
            "end_intent_created_at,end_delivered_at "
            "FROM executions WHERE handle=?", (handle,)
        ).fetchone()
        if row is None:
            raise BridgeError(404, "unknown work handle")
        return {
            "latest_end_operation_id": row[0],
            "latest_end_payload": json.loads(row[1]) if row[1] else None,
            "latest_end_claim_id": row[2],
            "end_intent_created_at": _parse(row[3]) if row[3] else None,
            "end_delivered_at": _parse(row[4]) if row[4] else None,
        }

    def mark_intent_delivered(self, row: QueueRow, delivered_at: datetime):
        with self._immediate() as db:
            if row.kind == "release_ticket":
                db.execute(
                    "UPDATE claims SET release_delivered_at=?,latest_release_operation_id=NULL,"
                    "latest_release_payload=NULL,release_intent_created_at=NULL,updated_at=? "
                    "WHERE handle=? AND claim_id=? AND run_generation=? "
                    "AND latest_release_operation_id=?",
                    (_stamp(delivered_at), _stamp(delivered_at), row.handle, row.claim_id,
                     row.run_generation, row.operation_id),
                )
            elif row.kind == "end_session":
                db.execute(
                    "UPDATE executions SET end_delivered_at=?,latest_end_operation_id=NULL,"
                    "latest_end_payload=NULL,latest_end_claim_id=NULL,end_intent_created_at=NULL,updated_at=? "
                    "WHERE handle=? AND run_generation=? AND latest_end_operation_id=?",
                    (_stamp(delivered_at), _stamp(delivered_at), row.handle,
                     row.run_generation, row.operation_id),
                )

    def cleanup(self, now: datetime | None = None):
        cutoff = _stamp(_utc(now) - ENDED_RETENTION)
        permit_cutoff = _stamp(_utc(now) - CONSUMED_PERMIT_RETENTION)
        native_event_cutoff = _stamp(_utc(now) - NATIVE_EVENT_RETENTION)
        with self._immediate() as db:
            db.execute("DELETE FROM permits WHERE consumed_at IS NOT NULL AND consumed_at<?", (permit_cutoff,))
            db.execute(
                "DELETE FROM native_events WHERE state='done' AND completed_at<?",
                (native_event_cutoff,),
            )
            db.execute(
                "DELETE FROM executions WHERE ended_at IS NOT NULL AND ended_at<? "
                "AND latest_end_operation_id IS NULL "
                "AND NOT EXISTS(SELECT 1 FROM claims WHERE claims.handle=executions.handle "
                "AND claims.latest_release_operation_id IS NOT NULL) "
                "AND NOT EXISTS(SELECT 1 FROM queue WHERE queue.handle=executions.handle)", (cutoff,)
            )

    def schema_columns(self) -> list[str]:
        result = []
        for table in ("executions", "permits", "claims", "operations", "queue",
                      "native_events", "tool_operations"):
            result.extend(row[1] for row in self._connection.execute(f"PRAGMA table_info({table})"))
        return result
