"""HttpTransport keeps kanban-post's credential rules in process."""

import json
import socket
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock

from lib.kanban_work import transport
from lib.kanban_work.schema import BridgeError
from lib.kanban_work.transport import HttpTransport, LIFECYCLE_OPERATIONS, fetch_instructions
from tests.python.fake_board import INSTRUCTIONS, TOKEN, FakeBoardServer

ROOT = Path(__file__).resolve().parents[2]
KANBAN_WORK = ROOT / "bin" / "kanban-work"
SESSION = "11111111-1111-4111-8111-111111111111"


class HostileServer:
    """A loopback server whose answer is scripted per test."""

    def __init__(self, respond):
        self.seen: list[tuple[str, str, str]] = []
        server = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def _serve(self):
                server.seen.append((self.command, self.path, self.headers.get("Authorization", "")))
                status, headers, body = respond(self)
                try:
                    self.send_response(status)
                    for name, value in headers.items():
                        self.send_header(name, value)
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            do_GET = do_POST = _serve

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.httpd.daemon_threads = True
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.httpd.server_address[1]}"

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


def json_answer(status, value):
    return lambda handler: (status, {"Content-Type": "application/json"}, json.dumps(value).encode())


class TransportCase(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name) / "home"
        self.home.mkdir()

    def write_store(self, text: str):
        store = self.home / ".aicodingsetup"
        store.mkdir(exist_ok=True)
        (store / ".secrets.env").write_text(text)

    def serve(self, respond) -> HostileServer:
        server = HostileServer(respond)
        self.addCleanup(server.close)
        return server

    def board(self) -> FakeBoardServer:
        fake = FakeBoardServer()
        self.addCleanup(fake.close)
        return fake

    def transport(self, url: str | None, **extra) -> HttpTransport:
        environ = dict(extra)
        if url is not None:
            environ.setdefault("KANBAN_URL", url)
            environ.setdefault("KANBAN_TEST_TOKEN", TOKEN)
        return HttpTransport(home=self.home, environ=environ)


class RouteTests(TransportCase):
    def test_each_lifecycle_operation_reaches_its_route(self):
        self.assertEqual(LIFECYCLE_OPERATIONS, frozenset({
            "register_session", "session_activity", "release_active",
            "cancel_stop", "end_session", "mcp_instructions",
        }))
        fake = self.board()
        send = self.transport(fake.url)
        register = {"harness": "claude", "native_session_id": "native-1",
                    "run_generation": "gen-1", "label": "test", "lifecycle_capable": True,
                    "operation_id": "op-register", "repo": "aiCodingBaseSetup"}
        session = send("register_session", register)["id"]
        calls = [
            ("session_activity", {"work_session_id": session, "operation_id": "op-a",
                                  "run_generation": "gen-1",
                                  "observed_at": "2026-10-29T00:00:00Z", "sequence": 1},
             f"/api/work/sessions/{session}/activity"),
            ("release_active", {"work_session_id": session, "operation_id": "op-r",
                                "observed_at": "2026-10-29T00:00:00Z", "reason": "paused"},
             f"/api/work/sessions/{session}/release-active"),
            ("cancel_stop", {"work_session_id": session, "operation_id": "op-c"},
             f"/api/work/sessions/{session}/cancel-stop"),
            ("end_session", {"work_session_id": session, "operation_id": "op-e"},
             f"/api/work/sessions/{session}/end"),
        ]
        for operation, payload, _ in calls:
            send(operation, payload)
        send("mcp_instructions", {})
        recorded = fake.board.calls
        self.assertEqual(recorded[0], ("POST", "/api/work/sessions", register))
        for (operation, payload, path), call in zip(calls, recorded[1:5]):
            body = {key: value for key, value in payload.items() if key != "work_session_id"}
            self.assertEqual(call, ("POST", path, body), operation)
        self.assertEqual(recorded[5], ("GET", "/api/mcp/instructions", None))
        self.assertEqual(len(recorded), 6)

    def test_session_id_is_quoted_and_required(self):
        server = self.serve(json_answer(200, {}))
        send = self.transport(server.url)
        send("cancel_stop", {"work_session_id": "a/b c", "operation_id": "op"})
        self.assertEqual(server.seen[0][1], "/api/work/sessions/a%2Fb%20c/cancel-stop")
        for payload in ({"operation_id": "op"}, {"work_session_id": 7, "operation_id": "op"}):
            with self.assertRaises(ValueError):
                send("end_session", payload)
        self.assertEqual(len(server.seen), 1)

    def test_mcp_instructions_returns_board_text(self):
        fake = self.board()
        self.assertEqual(fetch_instructions(self.transport(fake.url)), INSTRUCTIONS)

    def test_unknown_operation_is_a_value_error_and_sends_nothing(self):
        fake = self.board()
        with self.assertRaises(ValueError):
            self.transport(fake.url)("create_ticket", {"title": "x"})
        self.assertEqual(fake.board.calls, [])


