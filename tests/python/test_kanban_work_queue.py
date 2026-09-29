import tempfile
import unittest
from datetime import UTC, datetime, timedelta
from pathlib import Path

from lib.kanban_work.events import EventIngestor
from lib.kanban_work.queue import LifecycleQueue
from lib.kanban_work.schema import BridgeError
from lib.kanban_work.store import Store
from tests.python.fake_board import Board


NOW = datetime(2026, 9, 29, 12, tzinfo=UTC)
ROUTES = {
    "register_session": lambda body: ("POST", "/api/work/sessions"),
    "session_activity": lambda body: ("POST", f"/api/work/sessions/{body['work_session_id']}/activity"),
    "release_active": lambda body: ("POST", f"/api/work/sessions/{body['work_session_id']}/release-active"),
    "cancel_stop": lambda body: ("POST", f"/api/work/sessions/{body['work_session_id']}/cancel-stop"),
    "end_session": lambda body: ("POST", f"/api/work/sessions/{body['work_session_id']}/end"),
}


class Clock:
    def __init__(self, value=NOW):
        self.value = value

    def __call__(self):
        return self.value

    def advance(self, **parts):
        self.value += timedelta(**parts)


class BoardTransport:
    """kanban-post's contract, in process: board answers raise with their status."""

    def __init__(self, board: Board):
        self.board = board
        self.unreachable = False
        self.lose_response: set[str] = set()
        self.operations: list[str] = []

    def __call__(self, operation, payload, *, timeout=30):
        self.operations.append(operation)
        if self.unreachable:
            raise BridgeError(502, "cannot reach the board")
        method, path = ROUTES[operation](payload)
        body = {key: value for key, value in payload.items() if key != "work_session_id"}
        status, value = self.board.handle(method, path, body)
        if operation in self.lose_response:
            raise BridgeError(504, "kanban transport timed out")
        if status >= 400:
            raise BridgeError(status, value.get("detail", "error"))
        return value


class QueueTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.clock = Clock()
        self.store = Store(Path(self.temp.name) / "kanban-work.sqlite3", now=self.clock)
        self.board = Board()
        self.transport = BoardTransport(self.board)
        self.queue = LifecycleQueue(self.store, self.transport, now=self.clock)
        self.repo = "aiCodingBaseSetup"
        self.ingress = EventIngestor(self.store, self.queue, now=self.clock,
                                     derive_repo=lambda checkout: self.repo, synchronous=True)

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def start(self, event="start-1"):
        lifecycle = self.ingress.ingest_event("claude", "start", {
            "native_event_id": event, "native_session_id": "native-a", "subagent_id": None,
            "checkout": "/tmp/repo", "lifecycle_capable": True,
        })
        return lifecycle["handle"], lifecycle["run_generation"]

    def event(self, name, handle, generation, event_id):
        return self.ingress.ingest_event("claude", name, {
            "native_event_id": event_id, "handle": handle, "run_generation": generation,
        })

    def session(self, handle):
        return self.board.session_for_handle(handle)

    # -- registration --------------------------------------------------------

    def test_start_registers_synchronously_with_handle_repo_label_and_capability(self):
        handle, generation = self.start()
        session = self.session(handle)
        self.assertEqual((session["repo"], session["label"], session["run_generation"]),
                         (self.repo, "claude session", generation))
        self.assertEqual(self.store.get_execution(handle).work_session_id, session["id"])
        self.assertEqual(self.store.pending_queue(), [])

    def test_unknown_repo_registers_without_one_under_a_distinct_operation(self):
        self.repo = "unlisted"
        handle, _ = self.start()
        self.assertIsNone(self.session(handle)["repo"])
        registers = [call for call in self.board.calls if call[1] == "/api/work/sessions"]
        self.assertEqual(len(registers), 2)
        self.assertNotEqual(registers[0][2]["operation_id"], registers[1][2]["operation_id"])

    def test_start_outside_a_checkout_registers_without_a_repo(self):
        self.repo = None
        handle, _ = self.start()
        self.assertIsNone(self.session(handle)["repo"])

    def test_unreachable_board_queues_registration_and_later_events_wait_for_it(self):
        self.transport.unreachable = True
        handle, generation = self.start()
        self.event("activity", handle, generation, "prompt-1")
        self.assertEqual([row.kind for row in self.queue.pending(handle)], ["register", "activity"])
        self.transport.unreachable = False
        self.assertEqual(self.queue.drain(3000)["delivered"], 2)
        self.assertIsNotNone(self.session(handle))
        self.assertEqual(self.session(handle)["sequence"], 1)

    def test_permanently_rejected_registration_drops_later_rows_without_blocking(self):
        self.board.repos.clear()
        original = self.board._route

        def refuse(method, path, body):
            if path == "/api/work/sessions":
                return 403, {"detail": "Human actors cannot register sessions"}
            return original(method, path, body)

        self.board._route = refuse
        handle, generation = self.start()
        self.event("stop", handle, generation, "stop-1")
        self.assertEqual(self.queue.pending(handle), [])
        self.assertEqual(self.store.unsettled_stops(handle), [])

    # -- activity ------------------------------------------------------------

    def test_activity_renews_without_knowing_the_claim(self):
        handle, generation = self.start()
        claim = self.board.claim(self.session(handle)["id"], "AICODINGBASESETUP-1")
        self.event("activity", handle, generation, "prompt-1")
        self.queue.drain(3000)
        activity = [call for call in self.board.calls if call[1].endswith("/activity")]
        self.assertEqual(len(activity), 1)
        self.assertNotIn("claim_id", activity[0][2])
        self.assertEqual(activity[0][2]["run_generation"], generation)
        self.assertIsNone(claim["released_at"])

    def test_stale_activity_is_dropped_instead_of_sent(self):
        handle, generation = self.start()
        self.event("activity", handle, generation, "prompt-1")
        self.clock.advance(seconds=61)
        self.assertEqual(self.queue.drain(3000)["dropped"], 1)
        self.assertFalse(any(call[1].endswith("/activity") for call in self.board.calls))

    # -- Stop release and the ordering cases of the design ----------------------

    def test_stop_delivered_before_the_next_turn_releases_the_claim(self):
        handle, generation = self.start()
        claim = self.board.claim(self.session(handle)["id"], "AICODINGBASESETUP-1")
        result = self.event("stop", handle, generation, "stop-1")
        self.assertIsNotNone(claim["released_at"])
        self.assertEqual(self.store.stop(result["operation_id"])["outcome"], "applied")
        self.assertTrue(self.ingress.settle_turn(handle))
        self.assertNotIn("cancel_stop", self.transport.operations)

    def test_queued_stop_is_deleted_at_the_next_turn_and_the_claim_stays_live(self):
        handle, generation = self.start()
        claim = self.board.claim(self.session(handle)["id"], "AICODINGBASESETUP-1")
        self.ingress.synchronous = False
        self.event("stop", handle, generation, "stop-1")
        self.ingress.synchronous = True
        self.assertTrue(self.ingress.settle_turn(handle))
        self.assertEqual(self.queue.drain(3000)["delivered"], 0)
        self.assertNotIn("release_active", self.transport.operations)
        self.assertNotIn("cancel_stop", self.transport.operations)
        self.assertIsNone(claim["released_at"])

    def test_timed_out_stop_is_cancelled_and_a_late_retry_leaves_the_replacement_live(self):
        handle, generation = self.start()
        session_id = self.session(handle)["id"]
        first = self.board.claim(session_id, "AICODINGBASESETUP-1")
        self.transport.unreachable = True
        result = self.event("stop", handle, generation, "stop-1")
        self.assertEqual(self.store.stop(result["operation_id"])["state"], "sent")
        self.transport.unreachable = False
        self.assertTrue(self.ingress.settle_turn(handle))
        self.assertEqual(self.store.stop(result["operation_id"])["outcome"], "cancelled")
        first["released_at"] = 1.0
        second = self.board.claim(session_id, "AICODINGBASESETUP-2")
        # The original request arrives late, however far its clock was off.
        for skew in (timedelta(hours=-3), timedelta(hours=3)):
            status, body = self.board.handle(
                "POST", f"/api/work/sessions/{session_id}/release-active",
                {"operation_id": result["operation_id"], "reason": "stopped",
                 "observed_at": (NOW + skew).isoformat()})
            self.assertEqual((status, body), (200, {"stop": "cancelled", "released": None}))
        self.assertIsNone(second["released_at"])
        # The queue never re-sends a settled Stop.
        self.assertEqual(self.queue.drain(3000), {"delivered": 0, "dropped": 0, "retried": 0,
                                                  "pending": 0})

    def test_stop_processed_before_the_cancellation_reports_applied(self):
        handle, generation = self.start()
        claim = self.board.claim(self.session(handle)["id"], "AICODINGBASESETUP-1")
        self.transport.lose_response = {"release_active"}
        result = self.event("stop", handle, generation, "stop-1")
        self.assertIsNotNone(claim["released_at"], "the board applied the Stop")
        self.assertEqual(self.store.stop(result["operation_id"])["state"], "sent")
        self.transport.lose_response = set()
        self.assertTrue(self.ingress.settle_turn(handle))
        self.assertEqual(self.store.stop(result["operation_id"])["outcome"], "applied")

    def test_board_unreachable_at_turn_start_leaves_the_stop_unsettled_until_it_answers(self):
        handle, generation = self.start()
        self.board.claim(self.session(handle)["id"], "AICODINGBASESETUP-1")
        self.transport.unreachable = True
        result = self.event("stop", handle, generation, "stop-1")
        self.assertFalse(self.ingress.settle_turn(handle))
        self.assertEqual(self.store.unsettled_stops(handle),
                         [{"operation_id": result["operation_id"], "state": "sent"}])
        self.transport.unreachable = False
        self.assertTrue(self.ingress.settle_turn(handle))

    def test_stop_retry_after_an_unreachable_board_reuses_its_operation_id(self):
        handle, generation = self.start()
        claim = self.board.claim(self.session(handle)["id"], "AICODINGBASESETUP-1")
        self.transport.unreachable = True
        result = self.event("stop", handle, generation, "stop-1")
        self.transport.unreachable = False
        self.clock.advance(seconds=61)
        self.assertEqual(self.queue.drain(3000)["delivered"], 1)
        self.assertIsNotNone(claim["released_at"])
        stops = [call[2]["operation_id"] for call in self.board.calls
                 if call[1].endswith("/release-active")]
        self.assertEqual(stops, [result["operation_id"]])
        self.assertEqual(self.store.stop(result["operation_id"])["outcome"], "applied")

    def test_end_is_delivered_and_later_events_are_dropped(self):
        handle, generation = self.start()
        claim = self.board.claim(self.session(handle)["id"], "AICODINGBASESETUP-1")
        self.event("end", handle, generation, "end-1")
        self.queue.drain(3000)
        self.assertIsNotNone(claim["released_at"])
        self.assertEqual(self.event("activity", handle, generation, "late")["status"],
                         "dropped_ended_generation")


if __name__ == "__main__":
    unittest.main()
