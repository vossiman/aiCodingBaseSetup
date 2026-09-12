"""Claude Code, Codex, Cursor, and OpenCode native Kanban lifecycle adapters."""

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
from .legacy import DENIAL, parse_legacy_complete, prepare_legacy_complete
from .schema import (
    BridgeError,
    READ_TOOLS,
    TOOL_SPECS,
    normalize_tool_args,
    normalized_dict,
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
CURSOR_EVENTS = frozenset({
    "sessionStart", "beforeSubmitPrompt", "preToolUse", "postToolUse",
    "postToolUseFailure", "stop", "sessionEnd", "subagentStart",
    "subagentStop", "preCompact",
})
START_SOURCES = {
    "claude": frozenset({"startup", "resume", "clear", "compact", "fork"}),
    "codex": frozenset({"startup", "resume", "clear", "compact"}),
}
FRESH_SOURCE_EVENTS = {
    "startup": "start", "resume": "resume", "clear": "clear", "fork": "start",
}
SHELL_TOOLS = frozenset({"Bash", "Shell"})
MCP_PREFIX = "mcp__kanban__"
VERSION_PATTERN = re.compile(r"\b\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?\b")
CLAUDE_BASH_FIELDS = frozenset({"command", "description", "timeout", "run_in_background"})
CODEX_BASH_FIELDS = frozenset({"command"})
CURSOR_SHELL_FIELDS = frozenset({"command", "working_directory"})
CURSOR_MCP_TOOLS = frozenset(
    f"MCP:{name}" for name in frozenset(TOOL_SPECS) | READ_TOOLS
)
OPENCODE_MCP_TOOLS = {
    f"kanban_{name}": name for name in frozenset(TOOL_SPECS) | READ_TOOLS
}
OPENCODE_IDENTITY_ERROR = (
    "OpenCode lifecycle identity is unavailable; "
    "Kanban mutations require a qualified native session"
)


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
        return _bounded(payload.get(name), name)

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

    def _child_start_event_id(self, harness: str, session_id: str, agent_id: str,
                              correlation_id: str, parent_generation: str) -> str:
        return _event_id(
            "subagent-start", harness, session_id, agent_id,
            correlation_id, parent_generation,
        )

    def _child_from_start(self, harness: str, session_id: str, agent_id: str,
                          correlation_id: str, description: str) -> Execution:
        matches = []
        for parent in self.store.executions_for_native(harness, session_id, None):
            event_id = self._child_start_event_id(
                harness, session_id, agent_id, correlation_id, parent.run_generation
            )
            record = self.store.native_event(harness, event_id)
            if record is not None:
                matches.append(record)
        if len(matches) != 1:
            raise BridgeError(
                409, f"cannot correlate {description} to an original child generation"
            )
        result = matches[0]["result"]
        if not isinstance(result, dict):
            raise BridgeError(409, f"captured {description} child start is incomplete")
        handle = result.get("handle")
        generation = result.get("run_generation")
        execution = self.store.get_execution(handle) if isinstance(handle, str) else None
        if execution is None or execution.run_generation != generation:
            raise BridgeError(409, f"captured {description} child generation is unavailable")
        return execution

    def _child_parent(self, harness: str, session_id: str,
                      correlation_id: str) -> Execution:
        if harness == "claude":
            prompt_event = self._prompt_event_id(harness, session_id, None, correlation_id)
            parent = self._execution_from_record(harness, prompt_event, "SubagentStart")
        else:
            parents = self.store.executions_for_native(harness, session_id, None)
            if len(parents) != 1:
                raise BridgeError(
                    409, "cannot correlate SubagentStart to one Codex parent generation"
                )
            parent = parents[0]
        if parent.state == "ended":
            raise BridgeError(409, "cannot correlate SubagentStart to an active parent generation")
        return parent

    def _execution_for_tool(self, harness: str, payload: dict) -> Execution:
        session_id, agent_id = self._native(payload)
        correlation_id = self._prompt_identifier(harness, payload)
        if agent_id is None:
            prompt_event = self._prompt_event_id(
                harness, session_id, None, correlation_id
            )
            return self._execution_from_record(harness, prompt_event, "PreToolUse")
        execution = self._child_from_start(
            harness, session_id, agent_id, correlation_id, "PreToolUse"
        )
        if execution.state == "ended":
            raise BridgeError(409, "captured PreToolUse child generation has ended")
        return execution

    @staticmethod
    def _validated_shell_input(harness: str, tool_input: dict) -> dict:
        allowed = CLAUDE_BASH_FIELDS if harness == "claude" else CODEX_BASH_FIELDS
        if set(tool_input) - allowed:
            raise BridgeError(422, DENIAL)
        if not isinstance(tool_input.get("command"), str):
            raise BridgeError(422, DENIAL)
        if harness == "claude":
            if "description" in tool_input and not isinstance(tool_input["description"], str):
                raise BridgeError(422, DENIAL)
            if "timeout" in tool_input:
                timeout = tool_input["timeout"]
                if isinstance(timeout, bool) or not isinstance(timeout, (int, float)):
                    raise BridgeError(422, DENIAL)
            if ("run_in_background" in tool_input
                    and not isinstance(tool_input["run_in_background"], bool)):
                raise BridgeError(422, DENIAL)
        return dict(tool_input)

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
        correlation_id = self._prompt_identifier(harness, payload)
        parent = self._child_parent(harness, session_id, correlation_id)
        checkout = payload.get("cwd", parent.checkout)
        if not isinstance(checkout, str) or not os.path.isabs(checkout):
            raise BridgeError(422, "cwd must be an absolute path")
        event_id = self._child_start_event_id(
            harness, session_id, agent_id, correlation_id, parent.run_generation
        )
        prior = self.store.native_event(harness, event_id)
        if prior is not None and prior["result"] is not None:
            lifecycle = prior["result"]
            prior_execution = self.store.get_execution(lifecycle["handle"])
            if prior_execution is None or prior_execution.state == "ended":
                raise BridgeError(409, "captured SubagentStart generation has ended")
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
        correlation_id = self._prompt_identifier(harness, payload)
        child = self._child_from_start(
            harness, session_id, agent_id, correlation_id, "SubagentStop"
        )
        if child.state == "ended":
            return AdapterResult({}, {
                "status": "dropped_old_generation", "handle": child.handle,
                "run_generation": child.run_generation,
            })
        lifecycle = self._record(
            harness, "end", child,
            _event_id("subagent-stop", harness, session_id, agent_id,
                      correlation_id, child.run_generation),
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
            tool_name = _bounded(payload.get("tool_name"), "tool_name")
            tool_input = payload.get("tool_input")
            mcp_tool = self._mcp_tool(tool_name)
            updated = None
            prepared_command = None
            verified_shell_input = None
            if mcp_tool is not None:
                if mcp_tool in READ_TOOLS:
                    pass
                elif mcp_tool in TOOL_SPECS:
                    if not isinstance(tool_input, dict):
                        raise BridgeError(422, "tool_input must be an object")
                else:
                    raise BridgeError(422, "unknown Kanban MCP tool")
            elif tool_name in SHELL_TOOLS and isinstance(tool_input, dict):
                command = tool_input.get("command")
                if isinstance(command, str):
                    prepared_command = parse_legacy_complete(command)
                    if prepared_command is not None:
                        verified_shell_input = self._validated_shell_input(harness, tool_input)

            requires_correlation = (
                mcp_tool is not None and mcp_tool not in READ_TOOLS
            ) or prepared_command is not None
            try:
                session_id, agent_id = self._native(payload)
                native_call_id = _bounded(payload.get("tool_use_id"), "tool_use_id")
                execution = self._execution_for_tool(harness, payload)
            except BridgeError:
                if requires_correlation:
                    raise
                return AdapterResult(self._allow())

            if mcp_tool is not None and mcp_tool not in READ_TOOLS:
                normalized = normalize_tool_args(mcp_tool, tool_input)
                self.store.permit_call(
                    execution.identity, native_call_id, mcp_tool, normalized, self.now()
                )
            elif prepared_command is not None:
                prepared = prepare_legacy_complete(
                    execution.identity, native_call_id, tool_input["command"],
                    store=self.store, now=self.now(),
                )
                updated = {
                    **verified_shell_input,
                    "command": shlex.join(prepared.rewritten_argv),
                }
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
        for child in self.store.active_child_executions(harness, session_id):
            self._record(
                harness, "end", child,
                _event_id("session-end-child", harness, session_id, child.subagent_id,
                          child.run_generation, payload.get("reason"),
                          payload.get("transcript_path")),
            )
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


class CursorAdapter(ClaudeCodexAdapter):
    """Translate Cursor's native flat hook contract into shared lifecycle events."""

    @staticmethod
    def _allow(updated_input: dict | None = None) -> dict:
        value = {"permission": "allow"}
        if updated_input is not None:
            value["updated_input"] = updated_input
        return value

    @staticmethod
    def _deny(message: str) -> dict:
        if message == "handle belongs to another native session":
            message = "handle does not belong to the bound Cursor session"
        return {"permission": "deny", "agent_message": message, "user_message": message}

    @staticmethod
    def _validate_event(harness: str, event_name: str, payload: dict):
        if harness != "cursor":
            raise BridgeError(422, f"unsupported lifecycle harness {harness!r}")
        if event_name not in CURSOR_EVENTS:
            raise BridgeError(422, f"unsupported cursor hook event {event_name!r}")
        if not isinstance(payload, dict):
            raise BridgeError(422, "native hook payload must be an object")
        if payload.get("hook_event_name") != event_name:
            raise BridgeError(422, "hook_event_name does not match invoked event")

    @staticmethod
    def _native(payload: dict) -> tuple[str, str | None]:
        return (
            _bounded(payload.get("conversation_id"), "conversation_id"),
            _bounded(payload.get("subagent_id"), "subagent_id", optional=True),
        )

    @staticmethod
    def _prompt_identifier(harness: str, payload: dict) -> str:
        return _bounded(payload.get("generation_id"), "generation_id")

    @staticmethod
    def _mcp_tool(tool_name: str) -> str | None:
        prefix = "MCP:"
        return tool_name[len(prefix):] if tool_name in CURSOR_MCP_TOOLS else None

    @staticmethod
    def _validated_shell_input(harness: str, tool_input: dict) -> dict:
        if set(tool_input) - CURSOR_SHELL_FIELDS:
            raise BridgeError(422, DENIAL)
        if not isinstance(tool_input.get("command"), str):
            raise BridgeError(422, DENIAL)
        if ("working_directory" in tool_input
                and not isinstance(tool_input["working_directory"], str)):
            raise BridgeError(422, DENIAL)
        return dict(tool_input)

    def _start_output(self, harness: str, lifecycle: dict) -> AdapterResult:
        handle = lifecycle["handle"]
        context = (
            f"{self.instructions_provider(handle).rstrip()}\n\n"
            f"Kanban work handle: {handle}"
        )
        return AdapterResult({
            "env": {"KANBAN_WORK_HANDLE": handle},
            "additional_context": context,
        }, lifecycle)

    def _session_start(self, harness: str, payload: dict) -> AdapterResult:
        session_id, agent_id = self._native(payload)
        if agent_id is not None:
            raise BridgeError(422, "sessionStart cannot identify a subagent")
        documented_session = _bounded(payload.get("session_id"), "session_id")
        if documented_session != session_id:
            raise BridgeError(422, "session_id must match conversation_id")
        if type(payload.get("is_background_agent")) is not bool:
            raise BridgeError(422, "is_background_agent must be a boolean")
        version = _bounded(payload.get("cursor_version"), "cursor_version")
        generation = self._prompt_identifier("cursor", payload)
        roots = payload.get("workspace_roots")
        if (not isinstance(roots, list) or len(roots) != 1
                or not isinstance(roots[0], str) or not os.path.isabs(roots[0])):
            raise BridgeError(422, "Cursor lifecycle requires exactly one workspace root")
        checkout = roots[0]
        start_id = _event_id(
            "session-start", "cursor", session_id, payload.get("transcript_path")
        )
        prior = self.store.native_event("cursor", start_id)
        if prior is not None and prior["result"] is not None:
            lifecycle = prior["result"]
            execution = self.store.get_execution(lifecycle["handle"])
            if execution is None:
                raise BridgeError(409, "captured sessionStart generation is unavailable")
            self._record(
                "cursor", "activity", execution,
                self._prompt_event_id("cursor", session_id, None, generation),
            )
            return self._start_output("cursor", lifecycle)
        current = self.store.current_execution("cursor", session_id, None)
        if current is not None and current.state != "ended":
            raise BridgeError(409, "Cursor conversation already has an active work generation")
        lifecycle = self.ingress.ingest_event("cursor", "start", {
            "native_event_id": start_id,
            "native_session_id": session_id,
            "subagent_id": None,
            "checkout": checkout,
            "lifecycle_capable": qualified_client_version("cursor", version),
        })
        execution = self.store.get_execution(lifecycle["handle"])
        if execution is None:
            raise BridgeError(409, "captured sessionStart generation is unavailable")
        self._record(
            "cursor", "activity", execution,
            self._prompt_event_id("cursor", session_id, None, generation),
        )
        return self._start_output("cursor", lifecycle)

    def _child_parent(self, harness: str, session_id: str,
                      correlation_id: str) -> Execution:
        prompt_event = self._prompt_event_id("cursor", session_id, None, correlation_id)
        parent = self._execution_from_record("cursor", prompt_event, "subagentStart")
        if parent.state == "ended":
            raise BridgeError(409, "cannot correlate subagentStart to an active parent generation")
        return parent

    def _subagent_start(self, harness: str, payload: dict) -> AdapterResult:
        if payload.get("parent_conversation_id") != payload.get("conversation_id"):
            raise BridgeError(422, "parent_conversation_id must match conversation_id")
        result = super()._subagent_start("cursor", payload)
        handle = result.lifecycle["handle"]
        return AdapterResult({
            "permission": "allow",
            "additional_context": (
                f"{self.instructions_provider(handle).rstrip()}\n\n"
                f"Kanban work handle: {handle}"
            ),
        }, result.lifecycle)

    def _subagent_stop(self, harness: str, payload: dict) -> AdapterResult:
        # Cursor's documented event has no subagent_id. Summaries, task text,
        # status and transcript paths are not stable identities, so keep both
        # child and parent live until an exact native correlation exists.
        return AdapterResult({}, {"status": "unsupported_child_correlation"})

    def _precompact(self, payload: dict) -> AdapterResult:
        session_id, agent_id = self._native(payload)
        execution = self._current("cursor", session_id, agent_id)
        generation = self._prompt_identifier("cursor", payload)
        lifecycle = self._record(
            "cursor", "activity", execution,
            _event_id("precompact", "cursor", session_id, agent_id, generation,
                      payload.get("trigger")),
        )
        return AdapterResult({}, lifecycle)

    def _session_end(self, harness: str, payload: dict) -> AdapterResult:
        session_id, agent_id = self._native(payload)
        if agent_id is not None:
            raise BridgeError(422, "sessionEnd cannot identify a subagent")
        documented_session = _bounded(payload.get("session_id"), "session_id")
        if documented_session != session_id:
            raise BridgeError(422, "session_id must match conversation_id")
        generation = self._prompt_identifier("cursor", payload)
        prompt_event = self._prompt_event_id("cursor", session_id, None, generation)
        execution = self._execution_from_record("cursor", prompt_event, "sessionEnd")
        for child in self.store.active_child_executions("cursor", session_id):
            if child.subagent_id is None:
                continue
            child_start = self._child_start_event_id(
                "cursor", session_id, child.subagent_id, generation,
                execution.run_generation,
            )
            if self.store.native_event("cursor", child_start) is None:
                continue
            self._record(
                "cursor", "end", child,
                _event_id("session-end-child", "cursor", session_id, generation,
                          child.subagent_id, child.run_generation,
                          payload.get("reason"), payload.get("transcript_path")),
            )
        if execution.state == "ended":
            return AdapterResult({}, {
                "status": "dropped_old_generation", "handle": execution.handle,
                "run_generation": execution.run_generation,
            })
        lifecycle = self._record(
            "cursor", "end", execution,
            _event_id("session-end", "cursor", session_id, generation,
                      execution.run_generation, payload.get("reason"),
                      payload.get("transcript_path")),
        )
        return AdapterResult({}, lifecycle)

    def adapt(self, event_name: str, payload: dict) -> AdapterResult:
        self._validate_event("cursor", event_name, payload)
        if event_name == "sessionStart":
            return self._session_start("cursor", payload)
        if event_name == "subagentStart":
            return self._subagent_start("cursor", payload)
        if event_name == "subagentStop":
            return self._subagent_stop("cursor", payload)
        if event_name == "beforeSubmitPrompt":
            return self._prompt("cursor", payload)
        if event_name == "preToolUse":
            return self._tool_start("cursor", payload)
        if event_name in {"postToolUse", "postToolUseFailure"}:
            mapped = "PostToolUse" if event_name == "postToolUse" else "PostToolUseFailure"
            return self._tool_finish("cursor", mapped, payload)
        if event_name == "preCompact":
            return self._precompact(payload)
        if event_name == "stop":
            return self._stop("cursor", "stop", payload)
        if event_name == "sessionEnd":
            return self._session_end("cursor", payload)
        raise BridgeError(422, f"unsupported cursor hook event {event_name!r}")


def adapt_cursor(event_name: str, payload: dict) -> AdapterResult:
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
        return CursorAdapter(store, ingress).adapt(event_name, payload)
    finally:
        store.close()


class OpenCodeAdapter:
    """Translate OpenCode's plugin contract into shared lifecycle events."""

    EVENTS = frozenset({
        "session.created", "session.compacted", "session.idle", "session.deleted",
        "session.error", "tool.execute.before", "tool.execute.after", "system.transform",
    })

    def __init__(self, store: Store | None = None, ingress: EventIngestor | None = None, *,
                 now: Callable[[], datetime] | None = None):
        self.store = store or Store()
        self.now = now or (lambda: datetime.now(UTC))
        self.ingress = ingress or EventIngestor(self.store, now=self.now)

    @staticmethod
    def _validate_event(event_name: str, payload: dict):
        if event_name not in OpenCodeAdapter.EVENTS:
            raise BridgeError(422, f"unsupported opencode plugin event {event_name!r}")
        if not isinstance(payload, dict):
            raise BridgeError(422, "native plugin payload must be an object")
        _bounded(payload.get("instanceID"), "instanceID")

    @staticmethod
    def _directory(payload: dict) -> str:
        directory = payload.get("directory")
        if not isinstance(directory, str) or not os.path.isabs(directory):
            raise BridgeError(422, "OpenCode directory must be an absolute path")
        return directory

    @staticmethod
    def _version(payload: dict) -> str | None:
        return _bounded(payload.get("clientVersion"), "clientVersion", optional=True)

    @staticmethod
    def _parent(payload: dict) -> str | None:
        return _bounded(payload.get("parentSessionID"), "parentSessionID", optional=True)

    @staticmethod
    def _instance(payload: dict) -> str:
        return _bounded(payload.get("instanceID"), "instanceID")

    @staticmethod
    def _parent_start_id(session_id: str, instance_id: str, *, observed: bool = False) -> str:
        kind = "session-first-observed" if observed else "session-created"
        return _event_id(kind, "opencode", instance_id, session_id)

    @staticmethod
    def _child_start_id(session_id: str, parent_session_id: str,
                        parent: Execution, instance_id: str) -> str:
        return _event_id(
            "session-created", "opencode", instance_id, session_id, parent_session_id,
            parent.handle, parent.run_generation,
        )

    def _execution_from_start_id(self, event_id: str) -> tuple[Execution, dict] | None:
        record = self.store.native_event("opencode", event_id)
        if record is None or not isinstance(record.get("result"), dict):
            return None
        result = record["result"]
        handle = result.get("handle")
        generation = result.get("run_generation")
        execution = self.store.get_execution(handle) if isinstance(handle, str) else None
        if execution is None or execution.run_generation != generation:
            raise BridgeError(409, "captured OpenCode session generation is unavailable")
        return execution, result

    def _known_parent(self, session_id: str,
                      instance_id: str) -> tuple[Execution, dict] | None:
        created = self._execution_from_start_id(
            self._parent_start_id(session_id, instance_id)
        )
        observed = self._execution_from_start_id(
            self._parent_start_id(session_id, instance_id, observed=True)
        )
        if created is not None and observed is not None and created[0].handle != observed[0].handle:
            raise BridgeError(409, "OpenCode session has ambiguous captured generations")
        return created or observed

    def _session_execution(self, payload: dict, description: str) -> tuple[Execution, dict]:
        session_id = _bounded(payload.get("sessionID"), "sessionID")
        instance_id = self._instance(payload)
        parent_id = self._parent(payload)
        if parent_id is None:
            known = self._known_parent(session_id, instance_id)
        else:
            parent = self._known_parent(parent_id, instance_id)
            if parent is None:
                raise BridgeError(409, f"cannot correlate {description} to a captured parent")
            known = self._execution_from_start_id(
                self._child_start_id(session_id, parent_id, parent[0], instance_id)
            )
        if known is None:
            raise BridgeError(409, f"cannot correlate {description} to a captured run generation")
        return known

    def _first_observed(self, payload: dict) -> tuple[Execution, dict]:
        session_id = _bounded(payload.get("sessionID"), "sessionID")
        instance_id = self._instance(payload)
        known = self._known_parent(session_id, instance_id)
        if known is not None:
            return known
        lifecycle = self.ingress.ingest_event("opencode", "start", {
            "native_event_id": self._parent_start_id(
                session_id, instance_id, observed=True
            ),
            "native_session_id": session_id,
            "subagent_id": None,
            "checkout": self._directory(payload),
            "lifecycle_capable": False,
        })
        execution = self.store.get_execution(lifecycle["handle"])
        if execution is None:
            raise BridgeError(409, "captured OpenCode session generation is unavailable")
        return execution, lifecycle

    def _session_or_observe(self, payload: dict, description: str) -> tuple[Execution, dict]:
        try:
            return self._session_execution(payload, description)
        except BridgeError as error:
            if error.code != 409 or self._parent(payload) is not None:
                raise
            return self._first_observed(payload)

    def _record(self, event_name: str, execution: Execution, event_id: str, *,
                native_call_id: str | None = None) -> dict:
        value = {
            "native_event_id": event_id,
            "handle": execution.handle,
            "run_generation": execution.run_generation,
        }
        if native_call_id is not None:
            value["native_call_id"] = native_call_id
        return self.ingress.ingest_event("opencode", event_name, value)

    @staticmethod
    def _identity_output(execution: Execution) -> dict:
        return {
            "handle": execution.handle,
            "lifecycle_capable": execution.lifecycle_capable,
        }

    def _session_created(self, payload: dict) -> AdapterResult:
        session_id = _bounded(payload.get("sessionID"), "sessionID")
        instance_id = self._instance(payload)
        info = payload.get("info")
        if not isinstance(info, dict):
            raise BridgeError(422, "session.created info must be an object")
        if _bounded(info.get("id"), "info.id") != session_id:
            raise BridgeError(422, "session.created info.id must match sessionID")
        checkout = info.get("directory")
        if not isinstance(checkout, str) or not os.path.isabs(checkout):
            raise BridgeError(422, "session.created info.directory must be an absolute path")
        version = self._version(payload)
        parent_id = _bounded(info.get("parentID"), "info.parentID", optional=True)

        if parent_id is None:
            known = self._known_parent(session_id, instance_id)
            if known is not None:
                execution, lifecycle = known
                if execution.subagent_id is not None:
                    raise BridgeError(409, "captured OpenCode session identity changed")
                return AdapterResult(self._identity_output(execution), lifecycle)
            start_id = self._parent_start_id(session_id, instance_id)
            lifecycle_capable = qualified_client_version("opencode", version)
            native_session_id = session_id
            subagent_id = None
        else:
            parent = self._known_parent(parent_id, instance_id)
            if parent is None or parent[0].state == "ended":
                raise BridgeError(409, "cannot correlate child session to an active parent")
            start_id = self._child_start_id(
                session_id, parent_id, parent[0], instance_id
            )
            known = self._execution_from_start_id(start_id)
            if known is not None:
                execution, lifecycle = known
                return AdapterResult(self._identity_output(execution), lifecycle)
            lifecycle_capable = parent[0].lifecycle_capable
            native_session_id = parent_id
            subagent_id = session_id

        lifecycle = self.ingress.ingest_event("opencode", "start", {
            "native_event_id": start_id,
            "native_session_id": native_session_id,
            "subagent_id": subagent_id,
            "checkout": checkout,
            "lifecycle_capable": lifecycle_capable,
        })
        execution = self.store.get_execution(lifecycle["handle"])
        if execution is None:
            raise BridgeError(409, "captured OpenCode session generation is unavailable")
        return AdapterResult(self._identity_output(execution), lifecycle)

    def _activity(self, event_name: str, payload: dict) -> AdapterResult:
        execution, _ = self._session_or_observe(payload, event_name)
        event_id = _bounded(payload.get("eventID"), "eventID")
        instance_id = self._instance(payload)
        normalized = "compaction" if event_name == "session.compacted" else "activity"
        lifecycle = self._record(
            normalized, execution,
            _event_id(event_name, "opencode", instance_id,
                      payload.get("sessionID"), event_id),
        )
        return AdapterResult({}, lifecycle)

    def _stop_candidate(self, event_name: str, payload: dict) -> AdapterResult:
        execution, _ = self._session_or_observe(payload, event_name)
        event_id = _bounded(payload.get("eventID"), "eventID")
        instance_id = self._instance(payload)
        active_children = []
        for child in self.store.active_child_executions("opencode", payload["sessionID"]):
            if child.subagent_id is None:
                continue
            captured = self._execution_from_start_id(self._child_start_id(
                child.subagent_id, payload["sessionID"], execution, instance_id
            ))
            if captured is not None and captured[0].handle == child.handle:
                active_children.append(child)
        if (self.store.has_active_tool_operations(execution.handle, execution.run_generation)
                or active_children):
            return AdapterResult({}, {
                "status": "deferred_active_work", "handle": execution.handle,
                "run_generation": execution.run_generation,
            })
        lifecycle = self._record(
            "stop", execution,
            _event_id(event_name, "opencode", instance_id,
                      payload.get("sessionID"), event_id),
        )
        return AdapterResult({}, lifecycle)

    def _session_error(self, payload: dict) -> AdapterResult:
        if payload.get("sessionID") is None:
            return AdapterResult({}, {"status": "ignored_missing_identity"})
        return self._stop_candidate("session.error", payload)

    def _session_deleted(self, payload: dict) -> AdapterResult:
        session_id = _bounded(payload.get("sessionID"), "sessionID")
        info = payload.get("info")
        if not isinstance(info, dict) or info.get("id") != session_id:
            raise BridgeError(422, "session.deleted info.id must match sessionID")
        parent_id = _bounded(info.get("parentID"), "info.parentID", optional=True)
        instance_id = self._instance(payload)
        lookup = dict(payload)
        lookup["parentSessionID"] = parent_id
        execution, _ = self._session_execution(lookup, "session.deleted")
        event_id = _bounded(payload.get("eventID"), "eventID")

        if parent_id is None:
            for child in self.store.active_child_executions("opencode", session_id):
                if child.subagent_id is None:
                    continue
                child_start = self._child_start_id(
                    child.subagent_id, session_id, execution, instance_id
                )
                captured = self._execution_from_start_id(child_start)
                if captured is None or captured[0].handle != child.handle:
                    continue
                self._record(
                    "end", child,
                    _event_id("session.deleted-child", "opencode", instance_id, session_id,
                              execution.run_generation, child.subagent_id,
                              child.run_generation, event_id),
                )
        lifecycle = self._record(
            "end", execution,
            _event_id("session.deleted", "opencode", instance_id, session_id,
                      execution.run_generation, event_id),
        )
        return AdapterResult({}, lifecycle)

    @staticmethod
    def _mcp_tool(tool_name: str) -> str | None:
        return OPENCODE_MCP_TOOLS.get(tool_name)

    @staticmethod
    def _tool_start_id(instance_id: str, session_id: str,
                       call_id: str, tool_name: str) -> str:
        return _event_id(
            "tool-start", "opencode", instance_id, session_id, call_id, tool_name
        )

    def _tool_before(self, payload: dict) -> AdapterResult:
        tool_name = _bounded(payload.get("tool"), "tool")
        mcp_tool = self._mcp_tool(tool_name)
        args = payload.get("args")
        command = args.get("command") if tool_name == "bash" and isinstance(args, dict) else None
        prepared_command = parse_legacy_complete(command) if isinstance(command, str) else None
        requires_identity = (
            mcp_tool is not None and mcp_tool not in READ_TOOLS
        ) or prepared_command is not None
        session_id = payload.get("sessionID")
        call_id = payload.get("callID")
        if not isinstance(session_id, str) or not session_id.strip() or not isinstance(
            call_id, str
        ) or not call_id.strip():
            if requires_identity:
                raise BridgeError(409, OPENCODE_IDENTITY_ERROR)
            return AdapterResult({})
        session_id = _bounded(session_id, "sessionID")
        call_id = _bounded(call_id, "callID")
        instance_id = self._instance(payload)
        execution, _ = self._session_or_observe(payload, "tool.execute.before")

        output = {}
        if mcp_tool is not None and mcp_tool not in READ_TOOLS:
            normalized = normalize_tool_args(mcp_tool, args)
            self.store.permit_call(
                execution.identity, call_id, mcp_tool, normalized, self.now()
            )
            output["args"] = normalized_dict(mcp_tool, args)
        elif prepared_command is not None:
            prepared = prepare_legacy_complete(
                execution.identity, call_id, command, store=self.store, now=self.now()
            )
            output["args"] = {"command": shlex.join(prepared.rewritten_argv)}

        lifecycle = self._record(
            "tool_start", execution,
            self._tool_start_id(instance_id, session_id, call_id, tool_name),
            native_call_id=call_id,
        )
        return AdapterResult(output, lifecycle)

    def _tool_after(self, payload: dict) -> AdapterResult:
        tool_name = _bounded(payload.get("tool"), "tool")
        session_id = _bounded(payload.get("sessionID"), "sessionID")
        call_id = _bounded(payload.get("callID"), "callID")
        instance_id = self._instance(payload)
        start_id = self._tool_start_id(instance_id, session_id, call_id, tool_name)
        record = self.store.native_event("opencode", start_id)
        if record is None or not record.get("handle") or not record.get("run_generation"):
            raise BridgeError(
                409, "cannot correlate tool.execute.after to the original tool call"
            )
        execution = self.store.get_execution(record["handle"])
        if execution is None or execution.run_generation != record["run_generation"]:
            raise BridgeError(409, "captured tool.execute.after generation is unavailable")
        lifecycle = self._record(
            "tool_success", execution,
            _event_id("tool-success", "opencode", instance_id,
                      session_id, call_id, tool_name,
                      execution.run_generation),
            native_call_id=call_id,
        )
        return AdapterResult({}, lifecycle)

    def _system_transform(self, payload: dict) -> AdapterResult:
        execution, lifecycle = self._session_or_observe(payload, "system.transform")
        return AdapterResult(self._identity_output(execution), lifecycle)

    def adapt(self, event_name: str, payload: dict) -> AdapterResult:
        self._validate_event(event_name, payload)
        if event_name == "session.created":
            return self._session_created(payload)
        if event_name == "session.compacted":
            return self._activity(event_name, payload)
        if event_name == "session.idle":
            return self._stop_candidate(event_name, payload)
        if event_name == "session.error":
            return self._session_error(payload)
        if event_name == "session.deleted":
            return self._session_deleted(payload)
        if event_name == "tool.execute.before":
            return self._tool_before(payload)
        if event_name == "tool.execute.after":
            return self._tool_after(payload)
        if event_name == "system.transform":
            return self._system_transform(payload)
        raise BridgeError(422, f"unsupported opencode plugin event {event_name!r}")


def adapt_opencode(event_name: str, payload: dict) -> AdapterResult:
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
        return OpenCodeAdapter(store, ingress).adapt(event_name, payload)
    finally:
        store.close()
