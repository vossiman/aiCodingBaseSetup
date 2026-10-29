"""In-process transport to the board for the six lifecycle operations.

The credential is read from the secrets store inside this process and placed in
one Authorization header. It never enters argv, the environment or output: the
host is pinned, a KANBAN_URL override must name a loopback test server and then
only KANBAN_TEST_TOKEN is sent, redirects are refused, and every error message
and every successful response is scrubbed of the token in use.
"""

from __future__ import annotations

import http.client
import json
import os
import re
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Mapping

from .schema import BridgeError


DEFAULT_TIMEOUT = 30.0
DEFAULT_URL = "https://kanban.dataprospectors.at"
LOOPBACK = frozenset({"127.0.0.1", "localhost", "::1"})
LIFECYCLE_OPERATIONS = frozenset({
    "register_session", "session_activity", "release_active",
    "cancel_stop", "end_session", "mcp_instructions",
})
SESSION_SUFFIXES = {
    "session_activity": "activity",
    "release_active": "release-active",
    "cancel_stop": "cancel-stop",
    "end_session": "end",
}
CHUNK = 16 * 1024
REDACTED = "<redacted>"
GITHUB_REMOTE = re.compile(
    r"^(?:https://|ssh://git@|git@)github\.com[:/][^/]+/([^/]+?)(?:\.git)?/?$"
)


class _NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise BridgeError(502, "refusing to follow a redirect")


def _route(operation: str, payload: dict) -> tuple[str, str, dict | None]:
    if operation not in LIFECYCLE_OPERATIONS:
        raise ValueError(f"{operation!r} is not a lifecycle operation")
    if not isinstance(payload, dict):
        raise ValueError("payload must be a dict")
    if operation == "mcp_instructions":
        return "GET", "/api/mcp/instructions", None
    if operation == "register_session":
        return "POST", "/api/work/sessions", payload
    session = payload.get("work_session_id")
    if not isinstance(session, str):
        raise ValueError(f"{operation} needs a string work_session_id")
    body = {key: value for key, value in payload.items() if key != "work_session_id"}
    path = f"/api/work/sessions/{urllib.parse.quote(session, safe='')}/{SESSION_SUFFIXES[operation]}"
    return "POST", path, body


def _store_token(home: Path) -> str:
    store = home / ".aicodingsetup" / ".secrets.env"
    if not store.is_file():
        raise BridgeError(401, f"no secrets store at {store}")
    try:
        lines = store.read_text().splitlines()
    except (OSError, UnicodeDecodeError):
        raise BridgeError(401, f"cannot read the secrets store at {store}") from None
    for line in lines:
        line = line.strip()
        if line.startswith("KANBAN_TOKEN="):
            value = line.split("=", 1)[1].strip().strip('"').strip("'")
            if value:
                return value
            break
    raise BridgeError(401, "KANBAN_TOKEN is not set in the secrets store")


def _scrub(value, secret: str | None):
    if not secret:
        return value
    if isinstance(value, str):
        return value.replace(secret, REDACTED)
    if isinstance(value, list):
        return [_scrub(item, secret) for item in value]
    if isinstance(value, dict):
        return {_scrub(key, secret): _scrub(item, secret) for key, item in value.items()}
    return value


def _error_message(value) -> str:
    if isinstance(value, dict):
        detail = value.get("detail")
        if isinstance(detail, str):
            return detail
        if detail is not None:
            return json.dumps(detail, separators=(",", ":"))
    if isinstance(value, str):
        return value
    return "board returned HTTP error"


def _remaining(deadline: float) -> float:
    left = deadline - time.monotonic()
    if left <= 0:
        raise TimeoutError
    return left


def _read_body(response, deadline: float) -> bytes:
    chunks = []
    while True:
        left = _remaining(deadline)
        sock = getattr(getattr(getattr(response, "fp", None), "raw", None), "_sock", None)
        if sock is not None:
            sock.settimeout(left)
        chunk = response.read1(CHUNK)
        if not chunk:
            return b"".join(chunks)
        chunks.append(chunk)


