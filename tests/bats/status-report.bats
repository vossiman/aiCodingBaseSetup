#!/usr/bin/env bats

setup() {
  : "${BLUEPRINT_ROOT:?run via tests/bats/run.sh}"
  TMP=$(mktemp -d)
  export HOME="$TMP/home" AICODING_STATE_DIR="$TMP/state" AICODING_DATA_DIR="$TMP/data"
  export AICODING_RESULTS_FILE="$TMP/state/update-results.json"
  export TZ=Europe/Vienna
  # importlib-based clock/lock tests must not write lib/__pycache__ into the
  # shared checkout while parallel host-installer tests tar that source tree.
  export PYTHONDONTWRITEBYTECODE=1
  BIN="$BLUEPRINT_ROOT/bin/aicoding-status"
  AUTO="$AICODING_STATE_DIR/auto-update"
  mkdir -p "$HOME" "$AUTO" "$TMP/stubs"
  export STATUS_COMMAND_LOG="$TMP/commands"
  for name in claude codex opencode agent cursor-agent pi dvw bw claude-bw firecrawl-mcp brave-search-mcp-server context7-mcp playwright-mcp aicoding-auto-update git curl npm; do
    cat > "$TMP/stubs/$name" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >> "$STATUS_COMMAND_LOG"
case "${0##*/}" in
  claude|codex|opencode|agent|cursor-agent|pi|dvw)
    [ "$*" = --version ] || exit 90
    echo '1.2.3';;
  *) exit 91;;
esac
STUB
    chmod +x "$TMP/stubs/$name"
  done
  cat > "$TMP/stubs/systemctl" <<'STUB'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$STATUS_COMMAND_LOG"
[ "$1 $2" = '--user show' ] || exit 92
case "$3" in
  *.timer) printf '%s\n' "${STATUS_TIMER:-LoadState=not-found}" ;;
  *.service) printf '%s\n' "${STATUS_SERVICE:-LoadState=not-found}" ;;
esac
STUB
  chmod +x "$TMP/stubs/systemctl"
  export PATH="$TMP/stubs:$PATH"
  unset STATUS_TIMER STATUS_SERVICE
}

teardown() {
  if [ -n "${HOLDER:-}" ]; then
    kill "$HOLDER" 2>/dev/null || true
    wait "$HOLDER" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}

start_holder() {
  local kind=$1
  cat > "$TMP/aicoding-auto-update" <<'WORKER'
#!/usr/bin/env bash
exec 9>"$1/$2.lock"
flock 9
printf '%s\n' "$$" > "$1/$2.pid"
if [ "$2" = run ]; then
  ticks=$(awk '{print $22}' "/proc/$$/stat")
  jq -n --argjson pid "$$" --argjson ticks "$ticks" '{pid:$pid,start_ticks:$ticks,source:"manual"}' > "$1/run.json"
fi
printf ready > "$1/ready"
# exec retains both PID and lock without leaving a sleep grandchild behind.
exec python3 -c 'import time; time.sleep(60)' aicoding-auto-update --worker
WORKER
  chmod +x "$TMP/aicoding-auto-update"
  "$TMP/aicoding-auto-update" "$AUTO" "$kind" --worker &
  HOLDER=$!
  for unused in $(seq 1 100); do
    [ -f "$AUTO/ready" ] && return 0
    sleep .02
  done
  false
}

@test "default missing state is useful read only and does not claim tools current" {
  rm -rf "$AICODING_STATE_DIR"
  run "$BIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Scheduler: not detected"* ]]
  [[ "$output" == *"Last completed outcome: not recorded"* ]]
  [[ "$output" == *"Next scheduled run: none verified"* ]]
  [[ "$output" == *"does not establish that every tool is current"* ]]
  [[ "$output" == *"aicoding-auto-update --once"* ]]
  [ ! -e "$AICODING_STATE_DIR" ]
  if grep -E '^(aicoding-auto-update|npm|git|curl|firecrawl-mcp|brave-search-mcp-server|context7-mcp|playwright-mcp) ' "$STATUS_COMMAND_LOG"; then false; fi
}

