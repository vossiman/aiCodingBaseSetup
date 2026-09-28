#!/usr/bin/env bats
setup() {
  export TMP; TMP=$(mktemp -d)
  export HOME="$TMP/home"
  mkdir -p "$HOME"
  export AICODING_PROGRESS_INTERVAL=0.1
}
teardown() { rm -rf "$TMP"; }

@test "long update operations report progress without contaminating result stdout" {
  run bash -c '
    . "$BLUEPRINT_ROOT/lib/update-progress.sh"
    aicoding_progress_run "fixture: download (timeout 2s)" bash -c "sleep 0.35; printf result" >"$TMP/result" 2>"$TMP/progress"
    test "$(cat "$TMP/result")" = result
    grep -q "fixture: download" "$TMP/progress"
    grep -q "still running" "$TMP/progress"
    grep -q "OK: fixture: download (" "$TMP/progress"
    if grep -q "timeout 2s" "$TMP/progress"; then exit 1; fi
  '
  [ "$status" -eq 0 ]
}

@test "plain progress follows the recorded log while failures stay on stderr" {
  run bash -c '
    . "$BLUEPRINT_ROOT/lib/update-progress.sh"
    {
      aicoding_progress_log_here
      aicoding_progress_run "fixture: fetch (timeout 2s)" bash -c "sleep 0.35; printf result" >"$TMP/result" 2>"$TMP/err"
    } >"$TMP/log"
    test "$(cat "$TMP/result")" = result || exit 1
    test ! -s "$TMP/err" || exit 2
    grep -q "still running" "$TMP/log" || exit 3
    grep -qxE "  OK: fixture: fetch \([0-9]+s\)" "$TMP/log" || exit 4
    if grep -q "starting" "$TMP/log"; then exit 5; fi
    aicoding_progress_run "fixture: broken" bash -c "exit 7" 2>"$TMP/err"
    test "$?" = 7 || exit 6
    grep -q "WARN: fixture: broken — failed" "$TMP/err" || exit 7
  '
  [ "$status" -eq 0 ]
}

@test "a detached daemon does not hold the recorded log open or write to it" {
  command -v setsid >/dev/null || skip "setsid unavailable"
  run bash -c '
    started=$SECONDS
    bash -c "
      . \"\$BLUEPRINT_ROOT/lib/update-progress.sh\"
      aicoding_progress_log_here
      setsid bash -c \". \\\"\$BLUEPRINT_ROOT/lib/update-progress.sh\\\"; aicoding_progress_log daemon-line; sleep 5\" </dev/null >/dev/null 2>&1 &
      sleep 0.3
      aicoding_progress_log parent-line
    " | cat >"$TMP/log"
    test $((SECONDS - started)) -lt 3 || exit 1
    grep -qx parent-line "$TMP/log" || exit 2
    if grep -q daemon-line "$TMP/log"; then exit 3; fi
  '
  [ "$status" -eq 0 ]
}

@test "operation failures preserve exit status and report timeout" {
  run bash -c '
    . "$BLUEPRINT_ROOT/lib/update-progress.sh"
    aicoding_progress_run "fixture: download" timeout 0.2 sleep 5 >"$TMP/result" 2>"$TMP/progress"
    rc=$?
    test "$rc" = 124 || exit 1
    grep -q "timed out" "$TMP/progress"
  '
  [ "$status" -eq 0 ]
}

@test "progress stops with its operation and does not print command arguments" {
  run bash -c '
    . "$BLUEPRINT_ROOT/lib/update-progress.sh"
    aicoding_progress_run "fixture: probe" bash -c "exit 7" private-argument >"$TMP/result" 2>"$TMP/progress"
    test "$?" = 7 || exit 1
    before=$(wc -c <"$TMP/progress")
    sleep 0.3
    test "$before" = "$(wc -c <"$TMP/progress")" || exit 1
    if grep -q private-argument "$TMP/progress"; then exit 1; fi
  '
  [ "$status" -eq 0 ]
}

@test "shipped agent-working hook is recognized by unmanaged detector" {
  run bash -c '
    SCRIPT_DIR="$BLUEPRINT_ROOT"
    CLAUDE_DIR="$HOME/.claude"
    mkdir -p "$CLAUDE_DIR/hooks"
    cp "$SCRIPT_DIR/configs/claude/hooks/agent-working.sh" "$CLAUDE_DIR/hooks/"
    . "$SCRIPT_DIR/lib/provision-managed-files.sh"
    claude() { return 0; }
    header() { :; }
    info() { echo "$*"; }
    report_unmanaged
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *"agent-working.sh"* ]]
}

@test "cancelling a progress operation stops its descendants before returning" {
  cat > "$TMP/operation.sh" <<'SCRIPT'
printf '%s' "$PPID" >"$TMP/wrapper"
sleep 2
touch "$TMP/late-write"
SCRIPT
  run bash -c '
    . "$BLUEPRINT_ROOT/lib/update-progress.sh"
    aicoding_progress_run fixture bash "$TMP/operation.sh" >"$TMP/output" 2>&1 & outer=$!
    for _ in {1..50}; do [ -s "$TMP/wrapper" ] && break; sleep 0.02; done
    kill -TERM "$(cat "$TMP/wrapper")"
    wait "$outer" 2>/dev/null || true
    sleep 2.1
    test ! -e "$TMP/late-write"
  '
  [ "$status" -eq 0 ]
}

@test "cancellation also stops commands supervised by nested timeout" {
  cat > "$TMP/operation.sh" <<'SCRIPT'
sleep 2
touch "$TMP/late-write"
SCRIPT
  run bash -c '
    . "$BLUEPRINT_ROOT/lib/update-progress.sh"
    operation() { printf "%s" "$BASHPID" >"$TMP/job"; timeout 5 bash "$TMP/operation.sh"; }
    aicoding_progress_run fixture operation >"$TMP/output" 2>&1 & outer=$!
    for _ in {1..50}; do [ -s "$TMP/job" ] && break; sleep 0.02; done
    wrapper=$(ps -o ppid= -p "$(cat "$TMP/job")" | tr -d " ")
    kill -TERM "$wrapper"
    wait "$outer" 2>/dev/null || true
    sleep 2.1
    test ! -e "$TMP/late-write"
  '
  [ "$status" -eq 0 ]
}
