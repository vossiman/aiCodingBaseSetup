"""Pure, value-safe three-way planner for Codex TOML configuration."""

from __future__ import annotations

from collections.abc import Mapping
from copy import deepcopy
from dataclasses import dataclass
import datetime as datetime_module
import hashlib
import math
from pathlib import Path
import sys
from typing import Any, Dict, List, Optional, Sequence, Tuple


VENDOR = Path(__file__).resolve().parent / "vendor"
if str(VENDOR) not in sys.path:
    sys.path.insert(0, str(VENDOR))

import tomlkit  # noqa: E402


USER_SCALARS = frozenset(("model", "model_reasoning_effort"))
USER_TREES = frozenset(("projects",))
PROFILE_PATHS = frozenset((("approval_policy",), ("sandbox_mode",)))
NODE_TYPES = frozenset(
    (
        "missing",
        "boolean",
        "integer",
        "float",
        "string",
        "date",
        "time",
        "datetime",
        "array",
        "table",
    )
)


class _Missing:
    pass


MISSING = _Missing()


@dataclass
class MergePlan:
    config_text: str
    config_changed: bool
    state_changed: bool
    acknowledged: Dict[str, Any]
    conflicts: List[Dict[str, Any]]
    changes: List[Dict[str, Any]]
    adoption_notices: List[Dict[str, Any]]
    error: Optional[Dict[str, Any]] = None


