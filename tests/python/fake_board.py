"""Loopback fake of the board's session-scoped work API (kanban docs/api.md, KANBAN-8)."""

from __future__ import annotations

import json
import re
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = "FAKE-KANBAN-E2E-TOKEN-do-not-use"
INSTRUCTIONS = "# Kanban agent workflow\nClaim before implementation."


class Board:
    def __init__(self, repos=("aiCodingBaseSetup",)):
        self.lock = threading.Lock()
        self.repos = set(repos)
        self.sessions: dict[str, dict] = {}
        self.receipts: dict[str, dict] = {}
        self.claims: dict[str, dict] = {}
        self.tickets = {"AICODINGBASESETUP-1": {"id": "t-1", "key": "AICODINGBASESETUP-1",
                                                 "status": "todo"},
                        "AICODINGBASESETUP-2": {"id": "t-2", "key": "AICODINGBASESETUP-2",
                                                 "status": "todo"}}
        self.calls: list[tuple[str, str, dict | None]] = []
        self.comments: list[tuple[str, str]] = []
        # path suffix -> seconds to sleep before processing (a slow board).
        self.delays: dict[str, float] = {}
        self.late_results: list[dict] = []

    # -- helpers used by tests ---------------------------------------------

    def session_for_handle(self, handle):
        return next((s for s in self.sessions.values() if s["handle"] == handle), None)

    def live_claim(self, session_id):
        return next((c for c in self.claims.values()
                     if c["work_session_id"] == session_id and c["released_at"] is None), None)

    def claim(self, session_id, ticket_key):
        """What the hosted MCP's claim_ticket does for this session."""
        with self.lock:
            claim = {"id": str(uuid.uuid4()), "work_session_id": session_id,
                     "ticket_id": self.tickets[ticket_key]["id"], "released_at": None}
            self.claims[claim["id"]] = claim
            self.tickets[ticket_key]["status"] = "doing"
            return claim

    # -- request handling --------------------------------------------------

    def handle(self, method, path, body):
        self.calls.append((method, path, body))
        delayed = False
        for suffix, seconds in list(self.delays.items()):
            if path.endswith(suffix):
                delayed = True
                time.sleep(seconds)
        with self.lock:
            status, value = self._route(method, path, body or {})
            if delayed:
                self.late_results.append(value)
            return status, value

    def _receipt(self, operation_id, kind, session_id, result):
        prior = self.receipts.get(operation_id)
        if prior is not None:
            if prior["kind"] != kind or prior["session"] != session_id:
                return 409, {"detail": "Operation ID was already used with a different request"}
            return 200, prior["result"]
        self.receipts[operation_id] = {"kind": kind, "session": session_id, "result": result()}
        return 200, self.receipts[operation_id]["result"]

    def _session_out(self, session):
        return {**session, "claims": [c for c in self.claims.values()
                                      if c["work_session_id"] == session["id"]
                                      and c["released_at"] is None]}

    def _route(self, method, path, body):
        if method == "GET" and path == "/api/mcp/instructions":
            return 200, {"instructions": INSTRUCTIONS, "version": "0.0.0-test"}
        if method == "POST" and path == "/api/work/sessions":
            if body.get("repo") is not None and body["repo"] not in self.repos:
                return 422, {"detail": f"Unknown repo '{body['repo']}'"}
            key = (body["harness"], body["native_session_id"], body.get("subagent_id"),
                   body["run_generation"])
            for session in self.sessions.values():
                if session["key"] == key:
                    return 200, self._session_out(session)
            session = {"id": str(uuid.uuid4()), "key": key, "handle": body.get("handle"),
                       "repo": body.get("repo"), "label": body["label"],
                       "run_generation": body["run_generation"], "ended_at": None,
                       "sequence": -1}
            self.sessions[session["id"]] = session
            return 200, self._session_out(session)
        match = re.fullmatch(r"/api/work/handles/([^/]+)", path)
        if method == "GET" and match:
            session = self.session_for_handle(match.group(1))
            if session is None:
                return 409, {"detail": "Work session not registered yet; retry in a few seconds"}
            return 200, self._session_out(session)
        match = re.fullmatch(r"/api/work/sessions/([^/]+)/(activity|release-active|cancel-stop|end)", path)
        if method == "POST" and match:
            session = self.sessions.get(match.group(1))
            if session is None:
                return 404, {"detail": "Work session not found"}
            action = match.group(2)
            operation_id = body["operation_id"]
            if action == "activity":
                if body["run_generation"] != session["run_generation"] or session["ended_at"]:
                    return 409, {"detail": "Activity is for a different run generation"}
                if body["sequence"] <= session["sequence"]:
                    return 409, {"detail": "Activity sequence is not newer"}
                session["sequence"] = body["sequence"]
                claim = self.live_claim(session["id"])
                return 200, {"renewed": claim is not None, "lease_extended": claim is not None,
                             "claim": claim, "ticket": None}
            if action == "release-active":
                def release():
                    claim = self.live_claim(session["id"])
                    if claim is None:
                        return {"stop": "applied", "released": None}
                    claim["released_at"] = time.time()
                    for ticket in self.tickets.values():
                        if ticket["id"] == claim["ticket_id"]:
                            ticket["status"] = "todo"
                    return {"stop": "applied", "released": {"claim": claim, "ticket": None}}
                prior = self.receipts.get(operation_id)
                if prior is not None and prior["kind"] == "cancel":
                    return 200, prior["result"]
                return self._receipt(operation_id, "stop", session["id"], release)
            if action == "cancel-stop":
                prior = self.receipts.get(operation_id)
                if prior is not None and prior["kind"] == "stop" and prior["session"] == session["id"]:
                    return 200, prior["result"]
                return self._receipt(operation_id, "cancel", session["id"],
                                     lambda: {"stop": "cancelled", "released": None})
            session["ended_at"] = time.time()
            for claim in self.claims.values():
                if claim["work_session_id"] == session["id"]:
                    claim["released_at"] = claim["released_at"] or time.time()
            return 200, self._session_out(session)
        match = re.fullmatch(r"/api/tickets/([^/]+)", path)
        if method == "GET" and match:
            ticket = self.tickets.get(match.group(1).upper())
            return (200, ticket) if ticket else (404, {"detail": "Ticket not found"})
        if method == "PATCH" and match:
            ticket = self.tickets.get(match.group(1).upper())
            if ticket is None:
                return 404, {"detail": "Ticket not found"}
            ticket.update(body)
            return 200, ticket
        match = re.fullmatch(r"/api/tickets/([^/]+)/comments", path)
        if method == "POST" and match:
            self.comments.append((match.group(1), body["body"]))
            return 201, {"id": str(uuid.uuid4()), "body": body["body"]}
        match = re.fullmatch(r"/api/work/claims/([^/]+)/complete", path)
        if method == "POST" and match:
            claim = self.claims.get(match.group(1))
            if claim is None or claim["released_at"] is not None \
                    or claim["work_session_id"] != body["work_session_id"]:
                return 409, {"detail": "Claim is not live"}
            claim["released_at"] = time.time()
            for ticket in self.tickets.values():
                if ticket["id"] == claim["ticket_id"]:
                    ticket["status"] = "done"
            return 200, {"claim": claim, "ticket": None}
        return 404, {"detail": f"no fake route for {method} {path}"}


class _Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _serve(self):
        if self.headers.get("Authorization") != f"Bearer {TOKEN}":
            status, value = 401, {"detail": "Not authenticated"}
        else:
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length) if length else b""
            status, value = self.server.board.handle(
                self.command, self.path.split("?")[0], json.loads(raw) if raw else None)
        encoded = json.dumps(value).encode()
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)
        except (BrokenPipeError, ConnectionResetError):
            pass

    do_GET = do_POST = do_PATCH = do_DELETE = _serve


class FakeBoardServer:
    def __init__(self, board: Board | None = None):
        self.board = board or Board()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
        self.server.daemon_threads = True
        self.server.board = self.board
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.server.server_address[1]}"

    def close(self):
        self.server.shutdown()
        self.server.server_close()