@test "dead worker PID and overdue timestamps do not prove scheduling" {
  printf '99999999\n' > "$AUTO/worker.pid"
  touch "$AUTO/worker.lock"
  printf '1704067200\n' > "$AUTO/next-due"
  printf '1704067100\n' > "$AUTO/last-success"
  run "$BIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dead or stale worker state"* ]]
  [[ "$output" == *"Next scheduled run: none verified"* ]]
  [[ "$output" == *"Saved fallback due time: 2024-01-01 01:00:00 CET"* ]]
  [[ "$output" == *"later outcomes unknown"* ]]
}

@test "fallback alive verifies identity and lock and labels overdue retry" {
  start_holder worker
  printf '1704067200\n' > "$AUTO/next-due"
  run "$BIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"detached fallback worker — alive"* ]]
  [[ "$output" == *"overdue; running or retry/backoff may delay it"* ]]
}

@test "fallback matching live PID with an unlocked worker file is stale" {
  start_holder worker
  mv "$AUTO/worker.lock" "$AUTO/held-old.lock"
  touch "$AUTO/worker.lock"
  run "$BIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dead or stale worker state"* ]]
}

@test "manual ongoing run and last deferred outcome are distinct" {
  start_holder run
  printf '1704067200\n' > "$AUTO/last-attempt"
  printf '%s\n' '{"started_at":1704000000,"completed_at":1704000060,"outcome":"deferred","exit_code":75,"source":"fallback"}' > "$AUTO/last-completed.json"
  run "$BIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Update: running (manual)"* ]]
  [[ "$output" == *"completed with deferred work"* ]]
  [[ "$output" == *"Last attempt: 2024-01-01 01:00:00 CET"* ]]
}

@test "stale run with recycled PID start time is not running" {
  start_holder run
  jq '.start_ticks = 1' "$AUTO/run.json" > "$AUTO/run-new.json"
  mv "$AUTO/run-new.json" "$AUTO/run.json"
  run "$BIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"run lock is held; owner could not be verified"* ]]
  if [[ "$output" == *"Update: running"* ]]; then false; fi
}

@test "systemd timer and active service report live running and local next realtime" {
  export STATUS_TIMER=$'LoadState=loaded\nActiveState=active\nSubState=waiting\nNextElapseUSecRealtime=2035-01-01 00:00:00 UTC'
  export STATUS_SERVICE=$'LoadState=loaded\nActiveState=activating\nSubState=start'
  run "$BIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"systemd user timer — alive"* ]]
  [[ "$output" == *"Update: running (systemd)"* ]]
  [[ "$output" == *"Next scheduled run: 2035-01-01 01:00:00 CET"* ]]
  if grep -E ' (start|restart|enable|daemon-reload) ' "$STATUS_COMMAND_LOG"; then false; fi
}

@test "systemd monotonic timer computes future schedule instead of fallback timestamp" {
  local next
  next=$(awk '{printf "%.0f", ($1 + 3600) * 1000000}' /proc/uptime)
  export STATUS_TIMER="LoadState=loaded
ActiveState=active
SubState=waiting
NextElapseUSecRealtime=n/a
NextElapseUSecMonotonic=$next"
  printf '1704067200\n' > "$AUTO/next-due"
  run "$BIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Next scheduled run: $(date -d '+1 hour' '+%Y-%m-%d')"* ]]
  if [[ "$output" == *"overdue;"* ]]; then false; fi
}

@test "inactive systemd and failed completed outcome are explicit" {
  export STATUS_TIMER=$'LoadState=loaded\nActiveState=inactive\nSubState=dead'
  printf '%s\n' '{"completed_at":1704067200,"outcome":"failed","exit_code":1,"source":"systemd"}' > "$AUTO/last-completed.json"
  run "$BIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"systemd user timer — not active (inactive)"* ]]
  [[ "$output" == *"Last completed outcome: failed at 2024-01-01 01:00:00 CET (systemd; exit 1)"* ]]
}

