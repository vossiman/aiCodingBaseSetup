import json
import os
import tempfile
import unittest
from datetime import UTC, datetime, timedelta
from pathlib import Path
from unittest import mock

from lib.kanban_work.adapters import ClaudeCodexAdapter, CursorAdapter, _client_version
from lib.kanban_work.events import EventIngestor
from lib.kanban_work.queue import LifecycleQueue
from lib.kanban_work.schema import BridgeError, normalize_tool_args
from lib.kanban_work.store import Store


NOW = datetime(2026, 9, 12, 12, tzinfo=UTC)
CLAIM = "22222222-2222-4222-8222-222222222222"


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
        self.matrix = self.root / "qualified.json"
        self.matrix.write_text(json.dumps({
            "clients": {
                "claude": {"versions": ["2.1.268"]},
                "codex": {"versions": ["0.154.0"]},
            }
        }))
        self.env = mock.patch.dict(os.environ, {
            "AICODING_KANBAN_QUALIFIED_CLIENTS": str(self.matrix),
            "KANBAN_URL": "http://127.0.0.1:8765",
            "KANBAN_TEST_TOKEN": "fixture-only-token",
            "AICODINGSETUP_SKIP_NETWORK": "1",
        }, clear=False)
        self.env.start()
        self.clock = Clock()
        self.store = Store(self.state)
        self.queue = LifecycleQueue(self.store, now=self.clock)
        self.ingress = EventIngestor(self.store, self.queue, now=self.clock)
        self.versions = {"claude": "2.1.268", "codex": "0.154.0"}
        self.adapter = ClaudeCodexAdapter(
            self.store,
            self.ingress,
            now=self.clock,
            version_provider=lambda harness: self.versions[harness],
            instructions_provider=lambda handle: f"Kanban workflow\nhandle={handle}",
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

    def test_exact_candidate_matrix_requires_loopback_and_fake_token(self):
        capable = self.start("claude", session="qualified")
        self.assertTrue(self.store.get_execution(capable["handle"]).lifecycle_capable)

        cases = [
            ({"KANBAN_URL": "https://kanban.dataprospectors.at"}, "remote"),
            ({"KANBAN_TEST_TOKEN": ""}, "no-token"),
        ]
        for changes, session in cases:
            with self.subTest(session=session), mock.patch.dict(os.environ, changes, clear=False):
                started = self.start("claude", session=session)
                self.assertFalse(self.store.get_execution(started["handle"]).lifecycle_capable)

        self.versions["claude"] = "2.1.269"
        mismatched = self.start("claude", session="mismatch")
        self.assertFalse(self.store.get_execution(mismatched["handle"]).lifecycle_capable)

    def test_two_sessions_same_checkout_and_peer_handle_never_authorize_each_other(self):
        first = self.start("claude", session="native-a")
        second = self.start("claude", session="native-b")
        self.prompt(session="native-a")
        denied = self.pre(
            "claude", "mcp__kanban__claim_ticket",
            {"handle": second["handle"], "ticket": "KANBAN-2"}, session="native-a",
        )
        output = denied.output["hookSpecificOutput"]
        self.assertEqual(output["permissionDecision"], "deny")
        self.assertIn("another native session", output["permissionDecisionReason"])
        self.assertFalse(self.store.has_any_permit())
        self.assertNotEqual(first["handle"], second["handle"])

    def test_mutating_mcp_pretool_mints_exact_once_permit_for_actual_caller(self):
        started = self.start("claude")
        self.prompt()
        args = {"handle": started["handle"], "ticket": "KANBAN-2"}
        allowed = self.pre("claude", "mcp__kanban__claim_ticket", args)
        self.assertEqual(
            allowed.output["hookSpecificOutput"]["permissionDecision"], "allow"
        )
        self.assertTrue(self.store.has_permit(
            started["handle"], "claim_ticket", normalize_tool_args("claim_ticket", args)
        ))

        replay = self.pre("claude", "mcp__kanban__claim_ticket", args)
        self.assertEqual(
            replay.output["hookSpecificOutput"]["permissionDecision"], "deny"
        )

    def test_permit_digest_change_is_rejected_by_bridge_boundary(self):
        started = self.start("codex")
        self.prompt("codex")
        args = {"handle": started["handle"], "ticket": "KANBAN-2"}
        self.pre("codex", "mcp__kanban__claim_ticket", args)
        with self.assertRaisesRegex(BridgeError, "digest does not match"):
            self.store.consume_permit(
                started["handle"], "claim_ticket",
                normalize_tool_args("claim_ticket", {**args, "ticket": "KANBAN-3"}),
                self.clock(),
            )

    def test_missing_native_session_call_or_object_input_denies_mutating_tool(self):
        started = self.start("codex")
        self.prompt("codex")
        base = self.tool_payload(
            "mcp__kanban__claim_ticket",
            {"handle": started["handle"], "ticket": "KANBAN-2"},
            harness="codex",
        )
        cases = [
            {key: value for key, value in base.items() if key != "session_id"},
            {key: value for key, value in base.items() if key != "tool_use_id"},
            {**base, "tool_input": "not-an-object"},
        ]
        for payload in cases:
            result = self.adapter.adapt("codex", "PreToolUse", payload)
            self.assertEqual(
                result.output["hookSpecificOutput"]["permissionDecision"], "deny"
            )
        shell = self.tool_payload("Bash", {"command": ["not", "text"]}, harness="codex")
        result = self.adapter.adapt("codex", "PreToolUse", shell)
        self.assertEqual(result.output["hookSpecificOutput"]["permissionDecision"], "allow")

    def test_read_and_unrelated_tools_allow_without_prompt_correlation(self):
        self.start("codex")
        read = self.pre("codex", "mcp__kanban__list_tickets", {})
        unrelated = self.pre("codex", "Bash", {"command": "git status --short"})
        self.assertEqual(read.output["hookSpecificOutput"]["permissionDecision"], "allow")
        self.assertEqual(unrelated.output["hookSpecificOutput"]["permissionDecision"], "allow")
        self.assertFalse(self.store.has_any_permit())

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
        self.assertEqual(self.queue.pending(started["handle"]), [])

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
        args = {"handle": child["handle"], "ticket": "KANBAN-2"}
        mutation = self.pre(
            "codex", "mcp__kanban__claim_ticket", args,
            agent="agent-1", turn="child-turn", call="child-claim",
        )
        self.assertEqual(read.output["hookSpecificOutput"]["permissionDecision"], "allow")
        self.assertEqual(mutation.output["hookSpecificOutput"]["permissionDecision"], "allow")
        self.assertTrue(self.store.has_permit(
            child["handle"], "claim_ticket", normalize_tool_args("claim_ticket", args)
        ))

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
        self.store.record_bound(parent["handle"], "backend-parent", "kanban", "parent")
        self.store.record_bound(child["handle"], "backend-child", "kanban", "child")
        self.adapter.adapt("claude", "SessionEnd", {
            "session_id": "final-parent", "hook_event_name": "SessionEnd",
            "reason": "completed", "cwd": "/tmp/repo",
            "transcript_path": "/tmp/final-parent.jsonl",
        })
        self.assertEqual(self.store.get_execution(child["handle"]).state, "ended")
        self.assertEqual(self.store.get_execution(parent["handle"]).state, "ended")
        self.assertEqual([row.kind for row in self.queue.pending(child["handle"])],
                         ["end_session"])
        self.assertEqual([row.kind for row in self.queue.pending(parent["handle"])],
                         ["end_session"])
        self.assertEqual(
            self.store.active_child_executions("claude", "final-parent"), []
        )

    def test_legacy_completion_rewrites_only_safe_argv_and_mints_same_permit(self):
        started = self.start("claude")
        handle = started["handle"]
        self.store.record_bound(handle, "backend-session", "kanban", "worker")
        self.store.set_claim(handle, CLAIM, "KANBAN-2")
        self.prompt()
        command = "kanban-post --done KANBAN-2 --evidence 'tests pass' --reference PR-17"
        native_input = {
            "command": command,
            "description": "Complete the claimed ticket",
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
        normalized = normalize_tool_args("complete_ticket", {
            "handle": handle, "claim_id": CLAIM, "evidence": "tests pass",
            "references": ["PR-17"], "operation_id": None,
        })
        self.assertTrue(self.store.has_permit(handle, "complete_ticket", normalized))

    def test_completion_like_shell_rejects_unverified_harness_input_fields(self):
        started = self.start("codex")
        self.store.record_bound(started["handle"], "backend-session", "kanban", "worker")
        self.store.set_claim(started["handle"], CLAIM, "KANBAN-2")
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
        started = self.start("claude")
        self.store.record_bound(started["handle"], "backend-session", "kanban", "worker")
        self.store.set_claim(started["handle"], CLAIM, "KANBAN-2")
        self.prompt("claude")
        result = self.pre("claude", "Bash", {
            "command": "kanban-post --done KANBAN-2 --evidence ok",
            "timeout": None,
        }, call="null-timeout")
        self.assertEqual(result.output["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertIn("Use the Kanban MCP complete_ticket tool",
                      result.output["hookSpecificOutput"]["permissionDecisionReason"])

    def test_completion_like_shell_rejections_are_actionable_and_unrelated_commands_pass(self):
        started = self.start("codex")
        self.prompt("codex")
        invalid = [
            "KANBAN_WORK_HANDLE=x kanban-post --done KANBAN-2 --evidence ok",
            "kanban-post --done KANBAN-2 --evidence $HOME",
            "kanban-post --done KANBAN-2 --evidence ok; echo bad",
            "kanban-post --done KANBAN-2 --evidence ok --unknown flag",
        ]
        for index, command in enumerate(invalid):
            with self.subTest(command=command):
                result = self.pre("codex", "Bash", {"command": command}, call=f"bad-{index}")
                output = result.output["hookSpecificOutput"]
                self.assertEqual(output["permissionDecision"], "deny")
                self.assertIn("Use the Kanban MCP complete_ticket tool",
                              output["permissionDecisionReason"])
        ordinary = self.pre("codex", "Bash", {"command": "git status --short"}, call="ordinary")
        self.assertEqual(ordinary.output["hookSpecificOutput"]["permissionDecision"], "allow")
        self.assertFalse(self.store.has_any_permit())
        self.assertTrue(self.store.tool_operation(started["handle"], "ordinary")["active"])

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
        self.matrix = self.root / "qualified.json"
        self.matrix.write_text(json.dumps({
            "clients": {"cursor": {"versions": [self.VERSION]}}
        }))
        self.env = mock.patch.dict(os.environ, {
            "AICODING_KANBAN_QUALIFIED_CLIENTS": str(self.matrix),
            "KANBAN_URL": "http://127.0.0.1:8765",
            "KANBAN_TEST_TOKEN": "fixture-only-token",
            "AICODINGSETUP_SKIP_NETWORK": "1",
        }, clear=False)
        self.env.start()
        self.clock = Clock()
        self.store = Store(self.state)
        self.queue = LifecycleQueue(self.store, now=self.clock)
        self.ingress = EventIngestor(self.store, self.queue, now=self.clock)
        self.adapter = CursorAdapter(
            self.store, self.ingress, now=self.clock,
            instructions_provider=lambda handle: f"Kanban workflow\nhandle={handle}",
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
        self.assertIn("Kanban workflow", result.output["additional_context"])
        execution = self.store.get_execution(result.lifecycle["handle"])
        self.assertEqual(execution.native_session_id, "conv-a")
        self.assertTrue(execution.lifecycle_capable)

    def test_background_session_uses_conversation_as_its_own_native_identity(self):
        result = self.start(is_background_agent=True)
        execution = self.store.get_execution(result.lifecycle["handle"])
        self.assertEqual(execution.native_session_id, "conv-a")
        self.assertIsNone(execution.subagent_id)

    def test_unlisted_cursor_version_remains_read_only(self):
        payload = self.payload(
            "sessionStart", session_id="conv-b", conversation="conv-b",
            cursor_version="2026.09.11-unlisted", is_background_agent=False,
        )
        result = self.adapter.adapt("sessionStart", payload)
        self.assertFalse(self.store.get_execution(result.lifecycle["handle"]).lifecycle_capable)

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

    def test_generic_pre_tool_is_only_permit_minter_and_denies_peer_handle(self):
        handle = self.start().lifecycle["handle"]
        self.prompt()
        peer = self.ingress.ingest_event("cursor", "start", {
            "native_event_id": "peer-start", "native_session_id": "conv-peer",
            "subagent_id": None, "checkout": str(self.checkout),
            "lifecycle_capable": True,
        })
        denied = self.pre(
            "MCP:claim_ticket", {"handle": peer["handle"], "ticket": "KANBAN-2"}
        )
        self.assertEqual(denied.output["permission"], "deny")
        self.assertIn("bound Cursor session", denied.output["agent_message"])
        self.assertFalse(self.store.has_any_permit())

        allowed = self.pre(
            "MCP:claim_ticket", {"handle": handle, "ticket": "KANBAN-2"}, call="claim-1"
        )
        self.assertEqual(allowed.output, {"permission": "allow"})
        normalized = normalize_tool_args(
            "claim_ticket", {"handle": handle, "ticket": "KANBAN-2"}
        )
        self.assertTrue(self.store.has_permit(handle, "claim_ticket", normalized))

    def test_generic_pre_tool_leaves_unrelated_mcp_tools_available(self):
        handle = self.start().lifecycle["handle"]
        self.prompt()
        result = self.pre(
            "MCP:github_search", {"query": "cursor hooks"}, call="github-read"
        )
        self.assertEqual(result.output, {"permission": "allow"})
        self.assertFalse(self.store.has_any_permit())
        self.assertTrue(self.store.tool_operation(handle, "github-read")["active"])

    def test_pre_tool_validates_object_input_and_replay_fails_closed(self):
        handle = self.start().lifecycle["handle"]
        self.prompt()
        malformed = self.pre("MCP:claim_ticket", "not-an-object", call="bad")
        self.assertEqual(malformed.output["permission"], "deny")
        first = self.pre("MCP:claim_ticket", {"handle": handle, "ticket": "KANBAN-2"})
        replay = self.pre("MCP:claim_ticket", {"handle": handle, "ticket": "KANBAN-2"})
        self.assertEqual(first.output["permission"], "allow")
        self.assertEqual(replay.output["permission"], "deny")

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
        self.store.record_bound(handle, "backend-session", "kanban", "worker")
        self.store.set_claim(handle, CLAIM, "KANBAN-2")
        self.prompt()
        command = "kanban-post --done KANBAN-2 --evidence 'tests pass'"
        native = {"command": command, "working_directory": str(self.checkout)}
        result = self.pre("Shell", native, call="legacy")
        self.assertEqual(result.output["permission"], "allow")
        self.assertEqual(result.output["updated_input"], {
            **native,
            "command": f"kanban-post --done KANBAN-2 --evidence 'tests pass' --work-handle {handle}",
        })
        replay = self.pre("Shell", native, call="legacy")
        self.assertEqual(replay.output["permission"], "deny")
        for index, bad in enumerate((
            "KANBAN_WORK_HANDLE=x kanban-post --done KANBAN-2 --evidence ok",
            "kanban-post --done KANBAN-2 --evidence ok; echo bad",
        )):
            denied = self.pre("Shell", {"command": bad}, call=f"bad-{index}")
            self.assertEqual(denied.output["permission"], "deny")
        ordinary = self.pre("Shell", {"command": "git status --short"}, call="ordinary")
        self.assertEqual(ordinary.output["permission"], "allow")


if __name__ == "__main__":
    unittest.main()
