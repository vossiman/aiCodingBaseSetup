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
