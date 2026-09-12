import json
import os
import tempfile
import unittest
from datetime import UTC, datetime, timedelta
from pathlib import Path
from unittest import mock

from lib.kanban_work.adapters import ClaudeCodexAdapter, _client_version
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
    def prompt_payload(session="native-a", turn="turn-1", agent=None):
        payload = {
            "session_id": session,
            "hook_event_name": "UserPromptSubmit",
            "prompt": "work",
            "prompt_id": turn,
            "turn_id": turn,
            "cwd": "/tmp/repo",
        }
        if agent:
            payload["agent_id"] = agent
        return payload

    @staticmethod
    def tool_payload(tool, args, *, session="native-a", turn="turn-1",
                     call="call-7", agent=None, event="PreToolUse"):
        payload = {
            "session_id": session,
            "turn_id": turn,
            "prompt_id": turn,
            "hook_event_name": event,
            "tool_use_id": call,
            "tool_name": tool,
            "tool_input": args,
            "cwd": "/tmp/repo",
        }
        if agent:
            payload["agent_id"] = agent
        if event == "PostToolUse":
            payload["tool_response"] = {}
        if event == "PostToolUseFailure":
            payload.update(error="failed", is_interrupt=False, duration_ms=12)
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
            harness, "UserPromptSubmit", self.prompt_payload(session, turn, agent)
        )

    def pre(self, harness, tool, args, **parts):
        return self.adapter.adapt(
            harness, "PreToolUse", self.tool_payload(tool, args, **parts)
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
                self.tool_payload("Bash", {"command": "false"}, event="PostToolUseFailure"),
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
        shell = self.tool_payload("Bash", {"command": ["not", "text"]})
        result = self.adapter.adapt("codex", "PreToolUse", shell)
        self.assertEqual(result.output["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_delayed_post_after_resume_closes_only_captured_old_generation(self):
        old = self.start("codex")
        self.prompt("codex", turn="turn-old")
        self.pre("codex", "Bash", {"command": "sleep 1"}, turn="turn-old", call="long-1")
        self.assertTrue(self.store.tool_operation(old["handle"], "long-1")["active"])

        current = self.start("codex", source="resume")
        post = self.tool_payload(
            "Bash", {"command": "sleep 1"}, turn="turn-old", call="long-1",
            event="PostToolUse",
        )
        result = self.adapter.adapt("codex", "PostToolUse", post)
        self.assertEqual(result.lifecycle["handle"], old["handle"])
        self.assertNotEqual(result.lifecycle["handle"], current["handle"])
        self.assertIsNone(self.store.tool_operation(current["handle"], "long-1"))

    def test_long_codex_tool_stays_open_until_original_post_then_stop_releases(self):
        started = self.start("codex")
        self.prompt("codex")
        self.pre("codex", "Bash", {"command": "long command"}, call="unified-1")
        stop = {**self.prompt_payload(), "hook_event_name": "Stop",
                "stop_hook_active": False, "last_assistant_message": "waiting"}
        held = self.adapter.adapt("codex", "Stop", stop)
        self.assertEqual(held.lifecycle["status"], "deferred_active_work")
        self.assertTrue(self.store.tool_operation(started["handle"], "unified-1")["active"])

        self.adapter.adapt("codex", "PostToolUse", self.tool_payload(
            "Bash", {"command": "long command"}, call="unified-1", event="PostToolUse"
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
        child_result = self.adapter.adapt("claude", "SubagentStart", {
            "session_id": "native-a", "hook_event_name": "SubagentStart",
            "agent_id": "agent-1", "agent_type": "Task", "cwd": "/tmp/repo",
        })
        self.assertIn("Kanban workflow", child_result.output[
            "hookSpecificOutput"]["additionalContext"])
        child_start = child_result.lifecycle
        child = child_start["handle"]
        self.assertNotEqual(child, parent["handle"])

        result = self.adapter.adapt("claude", "SubagentStop", {
            "session_id": "native-a", "hook_event_name": "SubagentStop",
            "agent_id": "agent-1", "agent_type": "Task", "stop_hook_active": False,
        })
        self.assertEqual(result.lifecycle["handle"], child)
        self.assertEqual(self.store.get_execution(child).state, "ended")
        self.assertNotEqual(self.store.get_execution(parent["handle"]).state, "ended")

    def test_same_child_id_after_parent_resume_gets_a_fresh_child_generation(self):
        self.start("claude")
        first = self.adapter.adapt("claude", "SubagentStart", {
            "session_id": "native-a", "hook_event_name": "SubagentStart",
            "agent_id": "agent-1", "agent_type": "Task", "cwd": "/tmp/repo",
        }).lifecycle
        self.start("claude", source="resume")
        second = self.adapter.adapt("claude", "SubagentStart", {
            "session_id": "native-a", "hook_event_name": "SubagentStart",
            "agent_id": "agent-1", "agent_type": "Task", "cwd": "/tmp/repo",
        }).lifecycle
        self.assertNotEqual(first["handle"], second["handle"])
        self.assertNotEqual(first["run_generation"], second["run_generation"])

    def test_parent_stop_waits_for_live_child(self):
        self.start("claude")
        self.prompt()
        self.adapter.adapt("claude", "SubagentStart", {
            "session_id": "native-a", "hook_event_name": "SubagentStart",
            "agent_id": "agent-1", "agent_type": "Task", "cwd": "/tmp/repo",
        })
        result = self.adapter.adapt("claude", "Stop", {
            **self.prompt_payload(), "hook_event_name": "Stop",
        })
        self.assertEqual(result.lifecycle["status"], "deferred_active_work")

    def test_legacy_completion_rewrites_only_safe_argv_and_mints_same_permit(self):
        started = self.start("claude")
        handle = started["handle"]
        self.store.record_bound(handle, "backend-session", "kanban", "worker")
        self.store.set_claim(handle, CLAIM, "KANBAN-2")
        self.prompt()
        command = "kanban-post --done KANBAN-2 --evidence 'tests pass' --reference PR-17"
        result = self.pre("claude", "Bash", {"command": command}, call="legacy-1")
        output = result.output["hookSpecificOutput"]
        self.assertEqual(output["permissionDecision"], "allow")
        self.assertEqual(output["updatedInput"], {
            "command": f"kanban-post --done KANBAN-2 --evidence 'tests pass' --reference PR-17 --work-handle {handle}"
        })
        normalized = normalize_tool_args("complete_ticket", {
            "handle": handle, "claim_id": CLAIM, "evidence": "tests pass",
            "references": ["PR-17"], "operation_id": None,
        })
        self.assertTrue(self.store.has_permit(handle, "complete_ticket", normalized))

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
        prompt = self.prompt_payload()
        prompt["prompt"] = "sensitive prompt fixture"
        result = self.adapter.adapt("codex", "UserPromptSubmit", prompt)
        self.assertNotIn("sensitive prompt fixture", json.dumps(result.output))


if __name__ == "__main__":
    unittest.main()
