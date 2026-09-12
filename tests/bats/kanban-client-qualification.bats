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

@test "all-client preflight contains a hung process tree and continues without traceback" {
  fakebin="$BATS_TEST_TMPDIR/bin"
  reports="$BATS_TEST_TMPDIR/all-reports"
  child_pid="$BATS_TEST_TMPDIR/version-child.pid"
  mkdir -p "$fakebin"
  cat >"$fakebin/claude" <<PY
#!/usr/bin/env python3
import pathlib, subprocess, sys, time
child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
pathlib.Path("$child_pid").write_text(str(child.pid))
time.sleep(30)
PY
  cat >"$fakebin/codex" <<'SH'
#!/usr/bin/env sh
printf '%s\n' 'codex-cli 0.154.0'
SH
  cat >"$fakebin/agent" <<'SH'
#!/usr/bin/env sh
printf '%s\n' '2026.09.10-fd3934a'
SH
  cat >"$fakebin/opencode" <<'SH'
#!/usr/bin/env sh
printf '%s\n' '1.18.30'
SH
  chmod +x "$fakebin"/*

  PATH="$fakebin:$PATH" run tools/qualify-kanban-clients --all --output "$reports"
  [ "$status" -eq 1 ]
  [[ "$output" != *"Traceback"* ]]
  [ "$(find "$reports" -maxdepth 1 -name '*.json' | wc -l)" -eq 4 ]
  run rg -F "timed out" "$reports"/claude-*.json
  [ "$status" -eq 0 ]
  pid=$(cat "$child_pid")
  if kill -0 "$pid" 2>/dev/null; then
    fail "version probe left child process $pid running"
  fi
}