def _sha256(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()


def _frame(label: str, payload: bytes) -> bytes:
    name = label.encode("ascii")
    return len(name).to_bytes(2, "big") + name + len(payload).to_bytes(8, "big") + payload


def _unwrap(value: Any) -> Any:
    unwrap = getattr(value, "unwrap", None)
    return unwrap() if callable(unwrap) else value


def _float_bytes(value: float) -> bytes:
    if math.isnan(value):
        return b"nan"
    if math.isinf(value):
        return b"+inf" if value > 0 else b"-inf"
    return value.hex().encode("ascii")


def _datetime_bytes(value: datetime_module.datetime) -> bytes:
    if value.tzinfo is not None:
        value = value.astimezone(datetime_module.timezone.utc)
    return value.isoformat(timespec="microseconds").encode("ascii")


def _time_bytes(value: datetime_module.time) -> bytes:
    return value.isoformat(timespec="microseconds").encode("ascii")


def _table_node(children: Mapping[str, Dict[str, Any]]) -> Dict[str, Any]:
    copied = {str(key): deepcopy(child) for key, child in children.items()}
    payload = bytearray()
    for key in sorted(copied):
        child = copied[key]
        # Missing markers remain in the receipt so later additions/removals have
        # history, but an absent setting is not part of a table's semantic hash.
        if child["type"] == "missing":
            continue
        payload.extend(_frame("key", key.encode("utf-8")))
        payload.extend(_frame("child", child["fingerprint"].encode("ascii")))
    return {
        "type": "table",
        "fingerprint": _sha256(_frame("table", bytes(payload))),
        "children": copied,
    }


def fingerprint_value(value: Any) -> Dict[str, Any]:
    """Return the deterministic typed Merkle node for a TOML-compatible value."""

    if value is MISSING:
        return {"type": "missing", "fingerprint": _sha256(b"missing")}

    value = _unwrap(value)
    if isinstance(value, bool):
        kind, payload = "boolean", b"true" if value else b"false"
    elif isinstance(value, int):
        kind, payload = "integer", str(value).encode("ascii")
    elif isinstance(value, float):
        kind, payload = "float", _float_bytes(value)
    elif isinstance(value, str):
        kind, payload = "string", value.encode("utf-8")
    elif isinstance(value, datetime_module.datetime):
        kind, payload = "datetime", _datetime_bytes(value)
    elif isinstance(value, datetime_module.date):
        kind, payload = "date", value.isoformat().encode("ascii")
    elif isinstance(value, datetime_module.time):
        kind, payload = "time", _time_bytes(value)
    elif isinstance(value, Mapping):
        return _table_node({str(key): fingerprint_value(item) for key, item in value.items()})
    elif isinstance(value, (list, tuple)):
        payload_parts = bytearray()
        for item in value:
            child = fingerprint_value(item)
            payload_parts.extend(_frame("child", child["fingerprint"].encode("ascii")))
        kind, payload = "array", bytes(payload_parts)
    else:
        raise TypeError("unsupported TOML value")

    return {"type": kind, "fingerprint": _sha256(_frame(kind, payload))}


def empty_acknowledged() -> Dict[str, Any]:
    return _table_node({})


def validate_acknowledged(node: Any, *, root: bool = True) -> bool:
    """Validate a persisted Merkle tree without needing historical values."""

    if not isinstance(node, dict) or set(node) - {"type", "fingerprint", "children"}:
        return False
    kind = node.get("type")
    digest = node.get("fingerprint")
    if kind not in NODE_TYPES or not isinstance(digest, str):
        return False
    if not digest.startswith("sha256:") or len(digest) != 71:
        return False
    try:
        int(digest[7:], 16)
    except ValueError:
        return False
    if kind != "table":
        if "children" in node:
            return False
        if kind == "missing" and node != fingerprint_value(MISSING):
            return False
        return not root

    children = node.get("children")
    if not isinstance(children, dict) or not all(isinstance(key, str) for key in children):
        return False
    if root and any(key in USER_SCALARS or key in USER_TREES for key in children):
        return False
    if not all(validate_acknowledged(child, root=False) for child in children.values()):
        return False
    return _table_node(children)["fingerprint"] == digest


def _same(left: Dict[str, Any], right: Dict[str, Any]) -> bool:
    return left["type"] == right["type"] and left["fingerprint"] == right["fingerprint"]


def _node(value: Any) -> Dict[str, Any]:
    return fingerprint_value(value)


def _is_table(value: Any) -> bool:
    return value is not MISSING and isinstance(_unwrap(value), Mapping)


def _operation(local_value: Any, incoming_value: Any) -> str:
    if incoming_value is MISSING:
        return "remove"
    if local_value is MISSING:
        return "add"
    return "replace"


def _set_value(container: Any, key: str, incoming_value: Any) -> None:
    if incoming_value is MISSING:
        if key in container:
            del container[key]
        return
    container[key] = deepcopy(incoming_value)


def _ordered_keys(incoming: Any, base_children: Mapping[str, Any]) -> List[str]:
    ordered = list(incoming.keys()) if incoming is not MISSING else []
    ordered.extend(sorted(key for key in base_children if key not in ordered))
    return ordered


class _Planner:
    def __init__(
        self,
        result: Any,
        decisions: Mapping[Tuple[str, ...], str],
        adoption: bool,
    ) -> None:
        self.result = result
        self.decisions = decisions
        self.adoption = adoption
        self.conflicts: List[Dict[str, Any]] = []
        self.changes: List[Dict[str, Any]] = []
        self.adoption_notices: List[Dict[str, Any]] = []

    def _change(self, path: Tuple[str, ...], operation: str) -> None:
        self.changes.append({"path": list(path), "operation": operation})

    def merge_entry(
        self,
        result_container: Any,
        incoming_container: Any,
        key: str,
        base_node: Dict[str, Any],
        path: Tuple[str, ...],
    ) -> Dict[str, Any]:
        local_value = result_container[key] if key in result_container else MISSING
        incoming_value = (
            incoming_container[key]
            if incoming_container is not MISSING and key in incoming_container
            else MISSING
        )
        local_node = _node(local_value)
        incoming_node = _node(incoming_value)

        if self.adoption:
            if _is_table(local_value) and _is_table(incoming_value):
                for child_key in _ordered_keys(incoming_value, {}):
                    self.merge_entry(
                        local_value,
                        incoming_value,
                        child_key,
                        _node(MISSING),
                        path + (child_key,),
                    )
                return deepcopy(incoming_node)

            if _same(local_node, incoming_node):
                return deepcopy(incoming_node)
            if local_value is MISSING:
                _set_value(result_container, key, incoming_value)
                self._change(path, "add")
                return deepcopy(incoming_node)

            if path in PROFILE_PATHS:
                choice = self.decisions.get(path)
                if choice is None:
                    self.adoption_notices.append({"path": list(path)})
                if choice == "blueprint":
                    _set_value(result_container, key, incoming_value)
                    self._change(path, _operation(local_value, incoming_value))
            return deepcopy(incoming_node)

        can_recurse = (
            _is_table(local_value)
            and _is_table(incoming_value)
            and base_node["type"] in ("table", "missing")
        )
        if can_recurse:
            base_children = base_node.get("children", {})
            acknowledged_children: Dict[str, Dict[str, Any]] = {}
            for child_key in _ordered_keys(incoming_value, base_children):
                acknowledged_children[child_key] = self.merge_entry(
                    local_value,
                    incoming_value,
                    child_key,
                    base_children.get(child_key, _node(MISSING)),
                    path + (child_key,),
                )
            return _table_node(acknowledged_children)

        if _same(local_node, incoming_node):
            return deepcopy(incoming_node)
        if _same(incoming_node, base_node):
            return deepcopy(base_node)
        if _same(local_node, base_node):
            _set_value(result_container, key, incoming_value)
            self._change(path, _operation(local_value, incoming_value))
            return deepcopy(incoming_node)

        choice = self.decisions.get(path)
        if choice in ("local", "blueprint"):
            if choice == "blueprint":
                _set_value(result_container, key, incoming_value)
                self._change(path, _operation(local_value, incoming_value))
            return deepcopy(incoming_node)

        self.conflicts.append({"path": list(path)})
        return deepcopy(base_node)


def _error_plan(local_text: Optional[str], code: str) -> MergePlan:
    return MergePlan(
        config_text=local_text or "",
        config_changed=False,
        state_changed=False,
        acknowledged=empty_acknowledged(),
        conflicts=[],
        changes=[],
        adoption_notices=[],
        error={"code": code},
    )


def plan_merge(
    local_text: Optional[str],
    incoming_text: str,
    *,
    acknowledged: Optional[Dict[str, Any]] = None,
    decisions: Optional[Mapping[Tuple[str, ...], str]] = None,
    adoption: bool = False,
) -> MergePlan:
    """Plan a semantic merge without touching the filesystem.

    ``acknowledged`` is the typed Merkle root stored by the previous successful
    sync. Decisions are keyed by tuple paths so quoted TOML keys containing dots
    remain unambiguous.
    """

    try:
        incoming = tomlkit.parse(incoming_text)
    except Exception:
        return _error_plan(local_text, "invalid_source_toml")
    try:
        local = tomlkit.document() if local_text is None else tomlkit.parse(local_text)
    except Exception:
        return _error_plan(local_text, "invalid_destination_toml")

    recorded_base = (
        deepcopy(acknowledged) if acknowledged is not None else empty_acknowledged()
    )
    if not validate_acknowledged(recorded_base):
        return _error_plan(local_text, "invalid_receipt")
    # A missing whole document is a restore/install event. Per-key missing
    # sentinels describe removals within an existing document; they cannot
    # preserve an absent file because the receipt contains no recoverable user
    # values. Provenance is validated by the state adapter before this call.
    base = empty_acknowledged() if local_text is None else recorded_base
    base_children = {
        key: child
        for key, child in base.get("children", {}).items()
        if key not in USER_SCALARS and key not in USER_TREES
    }

    result = deepcopy(local)
    planner = _Planner(result, decisions or {}, adoption)

    # Existing model/effort are preferences, not managed blueprint values.
    # Missing values may still receive the fleet default.
    for key in incoming.keys():
        if key not in USER_SCALARS:
            continue
        if key not in result:
            result[key] = deepcopy(incoming[key])
            planner._change((key,), "add")

    incoming_keys = [
        key for key in incoming.keys() if key not in USER_SCALARS and key not in USER_TREES
    ]
    incoming_keys.extend(sorted(key for key in base_children if key not in incoming_keys))
    next_children: Dict[str, Dict[str, Any]] = {}
    for key in incoming_keys:
        next_children[key] = planner.merge_entry(
            result,
            incoming,
            key,
            base_children.get(key, _node(MISSING)),
            (key,),
        )

    next_acknowledged = _table_node(next_children)
    try:
        rendered = tomlkit.dumps(result)
        tomlkit.parse(rendered)
    except Exception:
        return _error_plan(local_text, "invalid_merged_toml")

    config_changed = local_text is None or bool(planner.changes)
    if not config_changed and local_text is not None:
        rendered = local_text
    return MergePlan(
        config_text=rendered,
        config_changed=config_changed,
        state_changed=next_acknowledged != recorded_base,
        acknowledged=next_acknowledged,
        conflicts=planner.conflicts,
        changes=planner.changes,
        adoption_notices=planner.adoption_notices,
        error=None,
    )
