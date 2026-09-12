import json
import os
import stat
import tempfile
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

from fake_kanban_board import FAKE_TOKEN, FakeKanbanBoard
from qualify_kanban_clients import (
    CLIENTS,
    REQUIRED_SCENARIOS,
    build_report,
    candidate_matrix,
    observe_version,
    qualify,
    validate_qualification_environment,
    validate_report,
    write_report,
)


class QualificationHarnessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def executable(self, name, source):
        path = self.root / name
        path.write_text("#!/usr/bin/env python3\n" + source, encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        return path

    def test_non_loopback_board_is_refused(self):
        with self.assertRaisesRegex(ValueError, "loopback"):
            validate_qualification_environment("https://kanban.example.test", FAKE_TOKEN)

    def test_fake_token_is_required(self):
        with self.assertRaisesRegex(ValueError, "KANBAN_TEST_TOKEN"):
            validate_qualification_environment("http://127.0.0.1:8123", "")

    def test_missing_scenario_cannot_be_qualified(self):
        scenarios = {name: True for name in REQUIRED_SCENARIOS}
        scenarios.pop("parent_child")
        report = build_report("claude", "2.1.268", scenarios, [], True)
        validated = validate_report(report)
        self.assertEqual(validated["status"], "unsupported")
        self.assertIn("missing required scenario: parent_child", validated["reasons"])

    def test_fixture_only_evidence_cannot_qualify_a_real_client(self):
        report = qualify(fake_client=True, real_binary_observed=False)
        self.assertEqual(report["status"], "unsupported")
        self.assertIn("real client binary was not observed", report["reasons"])

    def test_preflight_only_report_cannot_qualify_even_with_true_flags(self):
        report = build_report(
            "codex", "0.154.0",
            {name: True for name in REQUIRED_SCENARIOS}, [], True,
        )
        self.assertEqual(report["status"], "unsupported")
        self.assertIn("native lifecycle evidence was not collected", report["reasons"])

    def test_fake_token_echoed_by_version_command_is_never_reported(self):
        client = self.executable("fake-client", """
import os
print(os.environ.get("KANBAN_TEST_TOKEN"))
""")
        observation = observe_version(
            client, "claude", timeout=1,
            environment={"KANBAN_TEST_TOKEN": FAKE_TOKEN},
        )
        report = build_report(
            "claude", observation.version,
            {scenario: False for scenario in REQUIRED_SCENARIOS},
            [observation.reason], observation.observed,
        )
        path = write_report(self.root, report)
        serialized = path.read_text(encoding="utf-8")
        self.assertNotIn(FAKE_TOKEN, serialized)
        self.assertIn("did not return a bounded exact version", serialized)

    def test_hung_client_is_killed_at_timeout(self):
        client = self.executable("hung-client", """
import time
time.sleep(30)
""")
        started = time.monotonic()
        observation = observe_version(client, "claude", timeout=0.1)
        self.assertLess(time.monotonic() - started, 3)
        self.assertTrue(observation.observed)
        self.assertIn("timed out", observation.reason)

    def test_noisy_version_output_is_stopped_at_fixed_limit(self):
        client = self.executable("noisy-client", """
import sys
while True:
    sys.stdout.write("x" * 4096)
    sys.stdout.flush()
""")
        observation = observe_version(client, "claude", timeout=2)
        self.assertIsNone(observation.version)
        self.assertIn("output limit", observation.reason)

    def test_candidate_matrix_contains_only_one_exact_pair(self):
        self.assertEqual(candidate_matrix("codex", "0.154.0"), {
            "schema": 1,
            "clients": {"codex": ["0.154.0"]},
        })

    def test_all_client_result_is_nonzero_when_one_is_unsupported(self):
        reports = {
            name: build_report(
                name,
                "1.2.3",
                {scenario: True for scenario in REQUIRED_SCENARIOS},
                [] if name != "cursor" else ["native lifecycle gap"],
                name != "cursor",
            )
            for name in CLIENTS
        }
        self.assertTrue(any(report["status"] == "unsupported" for report in reports.values()))


class FakeBoardTests(unittest.TestCase):
    def request(self, board, method, path, payload=None, token=FAKE_TOKEN, host=None):
        data = None if payload is None else json.dumps(payload).encode()
        request = urllib.request.Request(
            board.url + path,
            data=data,
            method=method,
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
                **({"Host": host} if host else {}),
            },
        )
        with urllib.request.urlopen(request, timeout=2) as response:
            return response.status, json.load(response)

    def test_board_binds_only_loopback_and_rejects_wrong_auth_and_host(self):
        with FakeKanbanBoard() as board:
            self.assertEqual(board.address, "127.0.0.1")
            with self.assertRaises(urllib.error.HTTPError) as auth:
                self.request(board, "GET", "/api/repos", token="wrong")
            self.assertEqual(auth.exception.code, 401)
            with self.assertRaises(urllib.error.HTTPError) as host:
                self.request(board, "GET", "/api/repos", host="example.test")
            self.assertEqual(host.exception.code, 400)

    def test_clock_advance_expires_claim_without_sleeping(self):
        with FakeKanbanBoard() as board:
            _, ticket = self.request(board, "POST", "/api/tickets", {"title": "Expiry"})
            _, session = self.request(board, "POST", "/api/work/sessions", {
                "harness": "codex", "native_session_id": "hashed-native",
                "run_generation": "generation", "label": "worker", "repo": "aiCodingBaseSetup",
                "lifecycle_capable": True, "operation_id": "session-1",
            })
            key = ticket["key"]
            self.request(board, "POST", f"/api/work/tickets/{key}/claim", {
                "work_session_id": session["id"], "operation_id": "claim-1",
            })
            self.request(board, "POST", "/__qualification__/clock", {"advance_minutes": 17})
            _, expired = self.request(board, "GET", f"/api/tickets/{key}")
            self.assertEqual(expired["status"], "todo")
            self.assertIsNone(expired["claim_id"])

    def test_route_log_is_bounded_and_redacted(self):
        with FakeKanbanBoard() as board:
            self.request(board, "POST", "/api/work/sessions", {
                "harness": "claude", "native_session_id": "native-secret",
                "run_generation": "generation", "label": "private-label", "repo": "aiCodingBaseSetup",
                "lifecycle_capable": False, "operation_id": "op-1",
            })
            log = json.dumps(board.route_log)
            self.assertNotIn("native-secret", log)
            self.assertNotIn("private-label", log)
            self.assertIn("op-1", log)


if __name__ == "__main__":
    unittest.main()
