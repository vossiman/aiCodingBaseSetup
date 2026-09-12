import json
import os
import pathlib
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "bin" / "kanban-post"
TOKEN = "FAKE-KANBAN-JSON-TOKEN-do-not-use"
SESSION_ID = "11111111-1111-4111-8111-111111111111"
CLAIM_ID = "22222222-2222-4222-8222-222222222222"
RUN_ID = "33333333-3333-4333-8333-333333333333"
OP_ID = "fixture-operation-1"


class RecordingHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _handle(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b""
        body = json.loads(raw) if raw else None
        self.server.calls.append((
            self.command,
            self.path,
            body,
            self.headers.get("Authorization"),
        ))
        response = self.server.responses.pop(0) if self.server.responses else (200, {"result": "ok"}, {})
        status, value, headers = response
        encoded = b"" if value is None else json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        for name, header_value in headers.items():
            self.send_header(name, header_value)
        if encoded:
            self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        if encoded:
            self.wfile.write(encoded)

    do_GET = do_POST = do_PATCH = do_DELETE = _handle


class KanbanPostJsonTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = pathlib.Path(self.temp.name)
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), RecordingHandler)
        self.server.calls = []
        self.server.responses = []
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        self.env = {
            **os.environ,
            "HOME": str(self.home),
            "KANBAN_URL": self.url,
            "KANBAN_TEST_TOKEN": TOKEN,
        }

    def run_json(self, operation, payload, *, raw=None, cwd=None, env=None):
        if raw is None:
            raw = json.dumps(payload)
        return subprocess.run(
            [str(SCRIPT), "--json", operation],
            input=raw,
            text=True,
            capture_output=True,
            cwd=cwd or ROOT,
            env=env or self.env,
            timeout=10,
        )

    def assert_error(self, result, message, code=422):
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout), {
            "ok": False,
            "error": {"code": code, "message": message},
        })
        self.assertNotIn("Traceback", result.stdout + result.stderr)

    def fake_checkout(self, name="myrepo"):
        checkout = self.home / name
        checkout.mkdir()
        subprocess.run(["git", "init", "-q", str(checkout)], check=True)
        subprocess.run([
            "git", "-C", str(checkout), "remote", "add", "origin",
            f"https://github.com/vossiman/{name}.git",
        ], check=True)
        return checkout

    def test_read_operations_map_to_fixed_routes_and_encode_inputs(self):
        cases = [
            ("list_repos", {}, "GET", "/api/repos", None),
            ("list_tickets", {"repo": "data Env", "status": "doing", "swimlane": "required", "done": "recent"},
             "GET", "/api/tickets?repo=data+Env&status=doing&swimlane=required&done=recent", None),
            ("get_ticket", {"ticket": "repo/key ?#"}, "GET", "/api/tickets/repo%2Fkey%20%3F%23", None),
            ("get_session", {"work_session_id": SESSION_ID}, "GET", f"/api/work/sessions/{SESSION_ID}", None),
        ]
        for operation, payload, method, path, body in cases:
            with self.subTest(operation=operation):
                result = self.run_json(operation, payload)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), {"ok": True, "data": {"result": "ok"}})
                self.assertEqual(self.server.calls[-1], (method, path, body, "Bearer " + TOKEN))

    def test_ticket_mutations_map_to_fixed_routes_and_bodies(self):
        checkout = self.fake_checkout()
        cases = [
            ("create_ticket", {"checkout": str(checkout), "title": "Follow-up", "body": "Details", "priority": "high"},
             "POST", "/api/tickets", {"title": "Follow-up", "repo": "myrepo", "body": "Details", "priority": "high"}),
            ("update_ticket", {"ticket": "KANBAN/2", "fields": {"title": "Renamed", "due_date": None, "position": 2}},
             "PATCH", "/api/tickets/KANBAN%2F2", {"title": "Renamed", "due_date": None, "position": 2}),
            ("add_comment", {"ticket": "KANBAN-2", "body": "Parser verified."},
             "POST", "/api/tickets/KANBAN-2/comments", {"body": "Parser verified."}),
            ("link_tickets", {"ticket": "KANBAN-2", "target": "KANBAN-3", "kind": "relates"},
             "POST", "/api/tickets/KANBAN-2/links", {"target": "KANBAN-3", "kind": "relates"}),
        ]
        for operation, payload, method, path, body in cases:
            with self.subTest(operation=operation):
                result = self.run_json(operation, payload)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.server.calls[-1], (method, path, body, "Bearer " + TOKEN))

    def test_work_mutations_map_every_allowlisted_payload(self):
        cases = [
            ("register_session", {
                "harness": "codex", "native_session_id": "native-1", "subagent_id": None,
                "run_generation": RUN_ID, "label": "worker", "repo": "kanban",
                "lifecycle_capable": True, "operation_id": OP_ID,
            }, "POST", "/api/work/sessions", {
                "harness": "codex", "native_session_id": "native-1", "subagent_id": None,
                "run_generation": RUN_ID, "label": "worker", "repo": "kanban",
                "lifecycle_capable": True, "operation_id": OP_ID,
            }),
            ("rebind_session", {"work_session_id": SESSION_ID, "repo": "other", "label": "worker", "operation_id": OP_ID},
             "POST", f"/api/work/sessions/{SESSION_ID}/rebind", {"repo": "other", "label": "worker", "operation_id": OP_ID}),
            ("end_session", {"work_session_id": SESSION_ID, "handoff": "Stopped cleanly", "operation_id": OP_ID},
             "POST", f"/api/work/sessions/{SESSION_ID}/end", {"handoff": "Stopped cleanly", "operation_id": OP_ID}),
            ("claim_ticket", {"work_session_id": SESSION_ID, "ticket": "KANBAN-2", "operation_id": OP_ID},
             "POST", "/api/work/tickets/KANBAN-2/claim", {"work_session_id": SESSION_ID, "operation_id": OP_ID}),
            ("activity", {"work_session_id": SESSION_ID, "claim_id": CLAIM_ID, "observed_at": "2026-09-12T10:00:00Z", "sequence": 4, "operation_id": OP_ID},
             "POST", f"/api/work/claims/{CLAIM_ID}/activity", {"work_session_id": SESSION_ID, "observed_at": "2026-09-12T10:00:00Z", "sequence": 4, "operation_id": OP_ID}),
            ("checkpoint_work", {"work_session_id": SESSION_ID, "claim_id": CLAIM_ID, "checkpoint": "Parser implemented.", "operation_id": OP_ID},
             "POST", f"/api/work/claims/{CLAIM_ID}/checkpoint", {"work_session_id": SESSION_ID, "checkpoint": "Parser implemented.", "operation_id": OP_ID}),
            ("release_ticket", {"work_session_id": SESSION_ID, "claim_id": CLAIM_ID, "handoff": "Tests remain.", "reason": "paused", "swimlane": "required", "operation_id": OP_ID},
             "POST", f"/api/work/claims/{CLAIM_ID}/release", {"work_session_id": SESSION_ID, "handoff": "Tests remain.", "reason": "paused", "swimlane": "required", "operation_id": OP_ID}),
            ("complete_ticket", {"work_session_id": SESSION_ID, "claim_id": CLAIM_ID, "evidence": "24 tests passed", "references": [], "operation_id": OP_ID},
             "POST", f"/api/work/claims/{CLAIM_ID}/complete", {"work_session_id": SESSION_ID, "evidence": "24 tests passed", "references": [], "operation_id": OP_ID}),
            ("override_claim", {"claim_id": CLAIM_ID, "reason": "operator recovery", "status": "todo", "position": 1, "operation_id": OP_ID},
             "POST", f"/api/work/claims/{CLAIM_ID}/override", {"reason": "operator recovery", "status": "todo", "position": 1, "operation_id": OP_ID}),
        ]
        for operation, payload, method, path, expected_body in cases:
            with self.subTest(operation=operation):
                result = self.run_json(operation, payload)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.server.calls[-1], (method, path, expected_body, "Bearer " + TOKEN))

    def test_claim_maps_only_the_allowlisted_payload(self):
        result = self.run_json("claim_ticket", {
            "work_session_id": SESSION_ID,
            "ticket": "KANBAN-2",
            "operation_id": OP_ID,
        })
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["ok"], True)
        self.assertEqual(self.server.calls[-1], (
            "POST", "/api/work/tickets/KANBAN-2/claim",
            {"work_session_id": SESSION_ID, "operation_id": OP_ID},
            "Bearer " + TOKEN,
        ))

    def test_unknown_operation_never_reaches_network(self):
        result = self.run_json("request", {"url": "https://example.invalid"})
        self.assert_error(result, "unknown operation 'request'")
        self.assertEqual(self.server.calls, [])

    def test_malformed_non_object_and_oversize_input_are_json_errors(self):
        for raw, message in [
            ("{", "stdin must contain one valid JSON object"),
            ("[]", "stdin must contain one JSON object"),
            (json.dumps({"padding": "x" * (256 * 1024)}), "stdin exceeds 256 KiB"),
        ]:
            with self.subTest(message=message):
                result = self.run_json("list_repos", {}, raw=raw)
                self.assert_error(result, message)
        self.assertEqual(self.server.calls, [])

    def test_extra_and_local_identity_keys_are_rejected_before_network(self):
        for operation, payload, key in [
            ("list_repos", {"url": "https://example.invalid"}, "url"),
            ("claim_ticket", {"work_session_id": SESSION_ID, "ticket": "KANBAN-2", "operation_id": OP_ID, "handle": RUN_ID}, "handle"),
            ("update_ticket", {"ticket": "KANBAN-2", "fields": {"repo": "elsewhere"}}, "repo"),
        ]:
            with self.subTest(operation=operation, key=key):
                result = self.run_json(operation, payload)
                self.assert_error(result, f"unknown field {key!r} for {operation}")
        self.assertEqual(self.server.calls, [])

    def test_invalid_identifiers_operation_ids_enums_and_dates_are_rejected(self):
        cases = [
            ("get_session", {"work_session_id": ""}),
            ("checkpoint_work", {"work_session_id": SESSION_ID, "claim_id": "x" * 301, "checkpoint": "ok", "operation_id": OP_ID}),
            ("claim_ticket", {"work_session_id": SESSION_ID, "ticket": "KANBAN-2", "operation_id": "x" * 301}),
            ("register_session", {"harness": "unknown", "native_session_id": "native", "run_generation": RUN_ID, "label": "worker", "repo": "kanban", "lifecycle_capable": True, "operation_id": OP_ID}),
            ("release_ticket", {"work_session_id": SESSION_ID, "claim_id": CLAIM_ID, "handoff": "done", "reason": "later", "operation_id": OP_ID}),
            ("create_ticket", {"checkout": str(ROOT), "title": "x", "priority": "urgent"}),
            ("update_ticket", {"ticket": "K-1", "fields": {"status": "later"}}),
            ("create_ticket", {"checkout": str(ROOT), "title": "x", "due_date": "12/09/2026"}),
            ("end_session", {"work_session_id": SESSION_ID, "handoff": "   ", "operation_id": OP_ID}),
        ]
        for operation, payload in cases:
            with self.subTest(operation=operation, payload=payload):
                result = self.run_json(operation, payload)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(json.loads(result.stdout)["error"]["code"], 422)
        self.assertEqual(self.server.calls, [])

    def test_opaque_session_and_claim_refs_are_encoded_as_single_path_segments(self):
        result = self.run_json("get_session", {"work_session_id": "session/fixture?#"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.server.calls[-1][1], "/api/work/sessions/session%2Ffixture%3F%23")
        result = self.run_json("checkpoint_work", {
            "work_session_id": "session-fixture", "claim_id": "claim/fixture?#",
            "checkpoint": "verified", "operation_id": OP_ID,
        })
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.server.calls[-1][1], "/api/work/claims/claim%2Ffixture%3F%23/checkpoint")

    def test_complete_defaults_references_and_requires_nonblank_evidence(self):
        payload = {"work_session_id": SESSION_ID, "claim_id": CLAIM_ID, "evidence": "tests pass", "operation_id": OP_ID}
        result = self.run_json("complete_ticket", payload)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.server.calls[-1][2]["references"], [])
        before = len(self.server.calls)
        result = self.run_json("complete_ticket", {**payload, "evidence": "   "})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.server.calls), before)

    def test_create_derives_repo_from_explicit_checkout_and_refuses_mismatch(self):
        checkout = self.fake_checkout("dataEnv")
        result = self.run_json("create_ticket", {"checkout": str(checkout), "title": "Finding"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.server.calls[-1][2], {"repo": "dataEnv", "title": "Finding"})
        before = len(self.server.calls)
        result = self.run_json("create_ticket", {"checkout": str(checkout), "title": "Finding", "repo": "wrong"})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.server.calls), before)

    def test_unlink_resolves_one_matching_kind_and_accepts_204(self):
        self.server.responses.extend([
            (200, {"links": [
                {"id": "link-1", "kind": "depends_on", "ticket": {"id": "other-id", "key": "KANBAN-3"}},
                {"id": "link-2", "kind": "relates", "ticket": {"id": "other-id", "key": "KANBAN-3"}},
            ]}, {}),
            (204, None, {}),
        ])
        result = self.run_json("unlink_tickets", {"ticket": "KANBAN-2", "target": "KANBAN-3", "kind": "relates"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"ok": True, "data": None})
        self.assertEqual(self.server.calls[-1][:3], ("DELETE", "/api/tickets/KANBAN-2/links/link-2", None))

    def test_unlink_refuses_ambiguous_match_without_delete(self):
        self.server.responses.append((200, {"links": [
            {"id": "one", "kind": "depends_on", "ticket": {"id": "other", "key": "K-2"}},
            {"id": "two", "kind": "relates", "ticket": {"id": "other", "key": "K-2"}},
        ]}, {}))
        result = self.run_json("unlink_tickets", {"ticket": "K-1", "target": "K-2"})
        self.assert_error(result, "K-1 has more than one link to K-2; specify kind", 409)
        self.assertEqual(len(self.server.calls), 1)

    def test_redirect_is_refused_as_a_json_error(self):
        self.server.responses.append((302, None, {"Location": "http://127.0.0.1:1/stolen"}))
        result = self.run_json("list_repos", {})
        self.assertNotEqual(result.returncode, 0)
        value = json.loads(result.stdout)
        self.assertFalse(value["ok"])
        self.assertIn("refusing to follow", value["error"]["message"])
        self.assertEqual(len(self.server.calls), 1)

    def test_error_body_and_traceback_are_redacted(self):
        self.server.responses.append((409, {"detail": f"owner echoed {TOKEN}"}, {}))
        result = self.run_json("claim_ticket", {
            "work_session_id": SESSION_ID, "ticket": "KANBAN-2", "operation_id": OP_ID,
        })
        self.assertNotIn(TOKEN, result.stdout + result.stderr)
        self.assertNotIn("Traceback", result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout), {
            "ok": False,
            "error": {"code": 409, "message": "owner echoed <redacted>"},
        })

    def test_loopback_requires_the_fake_token_and_never_reads_store(self):
        secret_dir = self.home / ".aicodingsetup"
        secret_dir.mkdir()
        (secret_dir / ".secrets.env").write_text("KANBAN_TOKEN=REAL-TOKEN-MUST-NOT-BE-USED\n")
        env = self.env.copy()
        env.pop("KANBAN_TEST_TOKEN")
        result = self.run_json("list_repos", {}, env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("REAL-TOKEN", result.stdout + result.stderr)
        self.assertEqual(self.server.calls, [])

    def test_loopback_override_rejects_non_http_schemes(self):
        env = {**self.env, "KANBAN_URL": "file://127.0.0.1/tmp/board"}
        result = self.run_json("list_repos", {}, env=env)
        self.assert_error(result, "KANBAN_URL must use http or https", 502)
        self.assertEqual(self.server.calls, [])


if __name__ == "__main__":
    unittest.main()
