"""Credential-safe public registry bridge for the Kanban MCP."""

from __future__ import annotations

import json
import os
import sqlite3
import subprocess
from datetime import UTC, datetime
from pathlib import Path
from typing import Callable

from .schema import (
    BridgeError,
    TOOL_TO_BRIDGE_OPERATION,
    normalize_tool_args,
    normalized_dict,
    validate_local_handle,
)
from .store import Execution, Store


MAX_JSON_STDIN = 256 * 1024
PUBLIC_OPERATIONS = frozenset({"bind", "lookup", "execute", "instructions"})
EXECUTE_OPERATIONS = frozenset(TOOL_TO_BRIDGE_OPERATION.values())
LIFECYCLE_OPERATIONS = frozenset({
    "claim_ticket", "checkpoint_work", "release_ticket", "complete_ticket", "end_session"
})
TICKET_LIFECYCLE_OPERATIONS = frozenset({
    "claim_ticket", "checkpoint_work", "release_ticket", "complete_ticket"
})
ORDINARY_OPERATIONS = EXECUTE_OPERATIONS - LIFECYCLE_OPERATIONS


def _shape(payload, required=(), optional=()):
    if not isinstance(payload, dict):
        raise BridgeError(422, "stdin must contain one JSON object")
    allowed = set(required) | set(optional)
    unknown = sorted(set(payload) - allowed)
    if unknown:
        raise BridgeError(422, f"unknown field {unknown[0]!r}")
    missing = [name for name in required if name not in payload]
    if missing:
        raise BridgeError(422, f"missing field {missing[0]!r}")


class SubprocessTransport:
    def __init__(self, helper: str = "kanban-post"):
        self.helper = helper

    def __call__(self, operation: str, payload: dict) -> dict:
        try:
            result = subprocess.run(
                [self.helper, "--json", operation],
                input=json.dumps(payload, separators=(",", ":")), text=True,
                capture_output=True, shell=False, timeout=30,
            )
            envelope = json.loads(result.stdout)
        except (OSError, subprocess.SubprocessError, json.JSONDecodeError) as error:
            raise BridgeError(502, f"kanban transport failed: {type(error).__name__}") from None
        if not isinstance(envelope, dict) or set(envelope) - {"ok", "data", "error"}:
            raise BridgeError(502, "kanban transport returned an invalid envelope")
        if result.returncode != 0 or envelope.get("ok") is not True:
            error = envelope.get("error")
            code = error.get("code") if isinstance(error, dict) else 502
            message = error.get("message") if isinstance(error, dict) else None
            raise BridgeError(code if isinstance(code, int) else 502,
                              message if isinstance(message, str) else "kanban transport rejected the request")
        data = envelope.get("data")
        if not isinstance(data, (dict, list)):
            raise BridgeError(502, "kanban transport returned invalid success data")
        return data


