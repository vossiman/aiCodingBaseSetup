import json
import os
import stat
import subprocess
import sqlite3
import tempfile
import threading
import unittest
from datetime import UTC, datetime, timedelta
from pathlib import Path
from unittest import mock
from uuid import UUID

from lib.kanban_work import (
    Bridge,
    BridgeError,
    NativeIdentity,
    QueueEvent,
    Store,
    normalize_tool_args,
    qualified_client_version,
)


HANDLE = "11111111-1111-4111-8111-111111111111"
PEER_HANDLE = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
RUN = "33333333-3333-4333-8333-333333333333"
PEER_RUN = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
SESSION = "backend-session-ref"
CLAIM = "backend-claim-ref"
NOW = datetime(2026, 9, 12, 12, 0, tzinfo=UTC)


def session_snapshot(*, repo="aiCodingBaseSetup", label="worker", claim=None, ended=False):
    claims = []
    if claim:
        claims = [{
            "id": claim,
            "work_session_id": SESSION,
            "ticket_id": "ticket-db-ref",
            "agent": "codex",
            "session_label": label,
            "environment": "test",
            "native_session_id": "thread-7",
            "subagent_id": None,
            "run_generation": RUN,
            "claimed_at": "2026-09-12T12:00:00Z",
            "last_activity_at": "2026-09-12T12:00:00Z",
            "last_renewed_at": "2026-09-12T12:00:00Z",
            "expires_at": "2026-09-12T12:15:00Z",
            "released_at": None,
            "release_reason": None,
            "released_by": None,
            "handoff": None,
            "feedback_target": None,
            "prior_swimlane": "required",
            "latest_checkpoint": None,
            "checkpointed_at": None,
            "completion_evidence": None,
            "references": [],
        }]
    return {
        "id": SESSION,
        "actor": "test",
        "harness": "codex",
        "native_session_id": "thread-7",
        "subagent_id": None,
        "run_generation": RUN,
        "label": label,
        "repo": repo,
        "lifecycle_capable": True,
        "created_at": "2026-09-12T12:00:00Z",
        "ended_at": "2026-09-12T12:01:00Z" if ended else None,
        "claims": claims,
    }


def ticket_snapshot(*, claim=None, key="AICODINGBASESETUP-2", status="todo"):
    return {
        "id": "ticket-db-ref",
        "key": key,
        "title": "Bridge",
        "status": status,
        "swimlane": "required",
        "position": 1,
        "done_at": None,
        "doing_source": "agent" if claim else None,
        "doing_actor": "test" if claim else None,
        "work_claim": None if claim is None else {
            "id": claim,
            "agent": "codex",
            "session_label": "worker",
            "environment": "test",
            "claimed_at": "2026-09-12T12:00:00Z",
            "last_activity_at": "2026-09-12T12:00:00Z",
            "expires_at": "2026-09-12T12:15:00Z",
        },
    }


class FakeTransport:
    def __init__(self):
        self.calls = []
        self.repo = "aiCodingBaseSetup"
        self.label = "worker"
        self.claim = None
        self.ended = False
        self.fail_next = set()
        self.receipts = {}

    def __call__(self, operation, payload):
        self.calls.append((operation, dict(payload)))
        if operation in self.fail_next:
            self.fail_next.remove(operation)
            raise BridgeError(503, f"{operation} refresh unavailable")
        operation_id = payload.get("operation_id")
        if operation_id and (operation, operation_id) in self.receipts:
            return self.receipts[(operation, operation_id)]
        if operation == "register_session":
            result = session_snapshot(repo=self.repo, label=payload["label"])
        elif operation == "get_session":
            result = session_snapshot(
                repo=self.repo, label=self.label, claim=self.claim, ended=self.ended
            )
        elif operation == "get_ticket":
            result = ticket_snapshot(claim=self.claim, status="doing" if self.claim else "todo")
        elif operation == "rebind_session":
            self.repo = payload["repo"]
            if payload.get("label") is not None:
                self.label = payload["label"]
            result = session_snapshot(repo=self.repo, label=self.label)
        elif operation == "claim_ticket":
            if self.claim is not None:
                raise BridgeError(409, "work session already has an active claim")
            self.claim = CLAIM
            result = {"claim": session_snapshot(claim=CLAIM)["claims"][0],
                      "ticket": ticket_snapshot(claim=CLAIM, status="doing")}
        elif operation in {"checkpoint_work", "activity"}:
            result = {"claim": session_snapshot(claim=self.claim)["claims"][0],
                      "ticket": ticket_snapshot(claim=self.claim, status="doing")}
        elif operation in {"release_ticket", "complete_ticket"}:
            prior = self.claim
            self.claim = None
            result = {"claim": {**session_snapshot(claim=prior)["claims"][0],
                                "released_at": "2026-09-12T12:01:00Z"},
                      "ticket": ticket_snapshot(status="done" if operation == "complete_ticket" else "todo")}
        elif operation == "end_session":
            self.ended = True
            self.claim = None
            result = {"session": session_snapshot(ended=True), "released": []}
        else:
            result = {"key": "OTHER-1"} if operation == "create_ticket" else {"ok": True}
        if operation_id:
            self.receipts[(operation, operation_id)] = result
        return result


