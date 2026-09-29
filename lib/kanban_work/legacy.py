"""Exact compatibility translator for evidence-bearing legacy completion."""

from __future__ import annotations

import re
from dataclasses import dataclass
from uuid import UUID

from .schema import BridgeError


DENIAL = "Use the Kanban MCP complete_ticket tool"
ISSUE_KEY = re.compile(r"^[A-Za-z][A-Za-z0-9]*-[0-9]+$")


@dataclass(frozen=True)
class LegacyComplete:
    ticket: str
    evidence: str
    references: tuple[str, ...]
    argv: tuple[str, ...]


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


def looks_like_legacy_complete(command: str) -> bool:
    return isinstance(command, str) and _looks_like(command)


def rewrite_legacy_complete(command: str, handle: str) -> list[str]:
    """Pin an evidence-bearing completion to the calling session's handle."""
    parsed = parse_legacy_complete(command)
    if parsed is None:
        raise BridgeError(422, DENIAL)
    return [*parsed.argv, "--work-handle", handle]
