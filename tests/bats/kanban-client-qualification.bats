#!/usr/bin/env bats

setup() {
  export PYTHONDONTWRITEBYTECODE=1
}

@test "qualification harness self-tests pass" {
  run python3 -m unittest discover -s tests/qualification -p 'test_*.py'
  [ "$status" -eq 0 ]
}

@test "qualification command exposes focused and all-client modes" {
  run tools/qualify-kanban-clients --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--all"* ]]
  [[ "$output" == *"--client"* ]]
}

@test "tracked client matrix starts with no fixture-qualified clients" {
  run python3 - <<'PY'
import json
from pathlib import Path

matrix = json.loads(Path("configs/kanban/qualified-clients.json").read_text())
assert matrix == {
    "schema": 1,
    "clients": {"claude": [], "codex": [], "cursor": [], "opencode": []},
}
PY
  [ "$status" -eq 0 ]
}

@test "focused preflight exits unsupported and labels unobserved native evidence" {
  reports="$BATS_TEST_TMPDIR/reports"
  run tools/qualify-kanban-clients --client codex --output "$reports"
  [ "$status" -eq 1 ]
  [ "$(jq -r .status "$reports"/codex-*.json)" = "unsupported" ]
  [ "$(jq -r .evidence "$reports"/codex-*.json)" = "preflight_only" ]
  [ "$(jq '[.scenarios[] | select(. == true)] | length' "$reports"/codex-*.json)" -eq 0 ]
  run rg -F "app-server inventory does not use the same configuration" "$reports"/codex-*.json
  [ "$status" -eq 0 ]
}
