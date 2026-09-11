#!/usr/bin/env bats

setup() {
  : "${BLUEPRINT_ROOT:?run via tests/bats/run.sh}"
  export TMP; TMP=$(mktemp -d)
  export HOME="$TMP/home"
  export AICODING_STATE_DIR="$TMP/state"
  export AICODING_DATA_DIR="$TMP/data"
  export AICODING_SYNC_MODE=boot
  export AICODINGSETUP_SKIP_NETWORK=
  mkdir -p "$HOME/.local/bin" "$TMP/stubs"
  export PATH="$HOME/.local/bin:$TMP/stubs:/usr/bin:/bin"
  . "$BLUEPRINT_ROOT/lib/update-results.sh"
  . "$BLUEPRINT_ROOT/lib/update-components.sh"
  . "$BLUEPRINT_ROOT/lib/provision.sh"
}

teardown() { rm -rf "$TMP"; }

_managed_launcher() {
  printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/$1"
  chmod +x "$HOME/.local/bin/$1"
  aicoding_result_record "$2" current "$3" installed "$3"
}

@test "scheduled provision migrates a recognized moving Context7 registration to the stable launcher" {
  _managed_launcher context7-mcp mcp-context7 4.1.0
  cat > "$TMP/stubs/claude" <<'EOF'
#!/bin/sh
echo "$*" >> "$TMP/claude-calls"
case "$*" in
  '--version') echo '2.1.50 (Claude Code)' ;;
  'mcp get context7')
    if [ -f "$TMP/migrated" ]; then
      printf 'Command: %s/.local/bin/context7-mcp\n' "$HOME"
    else
      printf 'Command: npx\nArgs: -y @upstash/context7-mcp\n'
    fi ;;
  'mcp remove -s user context7') : > "$TMP/removed" ;;
  'mcp add context7 -s user -- '*'/context7-mcp') : > "$TMP/migrated" ;;
esac
EOF
  chmod +x "$TMP/stubs/claude"
  run _provision_reconcile_exact_mcp context7 mcp-context7 context7-mcp
  [ "$status" -eq 0 ]
  [ -f "$TMP/migrated" ]
  grep -q 'mcp add context7 -s user -- .*/context7-mcp$' "$TMP/claude-calls"
}

@test "scheduled provision preserves an unrecognized user MCP registration as a conflict" {
  _managed_launcher context7-mcp mcp-context7 4.1.0
  cat > "$TMP/stubs/claude" <<'EOF'
#!/bin/sh
echo "$*" >> "$TMP/claude-calls"
case "$*" in
  '--version') echo '2.1.50 (Claude Code)' ;;
  'mcp get context7') printf 'Command: /user/custom-context7\nArgs: --custom\n' ;;
esac
EOF
  chmod +x "$TMP/stubs/claude"
  run _provision_reconcile_exact_mcp context7 mcp-context7 context7-mcp
  [ "$status" -ne 0 ]
  if grep -q 'mcp remove\|mcp add' "$TMP/claude-calls"; then false; fi
  jq -e '.components["mcp-context7"].state == "current"
    and .components["mcp-registration-claude-context7"].state == "conflict"' \
    "$AICODING_STATE_DIR/update-results.json"
}

@test "failed stable registration restores the recognized moving registration" {
  _managed_launcher playwright-mcp mcp-playwright 0.0.80
  cat > "$TMP/stubs/claude" <<'EOF'
#!/bin/sh
echo "$*" >> "$TMP/claude-calls"
case "$*" in
  '--version') echo '2.1.50 (Claude Code)' ;;
  'mcp get playwright') printf 'Command: npx\nArgs: @playwright/mcp@latest --browser chromium\n' ;;
  'mcp remove -s user playwright') exit 0 ;;
  'mcp add playwright -s user -- '*'/playwright-mcp --browser chromium') exit 7 ;;
  'mcp add playwright -s user -- npx @playwright/mcp@latest --browser chromium') : > "$TMP/restored" ;;
