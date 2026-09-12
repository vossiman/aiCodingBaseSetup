"""Canonical local Kanban MCP argument validation and normalization."""

from __future__ import annotations

import json
import os
from datetime import date
from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType
from urllib.parse import urlsplit
from uuid import UUID


MAX_OPAQUE = 300
LOOPBACK = {"127.0.0.1", "localhost", "::1"}
STATUSES = frozenset({"backlog", "todo", "doing", "done"})
PRIORITIES = frozenset({"low", "normal", "high"})
SWIMLANES = frozenset({"required", "nice_to_have", "waiting_for_feedback", "needs_decision"})
LINK_KINDS = frozenset({"depends_on", "blocks", "relates"})
RELEASE_REASONS = frozenset({"paused", "feedback", "stopped"})


class BridgeError(Exception):
    """A redacted public bridge error with an HTTP-like numeric code."""

    def __init__(self, code: int, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


@dataclass(frozen=True)
class ToolSpec:
    required: tuple[str, ...]
    defaults: MappingProxyType

    @property
    def allowed(self) -> frozenset[str]:
        return frozenset(self.required) | frozenset(self.defaults)


def _spec(required=(), **defaults) -> ToolSpec:
    return ToolSpec(tuple(required), MappingProxyType(defaults))


TOOL_SPECS = MappingProxyType({
    "bind_work_session": _spec(("handle",), label=None, checkout=None, operation_id=None),
    "create_ticket": _spec(("handle", "title"), checkout=None, body=None, status=None,
                           priority=None, swimlane=None, due_date=None, operation_id=None),
    "update_ticket": _spec(("handle", "ticket"), fields={}, operation_id=None),
    "add_comment": _spec(("handle", "ticket", "body"), operation_id=None),
    "link_tickets": _spec(("handle", "ticket", "target", "kind"), operation_id=None),
    "unlink_tickets": _spec(("handle", "ticket", "target"), kind=None, operation_id=None),
    "claim_ticket": _spec(("handle", "ticket"), operation_id=None),
    "checkpoint_work": _spec(("handle", "claim_id", "checkpoint"), operation_id=None),
    "release_ticket": _spec(("handle", "claim_id", "handoff", "reason"),
                            feedback_target=None, swimlane=None, operation_id=None),
    "complete_ticket": _spec(("handle", "claim_id", "evidence"), references=[], operation_id=None),
    "end_work_session": _spec(("handle",), handoff=None, operation_id=None),
})

TOOL_TO_BRIDGE_OPERATION = MappingProxyType({
    "create_ticket": "create_ticket",
    "update_ticket": "update_ticket",
    "add_comment": "add_comment",
    "link_tickets": "link_tickets",
    "unlink_tickets": "unlink_tickets",
    "claim_ticket": "claim_ticket",
    "checkpoint_work": "checkpoint_work",
    "release_ticket": "release_ticket",
    "complete_ticket": "complete_ticket",
    "end_work_session": "end_session",
})
READ_TOOLS = frozenset({"list_repos", "list_tickets", "get_ticket", "my_work"})


def _text(value, name: str, maximum: int = MAX_OPAQUE, *, blank: bool = False) -> str:
    if not isinstance(value, str) or len(value) > maximum or (not blank and not value.strip()):
        raise BridgeError(422, f"{name} must be a nonempty string of at most {maximum} characters")
    return value


def _optional_text(value, name: str, maximum: int = MAX_OPAQUE, *, blank: bool = False):
    return None if value is None else _text(value, name, maximum, blank=blank)


def _enum(value, name: str, choices: frozenset[str]):
    if not isinstance(value, str) or value not in choices:
        raise BridgeError(422, f"{name} must be one of {', '.join(sorted(choices))}")
    return value


def validate_local_handle(value) -> str:
    """Validate and return a canonical UUID used as a local work handle."""
    value = _text(value, "handle")
    try:
        parsed = UUID(value)
    except (ValueError, AttributeError):
        raise BridgeError(422, "handle must be a UUID") from None
    if str(parsed) != value:
        raise BridgeError(422, "handle must use canonical UUID form")
    return value.lower()


def _validate_fields(fields) -> dict:
    if not isinstance(fields, dict):
        raise BridgeError(422, "fields must be an object")
    allowed = {"title", "body", "status", "priority", "swimlane", "due_date", "position"}
    unknown = sorted(set(fields) - allowed)
    if unknown:
        raise BridgeError(422, f"unknown field {unknown[0]!r} for update_ticket")
    if "title" in fields:
        _text(fields["title"], "title", 10_000)
    if "body" in fields and fields["body"] is not None:
        _text(fields["body"], "body", 100_000, blank=True)
    for key, values in (("status", STATUSES), ("priority", PRIORITIES), ("swimlane", SWIMLANES)):
        if key in fields and fields[key] is not None:
            _enum(fields[key], key, values)
    if "position" in fields and (
        isinstance(fields["position"], bool) or not isinstance(fields["position"], int)
        or fields["position"] < 0
    ):
        raise BridgeError(422, "position must be a nonnegative integer")
    return dict(fields)


def _validate(tool: str, values: dict) -> None:
    validate_local_handle(values["handle"])
    _optional_text(values.get("operation_id"), "operation_id")
    for name in ("ticket", "target", "claim_id"):
        if name in values:
            _text(values[name], name)
    if "checkout" in values and values["checkout"] is not None:
        checkout = _text(values["checkout"], "checkout", 4096)
        if not os.path.isabs(checkout):
            raise BridgeError(422, "checkout must be an absolute path")
    if "label" in values:
        _optional_text(values["label"], "label")
    if tool == "create_ticket":
        _text(values["title"], "title", 10_000)
        _optional_text(values["body"], "body", 100_000, blank=True)
        for key, choices in (("status", STATUSES), ("priority", PRIORITIES), ("swimlane", SWIMLANES)):
            if values[key] is not None:
                _enum(values[key], key, choices)
        due = _optional_text(values["due_date"], "due_date")
        if due is not None:
            try:
                if date.fromisoformat(due).isoformat() != due:
                    raise ValueError
            except ValueError:
                raise BridgeError(422, "due_date must be a date in YYYY-MM-DD form") from None
    elif tool == "update_ticket":
        values["fields"] = _validate_fields(values["fields"])
    elif tool == "add_comment":
        _text(values["body"], "body", 100_000)
    elif tool in {"link_tickets", "unlink_tickets"} and values["kind"] is not None:
        _enum(values["kind"], "kind", LINK_KINDS)
    elif tool == "checkpoint_work":
        _text(values["checkpoint"], "checkpoint", 10_000)
    elif tool == "release_ticket":
        _text(values["handoff"], "handoff", 10_000)
        _enum(values["reason"], "reason", RELEASE_REASONS)
        _optional_text(values["feedback_target"], "feedback_target", 1_000)
        if values["reason"] == "feedback" and values["feedback_target"] is None:
            raise BridgeError(422, "feedback_target is required when reason is 'feedback'")
        if values["reason"] != "feedback" and values["feedback_target"] is not None:
            raise BridgeError(422, "feedback_target requires reason 'feedback'")
        if values["swimlane"] is not None:
            _enum(values["swimlane"], "swimlane", SWIMLANES)
            if values["swimlane"] == "waiting_for_feedback":
                raise BridgeError(422, "swimlane must name the prior lane")
    elif tool == "complete_ticket":
        _text(values["evidence"], "evidence", 10_000)
        refs = values["references"]
        if not isinstance(refs, list) or len(refs) > 50:
            raise BridgeError(422, "references must be a list of at most 50 strings")
        for reference in refs:
            _text(reference, "reference", 1_000)
    elif tool == "end_work_session":
        _optional_text(values["handoff"], "handoff", 10_000)


def normalize_tool_args(tool: str, args: dict) -> bytes:
    """Return the one canonical byte representation hooks and bridge digest."""
    spec = TOOL_SPECS.get(tool)
    if spec is None:
        raise BridgeError(422, f"unknown tool {tool!r}")
    if not isinstance(args, dict):
        raise BridgeError(422, "tool arguments must be an object")
    unknown = sorted(set(args) - spec.allowed)
    if unknown:
        raise BridgeError(422, f"unknown field {unknown[0]!r} for {tool}")
    missing = [key for key in spec.required if key not in args]
    if missing:
        raise BridgeError(422, f"missing field {missing[0]!r} for {tool}")
    values = {key: (dict(value) if isinstance(value, dict) else list(value) if isinstance(value, list) else value)
              for key, value in spec.defaults.items()}
    values.update(args)
    _validate(tool, values)
    return json.dumps(values, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def normalized_dict(tool: str, args: dict) -> dict:
    return json.loads(normalize_tool_args(tool, args))


def _blueprint_matrix() -> Path:
    return Path(__file__).resolve().parents[2] / "configs" / "kanban" / "qualified-clients.json"


def _matrix_path() -> Path:
    override = os.environ.get("AICODING_KANBAN_QUALIFIED_CLIENTS")
    if override:
        parts = urlsplit(os.environ.get("KANBAN_URL", ""))
        if parts.hostname in LOOPBACK and os.environ.get("KANBAN_TEST_TOKEN"):
            return Path(override)
    return _blueprint_matrix()


def qualified_client_version(harness: str, version: str) -> bool:
    """Return true only for an exact version in a trusted matrix location."""
    if not isinstance(harness, str) or not isinstance(version, str):
        return False
    try:
        value = json.loads(_matrix_path().read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError):
        return False
    clients = value.get("clients", value) if isinstance(value, dict) else {}
    entry = clients.get(harness) if isinstance(clients, dict) else None
    if isinstance(entry, dict):
        entry = entry.get("versions", [])
    return isinstance(entry, list) and version in entry and all(isinstance(item, str) for item in entry)
