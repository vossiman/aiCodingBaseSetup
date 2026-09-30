import json
import os
import re
import tempfile
import unittest
from datetime import UTC, datetime, timedelta
from pathlib import Path
from unittest import mock

from lib.kanban_work.adapters import (
    UNSETTLED_STOP,
    ClaudeCodexAdapter,
    CursorAdapter,
    OpenCodeAdapter,
    _client_version,
    _hook_instructions,
)
from lib.kanban_work.events import EventIngestor
from lib.kanban_work.queue import LifecycleQueue
from lib.kanban_work.legacy import DENIAL
from lib.kanban_work.schema import BridgeError
from lib.kanban_work.store import Store


NOW = datetime(2026, 9, 12, 12, tzinfo=UTC)


class Clock:
    def __init__(self):
        self.value = NOW

    def __call__(self):
        return self.value

    def advance(self, **parts):
        self.value += timedelta(**parts)


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.state = self.root / "state" / "kanban-work.sqlite3"
        self.env = mock.patch.dict(os.environ, {
            "KANBAN_URL": "http://127.0.0.1:8765",
            "KANBAN_TEST_TOKEN": "fixture-only-token",
            "AICODINGSETUP_SKIP_NETWORK": "1",
        }, clear=False)
        self.env.start()
        self.clock = Clock()
        self.store = Store(self.state, now=self.clock)
        self.queue = LifecycleQueue(self.store, now=self.clock)
        self.ingress = EventIngestor(
            self.store, self.queue, now=self.clock, synchronous=False,
            derive_repo=lambda checkout: None,
        )
        self.versions = {"claude": "2.1.268", "codex": "0.154.0"}
        self.adapter = ClaudeCodexAdapter(
            self.store,
            self.ingress,
            now=self.clock,
            version_provider=lambda harness: self.versions[harness],
            instructions_provider=lambda harness: "Kanban workflow",
        )

    def tearDown(self):
        self.store.close()
        self.env.stop()
        self.temp.cleanup()

    @staticmethod
    def start_payload(session="native-a", source="startup", **extra):
        return {
            "session_id": session,
            "hook_event_name": "SessionStart",
            "source": source,
            "cwd": "/tmp/repo",
            "transcript_path": f"/tmp/{session}.jsonl",
            **extra,
        }

    @staticmethod
    def prompt_payload(harness="claude", session="native-a", turn="turn-1", agent=None):
        payload = {
            "session_id": session,
            "hook_event_name": "UserPromptSubmit",
            "prompt": "work",
            "cwd": "/tmp/repo",
        }
        payload["turn_id" if harness == "codex" else "prompt_id"] = turn
        if agent:
            payload["agent_id"] = agent
        return payload

    @staticmethod
    def tool_payload(tool, args, *, harness="claude", session="native-a", turn="turn-1",
                     call="call-7", agent=None, event="PreToolUse"):
        payload = {
            "session_id": session,
            "hook_event_name": event,
            "tool_use_id": call,
            "tool_name": tool,
            "tool_input": args,
            "cwd": "/tmp/repo",
        }
        payload["turn_id" if harness == "codex" else "prompt_id"] = turn
        if agent:
            payload["agent_id"] = agent
        if event == "PostToolUse":
            payload["tool_response"] = {}
        if event == "PostToolUseFailure":
            payload.update(error="failed", is_interrupt=False, duration_ms=12)
        return payload

    @staticmethod
    def subagent_payload(harness, event, *, session="native-a", turn="turn-1",
                         agent="agent-1"):
        payload = {
            "session_id": session,
            "hook_event_name": event,
            "agent_id": agent,
            "agent_type": "Task",
            "cwd": "/tmp/repo",
        }
        payload["turn_id" if harness == "codex" else "prompt_id"] = turn
        if event == "SubagentStop":
            payload["stop_hook_active"] = False
        return payload

    def start(self, harness="claude", session="native-a", source="startup", **extra):
        result = self.adapter.adapt(
            harness, "SessionStart", self.start_payload(session, source, **extra)
        )
        self.assertEqual(
            result.output["hookSpecificOutput"]["hookEventName"], "SessionStart"
        )
        self.assertIn("Kanban workflow", result.output["hookSpecificOutput"]["additionalContext"])
        return result.lifecycle

    def prompt(self, harness="claude", session="native-a", turn="turn-1", agent=None):
        return self.adapter.adapt(
            harness, "UserPromptSubmit",
            self.prompt_payload(harness, session, turn, agent),
        )

    def pre(self, harness, tool, args, **parts):
        return self.adapter.adapt(
            harness, "PreToolUse",
            self.tool_payload(tool, args, harness=harness, **parts),
        )

    def test_claude_start_sources_mint_fresh_generations_but_compact_preserves_current(self):
        first = self.start("claude", source="startup")
        compact = self.start("claude", source="compact")
        self.assertEqual((compact["handle"], compact["run_generation"]),
                         (first["handle"], first["run_generation"]))

        generations = {first["run_generation"]}
        for source in ("resume", "clear"):
            current = self.start("claude", source=source)
            self.assertNotIn(current["run_generation"], generations)
            generations.add(current["run_generation"])

        forked = self.start("claude", session="native-fork", source="fork")
        self.assertNotIn(forked["run_generation"], generations)

    def test_codex_ordinary_calls_emit_no_permission_decision_and_track_activity(self):
        started = self.start("codex")
        self.prompt("codex")
        cases = [
            ("web.run", {"search_query": [{"q": "Codex hooks"}]}),
            ("Bash", {"command": "git status --short"}),
            ("mcp__kanban__list_tickets", {}),
        ]
        for index, (tool, args) in enumerate(cases):
            with self.subTest(tool=tool):
                result = self.pre("codex", tool, args, call=f"ordinary-{index}")
                self.assertEqual(result.output, {})
                self.assertTrue(
                    self.store.tool_operation(started["handle"], f"ordinary-{index}")["active"]
                )

    def test_codex_supports_only_its_pinned_event_set(self):
        self.start("codex")
        with self.assertRaisesRegex(BridgeError, "unsupported codex hook event"):
            self.adapter.adapt(
                "codex", "PostToolUseFailure",
                self.tool_payload("Bash", {"command": "false"}, harness="codex",
                                  event="PostToolUseFailure"),
            )

    def test_version_probe_is_bounded_closed_stdin_and_credential_free(self):
        completed = mock.Mock(returncode=0, stdout="codex-cli 0.154.0\n")
        with mock.patch("lib.kanban_work.adapters.subprocess.run", return_value=completed) as run:
            self.assertEqual(_client_version("codex"), "0.154.0")
        args, kwargs = run.call_args
        self.assertEqual(args[0], ["codex", "--version"])
        self.assertIs(kwargs["stdin"], __import__("subprocess").DEVNULL)
        self.assertEqual(kwargs["timeout"], 2)
        self.assertFalse(kwargs["shell"])
        self.assertNotIn("KANBAN_TEST_TOKEN", kwargs["env"])
        self.assertNotIn("KANBAN_TOKEN", kwargs["env"])

    def test_start_context_is_handle_only_when_provider_has_no_instructions(self):
        adapter = ClaudeCodexAdapter(
            self.store, self.ingress, now=self.clock,
            version_provider=lambda harness: self.versions[harness],
            instructions_provider=lambda harness: None,
        )
        result = adapter.adapt("claude", "SessionStart", self.start_payload())
        self.assertEqual(
            result.output["hookSpecificOutput"]["additionalContext"],
            f"Kanban work handle: {result.lifecycle['handle']}",
        )

    def test_start_context_appends_handle_after_provider_instructions(self):
        seen = []

        def provider(harness):
            seen.append(harness)
            return "Kanban workflow\n"

        adapter = ClaudeCodexAdapter(
            self.store, self.ingress, now=self.clock,
            version_provider=lambda harness: self.versions[harness],
            instructions_provider=provider,
        )
        result = adapter.adapt("codex", "SessionStart", self.start_payload())
        self.assertEqual(
            result.output["hookSpecificOutput"]["additionalContext"],
            f"Kanban workflow\n\nKanban work handle: {result.lifecycle['handle']}",
        )
        self.assertEqual(seen, ["codex"])

    def test_default_instructions_provider_returns_nothing_for_claude(self):
        with mock.patch("lib.kanban_work.adapters.fetch_instructions") as fetch:
            self.assertIsNone(_hook_instructions("claude"))
        fetch.assert_not_called()

    def test_claim_is_denied_while_an_earlier_stop_cannot_be_settled(self):
        for harness in ("claude", "codex"):
            with self.subTest(harness=harness):
                started = self.start(harness)
                self.prompt(harness)
                with mock.patch.object(
                    self.ingress, "settle_turn", return_value=False
                ) as settle:
                    denied = self.pre(
                        harness, "mcp__kanban__claim_ticket", {"ticket": "KANBAN-2"},
                        call="claim-denied",
                    )
                output = denied.output["hookSpecificOutput"]
                self.assertEqual(output["permissionDecision"], "deny")
                self.assertEqual(output["permissionDecisionReason"], UNSETTLED_STOP)
                settle.assert_called_once_with(started["handle"])
                self.assertIsNone(self.store.tool_operation(started["handle"], "claim-denied"))

                with mock.patch.object(
                    self.ingress, "settle_turn", return_value=True
                ) as settle:
                    allowed = self.pre(
                        harness, "mcp__kanban__claim_ticket", {"ticket": "KANBAN-2"},
                        call="claim-allowed",
                    )
                if harness == "codex":
                    self.assertEqual(allowed.output, {})
                else:
                    output = allowed.output["hookSpecificOutput"]
                    self.assertEqual(output["permissionDecision"], "allow")
                    self.assertNotIn("updatedInput", output)
                settle.assert_called_once_with(started["handle"])
                self.assertTrue(
                    self.store.tool_operation(started["handle"], "claim-allowed")["active"]
                )

    def test_other_kanban_tools_are_allowed_without_inspecting_arguments(self):
        started = self.start("codex")
        self.prompt("codex")
        cases = [
            ("mcp__kanban__complete_ticket", {"handle": "not-a-uuid", "evidence": ""}),
            ("mcp__kanban__release_ticket", "not-an-object"),
            ("mcp__kanban__bind_work_session", {"unexpected": ["field"]}),
            ("mcp__kanban__list_tickets", {}),
        ]
        with mock.patch.object(self.ingress, "settle_turn", return_value=False) as settle:
            for index, (tool, args) in enumerate(cases):
                with self.subTest(tool=tool):
                    result = self.pre("codex", tool, args, call=f"other-{index}")
                    self.assertEqual(result.output, {})
                    self.assertTrue(
                        self.store.tool_operation(started["handle"], f"other-{index}")["active"]
                    )
        settle.assert_not_called()

    def test_uncorrelatable_tool_calls_are_allowed(self):
        self.start("codex")
        self.prompt("codex")
        base = self.tool_payload(
            "mcp__kanban__claim_ticket", {"ticket": "KANBAN-2"}, harness="codex",
        )
        cases = [
            {key: value for key, value in base.items() if key != "session_id"},
            {key: value for key, value in base.items() if key != "tool_use_id"},
            {**base, "turn_id": "never-submitted"},
        ]
        with mock.patch.object(self.ingress, "settle_turn", return_value=False) as settle:
            for payload in cases:
                result = self.adapter.adapt("codex", "PreToolUse", payload)
                self.assertEqual(result.output, {})
                self.assertIsNone(result.lifecycle)
        settle.assert_not_called()
        shell = self.tool_payload("Bash", {"command": ["not", "text"]}, harness="codex")
        result = self.adapter.adapt("codex", "PreToolUse", shell)
        self.assertEqual(result.output, {})

    def test_user_prompt_submit_settles_the_previous_turn_for_its_execution(self):
        for harness in ("claude", "codex"):
            with self.subTest(harness=harness):
                started = self.start(harness)
                self.prompt(harness, turn="turn-1")
                self.adapter.adapt(harness, "Stop", {
                    **self.prompt_payload(harness, turn="turn-1"),
                    "hook_event_name": "Stop",
                })
                self.assertEqual(len(self.store.unsettled_stops(started["handle"])), 1)
                with mock.patch.object(
                    self.ingress, "settle_turn", wraps=self.ingress.settle_turn
                ) as settle:
                    self.prompt(harness, turn="turn-2")
                settle.assert_called_once_with(started["handle"])
                self.assertEqual(self.store.unsettled_stops(started["handle"]), [])

    def test_read_and_unrelated_tools_allow_without_prompt_correlation(self):
        self.start("codex")
        read = self.pre("codex", "mcp__kanban__list_tickets", {})
        unrelated = self.pre("codex", "Bash", {"command": "git status --short"})
        self.assertEqual(read.output, {})
        self.assertEqual(unrelated.output, {})

    def test_delayed_post_after_resume_closes_only_captured_old_generation(self):
        old = self.start("codex")
        self.prompt("codex", turn="turn-old")
        self.pre("codex", "Bash", {"command": "sleep 1"}, turn="turn-old", call="long-1")
        self.assertTrue(self.store.tool_operation(old["handle"], "long-1")["active"])

        current = self.start("codex", source="resume")
        post = self.tool_payload(
            "Bash", {"command": "sleep 1"}, turn="turn-old", call="long-1",
            event="PostToolUse", harness="codex",
        )
        result = self.adapter.adapt("codex", "PostToolUse", post)
        self.assertEqual(result.lifecycle["handle"], old["handle"])
        self.assertNotEqual(result.lifecycle["handle"], current["handle"])
        self.assertIsNone(self.store.tool_operation(current["handle"], "long-1"))

    def test_long_codex_tool_stays_open_until_original_post_then_stop_releases(self):
        started = self.start("codex")
        self.prompt("codex")
        self.pre("codex", "Bash", {"command": "long command"}, call="unified-1")
        stop = {**self.prompt_payload("codex"), "hook_event_name": "Stop",
                "stop_hook_active": False, "last_assistant_message": "waiting"}
        held = self.adapter.adapt("codex", "Stop", stop)
        self.assertEqual(held.lifecycle["status"], "deferred_active_work")
        self.assertTrue(self.store.tool_operation(started["handle"], "unified-1")["active"])

        self.adapter.adapt("codex", "PostToolUse", self.tool_payload(
            "Bash", {"command": "long command"}, harness="codex",
            call="unified-1", event="PostToolUse"
        ))
        self.assertFalse(self.store.tool_operation(started["handle"], "unified-1")["active"])
        released = self.adapter.adapt("codex", "Stop", {**stop, "last_assistant_message": "done"})
        self.assertEqual(released.lifecycle["status"], "observed")

    def test_claude_background_tasks_and_crons_suppress_parent_stop(self):
        started = self.start("claude")
        self.prompt()
        for index, extra in enumerate((
            {"background_tasks": [{"id": "bg-1"}]},
            {"session_crons": [{"id": "cron-1"}]},
        )):
            stop = {**self.prompt_payload(turn=f"turn-{index + 1}"),
                    "hook_event_name": "Stop", **extra}
            self.prompt(turn=f"turn-{index + 1}")
            result = self.adapter.adapt("claude", "Stop", stop)
            self.assertEqual(result.lifecycle["status"], "deferred_active_work")
        self.assertNotIn("stop", [row.kind for row in self.queue.pending(started["handle"])])
        self.assertEqual(self.store.unsettled_stops(started["handle"]), [])

    def test_child_stop_ends_child_without_releasing_parent(self):
        parent = self.start("claude")
        self.prompt(turn="child-turn")
        child_result = self.adapter.adapt(
            "claude", "SubagentStart",
            self.subagent_payload("claude", "SubagentStart", turn="child-turn"),
        )
        self.assertIn("Kanban workflow", child_result.output[
            "hookSpecificOutput"]["additionalContext"])
        child_start = child_result.lifecycle
        child = child_start["handle"]
        self.assertEqual(
            child_result.output["hookSpecificOutput"]["additionalContext"],
            f"Kanban workflow\n\nKanban work handle: {child}",
        )
        self.assertNotEqual(child, parent["handle"])

        result = self.adapter.adapt(
            "claude", "SubagentStop",
            self.subagent_payload("claude", "SubagentStop", turn="child-turn"),
        )
        self.assertEqual(result.lifecycle["handle"], child)
        self.assertEqual(self.store.get_execution(child).state, "ended")
        self.assertNotEqual(self.store.get_execution(parent["handle"]).state, "ended")

    def test_same_child_id_after_parent_resume_gets_a_fresh_child_generation(self):
        self.start("claude")
        self.prompt(turn="old-turn")
        first = self.adapter.adapt(
            "claude", "SubagentStart",
            self.subagent_payload("claude", "SubagentStart", turn="old-turn"),
        ).lifecycle
        self.start("claude", source="resume")
        self.prompt(turn="new-turn")
        second = self.adapter.adapt(
            "claude", "SubagentStart",
            self.subagent_payload("claude", "SubagentStart", turn="new-turn"),
        ).lifecycle
        self.assertNotEqual(first["handle"], second["handle"])
        self.assertNotEqual(first["run_generation"], second["run_generation"])

    def test_parent_stop_waits_for_live_child(self):
        self.start("claude")
        self.prompt()
        self.adapter.adapt(
            "claude", "SubagentStart",
            self.subagent_payload("claude", "SubagentStart"),
        )
        result = self.adapter.adapt("claude", "Stop", {
            **self.prompt_payload(), "hook_event_name": "Stop",
        })
        self.assertEqual(result.lifecycle["status"], "deferred_active_work")

    def test_codex_child_tools_correlate_with_child_turn_not_parent_turn(self):
        self.start("codex")
        self.prompt("codex", turn="parent-turn")
        child = self.adapter.adapt(
            "codex", "SubagentStart",
            self.subagent_payload("codex", "SubagentStart", turn="child-turn"),
        ).lifecycle
        read = self.pre(
            "codex", "mcp__kanban__list_tickets", {}, agent="agent-1", turn="child-turn",
        )
        with mock.patch.object(
            self.ingress, "settle_turn", wraps=self.ingress.settle_turn
        ) as settle:
            claim = self.pre(
                "codex", "mcp__kanban__claim_ticket", {"ticket": "KANBAN-2"},
                agent="agent-1", turn="child-turn", call="child-claim",
            )
        self.assertEqual(read.output, {})
        self.assertEqual(claim.output, {})
        settle.assert_called_once_with(child["handle"])
        self.assertTrue(self.store.tool_operation(child["handle"], "child-claim")["active"])

    def test_delayed_child_start_after_codex_resume_cannot_select_latest_parent(self):
        self.start("codex")
        self.prompt("codex", turn="parent-old")
        self.start("codex", source="resume")
        self.prompt("codex", turn="parent-new")
        with self.assertRaisesRegex(BridgeError, "cannot correlate SubagentStart"):
            self.adapter.adapt(
                "codex", "SubagentStart",
                self.subagent_payload("codex", "SubagentStart", turn="child-old",
                                      agent="delayed-child"),
            )
        self.assertEqual(
            self.store.executions_for_native("codex", "native-a", "delayed-child"), []
        )

    def test_delayed_claude_child_stop_cannot_end_new_generation_child(self):
        self.start("claude")
        self.prompt(turn="old-turn")
        old = self.adapter.adapt(
            "claude", "SubagentStart",
            self.subagent_payload("claude", "SubagentStart", turn="old-turn"),
        ).lifecycle
        self.start("claude", source="resume")
        self.prompt(turn="new-turn")
        new = self.adapter.adapt(
            "claude", "SubagentStart",
            self.subagent_payload("claude", "SubagentStart", turn="new-turn"),
        ).lifecycle
        delayed = self.adapter.adapt(
            "claude", "SubagentStop",
            self.subagent_payload("claude", "SubagentStop", turn="old-turn"),
        )
        self.assertEqual(delayed.lifecycle["status"], "dropped_old_generation")
        self.assertEqual(self.store.get_execution(old["handle"]).state, "ended")
        self.assertNotEqual(self.store.get_execution(new["handle"]).state, "ended")

    def test_unambiguous_session_end_journals_children_before_parent(self):
        parent = self.start("claude", session="final-parent")
        self.prompt(session="final-parent", turn="final-turn")
        child = self.adapter.adapt(
            "claude", "SubagentStart",
            self.subagent_payload("claude", "SubagentStart", session="final-parent",
                                  turn="final-turn"),
        ).lifecycle
        self.adapter.adapt("claude", "SessionEnd", {
            "session_id": "final-parent", "hook_event_name": "SessionEnd",
            "reason": "completed", "cwd": "/tmp/repo",
            "transcript_path": "/tmp/final-parent.jsonl",
        })
        self.assertEqual(self.store.get_execution(child["handle"]).state, "ended")
        self.assertEqual(self.store.get_execution(parent["handle"]).state, "ended")
        self.assertEqual([row.kind for row in self.queue.pending(child["handle"])],
                         ["register", "end"])
        self.assertEqual([row.kind for row in self.queue.pending(parent["handle"])],
                         ["register", "end"])
        ends = [row.row_id for row in self.queue.pending() if row.kind == "end"]
        child_end = [row.row_id for row in self.queue.pending(child["handle"])
                     if row.kind == "end"]
        self.assertEqual(ends[0], child_end[0])
        self.assertEqual(
            self.store.active_child_executions("claude", "final-parent"), []
        )

    def test_legacy_completion_appends_work_handle_without_any_claim(self):
        started = self.start("claude")
        handle = started["handle"]
        self.prompt()
        command = "kanban-post --done KANBAN-2 --evidence 'tests pass' --reference PR-17"
        native_input = {
            "command": command,
            "description": "Complete the ticket",
            "timeout": 120000,
            "run_in_background": False,
        }
        result = self.pre("claude", "Bash", native_input, call="legacy-1")
        output = result.output["hookSpecificOutput"]
        self.assertEqual(output["permissionDecision"], "allow")
        self.assertEqual(output["updatedInput"], {
            **native_input,
            "command": f"kanban-post --done KANBAN-2 --evidence 'tests pass' --reference PR-17 --work-handle {handle}",
        })
        self.assertTrue(self.store.tool_operation(handle, "legacy-1")["active"])

        codex = self.start("codex")
        self.prompt("codex")
        result = self.pre("codex", "Bash", {
            "command": "kanban-post --done KANBAN-2 --evidence ok",
        }, call="legacy-codex")
        output = result.output["hookSpecificOutput"]
        self.assertEqual(output["permissionDecision"], "allow")
        self.assertEqual(output["updatedInput"], {
            "command": f"kanban-post --done KANBAN-2 --evidence ok --work-handle {codex['handle']}",
        })

    def test_completion_like_shell_rejects_unverified_harness_input_fields(self):
        self.start("codex")
        self.prompt("codex")
        command = "kanban-post --done KANBAN-2 --evidence ok"
        invalid = [
            {"command": command, "description": "not in Codex 0.154.0 PreToolUse"},
            {"command": command, "unknown": True},
        ]
        for index, tool_input in enumerate(invalid):
            with self.subTest(tool_input=tool_input):
                result = self.pre("codex", "Bash", tool_input, call=f"schema-{index}")
                self.assertEqual(
                    result.output["hookSpecificOutput"]["permissionDecision"], "deny"
                )
                self.assertIn("Use the Kanban MCP complete_ticket tool",
                              result.output["hookSpecificOutput"]["permissionDecisionReason"])

    def test_claude_completion_rejects_null_timeout_in_replacement_input(self):
        self.start("claude")
        self.prompt("claude")
        result = self.pre("claude", "Bash", {
            "command": "kanban-post --done KANBAN-2 --evidence ok",
            "timeout": None,
        }, call="null-timeout")
        self.assertEqual(result.output["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertIn("Use the Kanban MCP complete_ticket tool",
                      result.output["hookSpecificOutput"]["permissionDecisionReason"])

    def test_unsafe_completion_variants_are_denied_and_ordinary_shell_allowed(self):
        started = self.start("codex")
        self.prompt("codex")
        commands = [
            "KANBAN_WORK_HANDLE=x kanban-post --done KANBAN-2 --evidence ok",
            "kanban-post --done KANBAN-2 --evidence $HOME",
            "kanban-post --done KANBAN-2 --evidence ok; echo bad",
            "kanban-post --done KANBAN-2 --evidence ok --unknown flag",
            "kanban-post --done KANBAN-2 --evidence ok --work-handle x",
        ]
        for index, command in enumerate(commands):
            with self.subTest(command=command):
                result = self.pre("codex", "Bash", {"command": command}, call=f"unsafe-{index}")
                output = result.output["hookSpecificOutput"]
                self.assertEqual(output["permissionDecision"], "deny")
                self.assertEqual(output["permissionDecisionReason"], DENIAL)
                self.assertIsNone(self.store.tool_operation(started["handle"], f"unsafe-{index}"))
        ordinary = self.pre("codex", "Bash", {"command": "git status --short"}, call="ordinary")
        self.assertEqual(ordinary.output, {})
        self.assertTrue(self.store.tool_operation(started["handle"], "ordinary")["active"])

    def test_codex_leaves_ordinary_legacy_commands_available(self):
        self.start("codex")
        commands = [
            'kanban-post "follow-up" --repo aiCodingBaseSetup',
            "kanban-post --comment AICODINGBASESETUP-2 progress",
            "kanban-post --list-tickets",
            "kanban-post --selftest",
        ]
        for index, command in enumerate(commands):
            with self.subTest(command=command):
                result = self.pre(
                    "codex", "Bash", {"command": command}, call=f"ordinary-{index}"
                )
                self.assertEqual(result.output, {})

    def test_session_end_without_generation_correlation_fails_closed_after_resume(self):
        self.start("claude")
        self.start("claude", source="resume")
        with self.assertRaisesRegex(BridgeError, "cannot correlate SessionEnd"):
            self.adapter.adapt("claude", "SessionEnd", {
                "session_id": "native-a", "hook_event_name": "SessionEnd",
                "reason": "completed", "cwd": "/tmp/repo",
            })

    def test_session_end_reconciles_a_single_unambiguous_generation(self):
        started = self.start("claude", session="single")
        result = self.adapter.adapt("claude", "SessionEnd", {
            "session_id": "single", "hook_event_name": "SessionEnd",
            "reason": "completed", "cwd": "/tmp/repo",
            "transcript_path": "/tmp/single.jsonl",
        })
        self.assertEqual(result.lifecycle["handle"], started["handle"])
        self.assertEqual(self.store.get_execution(started["handle"]).state, "ended")

    def test_hook_outputs_never_echo_prompt_or_tool_response_text(self):
        self.start("codex")
        prompt = self.prompt_payload("codex")
        prompt["prompt"] = "sensitive prompt fixture"
        result = self.adapter.adapt("codex", "UserPromptSubmit", prompt)
        self.assertNotIn("sensitive prompt fixture", json.dumps(result.output))


class CursorAdapterTests(unittest.TestCase):
    VERSION = "2026.09.10-fd3934a"

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.checkout = self.root / "checkout"
        self.checkout.mkdir()
        self.state = self.root / "state" / "kanban-work.sqlite3"
        self.env = mock.patch.dict(os.environ, {
            "KANBAN_URL": "http://127.0.0.1:8765",
            "KANBAN_TEST_TOKEN": "fixture-only-token",
            "AICODINGSETUP_SKIP_NETWORK": "1",
        }, clear=False)
        self.env.start()
        self.clock = Clock()
        self.store = Store(self.state, now=self.clock)
        self.queue = LifecycleQueue(self.store, now=self.clock)
        self.ingress = EventIngestor(
            self.store, self.queue, now=self.clock, synchronous=False,
            derive_repo=lambda checkout: None,
        )
        self.adapter = CursorAdapter(
            self.store, self.ingress, now=self.clock,
            instructions_provider=lambda harness: "Kanban workflow",
        )

    def tearDown(self):
        self.store.close()
        self.env.stop()
        self.temp.cleanup()

    def payload(self, event, *, conversation="conv-a", generation="gen-a", **extra):
        return {
            "conversation_id": conversation,
            "generation_id": generation,
            "cursor_version": self.VERSION,
            "hook_event_name": event,
            "workspace_roots": [str(self.checkout)],
            "cwd": str(self.checkout),
            **extra,
        }

    def start(self, **extra):
        fields = {
            "session_id": "conv-a", "is_background_agent": False,
            "composer_mode": "agent", **extra,
        }
        return self.adapter.adapt("sessionStart", self.payload("sessionStart", **fields))

    def prompt(self, generation="gen-a"):
        return self.adapter.adapt("beforeSubmitPrompt", self.payload(
            "beforeSubmitPrompt", generation=generation, prompt="fixture prompt",
            attachments=[],
        ))

    def pre(self, tool, tool_input, *, call="call-7", generation="gen-a"):
        return self.adapter.adapt("preToolUse", self.payload(
            "preToolUse", generation=generation, tool_use_id=call,
            tool_name=tool, tool_input=tool_input,
        ))

    def test_session_start_refuses_multi_root_and_returns_native_cursor_context(self):
        bad = self.payload(
            "sessionStart", session_id="conv-a", is_background_agent=False,
            workspace_roots=[str(self.checkout), "/tmp/other"],
        )
        with self.assertRaisesRegex(BridgeError, "exactly one workspace root"):
            self.adapter.adapt("sessionStart", bad)

        result = self.start()
        self.assertEqual(result.output["env"]["KANBAN_WORK_HANDLE"], result.lifecycle["handle"])
        self.assertEqual(
            result.output["additional_context"],
            f"Kanban workflow\n\nKanban work handle: {result.lifecycle['handle']}",
        )
        execution = self.store.get_execution(result.lifecycle["handle"])
        self.assertEqual(execution.native_session_id, "conv-a")
        self.assertTrue(execution.lifecycle_capable)

    def test_background_session_uses_conversation_as_its_own_native_identity(self):
        result = self.start(is_background_agent=True)
        execution = self.store.get_execution(result.lifecycle["handle"])
        self.assertEqual(execution.native_session_id, "conv-a")
        self.assertIsNone(execution.subagent_id)

    def test_generation_changes_order_prompts_without_retargeting_the_run(self):
        started = self.start().lifecycle
        self.prompt("gen-a")
        self.prompt("gen-b")
        self.assertEqual(
            self.store.current_execution("cursor", "conv-a", None).run_generation,
            started["run_generation"],
        )
        self.assertIsNotNone(self.store.native_event(
            "cursor", self.adapter._prompt_event_id("cursor", "conv-a", None, "gen-a")
        ))
        self.assertIsNotNone(self.store.native_event(
            "cursor", self.adapter._prompt_event_id("cursor", "conv-a", None, "gen-b")
        ))

    def test_claim_tool_is_denied_only_while_an_earlier_stop_is_unsettled(self):
        handle = self.start().lifecycle["handle"]
        self.prompt()
        with mock.patch.object(self.ingress, "settle_turn", return_value=False) as settle:
            denied = self.pre("MCP:claim_ticket", {"ticket": "KANBAN-2"}, call="claim-0")
        self.assertEqual(denied.output, {
            "permission": "deny", "agent_message": UNSETTLED_STOP,
            "user_message": UNSETTLED_STOP,
        })
        settle.assert_called_once_with(handle)
        self.assertIsNone(self.store.tool_operation(handle, "claim-0"))

        with mock.patch.object(self.ingress, "settle_turn", return_value=True) as settle:
            allowed = self.pre("MCP:claim_ticket", "not-an-object", call="claim-1")
        self.assertEqual(allowed.output, {"permission": "allow"})
        settle.assert_called_once_with(handle)
        self.assertTrue(self.store.tool_operation(handle, "claim-1")["active"])

    def test_generic_pre_tool_leaves_other_mcp_tools_available_without_settling(self):
        handle = self.start().lifecycle["handle"]
        self.prompt()
        cases = [
            ("MCP:github_search", {"query": "cursor hooks"}),
            ("MCP:complete_ticket", {"handle": "not-a-uuid"}),
            ("MCP:release_ticket", "not-an-object"),
        ]
        with mock.patch.object(self.ingress, "settle_turn", return_value=False) as settle:
            for index, (tool, args) in enumerate(cases):
                with self.subTest(tool=tool):
                    result = self.pre(tool, args, call=f"other-{index}")
                    self.assertEqual(result.output, {"permission": "allow"})
                    self.assertTrue(
                        self.store.tool_operation(handle, f"other-{index}")["active"]
                    )
        settle.assert_not_called()

    def test_before_submit_prompt_settles_the_previous_turn(self):
        handle = self.start().lifecycle["handle"]
        self.prompt("gen-a")
        self.adapter.adapt("stop", self.payload("stop", status="completed", loop_count=0))
        self.assertEqual(len(self.store.unsettled_stops(handle)), 1)
        with mock.patch.object(
            self.ingress, "settle_turn", wraps=self.ingress.settle_turn
        ) as settle:
            self.prompt("gen-b")
        settle.assert_called_once_with(handle)
        self.assertEqual(self.store.unsettled_stops(handle), [])

    def test_matching_generic_post_success_and_failure_close_original_calls(self):
        handle = self.start().lifecycle["handle"]
        self.prompt()
        for event, call, extra in (
            ("postToolUse", "ok-call", {"tool_output": "{}", "duration": 2}),
            ("postToolUseFailure", "bad-call", {
                "error_message": "failed", "failure_type": "error",
                "duration": 3, "is_interrupt": False,
            }),
        ):
            self.pre("Read", {"path": "README.md"}, call=call)
            result = self.adapter.adapt(event, self.payload(
                event, tool_use_id=call, tool_name="Read",
                tool_input={"path": "README.md"}, **extra,
            ))
            self.assertEqual(result.output, {})
            self.assertFalse(self.store.tool_operation(handle, call)["active"])

    def test_delayed_post_uses_journaled_generation_and_never_latest(self):
        old = self.start().lifecycle
        self.prompt("gen-old")
        self.pre("Read", {"path": "README.md"}, call="delayed", generation="gen-old")
        self.adapter._record(
            "cursor", "end", self.store.get_execution(old["handle"]), "end-old"
        )
        self.adapter.adapt("sessionStart", self.payload(
            "sessionStart", conversation="conv-a", generation="gen-new",
            session_id="conv-a", is_background_agent=False,
            transcript_path="/tmp/new-transcript",
        ))
        result = self.adapter.adapt("postToolUse", self.payload(
            "postToolUse", generation="gen-old", tool_use_id="delayed",
            tool_name="Read", tool_input={"path": "README.md"},
            tool_output="{}", duration=1,
        ))
        self.assertEqual(result.lifecycle["handle"], old["handle"])

    def test_precompact_records_activity_while_stop_releases_when_idle(self):
        handle = self.start().lifecycle["handle"]
        self.prompt()
        compact = self.adapter.adapt("preCompact", self.payload(
            "preCompact", trigger="auto", context_usage_percent=85,
        ))
        self.assertEqual(compact.lifecycle["handle"], handle)
        self.assertNotEqual(self.store.get_execution(handle).state, "ended")
        stopped = self.adapter.adapt("stop", self.payload(
            "stop", status="completed", loop_count=0,
        ))
        self.assertEqual(stopped.lifecycle["handle"], handle)

    def test_subagent_stop_without_id_neither_invents_child_nor_releases_parent(self):
        parent = self.start().lifecycle
        self.prompt()
        child = self.adapter.adapt("subagentStart", self.payload(
            "subagentStart", subagent_id="child-1", subagent_type="generalPurpose",
            task="inspect", parent_conversation_id="conv-a", tool_call_id="task-1",
            subagent_model="fixture", is_parallel_worker=False,
        )).lifecycle
        result = self.adapter.adapt("subagentStop", self.payload(
            "subagentStop", subagent_type="generalPurpose", status="completed",
            task="inspect", description="inspect", summary="done", duration_ms=1,
            message_count=1, tool_call_count=0, loop_count=0, modified_files=[],
            agent_transcript_path=None,
        ))
        self.assertEqual(result.lifecycle["status"], "unsupported_child_correlation")
        self.assertNotEqual(self.store.get_execution(child["handle"]).state, "ended")
        self.assertNotEqual(self.store.get_execution(parent["handle"]).state, "ended")
        stopped = self.adapter.adapt("stop", self.payload(
            "stop", status="completed", loop_count=0,
        ))
        self.assertEqual(stopped.lifecycle["status"], "deferred_active_work")

    def test_session_end_is_fire_and_forget_and_ends_children_before_parent(self):
        parent = self.start().lifecycle
        self.prompt()
        child = self.adapter.adapt("subagentStart", self.payload(
            "subagentStart", subagent_id="child-end", subagent_type="generalPurpose",
            task="inspect", parent_conversation_id="conv-a", tool_call_id="task-end",
            subagent_model="fixture", is_parallel_worker=False,
        )).lifecycle
        result = self.adapter.adapt("sessionEnd", self.payload(
            "sessionEnd", session_id="conv-a", reason="completed", duration_ms=1,
            is_background_agent=False, final_status="completed",
        ))
        self.assertEqual(result.output, {})
        self.assertEqual(self.store.get_execution(child["handle"]).state, "ended")
        self.assertEqual(self.store.get_execution(parent["handle"]).state, "ended")

    def test_session_end_selects_new_generation_after_retained_old_generation(self):
        old = self.start().lifecycle
        self.prompt("gen-a")
        self.adapter._record(
            "cursor", "end", self.store.get_execution(old["handle"]), "end-old"
        )
        new = self.adapter.adapt("sessionStart", self.payload(
            "sessionStart", generation="gen-new", session_id="conv-a",
            is_background_agent=False, composer_mode="agent",
            transcript_path="/tmp/new-generation",
        )).lifecycle
        self.prompt("gen-new")
        child = self.adapter.adapt("subagentStart", self.payload(
            "subagentStart", generation="gen-new", subagent_id="child-new",
            subagent_type="generalPurpose", task="inspect",
            parent_conversation_id="conv-a", tool_call_id="task-new",
            subagent_model="fixture", is_parallel_worker=False,
        )).lifecycle

        result = self.adapter.adapt("sessionEnd", self.payload(
            "sessionEnd", generation="gen-new", session_id="conv-a",
            reason="completed", duration_ms=1, is_background_agent=False,
            final_status="completed",
        ))
        self.assertEqual(result.lifecycle["handle"], new["handle"])
        self.assertEqual(self.store.get_execution(child["handle"]).state, "ended")
        self.assertEqual(self.store.get_execution(new["handle"]).state, "ended")

    def test_late_old_session_end_cannot_retarget_new_generation(self):
        old = self.start().lifecycle
        self.prompt("gen-a")
        old_child = self.adapter.adapt("subagentStart", self.payload(
            "subagentStart", generation="gen-a", subagent_id="child-old",
            subagent_type="generalPurpose", task="old work",
            parent_conversation_id="conv-a", tool_call_id="task-old",
            subagent_model="fixture", is_parallel_worker=False,
        )).lifecycle
        self.adapter._record(
            "cursor", "end", self.store.get_execution(old["handle"]), "end-old"
        )
        new = self.adapter.adapt("sessionStart", self.payload(
            "sessionStart", generation="gen-new", session_id="conv-a",
            is_background_agent=False, composer_mode="agent",
            transcript_path="/tmp/new-generation",
        )).lifecycle
        self.prompt("gen-new")
        new_child = self.adapter.adapt("subagentStart", self.payload(
            "subagentStart", generation="gen-new", subagent_id="child-new",
            subagent_type="generalPurpose", task="new work",
            parent_conversation_id="conv-a", tool_call_id="task-new",
            subagent_model="fixture", is_parallel_worker=False,
        )).lifecycle

        result = self.adapter.adapt("sessionEnd", self.payload(
            "sessionEnd", generation="gen-a", session_id="conv-a",
            reason="completed", duration_ms=1, is_background_agent=False,
            final_status="completed",
        ))
        self.assertEqual(result.lifecycle["status"], "dropped_old_generation")
        self.assertEqual(result.lifecycle["handle"], old["handle"])
        self.assertEqual(self.store.get_execution(old_child["handle"]).state, "ended")
        self.assertNotEqual(self.store.get_execution(new_child["handle"]).state, "ended")
        self.assertNotEqual(self.store.get_execution(new["handle"]).state, "ended")

    def test_cursor_legacy_completion_rewrites_only_native_shell_input(self):
        handle = self.start().lifecycle["handle"]
        self.prompt()
        command = "kanban-post --done KANBAN-2 --evidence 'tests pass'"
        native = {"command": command, "working_directory": str(self.checkout)}
        result = self.pre("Shell", native, call="legacy")
        self.assertEqual(result.output["permission"], "allow")
        self.assertEqual(result.output["updated_input"], {
            **native,
            "command": f"kanban-post --done KANBAN-2 --evidence 'tests pass' --work-handle {handle}",
        })
        for index, bad in enumerate((
            "KANBAN_WORK_HANDLE=x kanban-post --done KANBAN-2 --evidence ok",
            "kanban-post --done KANBAN-2 --evidence ok; echo bad",
        )):
            denied = self.pre("Shell", {"command": bad}, call=f"bad-{index}")
            self.assertEqual(denied.output["permission"], "deny")
            self.assertEqual(denied.output["agent_message"], DENIAL)
        unknown_field = self.pre("Shell", {"command": command, "sandbox": True}, call="bad-field")
        self.assertEqual(unknown_field.output["permission"], "deny")
        ordinary = self.pre("Shell", {"command": "git status --short"}, call="ordinary")
        self.assertEqual(ordinary.output, {"permission": "allow"})

    def test_cursor_leaves_ordinary_legacy_commands_available(self):
        self.start()
        commands = [
            'kanban-post "follow-up" --repo aiCodingBaseSetup',
            "kanban-post --comment AICODINGBASESETUP-2 progress",
            "kanban-post --list-tickets",
            "kanban-post --selftest",
        ]
        for index, command in enumerate(commands):
            with self.subTest(command=command):
                result = self.pre("Shell", {"command": command}, call=f"ordinary-{index}")
                self.assertEqual(result.output["permission"], "allow")


class OpenCodeAdapterTests(unittest.TestCase):
    VERSION = "1.18.30"
    INSTANCE = "plugin-instance-a"

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.checkout = self.root / "checkout"
        self.checkout.mkdir()
        self.state = self.root / "state" / "kanban-work.sqlite3"
        self.env = mock.patch.dict(os.environ, {
            "KANBAN_URL": "http://127.0.0.1:8765",
            "KANBAN_TEST_TOKEN": "fixture-only-token",
            "AICODINGSETUP_SKIP_NETWORK": "1",
        }, clear=False)
        self.env.start()
        self.clock = Clock()
        self.store = Store(self.state, now=self.clock)
        self.queue = LifecycleQueue(self.store, now=self.clock)
        self.ingress = EventIngestor(
            self.store, self.queue, now=self.clock, synchronous=False,
            derive_repo=lambda checkout: None,
        )
        self.adapter = OpenCodeAdapter(self.store, self.ingress, now=self.clock)

    def tearDown(self):
        self.store.close()
        self.env.stop()
        self.temp.cleanup()

    def info(self, session="ses-parent", *, parent=None):
        value = {
            "id": session,
            "slug": session,
            "projectID": "global",
            "directory": str(self.checkout),
            "title": session,
            "version": self.VERSION,
            "time": {"created": 1, "updated": 1},
        }
        if parent is not None:
            value["parentID"] = parent
        return value

    def created(self, session="ses-parent", *, parent=None, event="evt-created",
                instance=None):
        return self.adapter.adapt("session.created", {
            "eventID": event,
            "sessionID": session,
            "info": self.info(session, parent=parent),
            "instanceID": instance or self.INSTANCE,
            "clientVersion": self.VERSION,
            "directory": str(self.checkout),
        })

    def before(self, tool, args, *, session="ses-parent", call="call-7", instance=None):
        return self.adapter.adapt("tool.execute.before", {
            "tool": tool,
            "sessionID": session,
            "callID": call,
            "args": args,
            "instanceID": instance or self.INSTANCE,
            "clientVersion": self.VERSION,
            "directory": str(self.checkout),
        })

    def test_created_uses_process_version_and_native_parent_child_identity(self):
        parent = self.created().lifecycle
        child = self.created("ses-child", parent="ses-parent", event="evt-child").lifecycle
        parent_execution = self.store.get_execution(parent["handle"])
        child_execution = self.store.get_execution(child["handle"])
        self.assertEqual(parent_execution.native_session_id, "ses-parent")
        self.assertIsNone(parent_execution.subagent_id)
        self.assertTrue(parent_execution.lifecycle_capable)
        self.assertEqual(child_execution.native_session_id, "ses-parent")
        self.assertEqual(child_execution.subagent_id, "ses-child")
        self.assertTrue(child_execution.lifecycle_capable)

        unlisted = self.adapter.adapt("session.created", {
            "eventID": "evt-unlisted", "sessionID": "ses-unlisted",
            "info": self.info("ses-unlisted"), "clientVersion": "1.18.31",
            "instanceID": self.INSTANCE, "directory": str(self.checkout),
        })
        self.assertTrue(
            self.store.get_execution(unlisted.lifecycle["handle"]).lifecycle_capable
        )
        missing = self.adapter.adapt("session.created", {
            "eventID": "evt-missing-version", "sessionID": "ses-missing-version",
            "info": self.info("ses-missing-version"), "clientVersion": None,
            "instanceID": self.INSTANCE, "directory": str(self.checkout),
        })
        self.assertTrue(
            self.store.get_execution(missing.lifecycle["handle"]).lifecycle_capable
        )

    def test_compaction_preserves_generation_and_parent_idle_defers_for_child(self):
        parent = self.created().lifecycle
        child = self.created("ses-child", parent="ses-parent", event="evt-child").lifecycle
        compacted = self.adapter.adapt("session.compacted", {
            "eventID": "evt-compact", "sessionID": "ses-parent",
            "instanceID": self.INSTANCE, "clientVersion": self.VERSION,
            "directory": str(self.checkout),
        })
        self.assertEqual(compacted.lifecycle["run_generation"], parent["run_generation"])
        idle = self.adapter.adapt("session.idle", {
            "eventID": "evt-idle", "sessionID": "ses-parent",
            "instanceID": self.INSTANCE, "clientVersion": self.VERSION,
            "directory": str(self.checkout),
        })
        self.assertEqual(idle.lifecycle["status"], "deferred_active_work")
        self.assertNotEqual(self.store.get_execution(parent["handle"]).state, "ended")
        self.assertNotEqual(self.store.get_execution(child["handle"]).state, "ended")

    def test_claim_tool_is_denied_only_while_an_earlier_stop_is_unsettled(self):
        handle = self.created().lifecycle["handle"]
        with mock.patch.object(self.ingress, "settle_turn", return_value=False) as settle:
            with self.assertRaisesRegex(BridgeError, re.escape(UNSETTLED_STOP)):
                self.before("kanban_claim_ticket", {"ticket": "KANBAN-2"}, call="claim-0")
        settle.assert_called_once_with(handle)
        self.assertIsNone(self.store.tool_operation(handle, "claim-0"))

        with mock.patch.object(self.ingress, "settle_turn", return_value=True) as settle:
            allowed = self.before("kanban_claim_ticket", {"ticket": "KANBAN-2"}, call="claim-1")
        self.assertEqual(allowed.output, {})
        settle.assert_called_once_with(handle)
        self.assertTrue(self.store.tool_operation(handle, "claim-1")["active"])

    def test_other_kanban_and_unrelated_tools_are_allowed_without_settling(self):
        handle = self.created().lifecycle["handle"]
        cases = [
            ("kanban_complete_ticket", {"handle": "not-a-uuid"}),
            ("kanban_release_ticket", None),
            ("kanban_github_search", {"query": "OpenCode hooks"}),
        ]
        with mock.patch.object(self.ingress, "settle_turn", return_value=False) as settle:
            for index, (tool, args) in enumerate(cases):
                with self.subTest(tool=tool):
                    result = self.before(tool, args, call=f"other-{index}")
                    self.assertEqual(result.output, {})
                    self.assertTrue(
                        self.store.tool_operation(handle, f"other-{index}")["active"]
                    )
        settle.assert_not_called()

    def test_uncorrelatable_calls_are_allowed_and_reads_remain_available(self):
        self.created()
        with mock.patch.object(self.ingress, "settle_turn", return_value=False) as settle:
            claim = self.adapter.adapt("tool.execute.before", {
                "tool": "kanban_claim_ticket", "args": {"ticket": "KANBAN-2"},
                "instanceID": self.INSTANCE, "clientVersion": self.VERSION,
                "directory": str(self.checkout),
            })
            read = self.adapter.adapt("tool.execute.before", {
                "tool": "kanban_list_tickets", "args": {},
                "instanceID": self.INSTANCE, "clientVersion": self.VERSION,
                "directory": str(self.checkout),
            })
        self.assertEqual(claim.output, {})
        self.assertIsNone(claim.lifecycle)
        self.assertEqual(read.output, {})
        settle.assert_not_called()

    def test_success_after_closes_only_its_journaled_original_call(self):
        parent = self.created().lifecycle
        self.before("read", {"filePath": "README.md"}, call="call-ok")
        result = self.adapter.adapt("tool.execute.after", {
            "tool": "read", "sessionID": "ses-parent", "callID": "call-ok",
            "instanceID": self.INSTANCE,
        })
        self.assertEqual(result.lifecycle["handle"], parent["handle"])
        self.assertFalse(self.store.tool_operation(parent["handle"], "call-ok")["active"])
        with self.assertRaisesRegex(BridgeError, "cannot correlate"):
            self.adapter.adapt("tool.execute.after", {
                "tool": "bash", "sessionID": "ses-parent", "callID": "call-ok",
                "instanceID": self.INSTANCE,
            })

    def test_failed_tool_without_after_remains_active_and_idle_does_not_invent_failure(self):
        parent = self.created().lifecycle
        self.before("read", {"filePath": "missing"}, call="failed-call")
        idle = self.adapter.adapt("session.idle", {
            "eventID": "evt-idle-failed", "sessionID": "ses-parent",
            "instanceID": self.INSTANCE, "clientVersion": self.VERSION,
            "directory": str(self.checkout),
        })
        self.assertEqual(idle.lifecycle["status"], "deferred_active_work")
        self.assertTrue(self.store.tool_operation(parent["handle"], "failed-call")["active"])
        missing = self.adapter.adapt("session.error", {
            "eventID": "evt-error", "error": {
                "name": "UnknownError", "data": {"message": "boom"},
            }, "instanceID": self.INSTANCE, "clientVersion": self.VERSION,
            "directory": str(self.checkout),
        })
        self.assertEqual(missing.lifecycle["status"], "ignored_missing_identity")

    def test_first_observation_is_journaled_capable_and_kept_by_later_create(self):
        observed = self.adapter.adapt("system.transform", {
            "sessionID": "ses-resumed", "clientVersion": self.VERSION,
            "instanceID": self.INSTANCE, "directory": str(self.checkout),
        })
        execution = self.store.get_execution(observed.lifecycle["handle"])
        self.assertTrue(execution.lifecycle_capable)
        claim = self.adapter.adapt("tool.execute.before", {
            "tool": "kanban_claim_ticket", "sessionID": "ses-resumed",
            "callID": "resumed-call", "args": {"ticket": "KANBAN-2"},
            "instanceID": self.INSTANCE, "clientVersion": self.VERSION,
            "directory": str(self.checkout),
        })
        self.assertEqual(claim.output, {})
        self.assertEqual(claim.lifecycle["handle"], execution.handle)
        later_created = self.created("ses-resumed", event="evt-created-late")
        self.assertEqual(later_created.lifecycle["handle"], execution.handle)
        self.assertTrue(self.store.get_execution(execution.handle).lifecycle_capable)

    def test_deleted_ends_exact_children_before_parent_without_latest_lookup(self):
        parent = self.created().lifecycle
        child = self.created("ses-child", parent="ses-parent", event="evt-child").lifecycle
        deleted = self.adapter.adapt("session.deleted", {
            "eventID": "evt-delete-parent", "sessionID": "ses-parent",
            "info": self.info(), "clientVersion": self.VERSION,
            "instanceID": self.INSTANCE, "directory": str(self.checkout),
        })
        self.assertEqual(deleted.lifecycle["handle"], parent["handle"])
        self.assertEqual(self.store.get_execution(child["handle"]).state, "ended")
        self.assertEqual(self.store.get_execution(parent["handle"]).state, "ended")

    def test_system_transform_returns_only_current_handle(self):
        started = self.created().lifecycle
        transformed = self.adapter.adapt("system.transform", {
            "sessionID": "ses-parent", "clientVersion": self.VERSION,
            "instanceID": self.INSTANCE, "directory": str(self.checkout),
        })
        self.assertEqual(transformed.output, {"handle": started["handle"]})

    def test_system_transform_settles_the_previous_turn(self):
        handle = self.created().lifecycle["handle"]
        self.adapter.adapt("session.idle", {
            "eventID": "evt-idle-settle", "sessionID": "ses-parent",
            "instanceID": self.INSTANCE, "clientVersion": self.VERSION,
            "directory": str(self.checkout),
        })
        self.assertEqual(len(self.store.unsettled_stops(handle)), 1)
        with mock.patch.object(
            self.ingress, "settle_turn", wraps=self.ingress.settle_turn
        ) as settle:
            self.adapter.adapt("system.transform", {
                "sessionID": "ses-parent", "clientVersion": self.VERSION,
                "instanceID": self.INSTANCE, "directory": str(self.checkout),
            })
        settle.assert_called_once_with(handle)
        self.assertEqual(self.store.unsettled_stops(handle), [])

    def test_legacy_completion_rewrites_only_safe_native_bash_command(self):
        handle = self.created().lifecycle["handle"]
        native = {"command": "kanban-post --done KANBAN-2 --evidence 'tests pass'"}
        prepared = self.before("bash", native, call="legacy")
        self.assertEqual(prepared.output["args"], {
            "command": (
                "kanban-post --done KANBAN-2 --evidence 'tests pass' "
                f"--work-handle {handle}"
            )
        })
        for index, command in enumerate((
            "KANBAN_WORK_HANDLE=x kanban-post --done KANBAN-2 --evidence ok",
            "kanban-post --done KANBAN-2 --evidence ok; echo bad",
        )):
            with self.assertRaisesRegex(BridgeError, "Kanban MCP complete_ticket"):
                self.before("bash", {"command": command}, call=f"bad-{index}")
        with self.assertRaisesRegex(BridgeError, "Kanban MCP complete_ticket"):
            self.adapter.adapt("tool.execute.before", {
                "tool": "bash", "args": native, "instanceID": self.INSTANCE,
                "clientVersion": self.VERSION, "directory": str(self.checkout),
            })
        ordinary = self.before("bash", {"command": "git status --short"}, call="ordinary")
        self.assertEqual(ordinary.output, {})

    def test_opencode_leaves_ordinary_legacy_commands_available(self):
        self.created()
        commands = [
            'kanban-post "follow-up" --repo aiCodingBaseSetup',
            "kanban-post --comment AICODINGBASESETUP-2 progress",
            "kanban-post --list-tickets",
            "kanban-post --selftest",
        ]
        for index, command in enumerate(commands):
            with self.subTest(command=command):
                result = self.before("bash", {"command": command}, call=f"ordinary-{index}")
                self.assertEqual(result.output, {})

    def test_new_plugin_instance_mints_fresh_generation_and_late_old_event_stays_old(self):
        old_instance = "plugin-instance-old"
        new_instance = "plugin-instance-new"
        old = self.created(instance=old_instance).lifecycle
        self.before("read", {"filePath": "old"}, call="old-call", instance=old_instance)

        self.store.close()
        self.store = Store(self.state, now=self.clock)
        self.queue = LifecycleQueue(self.store, now=self.clock)
        self.ingress = EventIngestor(
            self.store, self.queue, now=self.clock, synchronous=False,
            derive_repo=lambda checkout: None,
        )
        self.adapter = OpenCodeAdapter(self.store, self.ingress, now=self.clock)

        observed = self.adapter.adapt("system.transform", {
            "sessionID": "ses-parent", "instanceID": new_instance,
            "clientVersion": self.VERSION, "directory": str(self.checkout),
        })
        current = self.store.get_execution(observed.lifecycle["handle"])
        self.assertNotEqual(current.handle, old["handle"])
        self.assertNotEqual(current.run_generation, old["run_generation"])
        self.assertTrue(current.lifecycle_capable)

        new_tool = self.adapter.adapt("tool.execute.before", {
            "tool": "read", "sessionID": "ses-parent", "callID": "new-call",
            "args": {"filePath": "new"}, "instanceID": new_instance,
            "clientVersion": self.VERSION, "directory": str(self.checkout),
        })
        self.assertEqual(new_tool.lifecycle["handle"], current.handle)
        idle = self.adapter.adapt("session.idle", {
            "eventID": "evt-new-idle", "sessionID": "ses-parent",
            "instanceID": new_instance, "clientVersion": self.VERSION,
            "directory": str(self.checkout),
        })
        self.assertEqual(idle.lifecycle["status"], "deferred_active_work")

        late = self.adapter.adapt("tool.execute.after", {
            "tool": "read", "sessionID": "ses-parent", "callID": "old-call",
            "instanceID": old_instance,
        })
        self.assertEqual(late.lifecycle["handle"], old["handle"])
        self.assertFalse(self.store.tool_operation(old["handle"], "old-call")["active"])
        self.assertTrue(self.store.tool_operation(current.handle, "new-call")["active"])

        later_created = self.created(instance=new_instance, event="evt-created-new-instance")
        self.assertEqual(later_created.lifecycle["handle"], current.handle)
        self.assertTrue(self.store.get_execution(current.handle).lifecycle_capable)

    def test_tool_and_idle_each_mint_fresh_generation_when_first_seen_by_new_plugin_instance(self):
        old_instance = "plugin-instance-old"
        old_tool = self.created("ses-tool", event="evt-old-tool",
                                instance=old_instance).lifecycle
        old_idle = self.created("ses-idle", event="evt-old-idle",
                                instance=old_instance).lifecycle

        self.store.close()
        self.store = Store(self.state, now=self.clock)
        self.queue = LifecycleQueue(self.store, now=self.clock)
        self.ingress = EventIngestor(
            self.store, self.queue, now=self.clock, synchronous=False,
            derive_repo=lambda checkout: None,
        )
        self.adapter = OpenCodeAdapter(self.store, self.ingress, now=self.clock)

        tool = self.adapter.adapt("tool.execute.before", {
            "tool": "read", "sessionID": "ses-tool", "callID": "new-tool",
            "args": {"filePath": "README.md"}, "instanceID": "plugin-tool-new",
            "clientVersion": self.VERSION, "directory": str(self.checkout),
        })
        tool_execution = self.store.get_execution(tool.lifecycle["handle"])
        self.assertNotEqual(tool_execution.handle, old_tool["handle"])
        self.assertTrue(tool_execution.lifecycle_capable)

        idle = self.adapter.adapt("session.idle", {
            "eventID": "evt-first-idle", "sessionID": "ses-idle",
            "instanceID": "plugin-idle-new", "clientVersion": self.VERSION,
            "directory": str(self.checkout),
        })
        idle_execution = self.store.get_execution(idle.lifecycle["handle"])
        self.assertNotEqual(idle_execution.handle, old_idle["handle"])
        self.assertTrue(idle_execution.lifecycle_capable)


if __name__ == "__main__":
    unittest.main()
