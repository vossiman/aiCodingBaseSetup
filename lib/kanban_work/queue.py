"""Bounded, generation-fenced delivery for native lifecycle observations."""

from __future__ import annotations

import time
from datetime import UTC, datetime, timedelta
from typing import Callable
from uuid import uuid5

from .bridge import SubprocessTransport, authoritative_refresh
from .schema import BridgeError
from .store import OPERATION_NAMESPACE, QueueRow, Store


ACTIVITY_MAX_AGE = timedelta(seconds=60)
ACTIVITY_MAX_FUTURE = timedelta(seconds=5)
SUPERVISOR_INTERVAL = timedelta(seconds=60)
SUPERVISOR_MAX_AGE = timedelta(hours=2)
MAX_DRAIN_BUDGET_MS = 3_000


class LifecycleQueue:
    def __init__(self, store: Store | None = None,
                 transport: Callable[[str, dict], dict] | None = None, *,
                 now: Callable[[], datetime] | None = None):
        self.store = store or Store()
        self.transport = transport or SubprocessTransport()
        self.now = now or (lambda: datetime.now(UTC))
        self.delivered_pairs: list[tuple[str, str]] = []

    def pending(self, handle: str | None = None) -> list[QueueRow]:
        return self.store.pending_queue(handle)

    def reconstruct(self) -> int:
        return self.store.reconstruct_intents(self.now())

    def _drop_reason(self, row: QueueRow, now: datetime) -> str | None:
        execution = self.store.get_execution(row.handle)
        if execution is None or execution.run_generation != row.run_generation:
            return "old_generation"
        if not row.operation_id:
            return "invalid_index"
        if row.kind == "activity":
            if execution.state == "ended" or self.store.execution_intent(
                row.handle
            )["latest_end_operation_id"] is not None:
                return "ended_generation"
            if row.observed_at is None or now - row.observed_at > ACTIVITY_MAX_AGE:
                return "stale_activity"
            if row.observed_at - now > ACTIVITY_MAX_FUTURE:
                return "future_activity"
            claim = self.store.active_claim(row.handle)
            if claim is None or claim["id"] != row.claim_id:
                return "replaced_claim"
        elif row.kind == "release_ticket":
            claim = self.store.claim(row.handle, row.claim_id) if row.claim_id else None
            if claim is None or claim["latest_release_operation_id"] != row.operation_id:
                return "superseded_release"
        elif row.kind == "end_session":
            if self.store.execution_intent(row.handle)["latest_end_operation_id"] != row.operation_id:
                return "superseded_end"
        else:
            return "unknown_event"
        return None

    def drain_once(self) -> str:
        self.reconstruct()
        row = self.store.claim_queue_row(self.now())
        if row is None:
            return "empty"
        now = self.now()
        reason = self._drop_reason(row, now)
        if reason is not None:
            if reason == "invalid_index" and row.kind in {"release_ticket", "end_session"}:
                self.store.mark_intent_delivered(row, now)
            self.store.finish_queue_row(row, success=True)
            return f"dropped:{reason}"
        work_session_id = row.payload.get("work_session_id")
        if not isinstance(work_session_id, str) or not work_session_id:
            if row.kind in {"release_ticket", "end_session"}:
                self.store.mark_intent_delivered(row, now)
            self.store.finish_queue_row(row, success=True)
            return "dropped:unbound"
        try:
            payload = {**row.payload, "operation_id": row.operation_id}
            result = self.transport(row.kind, payload)
            if not isinstance(result, dict):
                raise BridgeError(502, "kanban transport returned invalid lifecycle data")
            ticket_ref = None
            if row.claim_id:
                claim = self.store.claim(row.handle, row.claim_id)
                ticket_ref = (claim or {}).get("ticket_id") or (claim or {}).get("ticket")
            authoritative_refresh(
                self.store, self.transport, row.handle, work_session_id,
                ticket_ref=ticket_ref,
            )
        except Exception as error:
            self.store.finish_queue_row(row, success=False, error_class=type(error).__name__)
            return "retry"
        if row.kind in {"release_ticket", "end_session"}:
            self.store.mark_intent_delivered(row, now)
        self.store.finish_queue_row(row, success=True)
        self.delivered_pairs.append((row.handle, row.operation_id))
        return "delivered"

    def drain(self, budget_ms: int = 2_000) -> dict:
        if type(budget_ms) is not int or budget_ms < 0 or budget_ms > MAX_DRAIN_BUDGET_MS:
            raise BridgeError(422, "drain budget_ms must be between 0 and 3000")
        deadline = time.monotonic() + budget_ms / 1000
        delivered = dropped = retried = 0
        while time.monotonic() <= deadline:
            outcome = self.drain_once()
            if outcome == "empty":
                break
            if outcome == "retry":
                retried += 1
                break
            if outcome == "delivered":
                delivered += 1
            else:
                dropped += 1
        return {"delivered": delivered, "dropped": dropped, "retried": retried,
                "pending": self.store.queue_count()}

    def supervise_once(self, handle: str, native_call_id: str) -> bool:
        operation = self.store.tool_operation(handle, native_call_id)
        execution = self.store.get_execution(handle)
        if operation is None or execution is None or not operation["active"]:
            return False
        if execution.run_generation != operation["run_generation"] or execution.state == "ended":
            return False
        claim = self.store.active_claim(handle)
        if claim is None or claim["id"] != operation["claim_id"]:
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
