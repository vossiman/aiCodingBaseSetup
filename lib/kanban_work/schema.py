"""Shared validation for native Kanban lifecycle events."""

from __future__ import annotations

from uuid import UUID


MAX_OPAQUE = 300
# The only Kanban tool the pre-tool hook inspects, and only by name: a claim
# must not be admitted while the previous turn's Stop is unsettled.
CLAIM_TOOL = "claim_ticket"


class BridgeError(Exception):
    """A redacted public error with an HTTP-like numeric code."""

    def __init__(self, code: int, message: str):
        super().__init__(message)
        self.code = code
        self.message = message

    @property
    def transient(self) -> bool:
        """True when the board never answered, so the outcome is unknown."""
        return self.code >= 500


def validate_local_handle(value) -> str:
    """Validate and return a canonical UUID used as a local work handle."""
    if not isinstance(value, str) or not value.strip() or len(value) > MAX_OPAQUE:
        raise BridgeError(422, f"handle must be a nonempty string of at most {MAX_OPAQUE} characters")
    try:
        parsed = UUID(value)
    except (ValueError, AttributeError):
        raise BridgeError(422, "handle must be a UUID") from None
    if str(parsed) != value:
        raise BridgeError(422, "handle must use canonical UUID form")
    return value.lower()


LIFECYCLE_CLIENTS = frozenset({"claude", "codex", "cursor", "opencode"})


def qualified_client_version(harness: str, version: str) -> bool:
    """Every supported harness is trusted; a client update that breaks hooks shows up in use."""
    return isinstance(harness, str) and harness in LIFECYCLE_CLIENTS