esac
EOF
  chmod +x "$TMP/stubs/claude"
  run _provision_reconcile_exact_mcp playwright mcp-playwright playwright-mcp --browser chromium
  [ "$status" -ne 0 ]
  [ -f "$TMP/restored" ]
  [ ! -e "$AICODING_STATE_DIR/registration-recovery/claude-playwright.json" ]
  jq -e '.components["mcp-playwright"].state == "current"
    and .components["mcp-registration-claude-playwright"].state == "failed"' \
    "$AICODING_STATE_DIR/update-results.json"
}

@test "scheduled Claude provisioning performs no user-state writes after a failed tool update" {
  _managed_launcher context7-mcp mcp-context7 4.1.0
  aicoding_result_record claude failed 2.1.51 stage_install_failed
  export AICODING_REQUIRE_UPDATE_RECEIPT=1
  cat > "$TMP/stubs/claude" <<'EOF'
#!/bin/sh
echo "$*" >> "$TMP/claude-calls"
case "$*" in
  '--version') echo '2.1.50 (Claude Code)' ;;
  'mcp get context7') printf 'Command: npx\nArgs: -y @upstash/context7-mcp\n' ;;
esac
EOF
  chmod +x "$TMP/stubs/claude"
  run _provision_reconcile_exact_mcp context7 mcp-context7 context7-mcp
  [ "$status" -ne 0 ]
  if grep -q 'mcp remove\|mcp add' "$TMP/claude-calls"; then false; fi
  jq -e '.components["mcp-registration-claude-context7"].state == "blocked"' \
    "$AICODING_STATE_DIR/update-results.json"
}

@test "exact MCP preprovision stages both packages and can force Claude registration" {
  aicoding_update_component() {
    printf '%s|%s|%s\n' "$1" "${AICODING_MCP_REGISTRATION_FORCE:-0}" \
      "${AICODING_MCP_REGISTRATION_DISABLE:-0}" >> "$TMP/prepared"
  }
  run aicoding_prepare_exact_mcps --register-claude
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/prepared")" = $'mcp-context7|1|0\nmcp-playwright|1|0' ]
  rm "$TMP/prepared"
  run aicoding_prepare_exact_mcps
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/prepared")" = $'mcp-context7|0|1\nmcp-playwright|0|1' ]
}

@test "offline exact MCP preprovision fails closed when local packages are not ready" {
  export AICODINGSETUP_SKIP_NETWORK=1
  aicoding_update_component() { : > "$TMP/network-called"; }

  run aicoding_prepare_exact_mcps
  [ "$status" -ne 0 ]
  [ ! -e "$TMP/network-called" ]
  jq -e '.components["mcp-context7"].state == "blocked"
    and .components["mcp-playwright"].state == "blocked"' \
    "$AICODING_STATE_DIR/update-results.json"
}

@test "scheduled tool readiness enforces shared inventory without a caller flag" {
  aicoding_result_record claude current 2.1.50 installed 2.1.50
  mkdir -p "$HOME/.claude"
  export AICODING_SHARED_CONFIG_ROOTS="$(readlink -f "$HOME/.claude")"
  export AICODING_SHARED_CONSUMERS_FILE="$TMP/missing-consumers.json"
  unset AICODING_REQUIRE_SHARED_COMPATIBILITY
  cat > "$TMP/stubs/claude" <<'EOF'
#!/bin/sh
echo '2.1.50 (Claude Code)'
EOF
  chmod +x "$TMP/stubs/claude"

  run _provision_tool_ready claude claude "" "$HOME/.claude"
  [ "$status" -ne 0 ]
  jq -e '.components["provision-claude"].reason == "claude_shared_consumers_incompatible"' \
    "$AICODING_STATE_DIR/update-results.json"
}

