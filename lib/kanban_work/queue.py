"""Bounded, generation-fenced delivery of session-scoped lifecycle events."""

from __future__ import annotations

import time
from datetime import UTC, datetime, timedelta
from typing import Callable
from uuid import uuid5

from .schema import BridgeError
from .store import OPERATION_NAMESPACE, QueueRow, Store
from .transport import DEFAULT_TIMEOUT, SubprocessTransport


ACTIVITY_MAX_AGE = timedelta(seconds=60)
ACTIVITY_MAX_FUTURE = timedelta(seconds=5)
SUPERVISOR_INTERVAL = timedelta(seconds=60)
SUPERVISOR_MAX_AGE = timedelta(hours=2)
MAX_DRAIN_BUDGET_MS = 3_000
SYNC_BUDGET_MS = 3_000
MIN_ATTEMPT_SECONDS = 0.5


class _Deadline:
    def __init__(self, budget_ms: int | None):
        self.end = None if budget_ms is None else time.monotonic() + budget_ms / 1000

    def remaining(self) -> float:
        return DEFAULT_TIMEOUT if self.end is None else self.end - time.monotonic()

    def expired(self) -> bool:
        return self.end is not None and time.monotonic() > self.end


class LifecycleQueue:
    def __init__(self, store: Store | None = None,
                 transport: Callable[..., dict] | None = None, *,
                 now: Callable[[], datetime] | None = None):
        self.store = store or Store()
        self.transport = transport or SubprocessTransport()
        self.now = now or (lambda: datetime.now(UTC))

    def pending(self, handle: str | None = None) -> list[QueueRow]:
        return self.store.pending_queue(handle)

    def _send(self, operation: str, payload: dict, deadline: _Deadline):
        return self.transport(operation, payload,
                              timeout=max(deadline.remaining(), MIN_ATTEMPT_SECONDS))

    def _drop(self, row: QueueRow, reason: str) -> str:
        if row.kind == "stop":
            self.store.settle_stop(row.operation_id, reason, self.now())
        self.store.finish_queue_row(row, success=True)
        return f"dropped:{reason}"

    def _retry(self, row: QueueRow, error: str) -> str:
        self.store.finish_queue_row(row, success=False, error_class=error)
        return "retry"

    def _register(self, row: QueueRow, deadline: _Deadline) -> str:
        payload = dict(row.payload)
        operation_id = row.operation_id
        while True:
            try:
                data = self._send("register_session", {**payload, "operation_id": operation_id}, deadline)
            except BridgeError as error:
                if error.transient:
                    return self._retry(row, "BoardUnavailable")
                # The board lists a repo only once it is registered there; a
                # session without one binds to its first claim's repo instead.
                if error.code == 422 and payload.get("repo") is not None:
                    payload["repo"] = None
                    operation_id = str(uuid5(OPERATION_NAMESPACE, f"{row.operation_id}\0without-repo"))
                    if not self.store.replace_register_payload(row, payload, operation_id):
                        return "retry"
                    continue
                return self._drop(row, "register_rejected")
            break
        session_id = data.get("id") if isinstance(data, dict) else None
        if not isinstance(session_id, str) or not session_id:
            return self._retry(row, "InvalidRegistration")
        repo = data.get("repo")
        self.store.record_registered(row.handle, session_id, repo if isinstance(repo, str) else None)
        self.store.finish_queue_row(row, success=True)
        return "delivered"

    def deliver(self, row: QueueRow, deadline: _Deadline | None = None) -> str:
        deadline = deadline or _Deadline(None)
        execution = self.store.get_execution(row.handle)
        if execution is None or execution.run_generation != row.run_generation:
            return self._drop(row, "old_generation")
        if not row.operation_id:
            return self._drop(row, "invalid_index")
        if row.kind == "register":
            return self._register(row, deadline)
        session_id = execution.work_session_id
        if not session_id:
            if self.store.has_pending_register(row.handle):
                return self._retry(row, "AwaitingRegistration")
            return self._drop(row, "unregistered")
        now = self.now()
        if row.kind == "activity":
            if execution.ended:
                return self._drop(row, "ended_generation")
            if row.observed_at is None or now - row.observed_at > ACTIVITY_MAX_AGE:
                return self._drop(row, "stale_activity")
            if row.observed_at - now > ACTIVITY_MAX_FUTURE:
                return self._drop(row, "future_activity")
            operation, body = "session_activity", {
                "work_session_id": session_id, "operation_id": row.operation_id,
                "run_generation": row.run_generation,
                "observed_at": row.payload["observed_at"], "sequence": row.payload["sequence"],
            }
        elif row.kind == "stop":
            operation, body = "release_active", {
                "work_session_id": session_id, "operation_id": row.operation_id,
                "observed_at": row.payload["observed_at"],
                "reason": row.payload.get("reason", "stopped"),
            }
        elif row.kind == "end":
            operation, body = "end_session", {
                "work_session_id": session_id, "operation_id": row.operation_id,
            }
            if isinstance(row.payload.get("handoff"), str) and row.payload["handoff"].strip():
                body["handoff"] = row.payload["handoff"]
        else:
            return self._drop(row, "unknown_event")
        try:
            data = self._send(operation, body, deadline)
        except BridgeError as error:
            if error.transient:
                return self._retry(row, "BoardUnavailable")
            return self._drop(row, f"rejected_{error.code}")
        if row.kind == "stop":
            outcome = data.get("stop") if isinstance(data, dict) else None
            self.store.settle_stop(row.operation_id,
                                   outcome if outcome in {"applied", "cancelled"} else "answered", now)
        self.store.finish_queue_row(row, success=True)
        return "delivered"

    def _run(self, deadline: _Deadline, *, bound_requests: bool, **selector) -> dict:
        delivered = dropped = retried = 0
        while not deadline.expired():
            row = self.store.claim_queue_row(self.now(), **selector)
            if row is None:
                break
            outcome = self.deliver(row, deadline if bound_requests else None)
            if outcome == "retry":
                retried += 1
                break
            if outcome == "delivered":
                delivered += 1
            else:
                dropped += 1
        return {"delivered": delivered, "dropped": dropped, "retried": retried,
                "pending": self.store.queue_count()}

    def drain(self, budget_ms: int = 2_000) -> dict:
        if type(budget_ms) is not int or budget_ms < 0 or budget_ms > MAX_DRAIN_BUDGET_MS:
            raise BridgeError(422, "drain budget_ms must be between 0 and 3000")
        # The budget bounds the loop; a started request keeps the full timeout
        # because drain runs detached from any hook.
        return self._run(_Deadline(budget_ms), bound_requests=False)

    def deliver_now(self, handle: str, kinds: tuple[str, ...],
                    budget_ms: int = SYNC_BUDGET_MS) -> dict:
        """Deliver one execution's rows of the given kinds within a hook's budget."""
        return self._run(_Deadline(budget_ms), bound_requests=True, handle=handle, kinds=kinds)

    def settle_stops(self, handle: str, budget_ms: int = SYNC_BUDGET_MS) -> bool:
        """Delete unsent Stops and cancel possibly-sent ones; True when none is unsettled."""
        deadline = _Deadline(budget_ms)
        self.store.delete_unsent_stops(handle)
        execution = self.store.get_execution(handle)
        for operation_id in self.store.sent_stops(handle):
            session_id = execution.work_session_id if execution else None
            if not session_id:
                self.store.settle_stop(operation_id, "unregistered", self.now())
                continue
            if deadline.expired():
                return False
            try:
                data = self._send("cancel_stop", {"work_session_id": session_id,
                                                  "operation_id": operation_id}, deadline)
            except BridgeError as error:
                if error.transient:
                    return False
                self.store.settle_stop(operation_id, f"rejected_{error.code}", self.now())
                continue
            outcome = data.get("stop") if isinstance(data, dict) else None
            self.store.settle_stop(operation_id,
                                   outcome if outcome in {"applied", "cancelled"} else "answered",
                                   self.now())
        return not self.store.unsettled_stops(handle)

    def supervise_once(self, handle: str, native_call_id: str) -> bool:
        operation = self.store.tool_operation(handle, native_call_id)
        execution = self.store.get_execution(handle)
        if operation is None or execution is None or not operation["active"]:
            return False
        if execution.run_generation != operation["run_generation"] or execution.ended:
            return False
        now = self.now()
        if now > operation["started_at"] + SUPERVISOR_MAX_AGE:
            return False
        latest = operation["last_activity_at"] or operation["latest_native_event_at"]
        if now < latest + SUPERVISOR_INTERVAL:
            return True
        operation_id = str(uuid5(
            OPERATION_NAMESPACE,
            f"supervise\0{handle}\0{operation['run_generation']}\0{native_call_id}\0{now.isoformat()}",
        ))
        sequence = self.store.maybe_enqueue_activity(
            handle, operation["run_generation"], now, operation_id
        )
        if sequence is not None:
            self.store.mark_tool_activity(handle, operation["run_generation"], native_call_id, now)
        return True

    def supervise(self, handle: str, native_call_id: str) -> dict:
        iterations = 0
        while self.supervise_once(handle, native_call_id):
            iterations += 1
            self.drain()
            time.sleep(SUPERVISOR_INTERVAL.total_seconds())
        return {"iterations": iterations, "pending": self.store.queue_count()}
