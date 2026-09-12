import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import UTC, datetime, timedelta
from pathlib import Path

from lib.kanban_work.events import EventIngestor
from lib.kanban_work.queue import LifecycleQueue
from lib.kanban_work.schema import BridgeError
from lib.kanban_work.store import MAX_QUEUE_ROWS, NativeIdentity, Store


HANDLE = "11111111-1111-4111-8111-111111111111"
PEER_HANDLE = "33333333-3333-4333-8333-333333333333"
RUN = "44444444-4444-4444-8444-444444444444"
CLAIM = "22222222-2222-4222-8222-222222222222"
SESSION = "55555555-5555-4555-8555-555555555555"
NOW = datetime(2026, 9, 12, 12, tzinfo=UTC)


class Clock:
    def __init__(self, value=NOW):
        self.value = value

    def __call__(self):
        return self.value

    def advance(self, **parts):
        self.value += timedelta(**parts)


def session_snapshot(*, claim=CLAIM, ended=False):
    claims = [] if claim is None else [{
        "id": claim,
        "work_session_id": SESSION,
        "ticket_id": "ticket-2",
        "released_at": None,
        "latest_checkpoint": "Parser implemented.",
        "handoff": None,
    }]
    return {
        "id": SESSION,
        "harness": "codex",
        "native_session_id": "thread-7",
        "subagent_id": None,
        "run_generation": RUN,
        "label": "worker",
        "repo": "aiCodingBaseSetup",
        "lifecycle_capable": True,
        "ended_at": "2026-09-12T12:01:00Z" if ended else None,
        "claims": claims,
    }


def ticket_snapshot(*, claim=CLAIM, status="doing"):
    return {
        "id": "ticket-2",
        "key": "AICODINGBASESETUP-2",
        "title": "Queue lifecycle",
        "status": status,
        "swimlane": "required",
        "position": 1,
        "done_at": None,
        "doing_source": "agent_claim" if claim else None,
        "doing_actor": "worker" if claim else None,
        "work_claim": None if claim is None else {"id": claim},
    }


class FakeTransport:
    def __init__(self):
        self.calls = []
        self.claim = CLAIM
        self.ended = False
        self.fail = set()
        self.during_call = None

    def __call__(self, operation, payload):
        self.calls.append((operation, dict(payload)))
        if self.during_call and operation in {"activity", "release_ticket", "end_session"}:
            self.during_call()
        if operation in self.fail:
            self.fail.remove(operation)
            raise BridgeError(503, "offline")
        if operation == "get_session":
            return session_snapshot(claim=self.claim, ended=self.ended)
        if operation == "get_ticket":
            return ticket_snapshot(claim=self.claim, status="doing" if self.claim else "todo")
        if operation == "release_ticket":
            self.claim = None
            return {"claim": {"id": CLAIM}, "ticket": ticket_snapshot(claim=None, status="todo")}
        if operation == "end_session":
            self.claim = None
            self.ended = True
            return {"session": session_snapshot(claim=None, ended=True), "released": []}
        return {"claim": {"id": CLAIM}, "ticket": ticket_snapshot()}