@test "scheduled Claude MCP migration enforces shared inventory before mutation" {
  _managed_launcher context7-mcp mcp-context7 4.1.0
  aicoding_result_record claude current 2.1.50 installed 2.1.50
  mkdir -p "$HOME/.claude"
  export AICODING_SHARED_CONFIG_ROOTS="$(readlink -f "$HOME/.claude")"
  export AICODING_SHARED_CONSUMERS_FILE="$TMP/missing-consumers.json"
  unset AICODING_REQUIRE_SHARED_COMPATIBILITY
  cat > "$TMP/stubs/claude" <<'EOF'
#!/bin/sh
echo "$*" >> "$TMP/claude-calls"
case "$*" in
  '--version') echo '2.1.50 (Claude Code)' ;;
  'mcp get context7') printf 'Command: npx\nArgs: -y @upstash/context7-mcp\n' ;;
esac
EOF
  chmod +x "$TMP/stubs/claude"

  run _provision_reconcile_exact_mcp context7 mcp-context7 context7-mcp
  [ "$status" -ne 0 ]
  if grep -q 'mcp remove\|mcp add' "$TMP/claude-calls"; then false; fi
  jq -e '.components["mcp-registration-claude-context7"].reason == "claude_consumers_incompatible"' \
    "$AICODING_STATE_DIR/update-results.json"
}

@test "missing actual Claude registration invalidates its prior success receipt" {
  _managed_launcher context7-mcp mcp-context7 4.1.0
  aicoding_result_record mcp-registration-claude-context7 current 4.1.0 registration_verified 4.1.0
  cat > "$TMP/stubs/claude" <<'EOF'
#!/bin/sh
case "$*" in '--version') echo '2.1.50 (Claude Code)' ;; 'mcp get context7') exit 1 ;; esac
EOF
  chmod +x "$TMP/stubs/claude"

  run _provision_reconcile_exact_mcp context7 mcp-context7 context7-mcp
  [ "$status" -eq 0 ]
  jq -e '.components["mcp-registration-claude-context7"].state == "blocked"
    and .components["mcp-registration-claude-context7"].reason == "registration_not_selected"' \
    "$AICODING_STATE_DIR/update-results.json"
}

@test "failed registration restoration keeps recovery material and reports rollback failure" {
  _managed_launcher playwright-mcp mcp-playwright 0.0.80
  cat > "$TMP/stubs/claude" <<'EOF'
#!/bin/sh
echo "$*" >> "$TMP/claude-calls"
case "$*" in
  '--version') echo '2.1.50 (Claude Code)' ;;
  'mcp get playwright') printf 'Command: npx\nArgs: @playwright/mcp@latest --browser chromium\n' ;;
  'mcp remove -s user playwright') exit 0 ;;
  'mcp add playwright -s user -- '*'/playwright-mcp --browser chromium') exit 7 ;;
  'mcp add playwright -s user -- npx @playwright/mcp@latest --browser chromium') exit 9 ;;
esac
EOF
  chmod +x "$TMP/stubs/claude"

  run _provision_reconcile_exact_mcp playwright mcp-playwright playwright-mcp --browser chromium
  [ "$status" -ne 0 ]
  jq -e '.components["mcp-registration-claude-playwright"].reason == "registration_rollback_restore_failed"' \
    "$AICODING_STATE_DIR/update-results.json"
  jq -e '.command == "npx" and .args == ["@playwright/mcp@latest","--browser","chromium"]' \
    "$AICODING_STATE_DIR/registration-recovery/claude-playwright.json"
}

@test "scheduled provision skips an exact MCP that is not registered or enabled" {
  cat > "$TMP/stubs/claude" <<'EOF'
#!/bin/sh
case "$*" in '--version') echo '2.1.50 (Claude Code)' ;; esac
EOF
  chmod +x "$TMP/stubs/claude"
  run _provision_reconcile_selected_exact_mcp context7 mcp-context7 context7-mcp
  [ "$status" -eq 0 ]
  [ ! -f "$AICODING_STATE_DIR/update-results.json" ]
}