class HttpTransport:
    """Call one lifecycle operation; errors carry the board's status, or 5xx if it never answered."""

    def __init__(self, *, home: Path | None = None, environ: Mapping[str, str] | None = None):
        self.home = Path.home() if home is None else Path(home)
        self.environ = os.environ if environ is None else environ

    def _base_url(self) -> str:
        override = self.environ.get("KANBAN_URL")
        if not override:
            return DEFAULT_URL
        url = override.rstrip("/")
        parts = urllib.parse.urlsplit(url)
        if parts.scheme not in {"http", "https"}:
            raise BridgeError(502, "KANBAN_URL must use http or https")
        if (parts.hostname or "") in LOOPBACK:
            return url
        raise BridgeError(
            502, "KANBAN_URL may only name a loopback test server; refusing to send "
                 f"a bearer token to {parts.hostname or 'a schemeless URL'}")

    def _token(self) -> str:
        if self.environ.get("KANBAN_URL"):
            value = self.environ.get("KANBAN_TEST_TOKEN", "")
            if not value:
                raise BridgeError(
                    401, "KANBAN_URL is set, so this is a test run; supply a fake credential "
                         "in KANBAN_TEST_TOKEN. The secrets store is not read for a test destination.")
            return value
        return _store_token(self.home)

    def __call__(self, operation: str, payload: dict, *, timeout: float = DEFAULT_TIMEOUT):
        deadline = time.monotonic() + timeout
        method, path, body = _route(operation, payload)
        url = self._base_url() + path
        secret = self._token()
        try:
            return _scrub(self._request(method, url, body, secret, deadline), secret)
        except BridgeError as error:
            raise BridgeError(error.code, _scrub(error.message, secret)) from None

    def _request(self, method: str, url: str, body: dict | None, secret: str, deadline: float):
        request = urllib.request.Request(
            url, method=method,
            data=None if body is None else json.dumps(body, separators=(",", ":")).encode(),
            headers={"Authorization": f"Bearer {secret}", "Content-Type": "application/json"},
        )
        opener = urllib.request.build_opener(_NoRedirects)
        try:
            try:
                with opener.open(request, timeout=_remaining(deadline)) as response:
                    raw = _read_body(response, deadline)
            except urllib.error.HTTPError as error:
                with error:
                    raw = _read_body(error.fp, deadline) if error.fp is not None else b""
                text = raw.decode(errors="replace")
                try:
                    value = json.loads(text)
                except ValueError:
                    value = text
                if error.code < 400:
                    raise BridgeError(502, "board returned HTTP error") from None
                raise BridgeError(error.code, _error_message(value)) from None
        except BridgeError:
            raise
        except TimeoutError:
            raise BridgeError(504, "kanban transport timed out") from None
        except urllib.error.URLError as error:
            if isinstance(error.reason, TimeoutError):
                raise BridgeError(504, "kanban transport timed out") from None
            raise BridgeError(502, f"cannot reach the board: {error.reason}") from None
        except (OSError, http.client.HTTPException, ValueError) as error:
            raise BridgeError(502, f"cannot reach the board: {type(error).__name__}") from None
        try:
            data = json.loads(raw)
        except ValueError:
            data = None
        if not isinstance(data, (dict, list)):
            raise BridgeError(502, "kanban transport returned invalid success data")
        return data


def derive_github_repo(checkout: str) -> str | None:
    """The GitHub repository name of a checkout's origin, or None outside one."""
    if not isinstance(checkout, str) or not os.path.isabs(checkout):
        return None
    try:
        result = subprocess.run(
            ["git", "remote", "get-url", "origin"], cwd=checkout,
            text=True, capture_output=True, shell=False, timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode:
        return None
    match = GITHUB_REMOTE.match(result.stdout.strip())
    return match.group(1) if match else None


def fetch_instructions(transport=None, *, timeout: float = 3.0) -> str | None:
    """Server instructions for clients that do not surface MCP initialize instructions."""
    try:
        data = (transport or HttpTransport())("mcp_instructions", {}, timeout=timeout)
    except BridgeError:
        return None
    text = data.get("instructions") if isinstance(data, dict) else None
    return text if isinstance(text, str) and text.strip() else None