class ErrorTests(TransportCase):
    def test_board_error_carries_status_and_detail(self):
        server = self.serve(json_answer(409, {"detail": "conflict"}))
        with self.assertRaises(BridgeError) as caught:
            self.transport(server.url)("cancel_stop", {"work_session_id": SESSION,
                                                      "operation_id": "op"})
        self.assertEqual(caught.exception.code, 409)
        self.assertEqual(caught.exception.message, "conflict")

    def test_structured_detail_and_bodyless_errors(self):
        server = self.serve(json_answer(422, {"detail": [{"loc": ["body"], "msg": "bad"}]}))
        with self.assertRaises(BridgeError) as caught:
            self.transport(server.url)("mcp_instructions", {})
        self.assertEqual(caught.exception.code, 422)
        self.assertEqual(caught.exception.message, '[{"loc":["body"],"msg":"bad"}]')
        server = self.serve(json_answer(500, {"other": 1}))
        with self.assertRaises(BridgeError) as caught:
            self.transport(server.url)("mcp_instructions", {})
        self.assertEqual((caught.exception.code, caught.exception.message),
                         (500, "board returned HTTP error"))

    def test_echoed_token_is_redacted(self):
        server = self.serve(lambda handler: (
            500, {"Content-Type": "application/json"},
            json.dumps({"detail": handler.headers.get("Authorization")}).encode()))
        with self.assertRaises(BridgeError) as caught:
            self.transport(server.url)("mcp_instructions", {})
        error = caught.exception
        self.assertEqual(server.seen[0][2], f"Bearer {TOKEN}")
        self.assertEqual(error.code, 500)
        self.assertNotIn(TOKEN, str(error))
        self.assertNotIn(TOKEN, error.message)
        self.assertIn("<redacted>", error.message)

    def test_redirect_is_refused_and_not_followed(self):
        target = self.serve(json_answer(200, {"instructions": "stolen"}))
        origin = self.serve(lambda handler: (
            302, {"Location": f"{target.url}/stolen"}, b""))
        with self.assertRaises(BridgeError) as caught:
            self.transport(origin.url)("mcp_instructions", {})
        self.assertEqual(caught.exception.code, 502)
        self.assertIn("redirect", caught.exception.message)
        self.assertEqual(len(origin.seen), 1)
        self.assertEqual(target.seen, [])

    def test_non_loopback_override_is_refused_before_any_request(self):
        self.write_store(f"KANBAN_TOKEN={TOKEN}\n")
        opened = mock.Mock(side_effect=AssertionError("a request was attempted"))
        read_store = mock.Mock(side_effect=AssertionError("the store was read"))
        with mock.patch.object(urllib.request.OpenerDirector, "open", opened), \
                mock.patch.object(transport, "_store_token", read_store):
            for url in ("https://kanban.example.invalid", "ftp://127.0.0.1"):
                with self.assertRaises(BridgeError) as caught:
                    self.transport(url)("mcp_instructions", {})
                self.assertEqual(caught.exception.code, 502)
            self.assertIn("loopback", self.refusal("https://kanban.example.invalid"))
        opened.assert_not_called()
        read_store.assert_not_called()

    def refusal(self, url) -> str:
        try:
            self.transport(url)("mcp_instructions", {})
        except BridgeError as error:
            return error.message
        self.fail("the override was accepted")

    def test_test_url_requires_test_token(self):
        self.write_store("KANBAN_TOKEN=real-looking\n")
        server = self.serve(json_answer(200, {"instructions": "x"}))
        send = HttpTransport(home=self.home, environ={"KANBAN_URL": server.url,
                                                      "KANBAN_TOKEN": "from-env"})
        with self.assertRaises(BridgeError) as caught:
            send("mcp_instructions", {})
        self.assertEqual(caught.exception.code, 401)
        self.assertNotIn("real-looking", caught.exception.message)
        self.assertEqual(server.seen, [])

    def test_missing_store_or_token_is_401(self):
        environ = {"KANBAN_TOKEN": "from-env"}
        opened = mock.Mock(side_effect=AssertionError("a request was attempted"))
        with mock.patch.object(urllib.request.OpenerDirector, "open", opened):
            with self.assertRaises(BridgeError) as caught:
                HttpTransport(home=self.home, environ=environ)("mcp_instructions", {})
            self.assertEqual(caught.exception.code, 401)
            self.write_store("OTHER=x\nKANBAN_TOKEN=\n")
            with self.assertRaises(BridgeError) as caught:
                HttpTransport(home=self.home, environ=environ)("mcp_instructions", {})
            self.assertEqual(caught.exception.code, 401)
            self.assertNotIn("from-env", caught.exception.message)
        opened.assert_not_called()

    def test_store_token_is_sent_as_bearer(self):
        fake = self.board()
        self.write_store(f'OTHER=x\nKANBAN_TOKEN="{TOKEN}"\n')
        with mock.patch.object(transport, "DEFAULT_URL", fake.url):
            send = HttpTransport(home=self.home, environ={"KANBAN_TOKEN": "from-env"})
            self.assertEqual(fetch_instructions(send), INSTRUCTIONS)
        self.assertEqual(fake.board.calls, [("GET", "/api/mcp/instructions", None)])

    def test_timeout_is_504(self):
        listener = socket.socket()
        self.addCleanup(listener.close)
        listener.bind(("127.0.0.1", 0))
        listener.listen(8)
        url = f"http://127.0.0.1:{listener.getsockname()[1]}"
        start = time.monotonic()
        with self.assertRaises(BridgeError) as caught:
            self.transport(url)("mcp_instructions", {}, timeout=0.2)
        self.assertEqual(caught.exception.code, 504)
        self.assertLess(time.monotonic() - start, 2)

    def test_slow_streaming_body_hits_the_deadline(self):
        listener = socket.socket()
        self.addCleanup(listener.close)
        listener.bind(("127.0.0.1", 0))
        listener.listen(8)

        def trickle():
            connection, _ = listener.accept()
            with connection:
                connection.recv(65536)
                connection.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                                   b"Content-Length: 50\r\n\r\n")
                try:
                    for _ in range(50):
                        connection.sendall(b" ")
                        time.sleep(0.1)
                except OSError:
                    pass

        threading.Thread(target=trickle, daemon=True).start()
        url = f"http://127.0.0.1:{listener.getsockname()[1]}"
        start = time.monotonic()
        with self.assertRaises(BridgeError) as caught:
            self.transport(url)("mcp_instructions", {}, timeout=0.5)
        self.assertEqual(caught.exception.code, 504)
        self.assertLess(time.monotonic() - start, 1.5)

    def test_slow_response_headers_hit_the_deadline(self):
        listener = socket.socket()
        self.addCleanup(listener.close)
        listener.bind(("127.0.0.1", 0))
        listener.listen(8)
        head = (b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                b"X-Padding: " + b"x" * 64 + b"\r\nContent-Length: 2\r\n\r\n{}")

        def trickle():
            connection, _ = listener.accept()
            with connection:
                connection.recv(65536)
                try:
                    for byte in head[:50]:
                        connection.sendall(bytes([byte]))
                        time.sleep(0.1)
                except OSError:
                    pass

        threading.Thread(target=trickle, daemon=True).start()
        url = f"http://127.0.0.1:{listener.getsockname()[1]}"
        start = time.monotonic()
        with self.assertRaises(BridgeError) as caught:
            self.transport(url)("mcp_instructions", {}, timeout=0.5)
        self.assertEqual(caught.exception.code, 504)
        self.assertLess(time.monotonic() - start, 1.5)

    def test_unreachable_board_is_502(self):
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        with self.assertRaises(BridgeError) as caught:
            self.transport(f"http://127.0.0.1:{port}")("mcp_instructions", {})
        self.assertEqual(caught.exception.code, 502)
        self.assertTrue(caught.exception.message.startswith("cannot reach the board: "))

    def test_token_echoed_in_a_success_body_is_redacted(self):
        server = self.serve(lambda handler: (
            200, {"Content-Type": "application/json"},
            json.dumps({"instructions": handler.headers.get("Authorization"),
                        "nested": [{"value": TOKEN}]}).encode()))
        send = self.transport(server.url)
        data = send("mcp_instructions", {})
        self.assertNotIn(TOKEN, json.dumps(data))
        self.assertEqual(data["nested"], [{"value": "<redacted>"}])
        text = fetch_instructions(send)
        self.assertEqual(text, "Bearer <redacted>")
        result = subprocess.run(
            ["python3", str(KANBAN_WORK), "--json", "instructions"], input="{}",
            capture_output=True, text=True, timeout=30,
            env={"HOME": str(self.home), "PATH": "/usr/local/bin:/usr/bin:/bin",
                 "KANBAN_URL": server.url, "KANBAN_TEST_TOKEN": TOKEN,
                 "AICODINGSETUP_SKIP_NETWORK": "1", "PYTHONDONTWRITEBYTECODE": "1"},
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn(TOKEN, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["data"]["text"], "Bearer <redacted>")

    def test_empty_success_body_is_502(self):
        for body in (b"", b"not json", b'"a string"'):
            server = self.serve(lambda handler, body=body: (200, {}, body))
            with self.assertRaises(BridgeError) as caught:
                self.transport(server.url)("mcp_instructions", {})
            self.assertEqual(caught.exception.code, 502)
            self.assertEqual(caught.exception.message,
                             "kanban transport returned invalid success data")


if __name__ == "__main__":
    unittest.main()
