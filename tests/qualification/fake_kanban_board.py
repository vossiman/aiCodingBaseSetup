"""Loopback-only board used by native-client qualification tests."""

from __future__ import annotations

import hashlib
import json
import threading
import uuid
from datetime import UTC, datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit


FAKE_TOKEN = "FAKE-KANBAN-QUALIFICATION-TOKEN"


class FakeKanbanBoard:
    """Small in-memory board. It cannot bind or redirect outside loopback."""

    address = "127.0.0.1"

    def __init__(self):
        self.now = datetime(2026, 9, 12, 12, tzinfo=UTC)
        self.tickets: dict[str, dict] = {}
        self.sessions: dict[str, dict] = {}
        self.claims: dict[str, dict] = {}
        self.route_log: list[dict] = []
        self._server = ThreadingHTTPServer((self.address, 0), self._handler())
        self._server.board = self
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)

    @property
    def port(self):
        return self._server.server_port

    @property
    def url(self):
        return f"http://{self.address}:{self.port}"

    def __enter__(self):
        self._thread.start()
        return self

    def __exit__(self, *_):
        self._server.shutdown()
        self._server.server_close()
        self._thread.join(timeout=2)

    def _expire(self):
        for claim in self.claims.values():
            if claim["active"] and self.now - claim["observed_at"] > timedelta(minutes=15):
                claim["active"] = False
                ticket = self.tickets[claim["ticket"]]
                ticket.update(status="todo", claim_id=None)

    @staticmethod
    def _label_hash(value):
        if not isinstance(value, str) or not value:
            return None
        return hashlib.sha256(value.encode()).hexdigest()[:12]

    def _record(self, method, route, payload):
        item = {"method": method, "route": route}
        if isinstance(payload, dict) and isinstance(payload.get("operation_id"), str):
            item["operation_id"] = payload["operation_id"][:300]
        if isinstance(payload, dict):
            actor = payload.get("native_session_id") or payload.get("work_session_id")
            label = payload.get("label")
            if actor:
                item["actor"] = self._label_hash(actor)
            if label:
                item["label"] = self._label_hash(label)
        self.route_log.append(item)

    def _handler(self):
        board = self

        class Handler(BaseHTTPRequestHandler):
            server_version = "kanban-qualification"
            sys_version = ""

            def log_message(self, *_):
                return

            def _json(self, status, value):
                encoded = json.dumps(value, separators=(",", ":")).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)

            def _authorize(self):
                expected_host = f"127.0.0.1:{board.port}"
                if self.headers.get("Host") != expected_host:
                    self._json(400, {"error": "invalid host"})
                    return False
                if self.headers.get("Authorization") != f"Bearer {FAKE_TOKEN}":
                    self._json(401, {"error": "invalid qualification credential"})
                    return False
                return True

            def _payload(self):
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                except ValueError:
                    raise ValueError("invalid content length") from None
                if length < 0 or length > 128 * 1024:
                    raise ValueError("request too large")
                if not length:
                    return {}
                value = json.loads(self.rfile.read(length))
                if not isinstance(value, dict):
                    raise ValueError("body must be an object")
                return value

            def _route(self):
                return urlsplit(self.path).path

            def do_GET(self):
                if not self._authorize():
                    return
                board._expire()
                path = self._route()
                if path == "/api/repos":
                    board._record("GET", "list_repos", {})
                    return self._json(200, [{"name": "aiCodingBaseSetup"}])
                if path.startswith("/api/tickets/"):
                    key = unquote(path.removeprefix("/api/tickets/"))
                    board._record("GET", "get_ticket", {})
                    ticket = board.tickets.get(key)
                    return self._json(200, ticket) if ticket else self._json(404, {"error": "not found"})
                if path.startswith("/api/work/sessions/"):
                    ref = unquote(path.removeprefix("/api/work/sessions/"))
                    board._record("GET", "get_session", {})
                    session = board.sessions.get(ref)
                    return self._json(200, session) if session else self._json(404, {"error": "not found"})
                board._record("GET", "unexpected", {})
                self._json(404, {"error": "unexpected route"})

            def do_POST(self):
                if not self._authorize():
                    return
                try:
                    payload = self._payload()
                except (ValueError, json.JSONDecodeError) as error:
                    return self._json(400, {"error": str(error)})
                board._expire()
                path = self._route()
                if path == "/__qualification__/clock":
                    minutes = payload.get("advance_minutes")
                    if isinstance(minutes, bool) or not isinstance(minutes, int) or not 0 <= minutes <= 120:
                        return self._json(422, {"error": "advance_minutes must be 0..120"})
                    board.now += timedelta(minutes=minutes)
                    board._expire()
                    board._record("POST", "advance_clock", payload)
                    return self._json(200, {"advanced_minutes": minutes})
                if path == "/api/tickets":
                    key = f"AICODINGBASESETUP-{len(board.tickets) + 1}"
                    ticket = {
                        "id": str(uuid.uuid4()), "key": key,
                        "title": payload.get("title", "qualification"),
                        "status": "todo", "swimlane": "needs_decision", "claim_id": None,
                    }
                    board.tickets[key] = ticket
                    board._record("POST", "create_ticket", payload)
                    return self._json(201, ticket)
                if path == "/api/work/sessions":
                    session_id = str(uuid.uuid4())
                    session = {
                        "id": session_id, "harness": payload.get("harness"),
                        "lifecycle_capable": payload.get("lifecycle_capable", False),
                        "claims": [], "ended": False,
                    }
                    board.sessions[session_id] = session
                    board._record("POST", "register_session", payload)
                    return self._json(201, session)
                prefix = "/api/work/tickets/"
                if path.startswith(prefix) and path.endswith("/claim"):
                    key = unquote(path[len(prefix):-len("/claim")])
                    ticket = board.tickets.get(key)
                    session = board.sessions.get(payload.get("work_session_id"))
                    if not ticket or not session:
                        return self._json(404, {"error": "not found"})
                    if ticket["claim_id"]:
                        return self._json(409, {"error": "live claim"})
                    claim_id = str(uuid.uuid4())
                    claim = {
                        "id": claim_id, "ticket": key, "work_session_id": session["id"],
                        "observed_at": board.now, "active": True,
                    }
                    board.claims[claim_id] = claim
                    session["claims"].append({"id": claim_id, "ticket": key})
                    ticket.update(status="doing", claim_id=claim_id)
                    board._record("POST", "claim_ticket", payload)
                    return self._json(200, {"claim": {**claim, "observed_at": board.now.isoformat()}, "ticket": ticket})
                board._record("POST", "unexpected", payload)
                self._json(404, {"error": "unexpected route"})

        return Handler


if __name__ == "__main__":
    with FakeKanbanBoard() as instance:
        print(instance.url, flush=True)
        threading.Event().wait()
