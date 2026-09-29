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
  aicoding_result_record claude current 2.1.50 installed 2.1.50
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
  aicoding_result_record claude current 2.1.50 installed 2.1.50
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
  aicoding_result_record claude current 2.1.50 installed 2.1.50
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

@test "exact MCP preprovision stages all packages and can force Claude registration" {
  aicoding_update_component() {
    printf '%s|%s|%s\n' "$1" "${AICODING_MCP_REGISTRATION_FORCE:-0}" \
      "${AICODING_MCP_REGISTRATION_DISABLE:-0}" >> "$TMP/prepared"
  }
  run aicoding_prepare_exact_mcps --register-claude
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/prepared")" = $'mcp-context7|1|0\nmcp-playwright|1|0\nmcp-kanban|1|0' ]
  rm "$TMP/prepared"
  run aicoding_prepare_exact_mcps
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/prepared")" = $'mcp-context7|0|1\nmcp-playwright|0|1\nmcp-kanban|0|1' ]
}

@test "offline exact MCP preprovision reports a nonfatal deferral when local packages are not ready" {
  export AICODINGSETUP_SKIP_NETWORK=1
  aicoding_update_component() { : > "$TMP/network-called"; }

  aicoding_prepare_exact_mcps
  [ "$?" -eq 0 ]
  [ "${_AICODING_PREPARATION_DEFERRED:-0}" -eq 1 ]
  [ ! -e "$TMP/network-called" ]
  jq -e '.components["mcp-context7"].state == "blocked"
    and .components["mcp-playwright"].state == "blocked"
    and .components["mcp-kanban"].state == "blocked"
    and .components["mcp-kanban"].reason == "offline_exact_package_not_ready"' \
    "$AICODING_STATE_DIR/update-results.json"
}

@test "scheduled provision adds an exact user-scope Kanban registration" {
  _managed_launcher kanban-mcp mcp-kanban a71a8bdcd12e39fcb74be3ecc0e45f757118f0e3
  aicoding_result_record claude current 2.1.50 installed 2.1.50
  cat > "$TMP/stubs/claude" <<'EOF'
#!/bin/sh
echo "$*" >> "$TMP/claude-calls"
case "$*" in
  '--version') echo '2.1.50 (Claude Code)' ;;
  'mcp get kanban')
    [ -f "$TMP/registered-kanban" ] || exit 1
    printf 'Command: %s/.local/bin/kanban-mcp\nArgs: \n' "$HOME" ;;
  'mcp add kanban -s user -- '*'/kanban-mcp') : > "$TMP/registered-kanban" ;;
esac
EOF
  chmod +x "$TMP/stubs/claude"

  AICODING_MCP_REGISTRATION_FORCE=1 run _provision_reconcile_exact_mcp \
    kanban mcp-kanban kanban-mcp

  [ "$status" -eq 0 ]
  grep -q 'mcp add kanban -s user -- .*/kanban-mcp$' "$TMP/claude-calls"
  jq -e '.components["mcp-registration-claude-kanban"].state == "updated"' \
    "$AICODING_RESULTS_FILE"
}

@test "Kanban is included in managed MCP inventory" {
  run printf '%s\n' "${MANAGED_MCPS[@]}"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Fxq kanban
}

@test "scheduled exact registration cannot bypass a missing Claude receipt" {
  _managed_launcher context7-mcp mcp-context7 4.1.0
  cat > "$TMP/stubs/claude" <<'EOF'
#!/bin/sh
echo "$*" >> "$TMP/claude-calls"
case "$*" in
  '--version') echo '2.1.50 (Claude Code)' ;;
  'mcp get context7') printf 'Command: npx\nArgs: -y @upstash/context7-mcp\n' ;;
  'mcp remove -s user context7'|'mcp add context7'*) : > "$TMP/mutated" ;;
esac
EOF
  chmod +x "$TMP/stubs/claude"
  unset AICODING_REQUIRE_UPDATE_RECEIPT

  run _provision_reconcile_exact_mcp context7 mcp-context7 context7-mcp

  [ "$status" -ne 0 ]
  [ ! -e "$TMP/mutated" ]
  jq -e '.components["mcp-registration-claude-context7"].reason == "claude_update_not_verified"' \
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
  aicoding_result_record claude current 2.1.50 installed 2.1.50
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

