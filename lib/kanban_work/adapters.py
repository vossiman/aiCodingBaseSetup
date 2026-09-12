"""Claude Code and Codex native hook adapters for Kanban work lifecycles."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Callable

from .bridge import Bridge
from .events import EventIngestor
from .legacy import parse_legacy_complete, prepare_legacy_complete
from .schema import (
    BridgeError,
    READ_TOOLS,
    TOOL_SPECS,
    normalize_tool_args,
    qualified_client_version,
)
from .store import Execution, MAX_OPAQUE, Store


CLAUDE_EVENTS = frozenset({
    "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
    "PostToolUseFailure", "Stop", "StopFailure", "SessionEnd",
    "SubagentStart", "SubagentStop",
})
CODEX_EVENTS = frozenset({
    "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop",
    "SessionEnd", "SubagentStart", "SubagentStop",
})
START_SOURCES = {
    "claude": frozenset({"startup", "resume", "clear", "compact", "fork"}),
    "codex": frozenset({"startup", "resume", "clear", "compact"}),
}
FRESH_SOURCE_EVENTS = {
    "startup": "start", "resume": "resume", "clear": "clear", "fork": "start",
}
SHELL_TOOLS = frozenset({"Bash"})
MCP_PREFIX = "mcp__kanban__"
VERSION_PATTERN = re.compile(r"\b\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?\b")


@dataclass(frozen=True)
class AdapterResult:
    output: dict
    lifecycle: dict | None = None


def _bounded(value, name: str, *, optional: bool = False) -> str | None:
    if optional and value is None:
        return None
    if not isinstance(value, str) or not value.strip() or len(value) > MAX_OPAQUE:
        raise BridgeError(422, f"{name} must be a bounded nonempty identifier")
    return value


def _event_id(*parts: str | None) -> str:
    encoded = json.dumps(parts, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _client_version(harness: str) -> str | None:
    binary = {"claude": "claude", "codex": "codex"}[harness]
    env = {key: value for key, value in os.environ.items()
           if key not in {"KANBAN_TOKEN", "KANBAN_TEST_TOKEN"}}
    try:
        result = subprocess.run(
            [binary, "--version"], stdin=subprocess.DEVNULL, capture_output=True,
            text=True, shell=False, timeout=2, env=env,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode:
        return None
    match = VERSION_PATTERN.search(result.stdout[:1024])
    return match.group(0) if match else None


class ClaudeCodexAdapter:
    def __init__(self, store: Store | None = None, ingress: EventIngestor | None = None, *,
                 now: Callable[[], datetime] | None = None,
                 version_provider: Callable[[str], str | None] | None = None,
                 instructions_provider: Callable[[str], str] | None = None):
        self.store = store or Store()
        self.now = now or (lambda: datetime.now(UTC))
        self.ingress = ingress or EventIngestor(self.store, now=self.now)
        self.version_provider = version_provider or _client_version
        self.instructions_provider = instructions_provider or self._instructions

    def _instructions(self, handle: str) -> str:
        return Bridge(store=self.store).instructions({"handle": handle})["text"]

    @staticmethod
    def _allow(updated_input: dict | None = None) -> dict:
        value = {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
        }
        if updated_input is not None:
            value["updatedInput"] = updated_input
        return {"hookSpecificOutput": value}

    @staticmethod
    def _deny(message: str) -> dict:
        return {"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": message,
        }}

    @staticmethod
    def _validate_event(harness: str, event_name: str, payload: dict):
        if harness not in {"claude", "codex"}:
            raise BridgeError(422, f"unsupported lifecycle harness {harness!r}")
        allowed = CLAUDE_EVENTS if harness == "claude" else CODEX_EVENTS
        if event_name not in allowed:
            raise BridgeError(422, f"unsupported {harness} hook event {event_name!r}")
        if not isinstance(payload, dict):
            raise BridgeError(422, "native hook payload must be an object")
        supplied = payload.get("hook_event_name")
        if supplied is not None and supplied != event_name:
            raise BridgeError(422, "hook_event_name does not match invoked event")

    @staticmethod
    def _native(payload: dict) -> tuple[str, str | None]:
        return (_bounded(payload.get("session_id"), "session_id"),
                _bounded(payload.get("agent_id"), "agent_id", optional=True))

    def _current(self, harness: str, session_id: str,
                 agent_id: str | None) -> Execution:
        execution = self.store.current_execution(harness, session_id, agent_id)
        if execution is None or execution.state == "ended":
            raise BridgeError(403, "native execution has no current Kanban work handle")
        return execution

    def _record(self, harness: str, event_name: str, execution: Execution, event_id: str,
                *, native_call_id: str | None = None) -> dict:
        payload = {
            "native_event_id": event_id,
            "handle": execution.handle,
            "run_generation": execution.run_generation,
        }
        if native_call_id is not None:
            payload["native_call_id"] = native_call_id
        return self.ingress.ingest_event(harness, event_name, payload)

    @staticmethod
    def _prompt_identifier(harness: str, payload: dict) -> str:
        name = "turn_id" if harness == "codex" else "prompt_id"
        value = payload.get(name)
        if value is None and harness == "claude":
            value = payload.get("turn_id")
        return _bounded(value, name)

    def _prompt_event_id(self, harness: str, session_id: str,
                         agent_id: str | None, prompt_id: str) -> str:
        return _event_id("prompt", harness, session_id, agent_id, prompt_id)

    def _execution_from_record(self, harness: str, event_id: str,
                               description: str) -> Execution:
        record = self.store.native_event(harness, event_id)
        if record is None or not record["handle"] or not record["run_generation"]:
            raise BridgeError(409, f"cannot correlate {description} to a captured run generation")
        execution = self.store.get_execution(record["handle"])
        if execution is None or execution.run_generation != record["run_generation"]:
            raise BridgeError(409, f"captured {description} generation is unavailable")
        return execution

    def _execution_for_prompt(self, harness: str, payload: dict,
                              description: str) -> tuple[Execution, str]:
        session_id, agent_id = self._native(payload)
        prompt_id = self._prompt_identifier(harness, payload)
        event_id = self._prompt_event_id(harness, session_id, agent_id, prompt_id)
        return self._execution_from_record(harness, event_id, description), prompt_id

    def _write_claude_hint(self, handle: str):
        path = os.environ.get("CLAUDE_ENV_FILE")
        if not path:
            return
        try:
            with Path(path).open("a", encoding="utf-8") as stream:
                stream.write(f"export KANBAN_WORK_HANDLE='{handle}'\n")
        except OSError:
            return

    def _start_output(self, harness: str, lifecycle: dict) -> AdapterResult:
        handle = lifecycle["handle"]
        if harness == "claude":
            self._write_claude_hint(handle)
        text = self.instructions_provider(handle)
        context = f"{text.rstrip()}\n\nKanban work handle: {handle}"
        return AdapterResult({"hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": context,
        }}, lifecycle)

    def _end_previous(self, harness: str, execution: Execution, reason: str):
        for child in self.store.active_child_executions(harness, execution.native_session_id):
            self._record(
                harness, "end", child,
                _event_id("generation-boundary", harness, child.handle, reason),
            )
        self._record(
            harness, "end", execution,
            _event_id("generation-boundary", harness, execution.handle, reason),
        )

    def _session_start(self, harness: str, payload: dict) -> AdapterResult:
        session_id, agent_id = self._native(payload)
        if agent_id is not None:
            raise BridgeError(422, "SessionStart cannot identify a subagent")
        source = _bounded(payload.get("source"), "source")
        if source not in START_SOURCES[harness]:
            raise BridgeError(422, f"unsupported {harness} SessionStart source")
        if source == "compact":
            execution = self._current(harness, session_id, None)
            lifecycle = self._record(
                harness, "compaction", execution,
                _event_id("compact", harness, session_id, execution.run_generation,
                          payload.get("transcript_path")),
            )
            return self._start_output(harness, lifecycle)

        checkout = payload.get("cwd")
        if not isinstance(checkout, str) or not os.path.isabs(checkout):
            raise BridgeError(422, "cwd must be an absolute path")
        start_id = _event_id(
            "session-start", harness, session_id, source, payload.get("transcript_path")
        )
        prior_receipt = self.store.native_event(harness, start_id)
        if prior_receipt is not None and prior_receipt["result"] is not None:
            return self._start_output(harness, prior_receipt["result"])
        current = self.store.current_execution(harness, session_id, None)
        if current is not None and current.state != "ended":
            self._end_previous(harness, current, source)
        version = self.version_provider(harness)
        lifecycle = self.ingress.ingest_event(harness, FRESH_SOURCE_EVENTS[source], {
            "native_event_id": start_id,
            "native_session_id": session_id,
            "subagent_id": None,
            "checkout": checkout,
            "lifecycle_capable": qualified_client_version(harness, version),
        })
        return self._start_output(harness, lifecycle)

    def _subagent_start(self, harness: str, payload: dict) -> AdapterResult:
        session_id, agent_id = self._native(payload)
        if agent_id is None:
            raise BridgeError(422, "SubagentStart requires agent_id")
        parent = self._current(harness, session_id, None)
        checkout = payload.get("cwd", parent.checkout)
        if not isinstance(checkout, str) or not os.path.isabs(checkout):
            raise BridgeError(422, "cwd must be an absolute path")
        event_id = _event_id(
            "subagent-start", harness, session_id, agent_id, parent.run_generation
        )
        prior = self.store.native_event(harness, event_id)
        if prior is not None and prior["result"] is not None:
            lifecycle = prior["result"]
        else:
            current = self.store.current_execution(harness, session_id, agent_id)
            if current is not None and current.state != "ended":
                self._record(
                    harness, "end", current,
                    _event_id("subagent-restart", harness, current.handle),
                )
            lifecycle = self.ingress.ingest_event(harness, "start", {
                "native_event_id": event_id,
                "native_session_id": session_id,
                "subagent_id": agent_id,
                "checkout": checkout,
                "lifecycle_capable": parent.lifecycle_capable,
            })
        handle = lifecycle["handle"]
        context = (
            f"{self.instructions_provider(handle).rstrip()}\n\n"
            f"Kanban work handle: {handle}"
        )
        return AdapterResult({"hookSpecificOutput": {
            "hookEventName": "SubagentStart",
            "additionalContext": context,
        }}, lifecycle)

    def _subagent_stop(self, harness: str, payload: dict) -> AdapterResult:
        session_id, agent_id = self._native(payload)
        if agent_id is None:
            raise BridgeError(422, "SubagentStop requires agent_id")
        child = self._current(harness, session_id, agent_id)
        lifecycle = self._record(
            harness, "end", child,
            _event_id("subagent-stop", harness, session_id, agent_id, child.run_generation),
        )
        return AdapterResult({}, lifecycle)

    def _prompt(self, harness: str, payload: dict) -> AdapterResult:
        session_id, agent_id = self._native(payload)
        execution = self._current(harness, session_id, agent_id)
        prompt_id = self._prompt_identifier(harness, payload)
        lifecycle = self._record(
            harness, "activity", execution,
            self._prompt_event_id(harness, session_id, agent_id, prompt_id),
        )
        return AdapterResult({}, lifecycle)

    @staticmethod
    def _mcp_tool(tool_name: str) -> str | None:
        return tool_name[len(MCP_PREFIX):] if tool_name.startswith(MCP_PREFIX) else None

    def _tool_start(self, harness: str, payload: dict) -> AdapterResult:
        try:
            session_id, agent_id = self._native(payload)
            native_call_id = _bounded(payload.get("tool_use_id"), "tool_use_id")
            tool_name = _bounded(payload.get("tool_name"), "tool_name")
            tool_input = payload.get("tool_input")
            if not isinstance(tool_input, dict):
                raise BridgeError(422, "tool_input must be an object")
            prompt_id = self._prompt_identifier(harness, payload)
            prompt_event = self._prompt_event_id(harness, session_id, agent_id, prompt_id)
            execution = self._execution_from_record(harness, prompt_event, "PreToolUse")
            mcp_tool = self._mcp_tool(tool_name)
            updated = None
            if mcp_tool is not None:
                if mcp_tool in READ_TOOLS:
                    pass
                elif mcp_tool in TOOL_SPECS:
                    normalized = normalize_tool_args(mcp_tool, tool_input)
                    self.store.permit_call(
                        execution.identity, native_call_id, mcp_tool, normalized, self.now()
                    )
                else:
                    raise BridgeError(422, "unknown Kanban MCP tool")
            elif tool_name in SHELL_TOOLS:
                command = tool_input.get("command")
                if not isinstance(command, str):
                    raise BridgeError(422, "native shell command is not verifiable")
                parsed = parse_legacy_complete(command)
                if parsed is not None:
                    prepared = prepare_legacy_complete(
                        execution.identity, native_call_id, command,
                        store=self.store, now=self.now(),
                    )
                    updated = {"command": shlex.join(prepared.rewritten_argv)}
            lifecycle = self._record(
                harness, "tool_start", execution,
                _event_id("tool-start", harness, session_id, agent_id, native_call_id),
                native_call_id=native_call_id,
            )
            return AdapterResult(self._allow(updated), lifecycle)
        except BridgeError as error:
            return AdapterResult(self._deny(error.message))

    def _tool_finish(self, harness: str, event_name: str, payload: dict) -> AdapterResult:
        session_id, agent_id = self._native(payload)
        native_call_id = _bounded(payload.get("tool_use_id"), "tool_use_id")
        _bounded(payload.get("tool_name"), "tool_name")
        event_id = _event_id("tool-start", harness, session_id, agent_id, native_call_id)
        execution = self._execution_from_record(harness, event_id, event_name)
        normalized_event = "tool_success" if event_name == "PostToolUse" else "tool_failure"
        lifecycle = self._record(
            harness, normalized_event, execution,
            _event_id(normalized_event, harness, session_id, agent_id, native_call_id),
            native_call_id=native_call_id,
        )
        return AdapterResult({}, lifecycle)

    def _stop(self, harness: str, event_name: str, payload: dict) -> AdapterResult:
        execution, prompt_id = self._execution_for_prompt(harness, payload, event_name)
        if execution.state == "ended":
            return AdapterResult({}, {
                "status": "dropped_old_generation", "handle": execution.handle,
                "run_generation": execution.run_generation,
            })
        if harness == "claude" and (
            payload.get("background_tasks") or payload.get("session_crons")
        ):
            return AdapterResult({}, {
                "status": "deferred_active_work", "handle": execution.handle,
                "run_generation": execution.run_generation,
            })
        if (self.store.has_active_tool_operations(execution.handle, execution.run_generation)
                or self.store.active_child_executions(harness, execution.native_session_id)):
            return AdapterResult({}, {
                "status": "deferred_active_work", "handle": execution.handle,
                "run_generation": execution.run_generation,
            })
        lifecycle = self._record(
            harness, "stop", execution,
            _event_id("stop", harness, event_name, execution.handle, prompt_id),
        )
        return AdapterResult({}, lifecycle)

    def _session_end(self, harness: str, payload: dict) -> AdapterResult:
        session_id, agent_id = self._native(payload)
        executions = self.store.executions_for_native(harness, session_id, agent_id)
        if len(executions) != 1:
            raise BridgeError(
                409, "cannot correlate SessionEnd after a generation boundary; bounded expiry applies"
            )
        execution = executions[0]
        lifecycle = self._record(
            harness, "end", execution,
            _event_id("session-end", harness, session_id, agent_id,
                      payload.get("reason"), payload.get("transcript_path")),
        )
        return AdapterResult({}, lifecycle)

    def adapt(self, harness: str, event_name: str, payload: dict) -> AdapterResult:
        self._validate_event(harness, event_name, payload)
        if event_name == "SessionStart":
            return self._session_start(harness, payload)
        if event_name == "SubagentStart":
            return self._subagent_start(harness, payload)
        if event_name == "SubagentStop":
            return self._subagent_stop(harness, payload)
        if event_name == "UserPromptSubmit":
            return self._prompt(harness, payload)
        if event_name == "PreToolUse":
            return self._tool_start(harness, payload)
        if event_name in {"PostToolUse", "PostToolUseFailure"}:
            return self._tool_finish(harness, event_name, payload)
        if event_name in {"Stop", "StopFailure"}:
            return self._stop(harness, event_name, payload)
        if event_name == "SessionEnd":
            return self._session_end(harness, payload)
        raise BridgeError(422, f"unsupported {harness} hook event {event_name!r}")


def adapt_claude_codex(harness: str, event_name: str, payload: dict) -> AdapterResult:
    store = Store()
    try:
        executable = Path(__file__).resolve().parents[2] / "bin" / "kanban-work"

        def start_supervisor(handle: str, native_call_id: str):
            try:
                subprocess.Popen(
                    [sys.executable, str(executable), "supervise", handle, native_call_id],
                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True,
                )
            except OSError:
                return

        ingress = EventIngestor(store, start_supervisor=start_supervisor)
        return ClaudeCodexAdapter(store, ingress).adapt(harness, event_name, payload)
    finally:
        store.close()
