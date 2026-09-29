"""Native execution identity, lifecycle delivery queue and Stop settlement; no claim cache."""

from __future__ import annotations

import json
import os
import sqlite3
import tempfile
import threading
from collections.abc import Callable
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from uuid import UUID, uuid4

from .schema import BridgeError, MAX_OPAQUE, validate_local_handle


ENDED_RETENTION = timedelta(days=7)
NATIVE_EVENT_RETENTION = timedelta(days=7)
ACTIVITY_INTERVAL = timedelta(seconds=60)
QUEUE_CLAIM_STALE = timedelta(seconds=60)
MAX_QUEUE_ROWS = 1024
OPERATION_NAMESPACE = UUID("91f57c8e-a13b-4874-9e20-52abf3eac150")
QUEUE_KINDS = frozenset({"register", "activity", "stop", "end"})
SCHEMA_VERSION = 2


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
    created_at: datetime
    ended_at: datetime | None

    @property
    def identity(self) -> NativeIdentity:
        return NativeIdentity(self.harness, self.native_session_id, self.subagent_id, self.run_generation)

    @property
    def ended(self) -> bool:
        return self.state == "ended"


@dataclass(frozen=True)
class QueueRow:
    row_id: int
    handle: str
    run_generation: str
    kind: str
    payload: dict
    operation_id: str
    observed_at: datetime | None
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
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  ended_at TEXT,
  last_activity_at TEXT
);
CREATE TABLE queue (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  handle TEXT NOT NULL REFERENCES executions(handle) ON DELETE CASCADE,
  run_generation TEXT NOT NULL,
  kind TEXT NOT NULL,
  payload TEXT NOT NULL,
  operation_id TEXT,
  observed_at TEXT,
  attempts INTEGER NOT NULL DEFAULT 0,
  last_error_class TEXT,
  claim_token TEXT,
  claimed_at TEXT,
  created_at TEXT NOT NULL
);
CREATE UNIQUE INDEX queue_operation ON queue(handle,run_generation,kind,operation_id)
  WHERE operation_id IS NOT NULL;