@test "mixed exact-MCP deferral and genuine hosted registration failure remains a failed provision step" {
  cat > "$TMP/stubs/claude" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$TMP/stubs/claude"
  _provision_tool_ready() { return 0; }
  _provision_reconcile_selected_exact_mcp() { return 3; }
  ensure_http_mcp() { return 1; }

  run install_claude_mcps
  [ "$status" -eq 1 ]
}

_kanban_claude_stub() {
  # $1: what `claude mcp get kanban` reports before any change.
  printf '%s' "$1" > "$TMP/kanban-before"
  cat > "$TMP/stubs/claude" <<'EOF'
#!/bin/sh
echo "$*" >> "$TMP/claude-calls"
case "$*" in
  'mcp get kanban')
    if [ -f "$TMP/added" ]; then
      printf 'kanban:\n  Type: http\n  URL: https://kanban.dataprospectors.at/mcp\n'
    elif [ -f "$TMP/removed" ] || [ ! -s "$TMP/kanban-before" ]; then
      exit 1
    else
      cat "$TMP/kanban-before"
    fi ;;
  'mcp get logfire') printf 'logfire:\n  URL: https://logfire-eu.pydantic.dev/mcp\n' ;;
  'mcp get '*) exit 1 ;;
  'mcp remove -s user kanban') : > "$TMP/removed" ;;
  'mcp add --transport http -s user kanban https://kanban.dataprospectors.at/mcp -H Authorization: Bearer kb-fake')
    : > "$TMP/added" ;;
  'mcp add'*) exit 1 ;;
esac
EOF
  chmod +x "$TMP/stubs/claude"
  _provision_tool_ready() { return 0; }
  _provision_reconcile_selected_exact_mcp() { return 0; }
  unset MEMORY_ROUTER_TOKEN FIRECRAWL_API_KEY BRAVE_API_KEY
  export AICODING_MCP_STATE="$TMP/mcp-fingerprints"
  mkdir -p "$AICODING_MCP_STATE"
  : > "$AICODING_MCP_STATE/logfire.sha256"
}

@test "Claude provision retires the local stdio kanban registration and registers the hosted MCP" {
  _kanban_claude_stub "$(printf 'kanban:\n  Type: stdio\n  Command: %s/.local/bin/kanban-mcp\n' "$HOME")"
  export KANBAN_TOKEN=kb-fake
  run install_claude_mcps
  [ "$status" -eq 0 ]
  [ -f "$TMP/removed" ]
  [ -f "$TMP/added" ]
  grep -qx 'mcp remove -s user kanban' "$TMP/claude-calls"
  # The fingerprint records a hash of the header, never the token itself.
  [ -s "$AICODING_MCP_STATE/kanban.sha256" ]
  if grep -rq 'kb-fake' "$AICODING_MCP_STATE"; then false; fi
}

@test "Claude provision registers the hosted kanban MCP on a machine without any registration" {
  _kanban_claude_stub ""
  export KANBAN_TOKEN=kb-fake
  run install_claude_mcps
  [ "$status" -eq 0 ]
  [ -f "$TMP/added" ]
  [ ! -f "$TMP/removed" ]
}

@test "Claude provision leaves a user's own stdio kanban registration and reports failure" {
  _kanban_claude_stub "$(printf 'kanban:\n  Type: stdio\n  Command: /opt/custom/kanban\n')"
  export KANBAN_TOKEN=kb-fake
  run install_claude_mcps
  [ "$status" -ne 0 ]
  [ ! -f "$TMP/removed" ]
  [ ! -f "$TMP/added" ]
  [[ "$output" == *"user stdio registration"* ]]
}

@test "Claude provision skips the hosted kanban MCP without KANBAN_TOKEN" {
  _kanban_claude_stub "$(printf 'kanban:\n  Type: stdio\n  Command: %s/.local/bin/kanban-mcp\n' "$HOME")"
  unset KANBAN_TOKEN
  run install_claude_mcps
  [ "$status" -eq 0 ]
  [[ "$output" == *"kanban MCP skipped (KANBAN_TOKEN not set)"* ]]
  if grep -q 'kanban' "$TMP/claude-calls" 2>/dev/null; then false; fi
}

@test "the kanban package updater no longer writes a Claude registration" {
  if grep -q '_aicoding_reconcile_claude_mcp_registration' "$BLUEPRINT_ROOT/lib/update-kanban.sh"; then false; fi
  if grep -q 'mcp-registration-claude-kanban' "$BLUEPRINT_ROOT/lib/update-components.sh"; then false; fi
}
