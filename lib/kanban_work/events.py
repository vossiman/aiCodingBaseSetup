"""Normalized ingress for trusted native client lifecycle events."""

from __future__ import annotations

import os
from datetime import UTC, datetime
from typing import Callable
from uuid import uuid4, uuid5

from .queue import LifecycleQueue
from .schema import BridgeError, validate_local_handle
from .store import MAX_OPAQUE, OPERATION_NAMESPACE, Store


EVENTS = frozenset({
    "start", "resume", "clear", "compaction", "activity",
    "tool_start", "tool_success", "tool_failure", "stop", "end",
})
DEFAULT_HANDOFF = "Agent stopped without recording a checkpoint."


def _bounded(value, name: str, *, optional: bool = False):
    if optional and value is None:
        return None
    if not isinstance(value, str) or not value.strip() or len(value) > MAX_OPAQUE:
        raise BridgeError(422, f"{name} must be a bounded nonempty identifier")
    return value


class EventIngestor:
    def __init__(self, store: Store | None = None, queue: LifecycleQueue | None = None, *,
                 now: Callable[[], datetime] | None = None,
                 start_supervisor: Callable[[str, str], None] | None = None):
        self.store = store or Store()
        self.now = now or (lambda: datetime.now(UTC))
        self.queue = queue or LifecycleQueue(self.store, now=self.now)
        self.start_supervisor = start_supervisor

    @staticmethod
    def _operation_id(handle: str, generation: str, event_id: str, kind: str) -> str:
        return str(uuid5(
            OPERATION_NAMESPACE, f"event\0{handle}\0{generation}\0{event_id}\0{kind}"
        ))

    def ingest_event(self, harness: str, event_name: str, payload: dict) -> dict:
        _bounded(harness, "harness")
        if event_name not in EVENTS:
            raise BridgeError(422, f"unsupported native event {event_name!r}")
        if not isinstance(payload, dict):
            raise BridgeError(422, "native event payload must be an object")
        event_id = _bounded(payload.get("native_event_id"), "native_event_id")
        observed_at = self.now()

        if event_name in {"start", "resume", "clear"}:
            allowed = {"native_event_id", "native_session_id", "subagent_id", "checkout",
                       "lifecycle_capable"}
            self._reject_unknown(payload, allowed)
            duplicate = self.store.begin_native_event(
                harness, event_id, event_name, None, None, observed_at
            )
            if duplicate is not None:
                return duplicate
            try:
                handle = str(uuid4())
                generation = str(uuid4())
                self.store.start_execution(
                    harness,
                    _bounded(payload.get("native_session_id"), "native_session_id"),
                    _bounded(payload.get("subagent_id"), "subagent_id", optional=True),
                    generation,
                    handle,
                    payload.get("checkout"),
                    payload.get("lifecycle_capable"),
                    now=observed_at,
                )
                result = {"status": "minted", "handle": handle,
                          "run_generation": generation}
                self.store.finish_native_event(harness, event_id, result)
                return result
            except Exception:
                self.store.abandon_native_event(harness, event_id)
                raise

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
        try:
            execution = self.store.get_execution(handle)
            if (execution is None or execution.harness != harness
                    or execution.run_generation != generation):
                result = {"status": "dropped_old_generation", "handle": handle,
                          "run_generation": generation}
            elif (execution.state == "ended"
                  or self.store.execution_intent(handle)["latest_end_operation_id"] is not None):
                result = {"status": "dropped_ended_generation", "handle": handle,
                          "run_generation": generation}
            elif event_name == "compaction":
                result = {"status": "observed", "handle": handle,
                          "run_generation": generation}
            elif event_name == "activity":
                sequence = self.store.maybe_enqueue_activity(
                    handle, generation, observed_at,
                    self._operation_id(handle, generation, event_id, "activity"),
                )
                result = {"status": "observed", "handle": handle,
                          "run_generation": generation, "sequence": sequence}
            elif event_name == "tool_start":
                native_call_id = _bounded(payload.get("native_call_id"), "native_call_id")
                sequence = self.store.start_tool_operation(
                    handle, generation, native_call_id, observed_at,
                    self._operation_id(handle, generation, event_id, "activity"),
                )
                if (self.start_supervisor is not None
                        and os.environ.get("AICODINGSETUP_SKIP_NETWORK") != "1"):
                    self.start_supervisor(handle, native_call_id)
                result = {"status": "observed", "handle": handle,
                          "run_generation": generation, "sequence": sequence}
            elif event_name in {"tool_success", "tool_failure"}:
                native_call_id = _bounded(payload.get("native_call_id"), "native_call_id")
                sequence = self.store.finish_tool_operation(
                    handle, generation, native_call_id, observed_at,
                    self._operation_id(handle, generation, event_id, "activity"),
                )
                result = {"status": "observed", "handle": handle,
                          "run_generation": generation, "sequence": sequence}
            elif event_name == "stop":
                self.store.close_tool_operations(handle, generation, observed_at)
                claim = self.store.active_claim(handle)
                operation_id = None
                if claim is not None:
                    handoff = claim.get("checkpoint") or DEFAULT_HANDOFF
                    operation_id = self._operation_id(handle, generation, event_id, "release")
                    self.store.persist_release_intent(
                        handle, generation, claim["id"], operation_id,
                        handoff, "stopped", observed_at,
                    )
                result = {"status": "observed", "handle": handle,
                          "run_generation": generation, "operation_id": operation_id}
            else:
                claim = self.store.active_claim(handle)
                handoff = (claim or {}).get("checkpoint") or DEFAULT_HANDOFF
                operation_id = self._operation_id(handle, generation, event_id, "end")
                self.store.persist_end_intent(
                    handle, generation, operation_id, handoff, observed_at
                )
                result = {"status": "observed", "handle": handle,
                          "run_generation": generation, "operation_id": operation_id}
            self.store.finish_native_event(harness, event_id, result)
            return result
        except Exception:
            self.store.abandon_native_event(harness, event_id)
            raise

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
