"""Exact compatibility translator for evidence-bearing legacy completion."""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import UTC, datetime
from uuid import UUID

from .schema import BridgeError, normalize_tool_args
from .store import NativeIdentity, Store


DENIAL = "Use the Kanban MCP complete_ticket tool"
ISSUE_KEY = re.compile(r"^[A-Za-z][A-Za-z0-9]*-[0-9]+$")


@dataclass(frozen=True)
class LegacyComplete:
    ticket: str
    evidence: str
    references: tuple[str, ...]
    argv: tuple[str, ...]


@dataclass(frozen=True)
class PreparedLegacyComplete:
    handle: str
    args: dict
    rewritten_argv: list[str]


def _looks_like(command: str) -> bool:
    stripped = command.lstrip()
    command_match = (
        re.match(r"^kanban-post(?:\s|$)", stripped)
        or re.match(r"^(?:\.?\.?/|/).*kanban-post(?:\s|$)", stripped)
        or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=.*\s+kanban-post(?:\s|$)", stripped)
    )
    return bool(
        command_match
        and re.search(r"(?:^|\s)--done\b", stripped)
        and re.search(r"(?:^|\s)--evidence\b", stripped)
    )


def _deny():
    raise BridgeError(422, DENIAL)


def _tokenize(command: str) -> list[str]:
    if not isinstance(command, str) or "\n" in command or "\r" in command or "\\\n" in command:
        _deny()
    tokens: list[str] = []
    current: list[str] = []
    quote = None
    token_started = False
    i = 0
    while i < len(command):
        char = command[i]
        if quote is None:
            if char.isspace():
                if token_started:
                    tokens.append("".join(current)); current = []; token_started = False
                i += 1; continue
            if char in "'\"":
                quote = char; token_started = True; i += 1; continue
            if char in "$`;|&<>()*?[]{}\\":
                _deny()
            current.append(char); token_started = True; i += 1; continue
        if char == quote:
            quote = None; i += 1; continue
        if char in "`;|&<>()*?[]{}\\" or (char == "$" and quote != "'"):
            _deny()
        current.append(char); token_started = True; i += 1
    if quote is not None:
        _deny()
    if token_started:
        tokens.append("".join(current))
    return tokens


def _ticket(value: str) -> bool:
    if ISSUE_KEY.fullmatch(value):
        return True
    try:
        return str(UUID(value)) == value.lower()
    except (ValueError, AttributeError):
        return False


def parse_legacy_complete(command: str) -> LegacyComplete | None:
    if not _looks_like(command):
        return None
    argv = _tokenize(command)
    if len(argv) < 5 or argv[:2] != ["kanban-post", "--done"] or argv[3] != "--evidence":
        _deny()
    if not _ticket(argv[2]) or not argv[4].strip():
        _deny()
    references = []
    rest = argv[5:]
    if len(rest) % 2:
        _deny()
    for index in range(0, len(rest), 2):
        if rest[index] != "--reference" or not rest[index + 1].strip():
            _deny()
        references.append(rest[index + 1])
    return LegacyComplete(argv[2], argv[4], tuple(references), tuple(argv))


def prepare_legacy_complete(identity: NativeIdentity, native_call_id: str, command: str, *,
                            store: Store | None = None, now: datetime | None = None) -> PreparedLegacyComplete:
    parsed = parse_legacy_complete(command)
    if parsed is None:
        raise BridgeError(422, DENIAL)
    owned_store = store is None
    store = store or Store()
    try:
        execution = store.execution_for_identity(identity)
        if execution is None:
            raise BridgeError(403, "native execution has no Kanban work handle")
        if execution.state != "bound" or not execution.cache_trusted:
            raise BridgeError(409, "native execution has no trusted bound work session")
        claim = store.active_claim(execution.handle)
        if claim is None:
            raise BridgeError(409, "native work session has no current claim")
        targets = {str(claim["ticket"]).upper()}
        if claim.get("ticket_id"):
            targets.add(str(claim["ticket_id"]).upper())
        if parsed.ticket.upper() not in targets:
            raise BridgeError(409, "legacy completion target is not the native session's current claim")
        args = {
            "handle": execution.handle,
            "claim_id": claim["id"],
            "evidence": parsed.evidence,
            "references": list(parsed.references),
            "operation_id": None,
        }
        normalized = normalize_tool_args("complete_ticket", args)
        store.permit_call(identity, native_call_id, "complete_ticket", normalized,
                          now or datetime.now(UTC))
        return PreparedLegacyComplete(execution.handle, args,
                                      [*parsed.argv, "--work-handle", execution.handle])
    finally:
        if owned_store:
            store.close()
