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
    grep -q "completed" "$TMP/progress"
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
