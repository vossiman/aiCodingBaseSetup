"""Normalized ingress for trusted native client lifecycle events."""

from __future__ import annotations

import os
from datetime import UTC, datetime
from typing import Callable
from uuid import uuid5

from .queue import LifecycleQueue
from .schema import BridgeError, validate_local_handle
from .store import MAX_OPAQUE, OPERATION_NAMESPACE, Store
from .transport import derive_github_repo


EVENTS = frozenset({
    "start", "resume", "clear", "compaction", "activity",
    "tool_start", "tool_success", "tool_failure", "stop", "end",
})


def network_allowed() -> bool:
    """Tests run offline unless they aim kanban-post at a loopback fake board."""
    return background_allowed() or bool(os.environ.get("KANBAN_URL"))


def background_allowed() -> bool:
    """Detached drains and supervisors never start under tests."""
    return os.environ.get("AICODINGSETUP_SKIP_NETWORK") != "1"


def _bounded(value, name: str, *, optional: bool = False):
    if optional and value is None:
        return None
    if not isinstance(value, str) or not value.strip() or len(value) > MAX_OPAQUE:
        raise BridgeError(422, f"{name} must be a bounded nonempty identifier")
    return value


class EventIngestor:
    def __init__(self, store: Store | None = None, queue: LifecycleQueue | None = None, *,
                 now: Callable[[], datetime] | None = None,
                 start_supervisor: Callable[[str, str], None] | None = None,
                 derive_repo: Callable[[str], str | None] = derive_github_repo,
                 synchronous: bool | None = None):
        self.store = store or Store()
        self.now = now or (lambda: datetime.now(UTC))
        self.queue = queue or LifecycleQueue(self.store, now=self.now)
        self.start_supervisor = start_supervisor
        self.derive_repo = derive_repo
        self.synchronous = network_allowed() if synchronous is None else synchronous

    @staticmethod
    def _operation_id(handle: str, generation: str, event_id: str, kind: str) -> str:
        return str(uuid5(
            OPERATION_NAMESPACE, f"event\0{handle}\0{generation}\0{event_id}\0{kind}"
        ))

    def _start(self, harness: str, payload: dict, event_id: str, observed_at: datetime) -> dict:
        handle = str(uuid5(OPERATION_NAMESPACE, f"native-handle\0{harness}\0{event_id}"))
        generation = str(uuid5(OPERATION_NAMESPACE, f"run-generation\0{harness}\0{event_id}"))
        native_session_id = _bounded(payload.get("native_session_id"), "native_session_id")
        subagent_id = _bounded(payload.get("subagent_id"), "subagent_id", optional=True)
        checkout = payload.get("checkout")
        capable = payload.get("lifecycle_capable")
        repo = self.derive_repo(checkout) if isinstance(checkout, str) else None
        label = f"{harness} {'subagent' if subagent_id else 'session'}"
        self.store.start_execution(
            harness, native_session_id, subagent_id, generation, handle, checkout, capable,
            repo=repo, label=label, now=observed_at,
        )
        self.store.enqueue_register(handle, {
            "harness": harness, "native_session_id": native_session_id,
            "subagent_id": subagent_id, "run_generation": generation, "handle": handle,
            "label": label, "repo": repo, "lifecycle_capable": capable,
        }, str(uuid5(OPERATION_NAMESPACE, f"register\0{handle}")), observed_at)
        return {"status": "minted", "handle": handle, "run_generation": generation}

    def ingest_event(self, harness: str, event_name: str, payload: dict) -> dict:
        _bounded(harness, "harness")
        if event_name not in EVENTS:
            raise BridgeError(422, f"unsupported native event {event_name!r}")
        if not isinstance(payload, dict):
            raise BridgeError(422, "native event payload must be an object")
        event_id = _bounded(payload.get("native_event_id"), "native_event_id")
        observed_at = self.now()

        if event_name in {"start", "resume", "clear"}:
            self._reject_unknown(payload, {"native_event_id", "native_session_id", "subagent_id",
                                           "checkout", "lifecycle_capable"})
            duplicate = self.store.begin_native_event(
                harness, event_id, event_name, None, None, observed_at
            )
            if duplicate is not None:
                return duplicate
            try:
                result = self._start(harness, payload, event_id, observed_at)
                self.store.finish_native_event(harness, event_id, result, observed_at)
            except Exception:
                self.store.abandon_native_event(harness, event_id)
                raise
            if self.synchronous:
                self.queue.deliver_now(result["handle"], ("register",))
            return result

        allowed = {"native_event_id", "handle", "run_generation"}
        if event_name in {"tool_start", "tool_success", "tool_failure"}:
            allowed.add("native_call_id")
        self._reject_unknown(payload, allowed)
        handle = validate_local_handle(payload.get("handle"))
        generation = _bounded(payload.get("run_generation"), "run_generation")
        duplicate = self.store.begin_native_event(
            harness, event_id, event_name, handle, generation, observed_at
        )
        if duplicate is not None:
            return duplicate
        deliver = None
        try:
            execution = self.store.get_execution(handle)
            base = {"handle": handle, "run_generation": generation}
            if (execution is None or execution.harness != harness
                    or execution.run_generation != generation):
                result = {"status": "dropped_old_generation", **base}
            elif execution.ended:
                result = {"status": "dropped_ended_generation", **base}
            elif event_name == "compaction":
                result = {"status": "observed", **base}
            elif event_name == "activity":
                sequence = self.store.maybe_enqueue_activity(
                    handle, generation, observed_at,
                    self._operation_id(handle, generation, event_id, "activity"),
                )
                result = {"status": "observed", **base, "sequence": sequence}
            elif event_name == "tool_start":
                native_call_id = _bounded(payload.get("native_call_id"), "native_call_id")
                sequence = self.store.start_tool_operation(
                    handle, generation, native_call_id, observed_at,
                    self._operation_id(handle, generation, event_id, "activity"),
                )
                if self.start_supervisor is not None and background_allowed():
                    self.start_supervisor(handle, native_call_id)
                result = {"status": "observed", **base, "sequence": sequence}
            elif event_name in {"tool_success", "tool_failure"}:
                native_call_id = _bounded(payload.get("native_call_id"), "native_call_id")
                sequence = self.store.finish_tool_operation(
                    handle, generation, native_call_id, observed_at,
                    self._operation_id(handle, generation, event_id, "activity"),
                )
                result = {"status": "observed", **base, "sequence": sequence}
            elif event_name == "stop":
                operation_id = self._operation_id(handle, generation, event_id, "stop")
                self.store.close_tool_operations(handle, generation, observed_at)
                self.store.record_stop(handle, generation, operation_id, observed_at)
                result = {"status": "observed", **base, "operation_id": operation_id}
                deliver = ("register", "stop")
            else:
                operation_id = self._operation_id(handle, generation, event_id, "end")
                self.store.record_end(handle, generation, operation_id, observed_at)
                result = {"status": "observed", **base, "operation_id": operation_id}
            self.store.finish_native_event(harness, event_id, result, observed_at)
        except Exception:
            self.store.abandon_native_event(harness, event_id)
            raise
        if deliver and self.synchronous:
            self.queue.deliver_now(handle, deliver)
        return result

    def settle_turn(self, handle: str) -> bool:
        """Settle earlier Stops before a new turn or claim; True when none remain."""
        if not self.synchronous:
            self.store.delete_unsent_stops(handle)
            return not self.store.unsettled_stops(handle)
        return self.queue.settle_stops(handle)

    @staticmethod
    def _reject_unknown(payload: dict, allowed: set[str]):
        unknown = sorted(set(payload) - allowed)
        if unknown:
            raise BridgeError(422, f"unknown native event field {unknown[0]!r}")


def ingest_event(harness: str, event_name: str, payload: dict) -> dict:
    store = Store()
    try:
        queue = LifecycleQueue(store)
        return EventIngestor(store, queue).ingest_event(harness, event_name, payload)
    finally:
        store.close()