@test "versions cover all supported tools using package metadata and managed Chromium" {
  local key package
  for key in mcp-firecrawl mcp-brave mcp-context7 mcp-playwright; do
    case "$key" in
      mcp-firecrawl) package=firecrawl-mcp;;
      mcp-brave) package=@brave/brave-search-mcp-server;;
      mcp-context7) package=@upstash/context7-mcp;;
      mcp-playwright) package=@playwright/mcp;;
    esac
    mkdir -p "$AICODING_DATA_DIR/versions/$key/4.5.6/node_modules/$package" "$AICODING_DATA_DIR/current"
    printf '{"version":"4.5.6"}\n' > "$AICODING_DATA_DIR/versions/$key/4.5.6/node_modules/$package/package.json"
    ln -s "../versions/$key/4.5.6" "$AICODING_DATA_DIR/current/$key"
  done
  mkdir -p "$AICODING_DATA_DIR/versions/bw-AICode/abc"
  printf 'abc\n' > "$AICODING_DATA_DIR/versions/bw-AICode/abc/.aicoding-version"
  ln -s ../versions/bw-AICode/abc "$AICODING_DATA_DIR/current/bw-AICode"
  local cache="$AICODING_DATA_DIR/browser-cache/mcp-playwright/4.5.6"
  mkdir -p "$cache"
  printf '#!/bin/sh\necho Chromium 140.1.2.3\n' > "$cache/chrome"
  chmod +x "$cache/chrome"
  printf '%s\n' "$cache/chrome" > "$cache/.browser-bin"
  run "$BIN"
  [ "$status" -eq 0 ]
  for key in Claude Codex OpenCode 'Cursor CLI' Pi dvw; do
    [[ "$output" == *"$key: 1.2.3 (local version probe)"* ]]
  done
  for key in Firecrawl Brave Context7 Playwright; do
    [[ "$output" == *"$key MCP: 4.5.6 (selected local release)"* ]]
  done
  [[ "$output" == *"bw-AICode: abc (selected local release)"* ]]
  [[ "$output" == *"Playwright Chromium: Chromium 140.1.2.3"* ]]
}

@test "saved results show freshness and unresolved rows separately from recovered rows" {
  cat > "$AICODING_RESULTS_FILE" <<'JSON'
{"schema":1,"components":{
  "cursor":{"state":"current","successful_version":"1.2.3","attempted_at":"2024-01-01T00:00:00Z","reason":"verified"},
  "config-cursor":{"state":"current","attempted_at":"2024-01-01T00:00:00Z","reason":"all_destinations_reconciled"},
  "config-codex":{"state":"blocked","attempted_at":"2024-01-01T00:00:00Z","reason":"mcp_exact_version_staging_unavailable"},
  "config":{"state":"conflict","attempted_at":"2024-01-01T00:00:00Z","reason":"managed_config_conflict"}}}
JSON
  run "$BIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"days ago; recorded, not rechecked"* ]]
  [[ "$output" == *"mcp exact version staging unavailable"* ]]
  local blockers="${output#*Unresolved recorded blockers}"
  [[ "$blockers" == *"config-codex: blocked"* ]]
  [[ "$blockers" == *"config: conflict"* ]]
  if [[ "$blockers" == *"config-cursor:"* ]]; then false; fi
}

@test "malformed state degrades to unknown without breaking status" {
  printf '{broken\n' > "$AUTO/run.json"
  printf '{broken\n' > "$AICODING_RESULTS_FILE"
  printf 'not a date\n' > "$AUTO/last-attempt"
  run "$BIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Last attempt: unknown"* ]]
  [[ "$output" == *"no update result recorded"* ]]
}

@test "worker PID pointing at another runtime with a separately held lock is rejected" {
  start_holder worker
  mv "$AUTO/worker.lock" "$AUTO/other-runtime.lock"
  (
    exec 8>"$AUTO/worker.lock"
    flock 8
    "$BIN" > "$TMP/output"
  )
  run cat "$TMP/output"
  [[ "$output" == *"dead or stale worker state"* ]]
}

@test "held sync lock reports remaining work after controller disappeared" {
  printf '{"pid":99999999,"start_ticks":1}\n' > "$AUTO/run.json"
  (
    exec 8>"$AICODING_STATE_DIR/sync.lock"
    flock 8
    "$BIN" > "$TMP/output"
  )
  run cat "$TMP/output"
  [[ "$output" == *"sync/install lock held; activity owner unknown"* ]]
}

