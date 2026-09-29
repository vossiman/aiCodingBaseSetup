"""Credential-free transport to the board through the kanban-post helper."""

from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path

from .schema import BridgeError


DEFAULT_TIMEOUT = 30.0
RELEASE_HELPER = Path(__file__).resolve().parents[2] / "bin" / "kanban-post"
GITHUB_REMOTE = re.compile(
    r"^(?:https://|ssh://git@|git@)github\.com[:/][^/]+/([^/]+?)(?:\.git)?/?$"
)


def _environment() -> dict:
    # kanban-post reads the credential from the secrets store itself.
    return {key: value for key, value in os.environ.items() if key != "KANBAN_TOKEN"}


class SubprocessTransport:
    """Call one kanban-post JSON operation; errors carry the board's status, or 5xx if it never answered."""

    def __init__(self, helper: str | None = None):
        # The helper from this same release, never an older one on PATH.
        self.helper = helper or str(RELEASE_HELPER)

    def __call__(self, operation: str, payload: dict, *, timeout: float = DEFAULT_TIMEOUT):
        try:
            result = subprocess.run(
                [self.helper, "--json", operation],
                input=json.dumps(payload, separators=(",", ":")), text=True,
                capture_output=True, shell=False, timeout=max(timeout, 0.1), env=_environment(),
            )
        except subprocess.TimeoutExpired:
            raise BridgeError(504, "kanban transport timed out") from None
        except (OSError, subprocess.SubprocessError) as error:
            raise BridgeError(502, f"kanban transport failed: {type(error).__name__}") from None
        try:
            envelope = json.loads(result.stdout)
        except json.JSONDecodeError:
            raise BridgeError(502, "kanban transport returned invalid JSON") from None
        if not isinstance(envelope, dict) or set(envelope) - {"ok", "data", "error"}:
            raise BridgeError(502, "kanban transport returned an invalid envelope")
        if result.returncode != 0 or envelope.get("ok") is not True:
            error = envelope.get("error")
            code = error.get("code") if isinstance(error, dict) else 502
            message = error.get("message") if isinstance(error, dict) else None
            raise BridgeError(code if isinstance(code, int) and not isinstance(code, bool) else 502,
                              message if isinstance(message, str) else "kanban transport rejected the request")
        data = envelope.get("data")
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
        data = (transport or SubprocessTransport())("mcp_instructions", {}, timeout=timeout)
    except BridgeError:
        return None
    text = data.get("instructions") if isinstance(data, dict) else None
    return text if isinstance(text, str) and text.strip() else None
