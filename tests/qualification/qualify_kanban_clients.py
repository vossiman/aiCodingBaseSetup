"""Honest native-client qualification preflight and report writer.

This module deliberately does not accept transcripts or fixture evidence. Until a
same-launch native evidence path exists, every scenario remains unobserved.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from urllib.parse import urlsplit

from fake_kanban_board import FAKE_TOKEN, FakeKanbanBoard


CLIENTS = ("claude", "codex", "cursor", "opencode")
REQUIRED_SCENARIOS = (
    "instructions", "bind", "mutating_identity_check", "activity", "turn_stop",
    "session_end", "generation_boundaries", "two_sessions_one_checkout",
    "shared_mcp_process", "long_tool", "failure_reconciliation", "parent_child",
    "crash_expiry",
)
BINARIES = {
    "claude": ("claude",),
    "codex": ("codex",),
    "cursor": ("agent", "cursor-agent"),
    "opencode": ("opencode",),
}
VERSION_RE = re.compile(r"(?<![A-Za-z0-9.])\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?(?![A-Za-z0-9.])")
PIN_FILE = Path(__file__).resolve().parents[2] / "configs" / "versions" / "kanban-mcp.rev"


class CommandTimeout(RuntimeError):
    pass


@dataclass(frozen=True)
class VersionObservation:
    client: str
    command: str
    version: str | None
    observed: bool
    reason: str


def validate_qualification_environment(url: str, token: str) -> None:
    parts = urlsplit(url)
    if parts.scheme != "http" or parts.hostname != "127.0.0.1" or parts.username or parts.password:
        raise ValueError("qualification board must be loopback http://127.0.0.1")
    if not parts.port:
        raise ValueError("qualification board must use an explicit loopback port")
    if token != FAKE_TOKEN:
        raise ValueError("KANBAN_TEST_TOKEN must be the fixed qualification token")


def candidate_matrix(client: str, version: str) -> dict:
    if client not in CLIENTS or not isinstance(version, str) or not VERSION_RE.fullmatch(version):
        raise ValueError("candidate matrix requires one exact client/version pair")
    return {"schema": 1, "clients": {client: [version]}}


def observe_version(binary: Path | str, client: str, *, timeout: float = 2,
                    environment: dict[str, str] | None = None) -> VersionObservation:
    command = Path(binary).name
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LANG": "C.UTF-8"}
    if environment:
        env.update(environment)
    try:
        result = subprocess.run(
            [str(binary), "--version"], stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            timeout=timeout, shell=False, env=env,
        )
    except subprocess.TimeoutExpired as error:
        raise CommandTimeout(f"{command} --version timed out") from error
    except OSError:
        return VersionObservation(client, command, None, False, f"{command} is not installed")
    if result.returncode != 0:
        return VersionObservation(
            client, command, None, True,
            f"{command} --version exited nonzero without a usable version",
        )
    output = (result.stdout + "\n" + result.stderr)[:4096]
    match = VERSION_RE.search(output)
    if not match or len(match.group(0)) > 100:
        return VersionObservation(
            client, command, None, True,
            f"{command} --version did not return a bounded exact version",
        )
    return VersionObservation(client, command, match.group(0), True, "")


def _metadata() -> tuple[str, str]:
    try:
        commit = subprocess.run(
            ["git", "rev-parse", "HEAD"], stdin=subprocess.DEVNULL,
            capture_output=True, text=True, timeout=2, check=True,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        commit = "unknown"
    try:
        pin = PIN_FILE.read_text(encoding="utf-8").strip()
    except OSError:
        pin = "unknown"
    return commit, pin


def build_report(client: str, version: str | None, scenarios: dict[str, bool],
                 reasons: list[str], real_binary_observed: bool) -> dict:
    commit, pin = _metadata()
    report = {
        "schema": 1,
        "timestamp": datetime.now(UTC).isoformat(),
        "blueprint_commit": commit,
        "pinned_kanban_revision": pin,
        "client": client,
        "version": version,
        "evidence": "preflight_only",
        "scenarios": dict(scenarios),
        "status": "qualified",
        "reasons": list(reasons),
        "real_binary_observed": bool(real_binary_observed),
    }
    return validate_report(report)


def validate_report(report: dict) -> dict:
    value = dict(report)
    scenarios = value.get("scenarios")
    if not isinstance(scenarios, dict):
        scenarios = {}
    reasons = [item for item in value.get("reasons", []) if isinstance(item, str)]
    normalized = {}
    for scenario in REQUIRED_SCENARIOS:
        present = scenario in scenarios and type(scenarios[scenario]) is bool
        normalized[scenario] = scenarios.get(scenario) is True if present else False
        if not present:
            reasons.append(f"missing required scenario: {scenario}")
    if set(scenarios) - set(REQUIRED_SCENARIOS):
        reasons.append("report contains an unknown scenario")
    if not value.get("real_binary_observed"):
        reasons.append("real client binary was not observed")
    if value.get("evidence") == "preflight_only":
        reasons.append("native lifecycle evidence was not collected")
    value["scenarios"] = normalized
    value["reasons"] = list(dict.fromkeys(reasons))
    value["status"] = (
        "qualified" if all(normalized.values()) and not value["reasons"]
        and value.get("real_binary_observed") is True else "unsupported"
    )
    return value


def qualify(*, fake_client: bool, real_binary_observed: bool) -> dict:
    """Small invariant helper: fixtures can exercise reporting but never qualify."""
    scenarios = {name: bool(fake_client) for name in REQUIRED_SCENARIOS}
    return build_report("claude", "fixture" if fake_client else None, scenarios, [], real_binary_observed)


def _safe_report(report: dict) -> dict:
    """Allowlist report fields so raw client output can never enter an artifact."""
    keys = (
        "schema", "timestamp", "blueprint_commit", "pinned_kanban_revision",
        "client", "version", "evidence", "scenarios", "status", "reasons",
        "real_binary_observed",
    )
    value = {key: report.get(key) for key in keys}
    serialized = json.dumps(value, ensure_ascii=False)
    serialized = serialized.replace(FAKE_TOKEN, "[REDACTED]")
    return json.loads(serialized)


def write_report(output: Path | str, report: dict) -> Path:
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    safe = _safe_report(validate_report(report))
    version = safe.get("version") or "unknown"
    filename = re.sub(r"[^A-Za-z0-9._+-]", "_", f"{safe['client']}-{version}.json")
    target = output / filename
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=output, delete=False) as handle:
        json.dump(safe, handle, indent=2, sort_keys=True)
        handle.write("\n")
        temporary = Path(handle.name)
    temporary.replace(target)
    return target


def _binary(client: str) -> str:
    for name in BINARIES[client]:
        found = shutil.which(name)
        if found:
            return found
    return BINARIES[client][0]


def _preflight_reason(client: str) -> str:
    reasons = {
        "claude": (
            "native launch was not run: restricted-mode qualification still requires "
            "reviewed managed-layer provenance"
        ),
        "codex": (
            "native launch was not run: codex app-server inventory does not use the same "
            "configuration as codex exec --ignore-user-config, so it cannot prove the "
            "candidate hooks are the only executable hooks in the model launch"
        ),
        "cursor": (
            "native launch was not run: this client has no exclusive hook, plugin, and MCP "
            "configuration mode that retains installed authentication"
        ),
        "opencode": (
            "native launch was not run: merged configuration cannot isolate the candidate "
            "plugin and MCP while retaining installed authentication"
        ),
    }
    return reasons[client]


def preflight_client(client: str, output: Path, board_url: str) -> dict:
    validate_qualification_environment(board_url, FAKE_TOKEN)
    observation = observe_version(_binary(client), client)
    reasons = [reason for reason in (observation.reason, _preflight_reason(client)) if reason]
    report = build_report(
        client, observation.version,
        {scenario: False for scenario in REQUIRED_SCENARIOS},
        reasons, observation.observed,
    )
    write_report(output, report)
    return report


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Observe exact native client versions and write honest Kanban qualification reports."
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--all", action="store_true", help="report all four installed clients")
    group.add_argument("--client", choices=CLIENTS, help="report one installed client")
    parser.add_argument(
        "--output", type=Path, default=Path("out/kanban-mcp-qualification"),
        help="report directory (default: out/kanban-mcp-qualification)",
    )
    args = parser.parse_args(argv)
    selected = CLIENTS if args.all else (args.client,)
    with FakeKanbanBoard() as board:
        reports = [preflight_client(client, args.output, board.url) for client in selected]
    for report in reports:
        version = report["version"] or "unobserved"
        print(f"{report['client']} {version}: {report['status']}")
    return 0 if all(report["status"] == "qualified" for report in reports) else 1


if __name__ == "__main__":
    sys.exit(main())