@test "nonfinite saved timestamps and unknown target fields stay readable" {
  printf '{"components":{"config":{"state":"blocked","attempted_at":NaN,"target_version":"abc","reason":"preparation_deferred"}}}\n' > "$AICODING_RESULTS_FILE"
  run "$BIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"age unknown"* ]]
  [[ "$output" == *"target abc"* ]]
}

@test "systemd running source ignores stale fallback record and incomplete service state" {
  export STATUS_SERVICE=$'LoadState=loaded\nActiveState=activating\nSubState=start'
  printf '{"pid":99999999,"start_ticks":1,"source":"fallback"}\n' > "$AUTO/run.json"
  run "$BIN"
  [[ "$output" == *"Update: running (systemd)"* ]]
  export STATUS_SERVICE=$'ActiveState=active'
  run "$BIN"
  [[ "$output" == *"interrupted/stale run record remains"* ]]
}

@test "monotonic schedule uses suspend-excluding clock" {
  export STATUS_TIMER=$'LoadState=loaded\nActiveState=active\nSubState=waiting\nNextElapseUSecMonotonic=1000000000'
  run python3 - "$BLUEPRINT_ROOT/lib/status-report.py" <<'PY'
import importlib.util
import sys
spec = importlib.util.spec_from_file_location('status_report', sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.time.time = lambda: 1704067200
module.time.monotonic = lambda: 100
module.scheduler()
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *"Next scheduled run: 2024-01-01 01:15:00 CET"* ]]
}

@test "foreign WSL CLI is excluded without executing it" {
  mkdir -p "$TMP/windows"
  mv "$TMP/stubs/claude" "$TMP/windows/claude"
  ln -s "$TMP/windows/claude" "$TMP/stubs/claude"
  export AICODING_WSL_MOUNT_PREFIX="$TMP/windows/"
  run "$BIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Not detected locally:"*"Claude"* ]]
  if grep '^claude ' "$STATUS_COMMAND_LOG"; then false; fi
}

@test "effective CLI version is visible even when a different managed release is selected" {
  mkdir -p "$AICODING_DATA_DIR/versions/claude/9.9.9" "$AICODING_DATA_DIR/current"
  ln -s ../versions/claude/9.9.9 "$AICODING_DATA_DIR/current/claude"
  run "$BIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Claude: 1.2.3 (local version probe); selected local release 9.9.9"* ]]
}

@test "legacy bw vendor checkout revision is detected without invoking bw" {
  mkdir -p "$AICODING_DATA_DIR/vendor/bw-AICode/.git"
  cat > "$TMP/stubs/git" <<'STUB'
#!/bin/sh
[ "$3 $4 $5" = 'rev-parse --verify HEAD' ] || exit 92
printf '1111111111111111111111111111111111111111\n'
STUB
  run "$BIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bw-AICode: 1111111111111111111111111111111111111111 (local vendor checkout; working tree may differ)"* ]]
  if grep -E '^(bw|claude-bw) ' "$STATUS_COMMAND_LOG"; then false; fi
}

@test "malformed nested record shapes degrade to unknown" {
  printf '{"outcome":[],"completed_at":null}\n' > "$AUTO/last-completed.json"
  printf '{"components":{"config":{"state":[],"reason":[],"attempted_at":{}}}}\n' > "$AICODING_RESULTS_FILE"
  run "$BIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unknown outcome"* ]]
  [[ "$output" == *"age unknown"* ]]
}

@test "Chromium has its own update receipt independent of Playwright MCP success" {
  printf '%s\n' '{"components":{"mcp-playwright":{"state":"current","reason":"verified","attempted_at":"2024-01-01T00:00:00Z"},"playwright-chromium":{"state":"failed","reason":"browser_install_failed","attempted_at":"2024-01-01T00:00:01Z"}}}' > "$AICODING_RESULTS_FILE"
  run "$BIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Last browser update: failed — browser install failed"* ]]
  [[ "${output#*Unresolved recorded blockers}" == *"playwright-chromium: failed"* ]]
}

