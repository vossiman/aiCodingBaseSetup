"""Prove HttpTransport's credential rules against throwaway loopback servers.

Touches neither the real board nor the real secrets store: the transport gets
an explicit temporary home and environment.
"""

from __future__ import annotations

import contextlib
import io
import json
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from .schema import BridgeError
from .transport import HttpTransport

TEST_TOKEN = "FAKE-KANBAN-SELFTEST-TOKEN-do-not-use"
STORE_TOKEN = "FAKE-KANBAN-SELFTEST-STORE-do-not-use"


class _Server:
    def __init__(self, redirect_to: str | None = None):
        self.seen: list[str] = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def _serve(self):
                authorization = self.headers.get("Authorization", "")
                owner.seen.append(authorization)
                if redirect_to and self.path.startswith("/redirect"):
                    status, headers, body = 302, {"Location": f"{redirect_to}/stolen"}, b""
                elif self.path.startswith("/ok"):
                    status, headers = 200, {"Content-Type": "application/json"}
                    body = json.dumps({"instructions": authorization}).encode()
                else:
                    status, headers = 500, {"Content-Type": "application/json"}
                    body = json.dumps({"detail": authorization}).encode()
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


def _leaks(text: str) -> bool:
    return TEST_TOKEN in text or STORE_TOKEN in text


def _attempt(home: Path, environ: dict):
    try:
        return HttpTransport(home=home, environ=environ)("mcp_instructions", {}, timeout=10)
    except BridgeError as error:
        return error


def _checks(home: Path, origin: _Server, target: _Server) -> list[str]:
    failures = []
    test_run = {"KANBAN_TEST_TOKEN": TEST_TOKEN}

    result = _attempt(home, {**test_run, "KANBAN_URL": origin.url})
    if not isinstance(result, BridgeError):
        failures.append("echoing error: the board's 500 was not raised")
    elif _leaks(result.message) or _leaks(str(result)) or "<redacted>" not in result.message:
        failures.append("echoing error: the token was not redacted from the error message")
    if origin.seen[-1:] != [f"Bearer {TEST_TOKEN}"]:
        failures.append("echoing error: the test token was not the credential sent")

    result = _attempt(home, {**test_run, "KANBAN_URL": f"{origin.url}/ok"})
    if isinstance(result, BridgeError):
        failures.append(f"echoing success: the call failed with {result.code}")
    elif _leaks(json.dumps(result)):
        failures.append("echoing success: the token was not redacted from the response")

    before = len(origin.seen)
    result = _attempt(home, {**test_run, "KANBAN_URL": f"{origin.url}/redirect"})
    if not isinstance(result, BridgeError) or result.code != 502 or "redirect" not in result.message:
        failures.append("redirect: was not refused")
    if len(origin.seen) != before + 1 or target.seen:
        failures.append("redirect: Authorization reached a second location")

    before = len(origin.seen)
    result = _attempt(home, {"KANBAN_URL": origin.url})
    if not isinstance(result, BridgeError) or result.code != 401 or len(origin.seen) != before:
        failures.append("test destination: a request was sent without KANBAN_TEST_TOKEN")

    result = _attempt(home, {**test_run, "KANBAN_URL": "https://kanban.example.invalid"})
    if not isinstance(result, BridgeError) or "loopback" not in result.message:
        failures.append("destination: an arbitrary https host was not refused")

    if any(STORE_TOKEN in seen for seen in origin.seen + target.seen):
        failures.append("store: the stored credential was sent to a test destination")
    return failures


def run_selftest() -> int:
    origin = target = None
    with tempfile.TemporaryDirectory() as temp:
        home = Path(temp)
        (home / ".aicodingsetup").mkdir()
        (home / ".aicodingsetup" / ".secrets.env").write_text(f"OTHER=x\nKANBAN_TOKEN={STORE_TOKEN}\n")
        captured = io.StringIO()
        try:
            target = _Server()
            origin = _Server(redirect_to=target.url)
            with contextlib.redirect_stdout(captured), contextlib.redirect_stderr(captured):
                failures = _checks(home, origin, target)
        except Exception as error:
            failures = [f"selftest crashed: {type(error).__name__}"]
        finally:
            for server in (origin, target):
                if server is not None:
                    server.close()
    if _leaks(captured.getvalue()):
        failures.append("output: the token reached stdout or stderr")
    for failure in failures:
        print("FAIL", failure)
    if failures:
        return 1
    print("selftest: ok (token never reached output or errors; redirects refused; "
          "non-loopback destinations refused)")
    return 0