def derive_github_repo(checkout: str) -> str | None:
    if not isinstance(checkout, str) or not os.path.isabs(checkout):
        return None
    try:
        result = subprocess.run(
            ["git", "remote", "get-url", "origin"], cwd=checkout,
            text=True, capture_output=True, shell=False, timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode:
        return None
    import re
    match = re.match(r"^(?:https://|ssh://git@|git@)github\.com[:/][^/]+/([^/]+?)(?:\.git)?/?$",
                     result.stdout.strip())
    return match.group(1) if match else None


class Bridge:
    def __init__(self, store: Store | None = None,
                 transport: Callable[[str, dict], dict] | None = None, *,
                 now: Callable[[], datetime] | None = None,
                 derive_repo: Callable[[str], str | None] | None = None,
                 instructions_helper: str = "kanban-mcp"):
        self.store = store or Store()
        self.transport = transport or SubprocessTransport()
        self.now = now or (lambda: datetime.now(UTC))
        self.derive_repo = derive_repo or derive_github_repo
        self.instructions_helper = instructions_helper

    def dispatch(self, operation: str, payload: dict) -> dict:
        if operation not in PUBLIC_OPERATIONS:
            raise BridgeError(422, f"unknown public operation {operation!r}")
        return getattr(self, operation)(payload)

    def lookup(self, payload: dict) -> dict:
        _shape(payload, required=("handle",))
        return self.store.lookup(validate_local_handle(payload["handle"]))

    def _repo(self, checkout: str) -> str:
        repo = self.derive_repo(checkout)
        if not repo:
            raise BridgeError(422, "checkout is not a repository with a github.com origin")
        return repo

    def _refresh(self, handle: str, work_session_id: str, *, ticket_ref: str | None = None,
                 checkout: str | None = None):
        try:
            session = self.transport("get_session", {"work_session_id": work_session_id})
            if ticket_ref is None and isinstance(session, dict):
                claims = session.get("claims")
                if isinstance(claims, list) and len(claims) == 1 and isinstance(claims[0], dict):
                    candidate = claims[0].get("ticket_id")
                    if isinstance(candidate, str) and candidate:
                        ticket_ref = candidate
            ticket = self.transport("get_ticket", {"ticket": ticket_ref}) if ticket_ref else None
            if checkout is not None and isinstance(session, dict):
                if self.derive_repo(checkout) != session.get("repo"):
                    checkout = None
            self.store.refresh_authoritative(handle, session, ticket, checkout=checkout)
        except (BridgeError, sqlite3.Error):
            self.store.mark_untrusted(handle, work_session_id)
            raise BridgeError(503, "authoritative refresh failed; retry after checking current state") from None

    def _ensure_trusted(self, execution: Execution) -> Execution:
        if execution.cache_trusted:
            return execution
        if not execution.work_session_id:
            raise BridgeError(503, "work session cache is untrusted and has no backend identity")
        claim = self.store.active_claim(execution.handle)
        self._refresh(execution.handle, execution.work_session_id,
                      ticket_ref=(claim or {}).get("ticket_id") or (claim or {}).get("ticket"))
        refreshed = self.store.get_execution(execution.handle)
        if refreshed is None or not refreshed.cache_trusted:
            raise BridgeError(503, "authoritative refresh did not restore trusted state")
        return refreshed

    def bind(self, payload: dict) -> dict:
        _shape(payload, required=("handle",), optional=("label", "checkout", "operation_id"))
        normalized = normalize_tool_args("bind_work_session", payload)
        values = json.loads(normalized)
        permit = self.store.consume_permit(values["handle"], "bind_work_session", normalized, self.now())
        execution = self.store.get_execution(values["handle"])
        if execution is None:
            raise BridgeError(403, "handle was not minted by a native hook")
        if not execution.lifecycle_capable:
            raise BridgeError(409, "native client version lacks qualified lifecycle support")
        if not execution.cache_trusted:
            execution = self._ensure_trusted(execution)
        operation_id = values["operation_id"] or permit.operation_id
        prior_operation = self.store.operation(execution.handle, operation_id)
        requested_checkout = values["checkout"]
        requested_label = values["label"]
        if execution.state == "minted":
            checkout = requested_checkout or execution.checkout
            if requested_checkout and Path(requested_checkout).resolve() != Path(execution.checkout).resolve():
                raise BridgeError(403, "initial bind must use the hook-validated checkout")
            repo = self._repo(checkout)
            label = requested_label or execution.label or f"{execution.harness} session"
            request = {
                "harness": execution.harness,
                "native_session_id": execution.native_session_id,
                "subagent_id": execution.subagent_id,
                "run_generation": execution.run_generation,
                "label": label,
                "repo": repo,
                "lifecycle_capable": execution.lifecycle_capable,
                "operation_id": operation_id,
            }
            self.store.begin_operation(execution.handle, execution.run_generation, operation_id,
                                       "register_session", normalized)
            try:
                receipt = self.transport("register_session", request)
                work_session_id = receipt.get("id") if isinstance(receipt, dict) else None
                if not isinstance(work_session_id, str):
                    raise BridgeError(502, "register_session returned no backend session identity")
                self._refresh(execution.handle, work_session_id, checkout=checkout)
            except BridgeError as error:
                self.store.finish_operation(execution.handle, operation_id,
                                            "ambiguous" if error.code >= 500 else "rejected",
                                            type(error).__name__)
                raise
            self.store.finish_operation(execution.handle, operation_id, "succeeded")
        elif execution.state == "bound":
            checkout = requested_checkout or execution.checkout
            repo = self._repo(checkout)
            label_changed = requested_label is not None and requested_label != execution.label
            checkout_changed = Path(checkout).resolve() != Path(execution.checkout).resolve()
            replay_register = prior_operation is not None and prior_operation["kind"] == "register_session"
            replay_rebind = prior_operation is not None and prior_operation["kind"] == "rebind_session"
            if replay_register:
                label = requested_label or execution.label or f"{execution.harness} session"
                self.store.begin_operation(execution.handle, execution.run_generation, operation_id,
                                           "register_session", normalized)
                try:
                    receipt = self.transport("register_session", {
                        "harness": execution.harness, "native_session_id": execution.native_session_id,
                        "subagent_id": execution.subagent_id, "run_generation": execution.run_generation,
                        "label": label, "repo": repo, "lifecycle_capable": execution.lifecycle_capable,
                        "operation_id": operation_id,
                    })
                    work_session_id = receipt.get("id") if isinstance(receipt, dict) else None
                    if not isinstance(work_session_id, str):
                        raise BridgeError(502, "register_session returned no backend session identity")
                    self._refresh(execution.handle, work_session_id, checkout=checkout)
                except BridgeError as error:
                    self.store.finish_operation(execution.handle, operation_id,
                                                "ambiguous" if error.code >= 500 else "rejected",
                                                type(error).__name__)
                    raise
                self.store.finish_operation(execution.handle, operation_id, "succeeded")
            elif checkout_changed or label_changed or replay_rebind:
                if self.store.active_claim(execution.handle) and not replay_rebind:
                    raise BridgeError(409, "release the active claim before rebinding the checkout or label")
                request = {"work_session_id": execution.work_session_id, "repo": repo,
                           "operation_id": operation_id}
                if requested_label is not None:
                    request["label"] = requested_label
                self.store.begin_operation(execution.handle, execution.run_generation, operation_id,
                                           "rebind_session", normalized)
                try:
                    self.transport("rebind_session", request)
                    self._refresh(execution.handle, execution.work_session_id, checkout=checkout)
                except BridgeError as error:
                    self.store.finish_operation(execution.handle, operation_id,
                                                "ambiguous" if error.code >= 500 else "rejected",
                                                type(error).__name__)
                    raise
                self.store.finish_operation(execution.handle, operation_id, "succeeded")
        else:
            raise BridgeError(409, "work session has ended")
        current = self.store.lookup(execution.handle)
        return {
            "handle": current["handle"],
            "work_session_id": current["work_session_id"],
            "harness": current["harness"],
            "run_generation": current["run_generation"],
            "label": current["label"],
            "repo": current["repo"],
            "lifecycle_capable": current["lifecycle_capable"],
            "operation_id": operation_id,
        }

    def execute(self, payload: dict) -> dict:
        _shape(payload, required=("handle", "operation", "payload"))
        handle, operation, raw = payload["handle"], payload["operation"], payload["payload"]
        if operation not in EXECUTE_OPERATIONS:
            raise BridgeError(422, f"operation {operation!r} is not executable")
        if not isinstance(raw, dict):
            raise BridgeError(422, "payload must be an object")
        tool = "end_work_session" if operation == "end_session" else operation
        normalized = normalize_tool_args(tool, {"handle": handle, **raw})
        values = json.loads(normalized)
        permit = self.store.consume_permit(handle, tool, normalized, self.now())
        execution = self.store.get_execution(handle)
        if execution is None or execution.state == "minted" or not execution.work_session_id:
            raise BridgeError(409, "bind the native work session before mutating tickets")
        execution = self._ensure_trusted(execution)
        active = self.store.active_claim(handle)
        operation_id = values.pop("operation_id") or permit.operation_id
        existing_operation = self.store.operation(handle, operation_id)
        claim_id = values.get("claim_id")
        end_claim_id = None
        if operation == "end_session":
            end_claim_id = (active or {}).get("id") or (
                existing_operation or {}
            ).get("claim_id")
        if execution.state == "ended":
            if operation != "end_session" or existing_operation is None:
                raise BridgeError(409, "work session has ended")
            previous = self.store.begin_operation(
                handle, execution.run_generation, operation_id, operation, normalized, end_claim_id
            )
            if not previous["existing"]:
                raise BridgeError(409, "work session has ended")
        else:
            previous = None
        if operation in {"checkpoint_work", "release_ticket", "complete_ticket"} and (
            not active or active["id"] != claim_id
        ):
            if (existing_operation is None or existing_operation["kind"] != operation
                    or existing_operation["claim_id"] != claim_id
                    or not self.store.owns_claim(handle, claim_id, execution.run_generation)):
                raise BridgeError(409, "claim is not the work session's current active claim")
        values.pop("handle")
        if operation == "create_ticket" and values.get("checkout") is None:
            values["checkout"] = execution.checkout
        if operation in LIFECYCLE_OPERATIONS:
            values["work_session_id"] = execution.work_session_id
            values["operation_id"] = operation_id
        else:
            values = {key: value for key, value in values.items() if value is not None}
        ticket_ref = None
        if operation == "claim_ticket":
            ticket_ref = values["ticket"]
        elif operation in TICKET_LIFECYCLE_OPERATIONS:
            known_claim = active or (self.store.claim(handle, claim_id) if claim_id else None)
            ticket_ref = (known_claim or {}).get("ticket_id") or (known_claim or {}).get("ticket")
        elif operation == "end_session" and end_claim_id:
            known_claim = active or self.store.claim(handle, end_claim_id)
            ticket_ref = (known_claim or {}).get("ticket_id") or (known_claim or {}).get("ticket")
        if previous is None:
            previous = self.store.begin_operation(
                handle, execution.run_generation, operation_id, operation, normalized,
                end_claim_id if operation == "end_session" else claim_id,
            )
        if operation in ORDINARY_OPERATIONS and previous["existing"]:
            raise BridgeError(409, "operation was already attempted; read current state before retrying")
        try:
            result = self.transport(operation, values)
            if operation in LIFECYCLE_OPERATIONS:
                self._refresh(handle, execution.work_session_id, ticket_ref=ticket_ref)
        except BridgeError as error:
            self.store.finish_operation(handle, operation_id,
                                        "ambiguous" if error.code >= 500 else "rejected",
                                        type(error).__name__)
            raise
        if not isinstance(result, dict):
            self.store.finish_operation(handle, operation_id, "ambiguous", "InvalidResult")
            raise BridgeError(502, "kanban transport returned invalid operation data")
        self.store.finish_operation(handle, operation_id, "succeeded")
        return {**result, "operation_id": operation_id}

    def instructions(self, payload: dict) -> dict:
        _shape(payload, optional=("handle",))
        handle = payload.get("handle")
        capable = False
        if handle is not None:
            handle = validate_local_handle(handle)
            capable = self.store.get_execution(handle)
            if capable is None:
                raise BridgeError(404, "unknown work handle")
            capable = capable.lifecycle_capable
        env = {key: value for key, value in os.environ.items()
               if key not in {"KANBAN_TOKEN", "KANBAN_TEST_TOKEN"}}
        try:
            result = subprocess.run([self.instructions_helper, "--instructions"],
                                    text=True, capture_output=True, shell=False, timeout=30, env=env)
        except (OSError, subprocess.SubprocessError) as error:
            raise BridgeError(502, f"kanban instructions failed: {type(error).__name__}") from None
        if result.returncode:
            raise BridgeError(502, "kanban instructions helper failed")
        return {"text": result.stdout, "lifecycle_capable": bool(capable), "handle": handle}
