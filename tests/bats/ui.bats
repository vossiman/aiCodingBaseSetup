#!/usr/bin/env bats
setup() {
  export TMP; TMP=$(mktemp -d)
  export HOME="$TMP/home"
  mkdir -p "$HOME" "$TMP/bin"
  export AICODING_PROGRESS_INTERVAL=0.1
  cat >"$TMP/bin/claude" <<'EOF'
#!/bin/bash
case "$*" in
  *"install hung"*) trap '' TERM; sleep 30 & wait; sleep 30 ;;
  *uninstall*) exit 1 ;;
  *"install fresh"*) echo 'Installed' ;;
  *install*) echo '✔ Plugin "x" is already installed (scope: user)' ;;
esac
EOF
  chmod +x "$TMP/bin/claude"
  cat >"$TMP/plugins.sh" <<EOF
export PATH="$TMP/bin:\$PATH" AICODING_SYNC_MODE=interactive
export AICODING_PROVISION_TIMEOUT=1 AICODING_PROVISION_KILL_AFTER=1
. "$BLUEPRINT_ROOT/lib/provision.sh"
_provision_tool_ready() { return 0; }
MANAGED_PLUGINS=(present@x hung@x fresh@x)
aicoding_ui_begin
install_claude_plugins; rc=\$?
aicoding_ui_summary "\$rc"
exit "\$rc"
EOF
}
teardown() {
  pkill -f "$TMP/bin/claude" 2>/dev/null || true
  rm -rf "$TMP"
}

@test "plugin step off a terminal names each command and hard-kills a hung one" {
  run bash "$TMP/plugins.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"… hung: claude plugin install hung@x"* ]]
  [[ "$output" == *"✖ hung"*"install timed out after 1s"* ]]
  [[ "$output" == *"✔ present"*"up to date"* ]]
  [[ "$output" == *"✔ fresh"*"installed"* ]]
  # A timed-out install must not fall through to an update that hangs again.
  if [[ "$output" == *"claude plugin update hung@x"* ]]; then false; fi
  if pgrep -f "$TMP/bin/claude" >/dev/null; then false; fi
}

@test "on a terminal the plugin step renders result lines and a summary" {
  command -v script >/dev/null || skip "script(1) unavailable"
  run script -qec "TERM=xterm bash $TMP/plugins.sh" /dev/null
  [[ "$output" == *"Claude Code Plugins"* ]]
  [[ "$output" == *"✔"*"present"*"up to date"* ]]
  [[ "$output" == *"✖"*"hung"*"timed out"* ]]
  [[ "$output" == *"2 ok"*"1 failed"* ]]
  # The terminal view replaces the log-style command lines.
  if [[ "$output" == *"… present: claude"* ]]; then false; fi
}

@test "progress keeps the plain log format when stderr is not a terminal" {
  run bash -c '
    . "$BLUEPRINT_ROOT/lib/update-progress.sh"
    aicoding_ui_active && exit 3
    aicoding_progress_run "fixture: step" true 2>"$TMP/progress"
    grep -q "OK: fixture: step (" "$TMP/progress"
  '
  [ "$status" -eq 0 ]
}

@test "NO_COLOR and AICODING_PLAIN keep the plain format on a terminal" {
  command -v script >/dev/null || skip "script(1) unavailable"
  run script -qec "TERM=xterm NO_COLOR=1 bash -c '. $BLUEPRINT_ROOT/lib/ui.sh; aicoding_ui_active && echo ACTIVE || echo PLAIN'" /dev/null
  [[ "$output" == *PLAIN* ]]
  run script -qec "TERM=xterm AICODING_PLAIN=1 bash -c '. $BLUEPRINT_ROOT/lib/ui.sh; aicoding_ui_active && echo ACTIVE || echo PLAIN'" /dev/null
  [[ "$output" == *PLAIN* ]]
}
