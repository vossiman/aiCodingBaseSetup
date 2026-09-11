#!/usr/bin/env python3
"""Value-safe CLI for planning and applying Codex configuration merges."""

import sys

sys.dont_write_bytecode = True

import argparse
import json
from pathlib import Path

try:
    from codex_merge_state import (
        Request,
        RequestFailure,
        error_result,
        execute,
        load_decisions,
    )
except Exception:
    # Runtime import errors must not expose installation paths, parser details,
    # or values through a traceback. Provisioning treats this as a hard error.
    RUNTIME_AVAILABLE = False
else:
    RUNTIME_AVAILABLE = True


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Plan or apply a setting-level Codex TOML merge.",
        epilog=(
            "An explicit local invocation (--local) may return a local receipt "
            "to tracking when the selected checkout is clean at origin/main."
        ),
    )
    parser.add_argument("action", choices=("plan", "apply"))
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--template", type=Path, required=True)
    parser.add_argument("--dest", type=Path, required=True)
    parser.add_argument("--clone", type=Path, required=True)
    parser.add_argument("--profile", choices=("host", "container"), required=True)
    parser.add_argument("--local", action="store_true")
    parser.add_argument("--tracked", action="store_true")
    parser.add_argument("--allow-adopt", action="store_true")
    parser.add_argument("--expected")
    parser.add_argument("--decisions", type=Path)
    return parser


def main() -> int:
    arguments = _parser().parse_args()
    if not RUNTIME_AVAILABLE:
        payload = {
            "config_changed": False,
            "state_changed": False,
            "conflicts": [],
            "error": {"code": "runtime_unavailable"},
            "unmanaged": False,
            "token": None,
            "changes": [],
            "adoption_notices": [],
        }
        if arguments.action == "apply":
            payload["applied"] = False
        sys.stdout.write(
            json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n"
        )
        return 2
    try:
        decisions = load_decisions(arguments.decisions)
    except RequestFailure as failure:
        payload, status = error_result(
            failure.diagnostic["code"], apply=arguments.action == "apply"
        )
    else:
        request = Request(
            action=arguments.action,
            source=arguments.source,
            template=arguments.template,
            dest=arguments.dest,
            clone=arguments.clone,
            profile=arguments.profile,
            local=arguments.local,
            tracked=arguments.tracked,
            allow_adopt=arguments.allow_adopt,
            expected=arguments.expected,
            decisions=decisions,
        )
        payload, status = execute(request)
    sys.stdout.write(json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n")
    return status


if __name__ == "__main__":
    raise SystemExit(main())
