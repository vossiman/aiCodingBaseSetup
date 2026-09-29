"""The real kanban-work hooks and kanban-post against a loopback fake board."""

import json
import os
import socket
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

from tests.python.fake_board import INSTRUCTIONS, TOKEN, FakeBoardServer

ROOT = Path(__file__).resolve().parents[2]
KANBAN_WORK = ROOT / "bin" / "kanban-work"
UNSETTLED = "the board has not confirmed the previous turn's stop; retry the claim"


def closed_port_url() -> str:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    return f"http://127.0.0.1:{port}"


class HookHarness(unittest.TestCase):
    """Drives one harness's hook command exactly as its config does."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.fake = FakeBoardServer()
        self.addCleanup(self.fake.close)
        self.board = self.fake.board
        self.url = self.fake.url
        self.checkout = self.git_checkout("https://github.com/vossiman/aiCodingBaseSetup.git")

    def git_checkout(self, origin: str | None, name="checkout") -> Path:
        path = self.root / name
        path.mkdir()
        if origin is not None:
            subprocess.run(["git", "init", "-q", str(path)], check=True)
            subprocess.run(["git", "-C", str(path), "remote", "add", "origin", origin], check=True)
        return path

    def env(self, url=None) -> dict:
        return {
            "HOME": str(self.home),
            "XDG_STATE_HOME": str(self.root / "state"),
            "PATH": f"{ROOT / 'bin'}:/usr/local/bin:/usr/bin:/bin",
            "KANBAN_URL": url or self.url,
            "KANBAN_TEST_TOKEN": TOKEN,
            "AICODINGSETUP_SKIP_NETWORK": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
        }

    def hook(self, harness, event, payload, *, url=None) -> dict:
        result = subprocess.run(
            ["python3", str(KANBAN_WORK), "hook", "--harness", harness, "--event", event],
            input=json.dumps(payload), capture_output=True, text=True,
            env=self.env(url), timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn(TOKEN, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def session(self, handle):
        session = self.board.session_for_handle(handle)
        self.assertIsNotNone(session, "session was not registered at start")
        return session


class ClaudeCodexBase(HookHarness):
    harness = "claude"
    turn_field = "prompt_id"

    def start(self, cwd=None, session="native-a"):
        out = self.hook(self.harness, "SessionStart", {
            "session_id": session, "hook_event_name": "SessionStart", "source": "startup",
            "cwd": str(cwd or self.checkout), "transcript_path": f"/tmp/{session}.jsonl",
        })
        context = out["hookSpecificOutput"]["additionalContext"]
        handle = context.rsplit("Kanban work handle: ", 1)[1].strip()
        return handle, context

    def prompt(self, turn, *, url=None, session="native-a"):
        return self.hook(self.harness, "UserPromptSubmit", {
            "session_id": session, "hook_event_name": "UserPromptSubmit",
            self.turn_field: turn, "prompt": "work", "cwd": str(self.checkout),
        }, url=url)

    def pre(self, tool, turn, call, *, url=None, tool_input=None):
        return self.hook(self.harness, "PreToolUse", {
            "session_id": "native-a", "hook_event_name": "PreToolUse",
            self.turn_field: turn, "tool_use_id": call, "tool_name": tool,
            "tool_input": tool_input if tool_input is not None else {"ticket": "X-1"},
            "cwd": str(self.checkout),
        }, url=url)

    def post(self, tool, turn, call):
        return self.hook(self.harness, "PostToolUse", {
            "session_id": "native-a", "hook_event_name": "PostToolUse",
            self.turn_field: turn, "tool_use_id": call, "tool_name": tool,
            "tool_input": {}, "tool_response": {}, "cwd": str(self.checkout),
        })

    def stop(self, turn, *, url=None):
        return self.hook(self.harness, "Stop", {
            "session_id": "native-a", "hook_event_name": "Stop",
            self.turn_field: turn, "stop_hook_active": False, "cwd": str(self.checkout),
        }, url=url)

    def decision(self, output):
        return output["hookSpecificOutput"]["permissionDecision"]

    def claim_tool(self):
        return "mcp__kanban__claim_ticket"


class ClaudeFlows(ClaudeCodexBase):
    # -- registration --------------------------------------------------------

    def test_start_registers_inside_a_checkout_with_its_repo_and_injects_the_handle(self):
        handle, context = self.start()
        session = self.session(handle)
        self.assertEqual(session["repo"], "aiCodingBaseSetup")
        self.assertEqual(session["handle"], handle)
        if self.harness == "claude":
            self.assertEqual(context, f"Kanban work handle: {handle}")
        else:
            self.assertEqual(context, f"{INSTRUCTIONS}\n\nKanban work handle: {handle}")

    def test_start_outside_a_checkout_registers_without_a_repo(self):
        handle, _ = self.start(cwd=self.git_checkout(None, "scratch"))
        self.assertIsNone(self.session(handle)["repo"])

    def test_start_in_a_checkout_the_board_does_not_know_registers_without_a_repo(self):
        other = self.git_checkout("git@github.com:vossiman/unlisted.git", "unlisted")
        handle, _ = self.start(cwd=other)
        self.assertIsNone(self.session(handle)["repo"])

    def test_start_with_the_board_down_still_hands_out_the_handle_and_registers_later(self):
        out = self.hook(self.harness, "SessionStart", {
            "session_id": "native-a", "hook_event_name": "SessionStart", "source": "startup",
            "cwd": str(self.checkout), "transcript_path": "/tmp/native-a.jsonl",
        }, url=closed_port_url())
        context = out["hookSpecificOutput"]["additionalContext"]
        handle = context.rsplit("Kanban work handle: ", 1)[1].strip()
        self.assertIsNone(self.board.session_for_handle(handle))
        drained = subprocess.run(["python3", str(KANBAN_WORK), "drain", "2000"],
                                 capture_output=True, text=True, env=self.env(), timeout=60)
        self.assertEqual(drained.returncode, 0, drained.stdout)
        self.assertEqual(self.session(handle)["repo"], "aiCodingBaseSetup")

    # -- Stop release and settlement ----------------------------------------

    def test_stop_releases_the_live_claim(self):
        handle, _ = self.start()
        session = self.session(handle)
        self.prompt("turn-1")
        claim = self.board.claim(session["id"], "AICODINGBASESETUP-1")
        self.stop("turn-1")
        self.assertIsNotNone(claim["released_at"])
        self.assertEqual(self.board.tickets["AICODINGBASESETUP-1"]["status"], "todo")

    def test_timed_out_stop_is_cancelled_and_its_late_request_leaves_the_new_claim_live(self):
        handle, _ = self.start()
        session = self.session(handle)
        self.prompt("turn-1")
        first = self.board.claim(session["id"], "AICODINGBASESETUP-1")
        self.board.delays["/release-active"] = 5
        started = time.monotonic()
        self.stop("turn-1")
        self.assertLess(time.monotonic() - started, 10)
        self.assertIsNone(first["released_at"], "the Stop must not have applied yet")
        self.board.delays.clear()
        self.prompt("turn-2")
        cancels = [c for c in self.board.calls if c[1].endswith("/cancel-stop")]
        self.assertEqual(len(cancels), 1)
        # The next turn hands T1 back and takes T2; the late Stop then lands.
        first["released_at"] = time.time()
        second = self.board.claim(session["id"], "AICODINGBASESETUP-2")
        stop_ids = [c[2]["operation_id"] for c in self.board.calls if c[1].endswith("/release-active")]
        self.assertEqual(len(stop_ids), 1)
        deadline = time.monotonic() + 15
        while not self.board.late_results and time.monotonic() < deadline:
            time.sleep(0.1)
        self.assertEqual(self.board.late_results, [{"stop": "cancelled", "released": None}])
        self.assertIsNone(second["released_at"])
        self.assertEqual(self.board.live_claim(session["id"])["id"], second["id"])

    def test_board_down_at_turn_start_blocks_only_the_claim_until_the_stop_is_settled(self):
        handle, _ = self.start()
        session = self.session(handle)
        self.prompt("turn-1")
        claim = self.board.claim(session["id"], "AICODINGBASESETUP-1")
        down = closed_port_url()
        self.stop("turn-1", url=down)
        self.prompt("turn-2", url=down)  # the turn proceeds
        blocked = self.pre(self.claim_tool(), "turn-2", "call-1", url=down)
        self.assertEqual(self.decision(blocked), "deny")
        self.assertIn(UNSETTLED, json.dumps(blocked))
        other = self.pre("mcp__kanban__add_comment", "turn-2", "call-2", url=down)
        self.assertEqual(self.decision(other), "allow")
        allowed = self.pre(self.claim_tool(), "turn-2", "call-3")
        self.assertEqual(self.decision(allowed), "allow")
        self.assertIsNone(claim["released_at"], "a cancelled Stop never releases the claim")
        self.assertEqual([c[1].rsplit("/", 1)[1] for c in self.board.calls
                          if "/release-active" in c[1] or "/cancel-stop" in c[1]],
                         ["cancel-stop"])

    def test_pre_tool_hook_never_inspects_other_kanban_tools(self):
        self.start()
        self.prompt("turn-1")
        before = len(self.board.calls)
        out = self.pre("mcp__kanban__create_ticket", "turn-1", "call-1",
                       tool_input={"handle": "not-even-a-uuid", "title": "x"})
        self.assertEqual(self.decision(out), "allow")
        self.assertEqual(len(self.board.calls), before)


class CodexFlows(ClaudeFlows):
    harness = "codex"
    turn_field = "turn_id"


class LegacyCompletion(ClaudeCodexBase):
    def run_post(self, command_argv, env_handle=None):
        env = self.env()
        if env_handle:
            env["KANBAN_WORK_HANDLE"] = env_handle
        return subprocess.run(command_argv, capture_output=True, text=True, env=env, timeout=60)

    def test_rewritten_completion_completes_through_the_sessions_claim(self):
        handle, _ = self.start()
        session = self.session(handle)
        self.prompt("turn-1")
        claim = self.board.claim(session["id"], "AICODINGBASESETUP-1")
        out = self.pre("Bash", "turn-1", "call-1", tool_input={
            "command": "kanban-post --done AICODINGBASESETUP-1 --evidence 'tests pass'"})
        command = out["hookSpecificOutput"]["updatedInput"]["command"]
        self.assertTrue(command.endswith(f"--work-handle {handle}"))
        import shlex
        result = self.run_post(shlex.split(command))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIsNotNone(claim["released_at"])
        self.assertEqual(self.board.tickets["AICODINGBASESETUP-1"]["status"], "done")

    def test_completion_of_another_ticket_is_refused_while_claimed(self):
        handle, _ = self.start()
        self.board.claim(self.session(handle)["id"], "AICODINGBASESETUP-1")
        result = self.run_post(["kanban-post", "--done", "AICODINGBASESETUP-2", "--evidence",
                                "x", "--work-handle", handle])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not the session's current claim", result.stderr)

    def test_completion_without_a_claim_records_evidence_then_marks_done(self):
        handle, _ = self.start()
        result = self.run_post(["kanban-post", "--done", "AICODINGBASESETUP-2", "--evidence",
                                "shipped", "--work-handle", handle])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.board.comments, [("AICODINGBASESETUP-2", "Completion evidence:\n\nshipped")])
        self.assertEqual(self.board.tickets["AICODINGBASESETUP-2"]["status"], "done")


class CursorFlows(HookHarness):
    def payload(self, event, generation, **extra):
        return {"conversation_id": "conv-a", "generation_id": generation,
                "cursor_version": "2026.09.10-fd3934a", "hook_event_name": event,
                "workspace_roots": [str(self.checkout)], "cwd": str(self.checkout), **extra}

    def test_cursor_registers_releases_on_stop_and_gates_the_claim(self):
        out = self.hook("cursor", "sessionStart", self.payload(
            "sessionStart", "gen-1", session_id="conv-a", is_background_agent=False,
            composer_mode="agent"))
        self.assertTrue(out["additional_context"].startswith(INSTRUCTIONS))
        handle = out["env"]["KANBAN_WORK_HANDLE"]
        session = self.session(handle)
        self.assertEqual(session["repo"], "aiCodingBaseSetup")
        self.hook("cursor", "beforeSubmitPrompt", self.payload("beforeSubmitPrompt", "gen-1",
                                                               prompt="x", attachments=[]))
        claim = self.board.claim(session["id"], "AICODINGBASESETUP-1")
        down = closed_port_url()
        self.hook("cursor", "stop", self.payload("stop", "gen-1", status="completed",
                                                  loop_count=0), url=down)
        self.hook("cursor", "beforeSubmitPrompt", self.payload("beforeSubmitPrompt", "gen-2",
                                                               prompt="x", attachments=[]), url=down)
        blocked = self.hook("cursor", "preToolUse", self.payload(
            "preToolUse", "gen-2", tool_use_id="c1", tool_name="MCP:claim_ticket",
            tool_input={"ticket": "X-1"}), url=down)
        self.assertEqual(blocked["permission"], "deny")
        self.assertEqual(blocked["agent_message"], UNSETTLED)
        allowed = self.hook("cursor", "preToolUse", self.payload(
            "preToolUse", "gen-2", tool_use_id="c2", tool_name="MCP:claim_ticket",
            tool_input={"ticket": "X-1"}))
        self.assertEqual(allowed["permission"], "allow")
        self.assertIsNone(claim["released_at"])
        self.hook("cursor", "postToolUse", self.payload(
            "postToolUse", "gen-2", tool_use_id="c2", tool_name="MCP:claim_ticket",
            tool_input={"ticket": "X-1"}, tool_output="{}"))
        self.hook("cursor", "stop", self.payload("stop", "gen-2", status="completed", loop_count=0))
        self.assertIsNotNone(claim["released_at"])


class OpenCodeFlows(HookHarness):
    def base(self, **extra):
        return {"instanceID": "inst-a", "clientVersion": "1.18.30",
                "directory": str(self.checkout), **extra}

    def test_opencode_registers_releases_on_idle_and_gates_the_claim(self):
        info = {"id": "ses-a", "directory": str(self.checkout), "title": "t",
                "version": "1.18.30", "time": {"created": 1, "updated": 1}}
        created = self.hook("opencode", "session.created",
                            self.base(eventID="e1", sessionID="ses-a", info=info))
        handle = created["handle"]
        self.assertEqual(set(created), {"handle"})
        session = self.session(handle)
        self.assertEqual(session["repo"], "aiCodingBaseSetup")
        self.hook("opencode", "system.transform", self.base(sessionID="ses-a"))
        claim = self.board.claim(session["id"], "AICODINGBASESETUP-1")
        down = closed_port_url()
        self.hook("opencode", "session.idle", self.base(eventID="e2", sessionID="ses-a"), url=down)
        self.hook("opencode", "system.transform", self.base(sessionID="ses-a"), url=down)
        result = subprocess.run(
            ["python3", str(KANBAN_WORK), "hook", "--harness", "opencode", "--event",
             "tool.execute.before"],
            input=json.dumps(self.base(tool="kanban_claim_ticket", sessionID="ses-a",
                                       callID="c1", args={"ticket": "X-1"})),
            capture_output=True, text=True, env=self.env(down), timeout=60)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(UNSETTLED, result.stdout)
        self.hook("opencode", "tool.execute.before", self.base(
            tool="kanban_claim_ticket", sessionID="ses-a", callID="c2", args={"ticket": "X-1"}))
        self.assertIsNone(claim["released_at"])
        self.hook("opencode", "tool.execute.after", self.base(
            tool="kanban_claim_ticket", sessionID="ses-a", callID="c2"))
        self.hook("opencode", "session.idle", self.base(eventID="e3", sessionID="ses-a"))
        self.assertIsNotNone(claim["released_at"])


class InstructionsCommand(HookHarness):
    def test_kanban_work_serves_the_boards_instructions(self):
        result = subprocess.run(["python3", str(KANBAN_WORK), "--json", "instructions"],
                                input="{}", capture_output=True, text=True, env=self.env(),
                                timeout=60)
        self.assertEqual(json.loads(result.stdout), {"ok": True, "data": {"text": INSTRUCTIONS}})


if __name__ == "__main__":
    unittest.main()
