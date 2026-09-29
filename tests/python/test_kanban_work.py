import sqlite3
import stat
import tempfile
import threading
import unittest
from datetime import UTC, datetime, timedelta
from pathlib import Path
from unittest import mock

from lib.kanban_work.schema import BridgeError, validate_local_handle
from lib.kanban_work.store import MAX_QUEUE_ROWS, Store


HANDLE = "11111111-1111-4111-8111-111111111111"
PEER_HANDLE = "33333333-3333-4333-8333-333333333333"
RUN = "44444444-4444-4444-8444-444444444444"
PEER_RUN = "66666666-6666-4666-8666-666666666666"
NOW = datetime(2026, 9, 29, 12, tzinfo=UTC)

# The registry layout before the hosted MCP: permits, a claim cache and
# bridge receipts beside claim-scoped queue rows.
PERMIT_ERA_SCHEMA = """
CREATE TABLE executions (handle TEXT PRIMARY KEY, identity_key TEXT NOT NULL UNIQUE,
  harness TEXT NOT NULL, native_session_id TEXT NOT NULL, subagent_id TEXT,
  run_generation TEXT NOT NULL, checkout TEXT NOT NULL, lifecycle_capable INTEGER NOT NULL,
  state TEXT NOT NULL, backend_session_id TEXT, label TEXT, repo TEXT,
  sequence INTEGER NOT NULL DEFAULT 0, cache_trusted INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL, ended_at TEXT, end_handoff TEXT,
  latest_end_operation_id TEXT, latest_end_payload TEXT, latest_end_claim_id TEXT,
  end_intent_created_at TEXT, end_delivered_at TEXT, last_activity_at TEXT);
CREATE TABLE permits (id INTEGER PRIMARY KEY AUTOINCREMENT, handle TEXT NOT NULL,
  identity_key TEXT NOT NULL, native_call_id TEXT NOT NULL, run_generation TEXT NOT NULL,
  tool TEXT NOT NULL, digest TEXT NOT NULL, operation_id TEXT NOT NULL,
  created_at TEXT NOT NULL, consumed_at TEXT);
CREATE TABLE claims (claim_id TEXT PRIMARY KEY, handle TEXT NOT NULL, run_generation TEXT NOT NULL,
  ticket_ref TEXT NOT NULL, ticket_id TEXT, active INTEGER NOT NULL, checkpoint TEXT, handoff TEXT,
  latest_release_operation_id TEXT, latest_release_payload TEXT, release_intent_created_at TEXT,
  release_delivered_at TEXT, updated_at TEXT NOT NULL);
CREATE TABLE operations (operation_id TEXT PRIMARY KEY, handle TEXT NOT NULL,
  run_generation TEXT NOT NULL, kind TEXT NOT NULL, digest TEXT NOT NULL, claim_id TEXT,
  state TEXT NOT NULL, last_error_class TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
CREATE TABLE queue (id INTEGER PRIMARY KEY AUTOINCREMENT, handle TEXT NOT NULL,
  run_generation TEXT NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL, operation_id TEXT,
  claim_id TEXT, observed_at TEXT, sequence INTEGER, attempts INTEGER NOT NULL DEFAULT 0,
  last_error_class TEXT, claim_token TEXT, claimed_at TEXT, created_at TEXT NOT NULL);
CREATE TABLE native_events (harness TEXT NOT NULL, native_event_id TEXT NOT NULL,
  event_name TEXT NOT NULL, handle TEXT, run_generation TEXT, state TEXT NOT NULL, result TEXT,
  created_at TEXT NOT NULL, completed_at TEXT, PRIMARY KEY(harness,native_event_id));
CREATE TABLE tool_operations (handle TEXT NOT NULL, run_generation TEXT NOT NULL,
  native_call_id TEXT NOT NULL, claim_id TEXT, active INTEGER NOT NULL, started_at TEXT NOT NULL,
  latest_native_event_at TEXT NOT NULL, last_activity_at TEXT,
  PRIMARY KEY(handle,run_generation,native_call_id));
"""


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "state" / "aicoding" / "kanban-work.sqlite3"
        self.store = Store(self.path, now=lambda: NOW)
        self.store.start_execution("codex", "thread-7", None, RUN, HANDLE, "/tmp/repo", True,
                                   repo="aiCodingBaseSetup", label="codex session", now=NOW)

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def kinds(self, handle=HANDLE):
        return [row.kind for row in self.store.pending_queue(handle)]

    def test_handles_must_be_canonical_uuids(self):
        self.assertEqual(validate_local_handle(HANDLE), HANDLE)
        for bad in ("not-a-uuid", "AAAAAAAA-1111-4111-8111-111111111111", "", "x" * 400, None):
            with self.assertRaises(BridgeError):
                validate_local_handle(bad)

    def test_modes_and_no_sensitive_columns(self):
        self.assertEqual(stat.S_IMODE(self.path.parent.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)
        columns = set(self.store.schema_columns())
        for forbidden in {"token", "credential", "secret", "headers", "environment", "argv",
                          "stdin", "claim_id", "digest"}:
            self.assertNotIn(forbidden, columns)

    def test_no_permit_claim_or_receipt_tables_exist(self):
        tables = {row[0] for row in self.store._connection.execute(
            "SELECT name FROM sqlite_master WHERE type='table'")}
        self.assertFalse({"permits", "claims", "operations"} & tables)

    def test_activity_is_queued_without_any_claim_and_throttled_per_minute(self):
        self.assertEqual(self.store.maybe_enqueue_activity(HANDLE, RUN, NOW, "a1"), 1)
        self.assertIsNone(self.store.maybe_enqueue_activity(HANDLE, RUN, NOW + timedelta(seconds=59), "a2"))
        self.assertEqual(self.store.maybe_enqueue_activity(HANDLE, RUN, NOW + timedelta(seconds=60), "a3"), 2)
        self.assertEqual(self.kinds(), ["activity", "activity"])
        self.assertEqual(self.store.pending_queue(HANDLE)[0].payload,
                         {"run_generation": RUN, "observed_at": NOW.isoformat(timespec="microseconds"),
                          "sequence": 1})
        self.assertIsNone(self.store.maybe_enqueue_activity(HANDLE, PEER_RUN, NOW + timedelta(minutes=5), "a4"))

    def test_sequence_is_monotonic_across_connections(self):
        values = []
        barrier = threading.Barrier(6)

        def observe(index):
            local = Store(self.path)
            barrier.wait()
            values.append(local.maybe_enqueue_activity(HANDLE, RUN, NOW, f"op-{index}", force=True))
            local.close()

        threads = [threading.Thread(target=observe, args=(index,)) for index in range(6)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.assertEqual(sorted(values), list(range(1, 7)))

    def test_end_drops_unsent_activity_and_blocks_new_activity(self):
        self.store.maybe_enqueue_activity(HANDLE, RUN, NOW, "a1")
        self.store.record_stop(HANDLE, RUN, "stop-1", NOW)
        self.assertTrue(self.store.record_end(HANDLE, RUN, "end-1", NOW))
        self.assertEqual(self.kinds(), ["stop", "end"])
        self.assertTrue(self.store.get_execution(HANDLE).ended)
        self.assertIsNone(self.store.maybe_enqueue_activity(HANDLE, RUN, NOW + timedelta(minutes=2), "a2"))
        self.assertFalse(self.store.record_end(HANDLE, RUN, "end-2", NOW))
        with self.assertRaisesRegex(BridgeError, "another run generation"):
            self.store.record_end(HANDLE, PEER_RUN, "end-3", NOW)

    def test_stop_is_queued_and_claiming_it_marks_it_sent_atomically(self):
        self.store.record_stop(HANDLE, RUN, "stop-1", NOW)
        self.store.record_stop(HANDLE, RUN, "stop-1", NOW)  # same Stop, retried hook
        self.assertEqual(self.store.unsettled_stops(HANDLE), [{"operation_id": "stop-1", "state": "queued"}])
        row = self.store.claim_queue_row(NOW)
        self.assertEqual((row.kind, row.operation_id), ("stop", "stop-1"))
        self.assertEqual(self.store.stop("stop-1")["state"], "sent")
        # A sent Stop is never deleted as unsent, even when its delivery failed.
        self.store.finish_queue_row(row, success=False, error_class="BoardUnavailable")
        self.assertEqual(self.store.delete_unsent_stops(HANDLE), 0)
        self.assertEqual(self.store.sent_stops(HANDLE), ["stop-1"])

    def test_unsent_stop_is_deleted_with_its_queue_row(self):
        self.store.record_stop(HANDLE, RUN, "stop-1", NOW)
        self.assertEqual(self.store.delete_unsent_stops(HANDLE), 1)
        self.assertEqual(self.kinds(), [])
        self.assertEqual(self.store.unsettled_stops(HANDLE), [])
        self.assertIsNone(self.store.claim_queue_row(NOW))

    def test_deleting_and_sending_a_stop_have_exactly_one_winner(self):
        for attempt in range(20):
            operation_id = f"stop-{attempt}"
            self.store.record_stop(HANDLE, RUN, operation_id, NOW)
            other = Store(self.path, now=lambda: NOW)
            outcomes = {}
            barrier = threading.Barrier(2)

            def send():
                barrier.wait()
                outcomes["sent"] = other.claim_queue_row(NOW, handle=HANDLE, kinds=("stop",))

            def delete():
                barrier.wait()
                outcomes["deleted"] = self.store.delete_unsent_stops(HANDLE)

            threads = [threading.Thread(target=send), threading.Thread(target=delete)]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join()
            sent = outcomes["sent"] is not None
            self.assertNotEqual(sent, outcomes["deleted"] == 1)
            if sent:
                self.assertEqual(self.store.stop(operation_id)["state"], "sent")
                other.settle_stop(operation_id, "applied", NOW)
            else:
                self.assertIsNone(self.store.stop(operation_id))
            other.close()

    def test_a_settled_stop_is_never_claimed_for_delivery(self):
        self.store.record_stop(HANDLE, RUN, "stop-1", NOW)
        row = self.store.claim_queue_row(NOW)
        self.store.finish_queue_row(row, success=False)
        self.store.settle_stop("stop-1", "cancelled", NOW)
        self.assertIsNone(self.store.claim_queue_row(NOW + timedelta(minutes=2)))
        self.assertEqual(self.store.stop("stop-1")["outcome"], "cancelled")

    def test_queue_keeps_stops_and_ends_when_full_by_evicting_activity(self):
        with self.store._immediate() as db:
            for index in range(MAX_QUEUE_ROWS - 1):
                db.execute("INSERT INTO queue(handle,run_generation,kind,payload,operation_id,created_at) "
                           "VALUES(?,?,'activity','{}',?,?)", (HANDLE, RUN, f"fill-{index}", NOW.isoformat()))
        self.store.record_stop(HANDLE, RUN, "stop-1", NOW)
        self.store.record_stop(HANDLE, RUN, "stop-2", NOW)
        self.assertEqual(self.store.queue_count(), MAX_QUEUE_ROWS)
        self.assertEqual(self.kinds().count("stop"), 2)

    def test_retention_keeps_executions_with_pending_work(self):
        self.store.record_end(HANDLE, RUN, "end-1", NOW - timedelta(days=8))
        self.store.cleanup(NOW)
        self.assertIsNotNone(self.store.get_execution(HANDLE))
        row = self.store.claim_queue_row(NOW)
        self.store.finish_queue_row(row, success=True)
        self.store.cleanup(NOW)
        self.assertIsNone(self.store.get_execution(HANDLE))

    def test_failed_schema_creation_leaves_no_partial_database_and_retry_recovers(self):
        recovery = Path(self.temp.name) / "recovery" / "aicoding" / "kanban-work.sqlite3"
        with mock.patch("sqlite3.connect", side_effect=OSError("disk unavailable")):
            with self.assertRaises(OSError):
                Store(recovery)
        self.assertFalse(recovery.exists())
        recovered = Store(recovery)
        try:
            recovered.start_execution("codex", "thread-7", None, RUN, HANDLE, "/tmp/repo", True)
            self.assertEqual(recovered.get_execution(HANDLE).handle, HANDLE)
        finally:
            recovered.close()


class PermitEraMigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "state" / "aicoding" / "kanban-work.sqlite3"
        self.path.parent.mkdir(parents=True)
        db = sqlite3.connect(self.path)
        db.executescript(PERMIT_ERA_SCHEMA)
        stamp = NOW.isoformat()
        for handle, run, state, backend in ((HANDLE, RUN, "bound", "ws-1"),
                                            (PEER_HANDLE, PEER_RUN, "ended", "ws-2")):
            db.execute(
                "INSERT INTO executions(handle,identity_key,harness,native_session_id,run_generation,"
                "checkout,lifecycle_capable,state,backend_session_id,created_at,updated_at) "
                "VALUES(?,?,?,?,?,?,1,?,?,?,?)",
                (handle, f"key-{handle}", "claude", f"native-{handle}", run, "/tmp/repo",
                 state, backend, stamp, stamp))
        db.execute("INSERT INTO permits(handle,identity_key,native_call_id,run_generation,tool,digest,"
                   "operation_id,created_at) VALUES(?,?,?,?,?,?,?,?)",
                   (HANDLE, "k", "c", RUN, "claim_ticket", "d", "o", stamp))
        for kind, operation in (("activity", "a1"), ("release", "r1"), ("end", "e1")):
            db.execute("INSERT INTO queue(handle,run_generation,kind,payload,operation_id,claim_id,"
                       "created_at) VALUES(?,?,?,?,?,?,?)",
                       (PEER_HANDLE if kind == "end" else HANDLE, PEER_RUN if kind == "end" else RUN,
                        kind, '{"handoff":null,"work_session_id":"ws-2"}', operation, "claim-1", stamp))
        db.commit()
        db.close()

    def tearDown(self):
        self.temp.cleanup()

    def test_upgrade_keeps_sessions_and_pending_ends_and_drops_permit_state(self):
        store = Store(self.path, now=lambda: NOW)
        try:
            tables = {row[0] for row in store._connection.execute(
                "SELECT name FROM sqlite_master WHERE type='table'")}
            self.assertFalse({"permits", "claims", "operations"} & tables)
            self.assertIn("stops", tables)
            live = store.get_execution(HANDLE)
            self.assertEqual((live.state, live.work_session_id), ("active", "ws-1"))
            self.assertTrue(store.get_execution(PEER_HANDLE).ended)
            self.assertEqual([(row.kind, row.operation_id) for row in store.pending_queue()],
                             [("end", "e1")])
            # New rows written after the upgrade survive reopening.
            store.record_stop(HANDLE, RUN, "stop-1", NOW)
        finally:
            store.close()
        reopened = Store(self.path, now=lambda: NOW)
        try:
            self.assertEqual([row.kind for row in reopened.pending_queue()], ["end", "stop"])
        finally:
            reopened.close()


if __name__ == "__main__":
    unittest.main()
