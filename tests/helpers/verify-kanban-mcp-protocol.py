#!/usr/bin/env python3
"""Exercise an already-installed Kanban MCP with its own pinned SDK runtime."""

from __future__ import annotations

import asyncio
import json
import os
import subprocess
import sys
import tempfile
from importlib.metadata import version
from pathlib import Path

from mcp import Client, StdioServerParameters


PINNED_MCP_SDK = "2.2.0"
HANDLE = "11111111-1111-4111-8111-111111111111"
TOOLS = {
    "bind_work_session",
    "list_tickets",
    "get_ticket",
    "create_ticket",
    "update_ticket",
    "add_comment",
    "link_tickets",
    "unlink_tickets",
    "list_repos",
    "claim_ticket",
    "my_work",
    "checkpoint_work",
    "release_ticket",
    "complete_ticket",
    "end_work_session",
}


def _server_environment(helper_dir: Path, home: Path) -> dict[str, str]:
    """Pass only non-secret runtime inputs to the real stdio server."""
    return {
        "HOME": str(home),
        "PATH": f"{helper_dir}{os.pathsep}{os.environ.get('PATH', '')}",
        "PYTHONDONTWRITEBYTECODE": "1",
        "AICODINGSETUP_SKIP_NETWORK": "1",
    }


def _write_fake_helpers(helper_dir: Path) -> None:
    script = """#!/usr/bin/env python3
import json
import os
import sys

if os.environ.get("KANBAN_TOKEN") or os.environ.get("KANBAN_TEST_TOKEN"):
    raise SystemExit("credential reached protocol fixture")
operation = sys.argv[2]
payload = json.load(sys.stdin)
if payload.get("payload", {}).get("title") == "claimed":
    print(json.dumps({"ok": False, "error": {"code": 409, "message": "ticket is claimed"}}))
    raise SystemExit(1)
print(json.dumps({"ok": True, "data": {"operation": operation, "received": payload}}))
"""
    for name in ("kanban-post", "kanban-work"):
        helper = helper_dir / name
        helper.write_text(script, encoding="utf-8")
        helper.chmod(0o755)


async def _exercise_mode(
    controller: Path,
    environment: dict[str, str],
    cwd: Path,
    mode: str | None,
    cli_instructions: str,
) -> None:
    parameters = StdioServerParameters(
        command=str(controller),
        cwd=cwd,
        env=environment,
    )
    client_kwargs = {} if mode is None else {"mode": mode}
    async with Client(parameters, **client_kwargs) as client:
        expected_protocol = "2025-11-25" if mode == "legacy" else "2026-07-28"
        assert client.protocol_version == expected_protocol
        assert client.instructions
        assert client.instructions == cli_instructions

        listed = await client.list_tools()
        assert {tool.name for tool in listed.tools} == TOOLS

        read = await client.call_tool("list_repos", {})
        assert read.is_error is False
        assert read.structured_content == {
            "data": {"operation": "list_repos", "received": {}}
        }

        failed = await client.call_tool(
            "create_ticket", {"handle": HANDLE, "title": "claimed"}
        )
        assert failed.is_error is True
        assert "Kanban error (409): ticket is claimed" in json.dumps(failed.model_dump())

    label = "legacy" if mode == "legacy" else "default-v2"
    print(f"{label}: protocol/read/instructions/isError PASS")


async def _main(controller: Path) -> None:
    assert version("mcp") == PINNED_MCP_SDK
    metadata_version = version("kanban")
    with tempfile.TemporaryDirectory(prefix="kanban-mcp-protocol-") as raw_tmp:
        root = Path(raw_tmp)
        helper_dir = root / "helpers"
        home = root / "home"
        cwd = root / "unrelated-cwd"
        helper_dir.mkdir()
        home.mkdir()
        cwd.mkdir()
        _write_fake_helpers(helper_dir)
        environment = _server_environment(helper_dir, home)

        version_result = subprocess.run(
            [controller, "--version"],
            cwd=cwd,
            env=environment,
            text=True,
            capture_output=True,
            timeout=10,
            check=True,
        )
        assert version_result.stderr == ""
        assert version_result.stdout == f"kanban-mcp {metadata_version}\n"
        instructions_result = subprocess.run(
            [controller, "--instructions"],
            cwd=cwd,
            env=environment,
            text=True,
            capture_output=True,
            timeout=10,
            check=True,
        )
        assert instructions_result.stderr == ""
        assert instructions_result.stdout.strip()

        await _exercise_mode(
            controller, environment, cwd, "legacy", instructions_result.stdout
        )
        await _exercise_mode(
            controller, environment, cwd, None, instructions_result.stdout
        )


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: verify-kanban-mcp-protocol.py CONTROLLER")
    target = Path(sys.argv[1])
    if not target.is_file() or not os.access(target, os.X_OK):
        raise SystemExit(f"controller is unavailable: {target}")
    asyncio.run(_main(target))