CREATE TABLE stops (
  operation_id TEXT PRIMARY KEY,
  handle TEXT NOT NULL REFERENCES executions(handle) ON DELETE CASCADE,
  run_generation TEXT NOT NULL,
  state TEXT NOT NULL,
  outcome TEXT,
  observed_at TEXT NOT NULL,
  settled_at TEXT
);
CREATE INDEX stops_unsettled ON stops(handle, state);
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
  active INTEGER NOT NULL,
  started_at TEXT NOT NULL,
  latest_native_event_at TEXT NOT NULL,
  last_activity_at TEXT,
  PRIMARY KEY(handle,run_generation,native_call_id)
);
PRAGMA user_version=2;
"""

EXECUTION_COLUMNS = (
    "handle,harness,native_session_id,subagent_id,run_generation,checkout,"
    "lifecycle_capable,state,backend_session_id,label,repo,sequence,created_at,ended_at"
)
QUEUE_COLUMNS = (
    "id,handle,run_generation,kind,payload,operation_id,observed_at,attempts,"
    "last_error_class,claim_token"
)


class Store:
    def __init__(self, path: str | Path | None = None, now: Callable[[], datetime] | None = None):
        self.now = now or (lambda: datetime.now(UTC))
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
        self.cleanup(self.now())

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
        # A permit-era registry keeps its executions and pending session ends;
        # permits, the claim cache and claim-scoped rows mean nothing now.
        with self._immediate() as db:
            if db.execute("PRAGMA user_version").fetchone()[0] >= SCHEMA_VERSION:
                return
            tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            permit_era = bool({"permits", "claims", "operations"} & tables)
            for table in ("permits", "claims", "operations"):
                if table in tables:
                    db.execute(f"DROP TABLE {table}")
            columns = {row[1] for row in db.execute("PRAGMA table_info(queue)")}
            for name, declaration in (("operation_id", "TEXT"), ("observed_at", "TEXT"),
                                      ("attempts", "INTEGER NOT NULL DEFAULT 0"),
                                      ("last_error_class", "TEXT"), ("claim_token", "TEXT"),
                                      ("claimed_at", "TEXT")):
                if name not in columns:
                    db.execute(f"ALTER TABLE queue ADD COLUMN {name} {declaration}")
            execution_columns = {row[1] for row in db.execute("PRAGMA table_info(executions)")}
            if "last_activity_at" not in execution_columns:
                db.execute("ALTER TABLE executions ADD COLUMN last_activity_at TEXT")
            if permit_era:
                db.execute("DELETE FROM queue WHERE kind NOT IN ('end','end_session')")
                db.execute("UPDATE queue SET kind='end',claim_token=NULL,claimed_at=NULL")
                db.execute("UPDATE executions SET state='active' WHERE state!='ended'")
            db.execute(
                "CREATE UNIQUE INDEX IF NOT EXISTS queue_operation "
                "ON queue(handle,run_generation,kind,operation_id) WHERE operation_id IS NOT NULL"
            )
            db.execute(
                "CREATE TABLE IF NOT EXISTS stops (operation_id TEXT PRIMARY KEY,"
                "handle TEXT NOT NULL REFERENCES executions(handle) ON DELETE CASCADE,"
                "run_generation TEXT NOT NULL,state TEXT NOT NULL,outcome TEXT,"
                "observed_at TEXT NOT NULL,settled_at TEXT)"
            )
            db.execute("CREATE INDEX IF NOT EXISTS stops_unsettled ON stops(handle, state)")
            db.execute(
                "CREATE TABLE IF NOT EXISTS native_events ("
                "harness TEXT NOT NULL,native_event_id TEXT NOT NULL,event_name TEXT NOT NULL,"
                "handle TEXT,run_generation TEXT,state TEXT NOT NULL,result TEXT,created_at TEXT NOT NULL,"
                "completed_at TEXT,PRIMARY KEY(harness,native_event_id))"
            )
            db.execute(
                "CREATE TABLE IF NOT EXISTS tool_operations ("
                "handle TEXT NOT NULL REFERENCES executions(handle) ON DELETE CASCADE,"
                "run_generation TEXT NOT NULL,native_call_id TEXT NOT NULL,"
                "active INTEGER NOT NULL,started_at TEXT NOT NULL,latest_native_event_at TEXT NOT NULL,"
                "last_activity_at TEXT,PRIMARY KEY(handle,run_generation,native_call_id))"
            )
            db.execute(f"PRAGMA user_version={SCHEMA_VERSION}")

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

    # --- executions -------------------------------------------------------

    @staticmethod
    def _execution(row) -> Execution | None:
        if row is None:
            return None
        return Execution(
            handle=row[0], harness=row[1], native_session_id=row[2], subagent_id=row[3],
            run_generation=row[4], checkout=row[5], lifecycle_capable=bool(row[6]),
            state="ended" if row[7] == "ended" else "active",
            work_session_id=row[8], label=row[9], repo=row[10], sequence=row[11],
            created_at=_parse(row[12]), ended_at=_parse(row[13]) if row[13] else None,
        )

    def get_execution(self, handle: str) -> Execution | None:
        row = self._connection.execute(
            f"SELECT {EXECUTION_COLUMNS} FROM executions WHERE handle=?", (handle,)
        ).fetchone()
        return self._execution(row)

    def execution_for_identity(self, identity: NativeIdentity) -> Execution | None:
        row = self._connection.execute(
            f"SELECT {EXECUTION_COLUMNS} FROM executions WHERE identity_key=?", (identity.key,)
        ).fetchone()
        return self._execution(row)

    def executions_for_native(self, harness: str, native_session_id: str,
                              subagent_id: str | None) -> list[Execution]:
        """Return generations for one native actor, newest first."""
        _opaque(harness, "harness")
        _opaque(native_session_id, "native_session_id")
        _opaque(subagent_id, "subagent_id", optional=True)
        rows = self._connection.execute(
            f"SELECT {EXECUTION_COLUMNS} FROM executions WHERE harness=? AND native_session_id=? "
            "AND subagent_id IS ? ORDER BY created_at DESC,rowid DESC",
            (harness, native_session_id, subagent_id),
        ).fetchall()
        return [self._execution(row) for row in rows]

    def current_execution(self, harness: str, native_session_id: str,
                          subagent_id: str | None) -> Execution | None:
        """Resolve the current generation for a trusted native ingress event."""
        executions = self.executions_for_native(harness, native_session_id, subagent_id)
        return next((execution for execution in executions if not execution.ended),
                    executions[0] if executions else None)

    def active_child_executions(self, harness: str, native_session_id: str) -> list[Execution]:
        """Return live child actors for one native parent session."""
        _opaque(harness, "harness")
        _opaque(native_session_id, "native_session_id")
        rows = self._connection.execute(
            f"SELECT {EXECUTION_COLUMNS} FROM executions WHERE harness=? AND native_session_id=? "
            "AND subagent_id IS NOT NULL AND state!='ended' ORDER BY created_at,rowid",
            (harness, native_session_id),
        ).fetchall()
        return [self._execution(row) for row in rows]

    def start_execution(self, harness: str, native_session_id: str, subagent_id: str | None,
                        run_generation: str, handle: str, checkout: str,
                        lifecycle_capable: bool, *, repo: str | None = None,
                        label: str | None = None, now: datetime | None = None) -> Execution:
        identity = NativeIdentity(_opaque(harness, "harness"),
                                  _opaque(native_session_id, "native_session_id"),
                                  _opaque(subagent_id, "subagent_id", optional=True),
                                  _opaque(run_generation, "run_generation"))
        validate_local_handle(handle)
        if not isinstance(checkout, str) or not os.path.isabs(checkout):
            raise BridgeError(422, "checkout must be an absolute path")
        if type(lifecycle_capable) is not bool:
            raise BridgeError(422, "lifecycle_capable must be a boolean")
        _opaque(repo, "repo", optional=True)
        _opaque(label, "label", optional=True)
        stamp = _stamp(now)
        try:
            with self._immediate() as db:
                db.execute(
                    "INSERT INTO executions(handle,identity_key,harness,native_session_id,subagent_id,"
                    "run_generation,checkout,lifecycle_capable,state,label,repo,created_at,updated_at) "
                    "VALUES(?,?,?,?,?,?,?,?,'active',?,?,?,?)",
                    (handle, identity.key, harness, native_session_id, subagent_id, run_generation,
                     checkout, int(lifecycle_capable), label, repo, stamp, stamp),
                )
        except sqlite3.IntegrityError:
            existing = self.execution_for_identity(identity)
            if existing and existing.handle == handle:
                return existing
            raise BridgeError(409, "native execution or handle is already registered") from None
        return self.get_execution(handle)

    def record_registered(self, handle: str, work_session_id: str, repo: str | None):
        _opaque(work_session_id, "work_session_id")
        _opaque(repo, "repo", optional=True)
        with self._immediate() as db:
            if db.execute(
                "UPDATE executions SET backend_session_id=?,repo=?,updated_at=? WHERE handle=?",
                (work_session_id, repo, _stamp(), handle),
            ).rowcount != 1:
                raise BridgeError(404, "unknown work handle")

    def has_active_tool_operations(self, handle: str, run_generation: str) -> bool:
        return self._connection.execute(
            "SELECT 1 FROM tool_operations WHERE handle=? AND run_generation=? AND active=1 LIMIT 1",
            (handle, run_generation),
        ).fetchone() is not None

    # --- queue ------------------------------------------------------------

    @staticmethod
    def _admit_queue(db, handle: str, run_generation: str, kind: str, payload: dict,
                     operation_id: str, observed_at: datetime | None,
                     created_at: datetime) -> bool:
        if kind not in QUEUE_KINDS:
            raise BridgeError(422, f"unknown queue kind {kind!r}")
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
            "INSERT INTO queue(handle,run_generation,kind,payload,operation_id,observed_at,created_at) "
            "VALUES(?,?,?,?,?,?,?)",
            (handle, run_generation, kind,
             json.dumps(payload, sort_keys=True, separators=(",", ":")), operation_id,
             _stamp(observed_at) if observed_at else None, _stamp(created_at)),
        )
        return True

    def enqueue_register(self, handle: str, payload: dict, operation_id: str,
                         observed_at: datetime) -> bool:
        with self._immediate() as db:
            execution = db.execute(
                "SELECT run_generation FROM executions WHERE handle=?", (handle,)
            ).fetchone()
            if execution is None:
                raise BridgeError(404, "unknown work handle")
            return self._admit_queue(db, handle, execution[0], "register", payload,
                                     operation_id, observed_at, observed_at)

    def replace_register_payload(self, row: QueueRow, payload: dict, operation_id: str) -> bool:
        """Swap a claimed registration row for a variant; False if it was reclaimed."""
        with self._immediate() as db:
            return db.execute(
                "UPDATE queue SET payload=?,operation_id=? WHERE id=? AND claim_token=?",
                (json.dumps(payload, sort_keys=True, separators=(",", ":")), operation_id,
                 row.row_id, row.claim_token),
            ).rowcount == 1

    def has_pending_register(self, handle: str) -> bool:
        return self._connection.execute(
            "SELECT 1 FROM queue WHERE handle=? AND kind='register' LIMIT 1", (handle,)
        ).fetchone() is not None

    def maybe_enqueue_activity(self, handle: str, run_generation: str, observed_at: datetime,
                               operation_id: str, *, force: bool = False) -> int | None:
        """Queue one session activity observation per interval, claim or not."""
        with self._immediate() as db:
            execution = db.execute(
                "SELECT run_generation,state,last_activity_at FROM executions WHERE handle=?",
                (handle,),
            ).fetchone()
            if execution is None:
                raise BridgeError(404, "unknown work handle")
            if execution[0] != run_generation or execution[1] == "ended":
                return None
            last = _parse(execution[2]) if execution[2] else None
            if not force and last is not None and _utc(observed_at) < last + ACTIVITY_INTERVAL:
                return None
            db.execute(
                "UPDATE executions SET sequence=sequence+1,last_activity_at=?,updated_at=? WHERE handle=?",
                (_stamp(observed_at), _stamp(observed_at), handle),
            )
            sequence = db.execute(
                "SELECT sequence FROM executions WHERE handle=?", (handle,)
            ).fetchone()[0]
            payload = {"run_generation": run_generation, "observed_at": _stamp(observed_at),
                       "sequence": sequence}
            admitted = self._admit_queue(
                db, handle, run_generation, "activity", payload, operation_id,
                observed_at, observed_at,
            )
            return sequence if admitted else None

    def record_stop(self, handle: str, run_generation: str, operation_id: str,
                    observed_at: datetime) -> bool:
        """Journal a Stop and its delivery row in one transaction."""
        _opaque(operation_id, "operation_id")
        payload = {"observed_at": _stamp(observed_at), "reason": "stopped"}
        with self._immediate() as db:
            if db.execute("SELECT 1 FROM stops WHERE operation_id=?", (operation_id,)).fetchone():
                return True
            db.execute(
                "INSERT INTO stops(operation_id,handle,run_generation,state,observed_at) "
                "VALUES(?,?,?,'queued',?)",
                (operation_id, handle, run_generation, _stamp(observed_at)),
            )
            if not self._admit_queue(db, handle, run_generation, "stop", payload,
                                     operation_id, observed_at, observed_at):
                raise BridgeError(503, "lifecycle queue is full")
            return True

    def record_end(self, handle: str, run_generation: str, operation_id: str,
                   observed_at: datetime) -> bool:
        """Mark the execution ended and queue its session end, dropping unsent activity."""
        with self._immediate() as db:
            execution = db.execute(
                "SELECT run_generation,state FROM executions WHERE handle=?", (handle,)
            ).fetchone()
            if execution is None:
                raise BridgeError(404, "unknown work handle")
            if execution[0] != run_generation:
                raise BridgeError(409, "end belongs to another run generation")
            if execution[1] == "ended":
                return False
            db.execute(
                "UPDATE executions SET state='ended',ended_at=?,updated_at=? WHERE handle=?",
                (_stamp(observed_at), _stamp(observed_at), handle),
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
            if not self._admit_queue(db, handle, run_generation, "end", {}, operation_id,
                                     observed_at, observed_at):
                raise BridgeError(503, "lifecycle queue is full")
            return True

    @staticmethod
    def _queue_row(row) -> QueueRow:
        return QueueRow(
            row_id=row[0], handle=row[1], run_generation=row[2], kind=row[3],
            payload=json.loads(row[4]), operation_id=row[5],
            observed_at=_parse(row[6]) if row[6] else None, attempts=row[7],
            last_error_class=row[8], claim_token=row[9],
        )

    def pending_queue(self, handle: str | None = None) -> list[QueueRow]:
        query = f"SELECT {QUEUE_COLUMNS} FROM queue"
        params = ()
        if handle is not None:
            query += " WHERE handle=?"
            params = (handle,)
        query += " ORDER BY id"
        return [self._queue_row(row) for row in self._connection.execute(query, params)]

    def queue_count(self) -> int:
        return self._connection.execute("SELECT count(*) FROM queue").fetchone()[0]

    def claim_queue_row(self, now: datetime, *, handle: str | None = None,
                        kinds: tuple[str, ...] | None = None) -> QueueRow | None:
        """Claim the oldest deliverable row, marking a Stop sent in the same transaction."""
        token = str(uuid4())
        stale = _stamp(_utc(now) - QUEUE_CLAIM_STALE)
        where = "(claim_token IS NULL OR claimed_at<?)"
        params: list = [stale]
        if handle is not None:
            where += " AND handle=?"
            params.append(handle)
        if kinds is not None:
            where += f" AND kind IN ({','.join('?' for _ in kinds)})"
            params.extend(kinds)
        with self._immediate() as db:
            while True:
                row = db.execute(
                    f"SELECT id,kind,operation_id FROM queue WHERE {where} ORDER BY id LIMIT 1", params,
                ).fetchone()
                if row is None:
                    return None
                if row[1] == "stop":
                    stop = db.execute(
                        "SELECT state FROM stops WHERE operation_id=?", (row[2],)
                    ).fetchone()
                    if stop is None or stop[0] == "settled":
                        db.execute("DELETE FROM queue WHERE id=?", (row[0],))
                        continue
                    db.execute("UPDATE stops SET state='sent' WHERE operation_id=?", (row[2],))
                db.execute(
                    "UPDATE queue SET claim_token=?,claimed_at=? WHERE id=?",
                    (token, _stamp(now), row[0]),
                )
                claimed = db.execute(
                    f"SELECT {QUEUE_COLUMNS} FROM queue WHERE id=?", (row[0],)
                ).fetchone()
                return self._queue_row(claimed)

    def finish_queue_row(self, row: QueueRow, *, success: bool,
                         error_class: str | None = None):
        with self._immediate() as db:
            if success:
                db.execute("DELETE FROM queue WHERE id=? AND claim_token=?", (row.row_id, row.claim_token))
                return
            error = (error_class or "DeliveryError")[:100]
            db.execute(
                "UPDATE queue SET attempts=attempts+1,last_error_class=?,claim_token=NULL,claimed_at=NULL "
                "WHERE id=? AND claim_token=?", (error, row.row_id, row.claim_token),
            )

    # --- stop settlement --------------------------------------------------

    def delete_unsent_stops(self, handle: str) -> int:
        """Delete Stops never handed to the transport; the session is active again."""
        with self._immediate() as db:
            ids = [row[0] for row in db.execute(
                "SELECT operation_id FROM stops WHERE handle=? AND state='queued'", (handle,)
            )]
            for operation_id in ids:
                db.execute("DELETE FROM queue WHERE handle=? AND kind='stop' AND operation_id=?",
                           (handle, operation_id))
                db.execute("DELETE FROM stops WHERE operation_id=?", (operation_id,))
            return len(ids)

    def sent_stops(self, handle: str) -> list[str]:
        return [row[0] for row in self._connection.execute(
            "SELECT operation_id FROM stops WHERE handle=? AND state='sent' ORDER BY observed_at",
            (handle,),
        )]

    def unsettled_stops(self, handle: str) -> list[dict]:
        return [{"operation_id": row[0], "state": row[1]} for row in self._connection.execute(
            "SELECT operation_id,state FROM stops WHERE handle=? AND state!='settled' ORDER BY observed_at",
            (handle,),
        )]

    def stop(self, operation_id: str) -> dict | None:
        row = self._connection.execute(
            "SELECT handle,run_generation,state,outcome FROM stops WHERE operation_id=?",
            (operation_id,),
        ).fetchone()
        return None if row is None else {
            "handle": row[0], "run_generation": row[1], "state": row[2], "outcome": row[3],
        }

    def settle_stop(self, operation_id: str, outcome: str, now: datetime | None = None):
        _opaque(outcome, "outcome")
        with self._immediate() as db:
            db.execute(
                "UPDATE stops SET state='settled',outcome=?,settled_at=? "
                "WHERE operation_id=? AND state!='settled'",
                (outcome, _stamp(now), operation_id),
            )
            db.execute("DELETE FROM queue WHERE kind='stop' AND operation_id=?", (operation_id,))

    # --- native events and tool operations --------------------------------

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
        with self._immediate() as db:
            inserted = db.execute(
                "INSERT OR IGNORE INTO tool_operations(handle,run_generation,native_call_id,active,"
                "started_at,latest_native_event_at) VALUES(?,?,?,1,?,?)",
                (handle, run_generation, native_call_id, _stamp(observed_at), _stamp(observed_at)),
            ).rowcount
        if inserted != 1:
            return None
        return self.maybe_enqueue_activity(handle, run_generation, observed_at, activity_operation_id)

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
        return self.maybe_enqueue_activity(handle, run_generation, observed_at, activity_operation_id)

    def close_tool_operations(self, handle: str, run_generation: str, observed_at: datetime):
        with self._immediate() as db:
            db.execute(
                "UPDATE tool_operations SET active=0,latest_native_event_at=? "
                "WHERE handle=? AND run_generation=? AND active=1",
                (_stamp(observed_at), handle, run_generation),
            )

    def tool_operation(self, handle: str, native_call_id: str) -> dict | None:
        row = self._connection.execute(
            "SELECT run_generation,active,started_at,latest_native_event_at,last_activity_at "
            "FROM tool_operations WHERE handle=? AND native_call_id=?",
            (handle, native_call_id),
        ).fetchone()
        if row is None:
            return None
        return {
            "run_generation": row[0], "active": bool(row[1]),
            "started_at": _parse(row[2]), "latest_native_event_at": _parse(row[3]),
            "last_activity_at": _parse(row[4]) if row[4] else None,
        }

    def mark_tool_activity(self, handle: str, run_generation: str, native_call_id: str,
                           observed_at: datetime):
        with self._immediate() as db:
            db.execute(
                "UPDATE tool_operations SET last_activity_at=? WHERE handle=? AND run_generation=? "
                "AND native_call_id=? AND active=1",
                (_stamp(observed_at), handle, run_generation, native_call_id),
            )

    # --- maintenance ------------------------------------------------------

    def cleanup(self, now: datetime | None = None):
        cutoff = _stamp(_utc(now) - ENDED_RETENTION)
        native_event_cutoff = _stamp(_utc(now) - NATIVE_EVENT_RETENTION)
        with self._immediate() as db:
            db.execute(
                "DELETE FROM native_events WHERE state='done' AND completed_at<?",
                (native_event_cutoff,),
            )
            db.execute("DELETE FROM stops WHERE state='settled' AND settled_at<?", (cutoff,))
            db.execute(
                "DELETE FROM executions WHERE ended_at IS NOT NULL AND ended_at<? "
                "AND NOT EXISTS(SELECT 1 FROM queue WHERE queue.handle=executions.handle) "
                "AND NOT EXISTS(SELECT 1 FROM stops WHERE stops.handle=executions.handle "
                "AND stops.state!='settled')", (cutoff,)
            )

    def schema_columns(self) -> list[str]:
        result = []
        for table in ("executions", "queue", "stops", "native_events", "tool_operations"):
            result.extend(row[1] for row in self._connection.execute(f"PRAGMA table_info({table})"))
        return result