@test "cyclic selected release symlinks leave the report usable" {
  mkdir -p "$AICODING_DATA_DIR/current"
  ln -s claude "$AICODING_DATA_DIR/current/claude"
  ln -s mcp-playwright "$AICODING_DATA_DIR/current/mcp-playwright"
  run "$BIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Claude: 1.2.3 (local version probe)"* ]]
  [[ "$output" == *"aicoding-auto-update --once"* ]]
}

@test "systemd long uptime spans retain years and months and reject partial parsing" {
  run python3 - "$BLUEPRINT_ROOT/lib/status-report.py" <<'PY'
import contextlib, importlib.util, io, sys
spec = importlib.util.spec_from_file_location("report", sys.argv[1])
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)
report.time.time = lambda: 1704067200
report.time.monotonic = lambda: 31557600 + 2629800
for span, expected in (("1y 1month 15min", "2024-01-01 01:15:00 CET"),
                       ("1unexpected 15min", "Next scheduled run: unknown")):
    report.systemd = lambda unit: {"LoadState": "loaded", "ActiveState": "active",
        "NextElapseUSecMonotonic": span} if unit.endswith(".timer") else {}
    capture = io.StringIO()
    with contextlib.redirect_stdout(capture):
        report.scheduler()
    assert expected in capture.getvalue(), capture.getvalue()
PY
  [ "$status" -eq 0 ]
}

@test "status observes free and held locks without ever acquiring flock" {
  start_holder worker
  touch "$AUTO/free.lock"
  run python3 - "$BLUEPRINT_ROOT/lib/status-report.py" "$AUTO" "$HOLDER" <<'PY'
import fcntl
import importlib.util
from pathlib import Path
import sys

def forbidden_flock(*args):
    raise AssertionError('status attempted to acquire an updater lock')

fcntl.flock = forbidden_flock
spec = importlib.util.spec_from_file_location('status_report', sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
state = Path(sys.argv[2])
# start_holder acquires via the short-lived `flock FD` utility and then execs
# Python with the descriptor retained. Force /proc/locks omission to exercise
# Linux's inherited PID-0 lock case on every runner, including other kernels.
original_read = module.read
module.read = lambda path: '' if path == Path('/proc/locks') else original_read(path)
assert not module.lock_held(state / 'free.lock')
assert module.lock_held(state / 'worker.lock')
assert module.owns_lock(sys.argv[3], state / 'worker.lock')
module.main()
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *"detached fallback worker — alive"* ]]
}

@test "having another process locked inode open does not prove lock ownership" {
  start_holder worker
  run python3 - "$BLUEPRINT_ROOT/lib/status-report.py" "$AUTO/worker.lock" <<'PY'
import importlib.util
import os
from pathlib import Path
import sys
spec = importlib.util.spec_from_file_location('status_report', sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
path = Path(sys.argv[2])
with path.open() as unrelated_open_description:
    assert module.lock_held(path)
    assert not module.owns_lock(os.getpid(), path)
PY
  [ "$status" -eq 0 ]
}

@test "browser version display preserves Playwright Chrome for Testing branding" {
  local cache="$AICODING_DATA_DIR/browser-cache/mcp-playwright/0.0.80"
  mkdir -p "$cache" "$AICODING_DATA_DIR/current" "$AICODING_DATA_DIR/versions/mcp-playwright/0.0.80"
  ln -s ../versions/mcp-playwright/0.0.80 "$AICODING_DATA_DIR/current/mcp-playwright"
  printf '#!/bin/sh\nprintf "Google Chrome for Testing 147.0.7718.0\\n"\n' > "$cache/chrome"
  chmod +x "$cache/chrome"
  printf '%s\n' "$cache/chrome" > "$cache/.browser-bin"
  run "$BIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Playwright Chromium: Google Chrome for Testing 147.0.7718.0"* ]]
}

@test "status helper imports never write bytecode into their source tree" {
  mkdir -p "$TMP/import-source"
  cp "$BLUEPRINT_ROOT/lib/status-report.py" "$TMP/import-source/status-report.py"
  run python3 - "$TMP/import-source/status-report.py" <<'PY'
import importlib.util
from pathlib import Path
import sys
source = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('status_report', source)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
assert sorted(path.name for path in source.parent.iterdir()) == ['status-report.py']
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