class QueueTestCase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "state" / "aicoding" / "kanban-work.sqlite3"
        self.store = Store(self.path)
        self.clock = Clock()
        self.transport = FakeTransport()
        self.store.start_execution(
            "codex", "thread-7", None, RUN, HANDLE, "/tmp/repo", True, now=NOW
        )
        self.store.record_bound(HANDLE, SESSION, "aiCodingBaseSetup", "worker")
        self.store.set_claim(HANDLE, CLAIM, "AICODINGBASESETUP-2", "ticket-2")
        self.queue = LifecycleQueue(self.store, self.transport, now=self.clock)
        self.events = EventIngestor(self.store, self.queue, now=self.clock)

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def event(self, name, event_id, **extra):
        payload = {
            "handle": HANDLE,
            "run_generation": RUN,
            "native_event_id": event_id,
            **extra,
        }
        return self.events.ingest_event("codex", name, payload)

    def test_tool_events_allocate_monotonic_activity_once_per_minute_and_deduplicate(self):
        first = self.event("tool_start", "event-1", native_call_id="tool-1")
        duplicate = self.event("tool_start", "event-1", native_call_id="tool-1")
        self.assertEqual(first, duplicate)
        self.assertEqual([row.sequence for row in self.queue.pending()], [1])
        self.clock.advance(seconds=59)
        self.event("tool_success", "event-2", native_call_id="tool-1")
        self.assertEqual([row.sequence for row in self.queue.pending()], [1])
        self.clock.advance(seconds=1)
        self.event("tool_start", "event-3", native_call_id="tool-2")
        self.assertEqual([row.sequence for row in self.queue.pending()], [1, 2])

    def test_old_generation_event_is_dropped_without_retargeting_current_execution(self):
        result = self.events.ingest_event("codex", "tool_start", {
            "handle": HANDLE,
            "run_generation": "old-generation",
            "native_event_id": "late-event",
            "native_call_id": "tool-old",
        })
        self.assertEqual(result["status"], "dropped_old_generation")
        self.assertEqual(self.queue.pending(), [])

    def test_end_dominates_activity_but_preserves_release(self):
        self.event("tool_start", "event-1", native_call_id="tool-1")
        self.event("stop", "event-2")
        self.event("end", "event-3")
        self.event("tool_success", "event-4", native_call_id="tool-1")
        self.assertEqual([row.kind for row in self.queue.pending()],
                         ["release_ticket", "end_session"])
        claim = self.store.claim(HANDLE, CLAIM)
        execution = self.store.execution_intent(HANDLE)
        self.assertIsNotNone(claim["latest_release_operation_id"])
        self.assertIsNotNone(execution["latest_end_operation_id"])

    def test_end_drops_a_late_stop_instead_of_creating_a_new_release_intent(self):
        self.event("end", "event-end")
        self.event("stop", "event-late-stop")
        self.assertIsNone(self.store.claim(HANDLE, CLAIM)["latest_release_operation_id"])
        self.assertEqual([row.kind for row in self.queue.pending()], ["end_session"])

    def test_end_remains_durable_while_earlier_release_receipt_is_refreshed(self):
        self.event("stop", "event-stop")
        self.event("end", "event-end")
        self.assertEqual(self.queue.drain_once(), "delivered")
        self.assertEqual(self.store.get_execution(HANDLE).state, "ended")
        self.event("stop", "event-late-stop")
        self.assertIsNone(self.store.claim(HANDLE, CLAIM)["latest_release_operation_id"])
        self.assertEqual([row.kind for row in self.queue.pending()], ["end_session"])

    def test_replacement_claim_can_enqueue_immediate_activity(self):
        self.event("tool_start", "event-1", native_call_id="tool-1")
        self.store.clear_queue()
        self.clock.advance(seconds=10)
        self.store.set_claim(
            HANDLE, "replacement-claim", "AICODINGBASESETUP-3", "ticket-3"
        )
        self.event("tool_start", "event-2", native_call_id="tool-2")
        self.assertEqual([row.claim_id for row in self.queue.pending()], ["replacement-claim"])

    def test_malformed_local_handle_is_rejected_at_native_ingress(self):
        with self.assertRaisesRegex(BridgeError, "must be a UUID"):
            self.events.ingest_event("codex", "activity", {
                "handle": "not-a-handle", "run_generation": RUN,
                "native_event_id": "bad-handle",
            })

    def test_cleanup_retains_an_unindexed_durable_end_intent(self):
        old = NOW - timedelta(days=8)
        self.store.persist_end_intent(HANDLE, RUN, "undelivered-end", "handoff", old)
        self.store.clear_queue()
        self.store.cleanup(NOW)
        self.assertIsNotNone(self.store.get_execution(HANDLE))

    def test_queue_cap_evicts_oldest_activity_before_critical_rows(self):
        for index in range(MAX_QUEUE_ROWS - 1):
            self.store.enqueue_activity(
                HANDLE, RUN, CLAIM, index + 1, NOW,
                f"activity-{index}", created_at=NOW,
            )
        self.store.persist_release_intent(
            HANDLE, RUN, CLAIM, "release-op", "checkpoint", "stopped", NOW
        )
        self.assertEqual(self.store.queue_count(), MAX_QUEUE_ROWS)
        self.store.start_execution(
            "codex", "thread-peer", None, "peer-generation", PEER_HANDLE,
            "/tmp/repo", True, now=NOW,
        )
        self.store.persist_end_intent(
            PEER_HANDLE, "peer-generation", "end-op", "checkpoint", NOW
        )
        self.assertEqual(self.store.queue_count(), MAX_QUEUE_ROWS)
        rows = self.queue.pending()
        self.assertNotIn("activity-0", [row.operation_id for row in rows])
        self.assertEqual(rows[-2].kind, "release_ticket")
        self.assertEqual(rows[-1].kind, "end_session")

    def test_critical_only_saturation_reconstructs_durable_end_after_capacity_opens(self):
        for index in range(MAX_QUEUE_ROWS):
            handle = f"00000000-0000-4000-8000-{index:012d}"
            generation = f"generation-{index}"
            self.store.start_execution(
                "codex", f"thread-{index}", None, generation, handle, "/tmp/repo", True, now=NOW
            )
            self.store.persist_end_intent(handle, generation, f"end-{index}", None, NOW)
        self.assertEqual(self.store.queue_count(), MAX_QUEUE_ROWS)
        self.store.persist_end_intent(HANDLE, RUN, "latest-end", "handoff", NOW)
        self.assertEqual(self.store.queue_count(), MAX_QUEUE_ROWS)
        self.assertEqual(self.store.execution_intent(HANDLE)["latest_end_operation_id"], "latest-end")

        self.queue.drain_once()
        self.queue.reconstruct()
        self.assertIn((HANDLE, "latest-end"), {
            (row.handle, row.operation_id) for row in self.queue.pending()
        } | set(self.queue.delivered_pairs))

    def test_drain_drops_stale_and_future_activity_before_transport(self):
        self.store.enqueue_activity(HANDLE, RUN, CLAIM, 1, NOW - timedelta(seconds=61), "old", created_at=NOW)
        self.store.enqueue_activity(HANDLE, RUN, CLAIM, 2, NOW + timedelta(seconds=6), "future", created_at=NOW)
        self.queue.drain(1000)
        self.assertNotIn("activity", [operation for operation, _ in self.transport.calls])
        self.assertEqual(self.store.queue_count(), 0)

    def test_offline_delivery_retries_with_same_operation_and_records_only_error_class(self):
        self.store.enqueue_activity(HANDLE, RUN, CLAIM, 1, NOW, "activity-one", created_at=NOW)
        self.transport.fail.add("activity")
        self.queue.drain_once()
        row = self.queue.pending()[0]
        self.assertEqual(row.attempts, 1)
        self.assertEqual(row.last_error_class, "BridgeError")
        self.assertEqual(row.operation_id, "activity-one")
        self.queue.drain_once()
        calls = [payload for operation, payload in self.transport.calls if operation == "activity"]
        self.assertEqual([call["operation_id"] for call in calls], ["activity-one", "activity-one"])

    def test_claim_fencing_drops_activity_for_replacement_claim(self):
        self.store.enqueue_activity(HANDLE, RUN, CLAIM, 1, NOW, "activity-one", created_at=NOW)
        self.store.set_claim(HANDLE, "replacement-claim", "AICODINGBASESETUP-3", "ticket-3")
        self.queue.drain_once()
        self.assertEqual(self.store.queue_count(), 0)
        self.assertNotIn("activity", [operation for operation, _ in self.transport.calls])

    def test_receipt_refreshes_session_and_ticket_before_clearing_release_intent(self):
        self.store.persist_release_intent(
            HANDLE, RUN, CLAIM, "release-op", "checkpoint", "stopped", NOW
        )
        self.transport.fail.add("get_ticket")
        self.queue.drain_once()
        self.assertEqual(self.store.queue_count(), 1)
        self.assertFalse(self.store.get_execution(HANDLE).cache_trusted)
        self.assertEqual(self.store.claim(HANDLE, CLAIM)["latest_release_operation_id"], "release-op")

        self.queue.drain_once()
        self.assertEqual(self.store.queue_count(), 0)
        self.assertIsNone(self.store.claim(HANDLE, CLAIM)["latest_release_operation_id"])
        self.assertEqual([name for name, _ in self.transport.calls[-3:]],
                         ["release_ticket", "get_session", "get_ticket"])

    def test_transport_runs_without_holding_sqlite_write_lock(self):
        self.store.enqueue_activity(HANDLE, RUN, CLAIM, 1, NOW, "activity-one", created_at=NOW)

        def concurrent_write():
            peer = Store(self.path)
            try:
                peer.allocate_sequence(HANDLE)
            finally:
                peer.close()

        self.transport.during_call = concurrent_write
        self.queue.drain_once()
        self.assertEqual(self.store.queue_count(), 0)

    def test_supervisor_is_bounded_by_exact_operation_and_two_hours(self):
        self.event("tool_start", "event-1", native_call_id="tool-1")
        self.store.clear_queue()
        self.clock.advance(seconds=60)
        self.assertTrue(self.queue.supervise_once(HANDLE, "tool-1"))
        self.assertEqual(len(self.queue.pending()), 1)
        self.event("tool_failure", "event-2", native_call_id="tool-1")
        self.store.clear_queue()
        self.clock.advance(seconds=60)
        self.assertFalse(self.queue.supervise_once(HANDLE, "tool-1"))

        self.event("tool_start", "event-3", native_call_id="tool-2")
        self.store.clear_queue()
        self.clock.advance(hours=2, seconds=1)
        self.assertFalse(self.queue.supervise_once(HANDLE, "tool-2"))
        self.assertEqual(self.queue.pending(), [])

    def test_start_mints_new_generation_compaction_reuses_it_and_crash_only_expires(self):
        other_store = Store(Path(self.temp.name) / "other" / "kanban-work.sqlite3")
        try:
            other_queue = LifecycleQueue(other_store, self.transport, now=self.clock)
            ingestor = EventIngestor(other_store, other_queue, now=self.clock)
            started = ingestor.ingest_event("codex", "start", {
                "native_session_id": "new-thread",
                "native_event_id": "start-1",
                "checkout": "/tmp/repo",
                "lifecycle_capable": True,
            })
            compacted = ingestor.ingest_event("codex", "compaction", {
                "handle": started["handle"],
                "run_generation": started["run_generation"],
                "native_event_id": "compact-1",
            })
            self.assertEqual(compacted["run_generation"], started["run_generation"])
            self.assertNotEqual(started["handle"], HANDLE)
            self.assertEqual(other_queue.pending(), [])
            self.clock.advance(minutes=20)
            self.assertEqual(other_queue.pending(), [])
            self.assertNotIn("complete_ticket", [name for name, _ in self.transport.calls])
        finally:
            other_store.close()

    def test_executable_exposes_hook_and_bounded_drain_without_detached_test_processes(self):
        env = {
            **os.environ,
            "XDG_STATE_HOME": str(Path(self.temp.name) / "cli-state"),
            "AICODINGSETUP_SKIP_NETWORK": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
        }
        executable = Path(__file__).resolve().parents[2] / "bin" / "kanban-work"
        started = subprocess.run(
            [sys.executable, str(executable), "hook", "codex", "start"],
            input=json.dumps({
                "native_session_id": "cli-thread", "native_event_id": "cli-start",
                "checkout": "/tmp/repo", "lifecycle_capable": True,
            }),
            text=True, capture_output=True, env=env, timeout=10,
        )
        self.assertEqual(started.returncode, 0, started.stdout + started.stderr)
        envelope = json.loads(started.stdout)
        self.assertTrue(envelope["ok"])
        self.assertEqual(envelope["data"]["status"], "minted")

        drained = subprocess.run(
            [sys.executable, str(executable), "drain", "0"],
            text=True, capture_output=True, env=env, timeout=10,
        )
        self.assertEqual(drained.returncode, 0, drained.stdout + drained.stderr)
        self.assertEqual(json.loads(drained.stdout)["data"]["pending"], 0)


if __name__ == "__main__":
    unittest.main()