class SchemaTests(unittest.TestCase):
    def test_every_frozen_tool_shape_receives_exact_defaults(self):
        samples = {
            "bind_work_session": ({"handle": HANDLE},
                {"handle": HANDLE, "label": None, "checkout": None, "operation_id": None}),
            "create_ticket": ({"handle": HANDLE, "title": "Follow-up"},
                {"handle": HANDLE, "checkout": None, "title": "Follow-up", "body": None,
                 "status": None, "priority": None, "swimlane": None, "due_date": None,
                 "operation_id": None}),
            "update_ticket": ({"handle": HANDLE, "ticket": "KANBAN-2"},
                {"handle": HANDLE, "ticket": "KANBAN-2", "fields": {}, "operation_id": None}),
            "add_comment": ({"handle": HANDLE, "ticket": "KANBAN-2", "body": "verified"},
                {"handle": HANDLE, "ticket": "KANBAN-2", "body": "verified", "operation_id": None}),
            "link_tickets": ({"handle": HANDLE, "ticket": "KANBAN-2", "target": "KANBAN-3", "kind": "relates"},
                {"handle": HANDLE, "ticket": "KANBAN-2", "target": "KANBAN-3", "kind": "relates",
                 "operation_id": None}),
            "unlink_tickets": ({"handle": HANDLE, "ticket": "KANBAN-2", "target": "KANBAN-3"},
                {"handle": HANDLE, "ticket": "KANBAN-2", "target": "KANBAN-3", "kind": None,
                 "operation_id": None}),
            "claim_ticket": ({"handle": HANDLE, "ticket": "KANBAN-2"},
                {"handle": HANDLE, "ticket": "KANBAN-2", "operation_id": None}),
            "checkpoint_work": ({"handle": HANDLE, "claim_id": CLAIM, "checkpoint": "parser done"},
                {"handle": HANDLE, "claim_id": CLAIM, "checkpoint": "parser done", "operation_id": None}),
            "release_ticket": ({"handle": HANDLE, "claim_id": CLAIM, "handoff": "tests remain", "reason": "paused"},
                {"handle": HANDLE, "claim_id": CLAIM, "handoff": "tests remain", "reason": "paused",
                 "feedback_target": None, "swimlane": None, "operation_id": None}),
            "complete_ticket": ({"handle": HANDLE, "claim_id": CLAIM, "evidence": "tests pass"},
                {"handle": HANDLE, "claim_id": CLAIM, "evidence": "tests pass", "references": [],
                 "operation_id": None}),
            "end_work_session": ({"handle": HANDLE},
                {"handle": HANDLE, "handoff": None, "operation_id": None}),
        }
        for tool, (raw, expected) in samples.items():
            with self.subTest(tool=tool):
                self.assertEqual(json.loads(normalize_tool_args(tool, raw)), expected)

    def test_exact_defaults_and_sorted_compact_encoding(self):
        self.assertEqual(
            normalize_tool_args("claim_ticket", {"handle": HANDLE, "ticket": "KANBAN-2"}),
            (b'{"handle":"' + HANDLE.encode() +
             b'","operation_id":null,"ticket":"KANBAN-2"}'),
        )
        self.assertEqual(
            json.loads(normalize_tool_args("create_ticket", {
                "handle": HANDLE, "title": "Follow-up"
            })),
            {"handle": HANDLE, "checkout": None, "title": "Follow-up", "body": None,
             "status": None, "priority": None, "swimlane": None, "due_date": None,
             "operation_id": None},
        )

    def test_release_omitted_reason_normalizes_identically_to_explicit_paused(self):
        omitted = {
            "handle": HANDLE, "claim_id": CLAIM, "handoff": "tests remain",
        }
        explicit = {**omitted, "reason": "paused"}
        normalized = normalize_tool_args("release_ticket", omitted)
        self.assertEqual(normalized, normalize_tool_args("release_ticket", explicit))
        self.assertEqual(json.loads(normalized)["reason"], "paused")

    def test_unknown_keys_bad_uuid_bad_enums_and_long_operation_ids_are_rejected(self):
        cases = [
            ("claim_ticket", {"handle": HANDLE, "ticket": "K-1", "native_session_id": "stolen"}),
            ("claim_ticket", {"handle": "not-a-uuid", "ticket": "K-1"}),
            ("link_tickets", {"handle": HANDLE, "ticket": "K-1", "target": "K-2", "kind": "waits"}),
            ("release_ticket", {"handle": HANDLE, "claim_id": CLAIM, "handoff": "x",
                                "reason": "later"}),
            ("claim_ticket", {"handle": HANDLE, "ticket": "K-1", "operation_id": "x" * 301}),
        ]
        for tool, args in cases:
            with self.subTest(tool=tool, args=args), self.assertRaises(BridgeError):
                normalize_tool_args(tool, args)

    def test_client_qualification_is_exact_and_override_is_loopback_test_only(self):
        with tempfile.TemporaryDirectory() as td:
            matrix = Path(td) / "matrix.json"
            matrix.write_text(json.dumps({"codex": ["0.154.0"], "claude": {"versions": ["2.1.268"]}}))
            env = {"AICODING_KANBAN_QUALIFIED_CLIENTS": str(matrix),
                   "KANBAN_URL": "http://127.0.0.1:8123", "KANBAN_TEST_TOKEN": "fake"}
            with mock.patch.dict(os.environ, env, clear=False):
                self.assertTrue(qualified_client_version("codex", "0.154.0"))
                self.assertFalse(qualified_client_version("codex", "0.154.1"))
                self.assertFalse(qualified_client_version("cursor", "0.154.0"))
            for bad_env in (
                {"AICODING_KANBAN_QUALIFIED_CLIENTS": str(matrix), "KANBAN_URL": "https://example.test", "KANBAN_TEST_TOKEN": "fake"},
                {"AICODING_KANBAN_QUALIFIED_CLIENTS": str(matrix), "KANBAN_URL": "http://localhost:1", "KANBAN_TEST_TOKEN": ""},
            ):
                with mock.patch.dict(os.environ, bad_env, clear=False):
                    self.assertFalse(qualified_client_version("codex", "0.154.0"))


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "state" / "aicoding" / "kanban-work.sqlite3"
        self.store = Store(self.path)
        self.identity = NativeIdentity("codex", "thread-7", None, RUN)
        self.store.start_execution("codex", "thread-7", None, RUN, HANDLE, "/tmp/repo", True, now=NOW)

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def test_two_sessions_share_checkout_but_peer_cannot_authorize_handle(self):
        self.store.start_execution("codex", "thread-8", None, PEER_RUN, PEER_HANDLE, "/tmp/repo", True, now=NOW)
        normalized = normalize_tool_args("bind_work_session", {"handle": HANDLE})
        peer = NativeIdentity("codex", "thread-8", None, PEER_RUN)
        with self.assertRaisesRegex(BridgeError, "belongs to another native session"):
            self.store.permit_call(peer, "call-peer", "bind_work_session", normalized, NOW)
        self.assertEqual(self.store.execution_for_identity(peer).handle, PEER_HANDLE)

    def test_permit_digest_one_use_and_fixed_expiry_boundary(self):
        args = normalize_tool_args("claim_ticket", {"handle": HANDLE, "ticket": "K-1"})
        self.store.permit_call(self.identity, "call-1", "claim_ticket", args, NOW)
        with self.assertRaisesRegex(BridgeError, "does not match"):
            self.store.consume_permit(HANDLE, "claim_ticket", normalize_tool_args(
                "claim_ticket", {"handle": HANDLE, "ticket": "K-2"}), NOW)
        self.store.consume_permit(HANDLE, "claim_ticket", args, NOW + timedelta(seconds=59))
        with self.assertRaisesRegex(BridgeError, "missing or already consumed"):
            self.store.consume_permit(HANDLE, "claim_ticket", args, NOW + timedelta(seconds=59))
        self.store.permit_call(self.identity, "call-2", "claim_ticket", args, NOW)
        with self.assertRaisesRegex(BridgeError, "expired"):
            self.store.consume_permit(HANDLE, "claim_ticket", args, NOW + timedelta(seconds=60))

    def test_permit_consumption_race_has_one_winner(self):
        args = normalize_tool_args("claim_ticket", {"handle": HANDLE, "ticket": "K-1"})
        self.store.permit_call(self.identity, "race-call", "claim_ticket", args, NOW)
        barrier = threading.Barrier(2)
        results = []

        def consume():
            local = Store(self.path)
            barrier.wait()
            try:
                local.consume_permit(HANDLE, "claim_ticket", args, NOW)
                results.append("ok")
            except BridgeError:
                results.append("denied")
            finally:
                local.close()

        threads = [threading.Thread(target=consume) for _ in range(2)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.assertCountEqual(results, ["ok", "denied"])

    def test_sequence_allocation_is_atomic_across_connections(self):
        values = []
        barrier = threading.Barrier(8)

        def allocate():
            local = Store(self.path)
            barrier.wait()
            values.append(local.allocate_sequence(HANDLE))
            local.close()

        threads = [threading.Thread(target=allocate) for _ in range(8)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.assertEqual(sorted(values), list(range(1, 9)))

    def test_modes_retention_and_sensitive_fields(self):
        self.assertEqual(stat.S_IMODE(self.path.parent.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)
        columns = set(self.store.schema_columns())
        for forbidden in {"token", "credential", "secret", "headers", "environment", "argv", "stdin"}:
            self.assertNotIn(forbidden, columns)
        self.store.mark_ended(HANDLE, NOW - timedelta(days=8))
        self.store.cleanup(NOW)
        self.assertIsNone(self.store.get_execution(HANDLE))
        self.store.start_execution("codex", "thread-8", None, PEER_RUN, PEER_HANDLE, "/tmp/repo", True,
                                   now=NOW - timedelta(days=8))
        self.store.enqueue(QueueEvent(PEER_HANDLE, PEER_RUN, "end", "{}", NOW))
        self.store.mark_ended(PEER_HANDLE, NOW - timedelta(days=8))
        self.store.cleanup(NOW)
        self.assertIsNotNone(self.store.get_execution(PEER_HANDLE))

    def test_queue_event_is_fenced_to_ingress_generation(self):
        self.store.enqueue(QueueEvent(HANDLE, RUN, "activity", "{}", NOW))
        with self.assertRaisesRegex(BridgeError, "another run generation"):
            self.store.enqueue(QueueEvent(HANDLE, PEER_RUN, "end", "{}", NOW))

    def test_end_queue_intent_suppresses_activity_in_both_arrival_orders(self):
        self.store.enqueue(QueueEvent(HANDLE, RUN, "activity", '{"sequence":1}', NOW))
        self.store.enqueue(QueueEvent(HANDLE, RUN, "release", '{"reason":"stopped"}', NOW))
        self.store.enqueue(QueueEvent(HANDLE, RUN, "end", '{"handoff":"done"}', NOW))
        rows = self.store._connection.execute(
            "SELECT kind FROM queue WHERE handle=? ORDER BY id", (HANDLE,)
        ).fetchall()
        self.assertEqual(rows, [("release",), ("end",)])

        self.store.enqueue(QueueEvent(HANDLE, RUN, "activity", '{"sequence":2}', NOW))
        rows = self.store._connection.execute(
            "SELECT kind FROM queue WHERE handle=? ORDER BY id", (HANDLE,)
        ).fetchall()
        self.assertEqual(rows, [("release",), ("end",)])

        self.store.start_execution("codex", "thread-8", None, PEER_RUN, PEER_HANDLE,
                                   "/tmp/repo", True, now=NOW)
        self.store.mark_ended(PEER_HANDLE, NOW)
        self.store.enqueue(QueueEvent(PEER_HANDLE, PEER_RUN, "activity", '{"sequence":1}', NOW))
        self.assertIsNone(self.store._connection.execute(
            "SELECT 1 FROM queue WHERE handle=?", (PEER_HANDLE,)
        ).fetchone())

    def test_failed_schema_creation_leaves_no_partial_database_and_retry_recovers(self):
        self.store.close()
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


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.checkout = Path(self.temp.name) / "checkout"
        self.other = Path(self.temp.name) / "other"
        self.checkout.mkdir()
        self.other.mkdir()
        self.store = Store(Path(self.temp.name) / "state" / "aicoding" / "kanban-work.sqlite3")
        self.identity = NativeIdentity("codex", "thread-7", None, RUN)
        self.store.start_execution("codex", "thread-7", None, RUN, HANDLE, str(self.checkout), True, now=NOW)
        self.transport = FakeTransport()
        self.call_number = 0
        self.repos = {str(self.checkout): "aiCodingBaseSetup", str(self.other): "otherRepo"}
        self.bridge = Bridge(self.store, self.transport, now=lambda: NOW,
                             derive_repo=lambda path: self.repos.get(path))

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def permit(self, tool, args, call_id=None):
        self.call_number += 1
        call_id = call_id or f"tool-call-{self.call_number}"
        normalized = normalize_tool_args(tool, {"handle": HANDLE, **args})
        return self.store.permit_call(self.identity, call_id, tool, normalized, NOW)

    def bind(self, **payload):
        args = {"handle": HANDLE, **payload}
        self.permit("bind_work_session", payload)
        return self.bridge.dispatch("bind", args)

    def execute(self, operation, payload):
        tool = "end_work_session" if operation == "end_session" else operation
        self.permit(tool, payload)
        return self.bridge.dispatch("execute", {"handle": HANDLE, "operation": operation,
                                                 "payload": payload})

    def test_bind_uses_native_identity_and_authoritative_refresh(self):
        result = self.bind(label="worker")
        self.assertEqual(set(result), {
            "handle", "work_session_id", "harness", "run_generation", "label", "repo",
            "lifecycle_capable", "operation_id",
        })
        self.assertEqual(result["work_session_id"], SESSION)
        self.assertEqual([call[0] for call in self.transport.calls], ["register_session", "get_session"])
        sent = self.transport.calls[0][1]
        self.assertEqual(sent["native_session_id"], "thread-7")
        self.assertNotIn("handle", sent)
        self.assertEqual(UUID(result["operation_id"]).version, 5)
        self.assertTrue(self.store.get_execution(HANDLE).cache_trusted)

    def test_lookup_and_instructions_reject_noncanonical_handles_with_422(self):
        for operation, value in (
            ("lookup", "not-a-uuid"),
            ("lookup", [HANDLE]),
            ("instructions", PEER_HANDLE.upper()),
            ("instructions", {"handle": HANDLE}),
        ):
            with self.subTest(operation=operation, value=value):
                self.transport.calls.clear()
                with self.assertRaises(BridgeError) as raised:
                    self.bridge.dispatch(operation, {"handle": value})
                self.assertEqual(raised.exception.code, 422)
                self.assertNotIn("sqlite", raised.exception.message.lower())
                self.assertEqual(self.transport.calls, [])

    def test_register_and_rebind_replays_refresh_current_backend_state(self):
        register = {"operation_id": "register-replay"}
        self.permit("bind_work_session", register, "register-first")
        self.bridge.dispatch("bind", {"handle": HANDLE, **register})
        self.transport.calls.clear()
        self.permit("bind_work_session", register, "register-second")
        self.bridge.dispatch("bind", {"handle": HANDLE, **register})
        self.assertEqual([name for name, _ in self.transport.calls], ["register_session", "get_session"])

        rebind = {"checkout": str(self.other), "label": "other", "operation_id": "rebind-replay"}
        self.permit("bind_work_session", rebind, "rebind-first")
        self.bridge.dispatch("bind", {"handle": HANDLE, **rebind})
        self.transport.calls.clear()
        self.permit("bind_work_session", rebind, "rebind-second")
        self.bridge.dispatch("bind", {"handle": HANDLE, **rebind})
        self.assertEqual([name for name, _ in self.transport.calls], ["rebind_session", "get_session"])

    def test_missing_mismatched_and_replayed_permits_never_reach_network(self):
        payload = {"handle": HANDLE, "operation": "claim_ticket", "payload": {"ticket": "K-1"}}
        with self.assertRaisesRegex(BridgeError, "permit"):
            self.bridge.dispatch("execute", payload)
        self.permit("claim_ticket", {"ticket": "K-2"})
        with self.assertRaisesRegex(BridgeError, "does not match"):
            self.bridge.dispatch("execute", payload)
        self.assertEqual(self.transport.calls, [])

    def test_execute_consumes_before_network_and_injects_backend_id(self):
        self.bind()
        result = self.execute("claim_ticket", {"ticket": "AICODINGBASESETUP-2"})
        claim_call = next(payload for op, payload in self.transport.calls if op == "claim_ticket")
        self.assertEqual(claim_call["work_session_id"], SESSION)
        self.assertNotIn("handle", claim_call)
        self.assertEqual(UUID(result["operation_id"]).version, 5)
        before = len(self.transport.calls)
        with self.assertRaisesRegex(BridgeError, "permit"):
            self.bridge.dispatch("execute", {"handle": HANDLE, "operation": "claim_ticket",
                                              "payload": {"ticket": "AICODINGBASESETUP-2"}})
        self.assertEqual(len(self.transport.calls), before)

    def test_release_permit_from_omitted_reason_matches_explicit_default_request(self):
        self.bind()
        claim = self.execute("claim_ticket", {"ticket": "AICODINGBASESETUP-2"})["claim"]["id"]
        omitted = {"handle": HANDLE, "claim_id": claim, "handoff": "ready"}
        normalized = normalize_tool_args("release_ticket", omitted)
        self.store.permit_call(self.identity, "release-default", "release_ticket", normalized, NOW)

        result = self.bridge.dispatch("execute", {
            "handle": HANDLE,
            "operation": "release_ticket",
            "payload": {"claim_id": claim, "handoff": "ready", "reason": "paused"},
        })

        sent = next(payload for operation, payload in self.transport.calls
                    if operation == "release_ticket")
        self.assertEqual(sent["reason"], "paused")
        self.assertEqual(result["claim"]["id"], claim)

    def test_explicit_operation_id_is_preserved_and_ordinary_mutation_strips_it(self):
        self.bind()
        result = self.execute("create_ticket", {"title": "Cross repo", "checkout": str(self.other),
                                                 "operation_id": "explicit-retry"})
        call = next(payload for op, payload in self.transport.calls if op == "create_ticket")
        self.assertEqual(call["checkout"], str(self.other))
        self.assertNotIn("operation_id", call)
        self.assertEqual(result["operation_id"], "explicit-retry")
        self.assertEqual(self.store.get_execution(HANDLE).repo, "aiCodingBaseSetup")

    def test_explicit_rebind_succeeds_but_live_claim_and_failed_rebind_preserve_checkout(self):
        self.bind()
        self.permit("bind_work_session", {"checkout": str(self.other), "label": "other"}, "rebind-1")
        result = self.bridge.dispatch("bind", {"handle": HANDLE, "checkout": str(self.other), "label": "other"})
        self.assertEqual(result["repo"], "otherRepo")
        self.assertEqual(self.store.get_execution(HANDLE).checkout, str(self.other))
        self.transport.claim = CLAIM
        self.store.refresh_authoritative(HANDLE, session_snapshot(repo="otherRepo", claim=CLAIM),
                                         ticket_snapshot(claim=CLAIM, key="OTHER-1", status="doing"))
        self.permit("bind_work_session", {"checkout": str(self.checkout)}, "rebind-2")
        with self.assertRaisesRegex(BridgeError, "active claim"):
            self.bridge.dispatch("bind", {"handle": HANDLE, "checkout": str(self.checkout)})
        self.transport.claim = None
        self.store.refresh_authoritative(HANDLE, session_snapshot(repo="otherRepo"), None)
        self.transport.fail_next.add("rebind_session")
        self.permit("bind_work_session", {"checkout": str(self.checkout)}, "rebind-3")
        with self.assertRaises(BridgeError):
            self.bridge.dispatch("bind", {"handle": HANDLE, "checkout": str(self.checkout)})
        self.assertEqual(self.store.get_execution(HANDLE).checkout, str(self.other))

    def test_changed_label_alone_uses_rebind_and_omitted_values_preserve_binding(self):
        self.bind()
        self.transport.calls.clear()
        self.permit("bind_work_session", {"label": "renamed"}, "label-rebind")
        result = self.bridge.dispatch("bind", {"handle": HANDLE, "label": "renamed"})
        self.assertEqual([name for name, _ in self.transport.calls], ["rebind_session", "get_session"])
        self.assertEqual(self.transport.calls[0][1]["repo"], "aiCodingBaseSetup")
        self.assertEqual(result["label"], "renamed")
        self.transport.calls.clear()
        self.permit("bind_work_session", {}, "bind-noop")
        unchanged = self.bridge.dispatch("bind", {"handle": HANDLE})
        self.assertEqual(self.transport.calls, [])
        self.assertEqual(unchanged["label"], "renamed")
        self.transport.claim = CLAIM
        self.store.refresh_authoritative(HANDLE, session_snapshot(label="renamed", claim=CLAIM),
                                         ticket_snapshot(claim=CLAIM, status="doing"))
        self.permit("bind_work_session", {"label": "blocked"}, "label-live-claim")
        with self.assertRaisesRegex(BridgeError, "active claim"):
            self.bridge.dispatch("bind", {"handle": HANDLE, "label": "blocked"})
        self.assertEqual(self.transport.calls, [])

    def test_refresh_failure_marks_cache_untrusted_and_retry_refreshes_before_work(self):
        self.bind()
        self.transport.fail_next.add("get_session")
        self.permit("claim_ticket", {"ticket": "AICODINGBASESETUP-2"}, "claim-1")
        with self.assertRaisesRegex(BridgeError, "authoritative refresh"):
            self.bridge.dispatch("execute", {"handle": HANDLE, "operation": "claim_ticket",
                                              "payload": {"ticket": "AICODINGBASESETUP-2"}})
        self.assertFalse(self.store.get_execution(HANDLE).cache_trusted)
        # The backend accepted claim-1. A later call first reconciles through
        # get_session/get_ticket, then correctly rejects a second live claim.
        self.permit("claim_ticket", {"ticket": "AICODINGBASESETUP-3"}, "claim-2")
        with self.assertRaisesRegex(BridgeError, "active claim"):
            self.bridge.dispatch("execute", {"handle": HANDLE, "operation": "claim_ticket",
                                              "payload": {"ticket": "AICODINGBASESETUP-3"}})
        self.assertTrue(self.store.get_execution(HANDLE).cache_trusted)
        self.assertIn("get_ticket", [name for name, _ in self.transport.calls])

    def test_sqlite_refresh_failure_rolls_back_then_reconciles_on_retry(self):
        self.bind()
        original = self.store.refresh_authoritative
        calls = 0

        def fail_once(*args, **kwargs):
            nonlocal calls
            calls += 1
            if calls == 1:
                raise sqlite3.OperationalError("injected commit failure")
            return original(*args, **kwargs)

        with mock.patch.object(self.store, "refresh_authoritative", side_effect=fail_once):
            self.permit("claim_ticket", {"ticket": "AICODINGBASESETUP-2"}, "sqlite-claim")
            with self.assertRaisesRegex(BridgeError, "authoritative refresh"):
                self.bridge.dispatch("execute", {"handle": HANDLE, "operation": "claim_ticket",
                                                  "payload": {"ticket": "AICODINGBASESETUP-2"}})
            self.assertIsNone(self.store.active_claim(HANDLE))
            self.assertFalse(self.store.get_execution(HANDLE).cache_trusted)
            self.permit("checkpoint_work", {"claim_id": CLAIM, "checkpoint": "recovered"},
                        "sqlite-retry")
            result = self.bridge.dispatch("execute", {
                "handle": HANDLE, "operation": "checkpoint_work",
                "payload": {"claim_id": CLAIM, "checkpoint": "recovered"},
            })
            self.assertEqual(result["claim"]["id"], CLAIM)
            self.assertTrue(self.store.get_execution(HANDLE).cache_trusted)

    def test_authoritative_identity_or_capability_change_never_updates_cache(self):
        self.bind()
        before = self.store.lookup(HANDLE)
        for changed in (
            {**session_snapshot(), "id": "different-backend-session"},
            {**session_snapshot(), "lifecycle_capable": False},
        ):
            with self.subTest(changed=changed), self.assertRaises(BridgeError):
                self.store.refresh_authoritative(HANDLE, changed, None)
            self.assertEqual(self.store.lookup(HANDLE), before)

    def test_old_replayed_claim_receipt_cannot_resurrect_replacement(self):
        self.bind()
        first = self.execute("claim_ticket", {"ticket": "AICODINGBASESETUP-2", "operation_id": "old"})
        self.execute("release_ticket", {"claim_id": first["claim"]["id"], "handoff": "done", "reason": "paused"})
        self.transport.claim = "replacement-claim"
        self.store.refresh_authoritative(HANDLE, session_snapshot(claim="replacement-claim"),
                                         ticket_snapshot(claim="replacement-claim", status="doing"))
        self.permit("claim_ticket", {"ticket": "AICODINGBASESETUP-2", "operation_id": "old"}, "replay")
        self.bridge.dispatch("execute", {"handle": HANDLE, "operation": "claim_ticket",
                                         "payload": {"ticket": "AICODINGBASESETUP-2", "operation_id": "old"}})
        self.assertEqual(self.store.lookup(HANDLE)["active_claim"]["id"], "replacement-claim")

    def test_replayed_checkpoint_and_release_receipts_still_refresh_authoritatively(self):
        self.bind()
        claim = self.execute("claim_ticket", {
            "ticket": "AICODINGBASESETUP-2", "operation_id": "claim-for-replays"
        })["claim"]["id"]
        checkpoint = {"claim_id": claim, "checkpoint": "focused tests pass",
                      "operation_id": "checkpoint-replay"}
        self.execute("checkpoint_work", checkpoint)
        self.transport.calls.clear()
        self.execute("checkpoint_work", checkpoint)
        self.assertEqual([name for name, _ in self.transport.calls],
                         ["checkpoint_work", "get_session", "get_ticket"])
        release = {"claim_id": claim, "handoff": "ready", "reason": "paused",
                   "operation_id": "release-replay"}
        self.execute("release_ticket", release)
        self.assertIsNone(self.store.active_claim(HANDLE))
        self.transport.calls.clear()
        self.execute("release_ticket", release)
        self.assertEqual([name for name, _ in self.transport.calls],
                         ["release_ticket", "get_session", "get_ticket"])
        self.assertIsNone(self.store.active_claim(HANDLE))

    def test_replayed_complete_receipt_refreshes_without_resurrecting_claim(self):
        self.bind()
        claim = self.execute("claim_ticket", {
            "ticket": "AICODINGBASESETUP-2", "operation_id": "claim-before-complete"
        })["claim"]["id"]
        complete = {"claim_id": claim, "evidence": "29 tests pass", "references": ["commit abc"],
                    "operation_id": "complete-replay"}
        self.execute("complete_ticket", complete)
        self.assertIsNone(self.store.active_claim(HANDLE))
        self.transport.calls.clear()
        self.execute("complete_ticket", complete)
        self.assertEqual([name for name, _ in self.transport.calls],
                         ["complete_ticket", "get_session", "get_ticket"])
        self.assertIsNone(self.store.active_claim(HANDLE))

    def test_lifecycle_receipts_refresh_session_and_ticket_before_cache(self):
        self.bind()
        claim = self.execute("claim_ticket", {"ticket": "AICODINGBASESETUP-2"})["claim"]["id"]
        for i, (operation, payload) in enumerate((
            ("checkpoint_work", {"claim_id": claim, "checkpoint": "tests pass"}),
            ("release_ticket", {"claim_id": claim, "handoff": "paused", "reason": "paused"}),
        )):
            self.transport.calls.clear()
            self.execute(operation, payload)
            names = [name for name, _ in self.transport.calls]
            self.assertEqual(names[:3], [operation, "get_session", "get_ticket"], (i, names))

    def test_end_session_refreshes_released_ticket_and_exact_replay_after_end(self):
        self.bind()
        self.execute("claim_ticket", {"ticket": "AICODINGBASESETUP-2"})
        self.transport.calls.clear()
        payload = {"handoff": "session finished", "operation_id": "end-replay"}
        result = self.execute("end_session", payload)
        self.assertEqual([name for name, _ in self.transport.calls],
                         ["end_session", "get_session", "get_ticket"])
        self.assertEqual(self.transport.calls[0][1]["work_session_id"], SESSION)
        self.assertEqual(self.transport.calls[2][1]["ticket"], "ticket-db-ref")
        self.assertEqual(result["session"]["ended_at"], "2026-09-12T12:01:00Z")
        self.assertEqual(self.store.get_execution(HANDLE).state, "ended")
        self.assertEqual(self.store.operation(HANDLE, "end-replay")["claim_id"], CLAIM)

        self.transport.calls.clear()
        replay = self.execute("end_session", payload)
        self.assertEqual(replay["operation_id"], "end-replay")
        self.assertEqual([name for name, _ in self.transport.calls],
                         ["end_session", "get_session", "get_ticket"])

        for changed, call_id in (
            ({"handoff": "changed", "operation_id": "end-replay"}, "changed-digest"),
            ({"handoff": "session finished", "operation_id": "another-end"}, "changed-operation"),
        ):
            with self.subTest(changed=changed), self.assertRaisesRegex(BridgeError, "ended"):
                self.permit("end_work_session", changed, call_id)

    def test_each_lifecycle_refresh_failure_replays_exact_operation_and_recovers(self):
        cases = (
            ("register", "get_session"),
            ("rebind", "get_session"),
            ("claim_ticket", "get_session"),
            ("claim_ticket", "get_ticket"),
            ("checkpoint_work", "get_session"),
            ("checkpoint_work", "get_ticket"),
            ("release_ticket", "get_session"),
            ("release_ticket", "get_ticket"),
            ("complete_ticket", "get_session"),
            ("complete_ticket", "get_ticket"),
            ("end_session", "get_session"),
            ("end_session", "get_ticket"),
        )
        for operation, failure in cases:
            with self.subTest(operation=operation, failure=failure), tempfile.TemporaryDirectory() as td:
                checkout = Path(td) / "checkout"
                other = Path(td) / "other"
                checkout.mkdir()
                other.mkdir()
                store = Store(Path(td) / "state" / "kanban-work.sqlite3")
                identity = NativeIdentity("codex", "thread-7", None, RUN)
                store.start_execution("codex", "thread-7", None, RUN, HANDLE,
                                      str(checkout), True, now=NOW)
                transport = FakeTransport()
                bridge = Bridge(store, transport, now=lambda: NOW,
                                derive_repo=lambda path: {
                                    str(checkout): "aiCodingBaseSetup", str(other): "otherRepo"
                                }.get(path))
                call_number = 0

                def invoke(public_operation, body):
                    nonlocal call_number
                    call_number += 1
                    tool = "bind_work_session" if public_operation in {"register", "rebind"} else (
                        "end_work_session" if public_operation == "end_session" else public_operation
                    )
                    normalized = normalize_tool_args(tool, {"handle": HANDLE, **body})
                    store.permit_call(identity, f"refresh-{call_number}", tool, normalized, NOW)
                    if public_operation in {"register", "rebind"}:
                        return bridge.dispatch("bind", {"handle": HANDLE, **body})
                    return bridge.dispatch("execute", {
                        "handle": HANDLE, "operation": public_operation, "payload": body,
                    })

                try:
                    if operation != "register":
                        invoke("register", {})
                    if operation in {"checkpoint_work", "release_ticket", "complete_ticket", "end_session"}:
                        invoke("claim_ticket", {"ticket": "AICODINGBASESETUP-2"})
                    operation_id = f"retry-{operation}"
                    bodies = {
                        "register": {"operation_id": operation_id},
                        "rebind": {"checkout": str(other), "label": "other",
                                   "operation_id": operation_id},
                        "claim_ticket": {"ticket": "AICODINGBASESETUP-2",
                                         "operation_id": operation_id},
                        "checkpoint_work": {"claim_id": CLAIM, "checkpoint": "saved",
                                            "operation_id": operation_id},
                        "release_ticket": {"claim_id": CLAIM, "handoff": "ready",
                                           "reason": "paused", "operation_id": operation_id},
                        "complete_ticket": {"claim_id": CLAIM, "evidence": "tests pass",
                                            "references": [], "operation_id": operation_id},
                        "end_session": {"handoff": "done", "operation_id": operation_id},
                    }
                    body = bodies[operation]
                    transport.fail_next.add(failure)
                    with self.assertRaisesRegex(BridgeError, "authoritative refresh"):
                        invoke(operation, body)
                    self.assertFalse(store.get_execution(HANDLE).cache_trusted)

                    transport.calls.clear()
                    result = invoke(operation, body)
                    self.assertEqual(result["operation_id"], operation_id)
                    self.assertTrue(store.get_execution(HANDLE).cache_trusted)
                    self.assertEqual(store.operation(HANDLE, operation_id)["state"], "succeeded")
                    expected = ["end_session" if operation == "end_session" else (
                        "register_session" if operation == "register" else (
                            "rebind_session" if operation == "rebind" else operation
                        )
                    ), "get_session"]
                    if operation not in {"register", "rebind"}:
                        expected.append("get_ticket")
                    self.assertEqual([name for name, _ in transport.calls][-len(expected):], expected)
                finally:
                    store.close()


class ExecutableTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(__file__).resolve().parents[2]
        self.state = Path(self.temp.name) / "state"
        self.tools = Path(self.temp.name) / "bin"
        self.tools.mkdir()
        (self.tools / "kanban-work").symlink_to(self.root / "bin" / "kanban-work")
        fake_post = self.tools / "kanban-post"
        fake_post.write_text("""#!/usr/bin/env python3
import json, sys
op = sys.argv[2]
payload = json.load(sys.stdin)
session = {
  "id": "backend-session-ref", "actor": "test", "harness": "codex",
  "native_session_id": "thread-7", "subagent_id": None,
  "run_generation": "33333333-3333-4333-8333-333333333333",
  "label": "worker", "repo": "aiCodingBaseSetup", "lifecycle_capable": True,
  "created_at": "2026-09-12T12:00:00Z", "ended_at": None, "claims": []
}
data = session if op in {"register_session", "get_session"} else {"ok": True}
print(json.dumps({"ok": True, "data": data}, separators=(",", ":")))
""")
        fake_post.chmod(0o755)
        fake_mcp = self.tools / "kanban-mcp"
        fake_mcp.write_text("""#!/bin/sh
[ -z "${KANBAN_TOKEN:-}" ] && [ -z "${KANBAN_TEST_TOKEN:-}" ] || exit 91
printf 'canonical workflow\\n'
""")
        fake_mcp.chmod(0o755)
        self.env = {**os.environ, "XDG_STATE_HOME": str(self.state),
                    "PATH": f"{self.tools}:{os.environ['PATH']}",
                    "KANBAN_TOKEN": "must-not-reach-instructions",
                    "KANBAN_TEST_TOKEN": "must-not-reach-instructions"}
        store = Store(self.state / "aicoding" / "kanban-work.sqlite3")
        identity = NativeIdentity("codex", "thread-7", None, RUN)
        store.start_execution("codex", "thread-7", None, RUN, HANDLE, str(self.root), True, now=NOW)
        normalized = normalize_tool_args("bind_work_session", {"handle": HANDLE})
        store.permit_call(identity, "cli-bind", "bind_work_session", normalized, datetime.now(UTC))
        store.close()

    def tearDown(self):
        self.temp.cleanup()

    def run_bridge(self, operation, payload):
        return subprocess.run(
            [str(self.root / "bin" / "kanban-work"), "--json", operation],
            input=json.dumps(payload), text=True, capture_output=True, env=self.env, timeout=10,
        )

    def test_real_executable_shares_registry_across_processes_and_runs_fake_helpers(self):
        bound = self.run_bridge("bind", {"handle": HANDLE})
        self.assertEqual(bound.returncode, 0, bound.stderr + bound.stdout)
        looked_up = self.run_bridge("lookup", {"handle": HANDLE})
        self.assertEqual(json.loads(looked_up.stdout)["data"]["work_session_id"], SESSION)
        instructions = self.run_bridge("instructions", {"handle": HANDLE})
        self.assertEqual(instructions.returncode, 0, instructions.stderr + instructions.stdout)
        self.assertEqual(json.loads(instructions.stdout)["data"]["text"], "canonical workflow\n")

    def test_explicit_and_environment_work_handles_do_not_prove_native_identity(self):
        store = Store(self.state / "aicoding" / "kanban-work.sqlite3")
        store.record_bound(HANDLE, SESSION, "aiCodingBaseSetup", "worker")
        store.set_claim(HANDLE, CLAIM, "AICODINGBASESETUP-2")
        store.start_execution("codex", "thread-peer", None, PEER_RUN, PEER_HANDLE,
                              str(self.root), True, now=NOW)
        store.record_bound(PEER_HANDLE, "peer-session", "aiCodingBaseSetup", "peer")
        store.set_claim(PEER_HANDLE, "peer-claim", "AICODINGBASESETUP-3")
        store.close()
        for extra, hint, ticket in (
            ([], HANDLE, "AICODINGBASESETUP-2"),
            (["--work-handle", PEER_HANDLE], HANDLE, "AICODINGBASESETUP-3"),
        ):
            env = {**self.env, "KANBAN_WORK_HANDLE": hint}
            result = subprocess.run(
                [str(self.root / "bin" / "kanban-post"), "--done", ticket,
                 "--evidence", "tests passed", *extra],
                text=True, capture_output=True, env=env, timeout=10,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("permit", result.stderr.lower())


if __name__ == "__main__":
    unittest.main()
