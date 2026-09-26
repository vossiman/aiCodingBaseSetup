#!/usr/bin/env bats

setup() {
  : "${BLUEPRINT_ROOT:?run via tests/bats/run.sh}"
  export TMP; TMP=$(mktemp -d)
  export HOME="$TMP/home"
  export AICODING_STATE_DIR="$TMP/state"
  export AICODING_DATA_DIR="$TMP/data"
  mkdir -p "$HOME/.local/bin" "$TMP/stubs"
  export PATH="$HOME/.local/bin:$TMP/stubs:/usr/bin:/bin"
  # GitHub-hosted Node lives outside /usr/bin. Keep package tests independent
  # of the runner image; tests for old Node replace this through _tool below.
  _tool node 'v22.14.0'
  . "$BLUEPRINT_ROOT/lib/update-results.sh"
  . "$BLUEPRINT_ROOT/lib/update-components.sh"
}

teardown() { rm -rf "$TMP"; }

_tool() {
  local name=$1 version=$2
  cat > "$TMP/stubs/$name" <<EOF
#!/bin/sh
echo '$version'
EOF
  chmod +x "$TMP/stubs/$name"
}

@test "installed component discovery includes host tools and excludes absent tools" {
  _tool claude '2.1.50 (Claude Code)'
  _tool codex 'codex-cli 0.150.0'
  _tool pi '0.73.1'

  run aicoding_installed_components
  [ "$status" -eq 0 ]
  [ "$output" = $'aicoding\nclaude\ncodex\npi\nmcp-kanban' ]
}

@test "pinned Kanban MCP is selected for a harness before it is ever installed" {
  _tool opencode '1.2.3'

  run aicoding_installed_components
  [ "$status" -eq 0 ]
  [ "$output" = $'aicoding\nopencode\nmcp-kanban' ]
}

@test "pinned Kanban MCP is not selected without a harness that consumes it" {
  _tool pi '0.73.1'

  run aicoding_installed_components
  [ "$status" -eq 0 ]
  [ "$output" = $'aicoding\npi' ]
}

@test "Kanban MCP without a blueprint pin is not bootstrapped" {
  _tool claude '2.1.50 (Claude Code)'
  _aicoding_kanban_pinned_revision() { return 1; }

  run aicoding_installed_components
  [ "$status" -eq 0 ]
  [ "$output" = $'aicoding\nclaude' ]
}

@test "installed component discovery rejects Windows binaries reached through WSL mounts" {
  mkdir -p "$TMP/mnt/c/Tools"
  printf '#!/bin/sh\necho 1.0.0\n' > "$TMP/mnt/c/Tools/opencode"
  chmod +x "$TMP/mnt/c/Tools/opencode"
  export PATH="$TMP/mnt/c/Tools:$PATH"
  export AICODING_WSL_MOUNT_PREFIX="$TMP/mnt/"

  run aicoding_installed_components
  [ "$output" = aicoding ]
}

@test "minimal Pi discovery honors persisted selection and ignores ambient harnesses" {
  _tool claude '2.1.50 (Claude Code)'
  _tool codex 'codex-cli 0.150.0'
  _tool dvw 'dvw 1.0.0'
  mkdir -p "$AICODING_STATE_DIR"
  printf '{"schema":1,"profile":"minimal-pi","components":["aicoding","dvw"]}\n' \
    > "$AICODING_STATE_DIR/component-selection.json"

  run aicoding_installed_components
  [ "$status" -eq 0 ]
  [ "$output" = $'aicoding\ndvw' ]
}

@test "unsupported Cursor platform is a completed component deferral" {
  unset AICODINGSETUP_SKIP_NETWORK
  _tool agent 'cursor-agent 2026.08.01'
  _tool uname 'Unsupported'

  run aicoding_update_installed_components
  [ "$status" -eq 0 ]
  jq -e '.components.cursor.state == "blocked"
    and .components.cursor.reason == "unsupported_platform"' \
    "$AICODING_STATE_DIR/update-results.json"
}

@test "a stale blocked receipt cannot hide an adapter failure without a fresh receipt" {
  unset AICODINGSETUP_SKIP_NETWORK
  aicoding_result_record cursor blocked "" old_staging_limit
  aicoding_installed_components() { printf 'cursor\n'; }
  aicoding_update_component() { return 1; }

  run aicoding_update_installed_components

  [ "$status" -ne 0 ]
  [ "${AICODING_UPDATE_DEFERRED:-0}" -eq 0 ]
  jq -e '.components.cursor.reason == "old_staging_limit"' "$AICODING_RESULTS_FILE"
}

_stub_selected_context7_aggregate() {
  printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/context7-mcp"
  chmod +x "$HOME/.local/bin/context7-mcp"
  cat > "$TMP/stubs/claude" <<'EOF'
#!/bin/sh
case "$*" in
  --version) echo '2.1.50 (Claude Code)' ;;
  'mcp get context7')
    echo 'Command: npx'
    echo 'Args: -y @upstash/context7-mcp'
    ;;
  mcp\ remove*|mcp\ add*) touch "$TMP/claude-mutated" ;;
esac
EOF
  chmod +x "$TMP/stubs/claude"
  aicoding_installed_components() { printf 'mcp-context7\n'; }
  aicoding_update_npm_entry_component() {
    local component=$1
    aicoding_result_record "$component" updated 4.1.0 installed 4.1.0
    _aicoding_reconcile_claude_mcp_registration \
      context7 "$component" 4.1.0 context7-mcp
  }
}

@test "scheduled MCP registration requires a Claude success receipt" {
  unset AICODINGSETUP_SKIP_NETWORK
  _stub_selected_context7_aggregate

  run aicoding_update_installed_components

  [ "$status" -eq 0 ]
  [ ! -e "$TMP/claude-mutated" ]
  jq -e '.components["mcp-context7"].state == "updated"
    and .components["mcp-registration-claude-context7"].state == "blocked"
    and .components["mcp-registration-claude-context7"].reason == "claude_update_not_verified"' \
    "$AICODING_RESULTS_FILE"
}

@test "scheduled MCP registration rejects a failed Claude receipt" {
  unset AICODINGSETUP_SKIP_NETWORK
  _stub_selected_context7_aggregate
  aicoding_result_record claude failed 2.1.51 stage_install_failed

  run aicoding_update_installed_components

  [ "$status" -eq 0 ]
  [ ! -e "$TMP/claude-mutated" ]
  jq -e '.components["mcp-context7"].state == "updated"
    and .components["mcp-registration-claude-context7"].state == "blocked"
    and .components["mcp-registration-claude-context7"].reason == "claude_update_not_verified"' \
    "$AICODING_RESULTS_FILE"
}

@test "Codex config capability requires the verified minimum version" {
  _tool codex 'codex-cli 0.147.0'
  run aicoding_config_is_compatible "$HOME/.codex/config.toml"
  [ "$status" -ne 0 ]
  [ "$output" = codex_requires_0.148 ]
  _tool codex 'codex-cli 0.148.0'
  run aicoding_config_is_compatible "$HOME/.codex/config.toml"
  [ "$status" -eq 0 ]
}

@test "a hanging installed version probe is bounded and blocks only that component" {
  cat > "$TMP/stubs/codex" <<'EOF'
#!/bin/sh
sleep 5
EOF
  chmod +x "$TMP/stubs/codex"
  export AICODING_PROBE_TIMEOUT=0.1
  local started=$SECONDS
  run aicoding_config_is_compatible "$HOME/.codex/config.toml"
  [ "$status" -ne 0 ]
  [ "$output" = codex_requires_0.148 ]
  [ $((SECONDS - started)) -lt 3 ]
  run aicoding_config_is_compatible "$HOME/.codex/AGENTS.md"
  [ "$status" -eq 0 ]
}

@test "ordinary skill text is independent of an absent tool" {
  run aicoding_config_is_compatible "$HOME/.codex/AGENTS.md"
  [ "$status" -eq 0 ]
  run aicoding_config_is_compatible "$HOME/.claude/skills/example/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "moving npx MCP config is deferred while ordinary skill text can advance" {
  export AICODING_REQUIRE_UPDATE_RECEIPT=1
  unset AICODINGSETUP_SKIP_NETWORK
  _tool codex 'codex-cli 0.200.0'
  aicoding_result_record codex current 0.200.0 installed 0.200.0
  run aicoding_config_is_compatible "$HOME/.codex/config.toml"
  [ "$status" -ne 0 ]
  [ "$output" = mcp_exact_version_staging_unavailable ]
  run aicoding_config_is_compatible "$HOME/.codex/AGENTS.md"
  [ "$status" -eq 0 ]
}

@test "Claude registration readiness is separate from package readiness for other harnesses" {
  for component in mcp-context7 mcp-playwright mcp-kanban; do
    aicoding_result_record "$component" current 1.0.0 installed 1.0.0
  done
  _aicoding_active_kanban_mcp_valid() { return 0; }
  run aicoding_exact_mcp_config_ready "$HOME/.codex/config.toml"
  [ "$status" -eq 0 ]
  run aicoding_exact_mcp_config_ready "$HOME/.claude/settings.json"
  [ "$status" -ne 0 ]
  for component in mcp-registration-claude-context7 mcp-registration-claude-playwright \
      mcp-registration-claude-kanban; do
    aicoding_result_record "$component" current 1.0.0 registration_verified 1.0.0
  done
  run aicoding_exact_mcp_config_ready "$HOME/.claude/settings.json"
  [ "$status" -eq 0 ]
}

@test "Cursor hook config does not depend on unrelated exact MCP packages" {
  _tool agent 'agent 1.2.3'
  aicoding_result_record cursor current 1.2.3 installed 1.2.3
  export AICODING_REQUIRE_UPDATE_RECEIPT=1
  run aicoding_config_is_compatible "$HOME/.cursor/hooks.json"
  [ "$status" -eq 0 ]
}

@test "a failed tool result blocks only its version-dependent config" {
  unset AICODINGSETUP_SKIP_NETWORK
  _tool codex 'codex-cli 0.200.0'
  aicoding_result_record codex failed 0.201.0 stage_install_failed
  export AICODING_REQUIRE_UPDATE_RECEIPT=1
  run aicoding_config_is_compatible "$HOME/.codex/config.toml"
  [ "$status" -ne 0 ]
  [ "$output" = codex_update_not_verified ]
  run aicoding_config_is_compatible "$HOME/.codex/AGENTS.md"
  [ "$status" -eq 0 ]
}

@test "network suppression does not authorize config without a success receipt" {
  _tool codex 'codex-cli 0.200.0'
  export AICODING_REQUIRE_UPDATE_RECEIPT=1
  export AICODINGSETUP_SKIP_NETWORK=1
  run aicoding_config_is_compatible "$HOME/.codex/config.toml"
  [ "$status" -ne 0 ]
  [ "$output" = codex_update_not_verified ]
}

@test "shared config waits when either known consumer is incompatible" {
  _tool codex 'codex-cli 0.200.0'
  export AICODING_REQUIRE_SHARED_COMPATIBILITY=1
  export AICODING_SHARED_CONSUMERS_FILE="$TMP/consumers.json"
  export AICODING_SELF_CONTAINER_ID=new
  mkdir -p "$HOME/.codex"
  local expires=$(( $(date +%s) + 3600 )) root
  root=$(readlink -f "$HOME/.codex")
  export AICODING_SHARED_CONFIG_ROOTS="$root"
  cat > "$AICODING_SHARED_CONSUMERS_FILE" <<'EOF'
{"schema":1,"generated_at":NOW,"newest_container_started_at":0,"roots":[{"inventory_complete":true,"shared_root":"ROOT","expires_at":EXPIRES,"consumers":[
  {"id":"new","components":{"codex":{"version":"0.200.0","config_compatible":true}}},
  {"id":"old","components":{"codex":{"version":"0.147.0","config_compatible":true}}}
]}]}
EOF
  sed -i "s|ROOT|$root|; s|EXPIRES|$expires|; s|NOW|$(date +%s)|" "$AICODING_SHARED_CONSUMERS_FILE"
  run aicoding_config_is_compatible "$HOME/.codex/config.toml"
  [ "$status" -ne 0 ]
  [ "$output" = codex_shared_consumers_incompatible ]

  jq '.roots[0].consumers[1].components.codex.version="0.148.0"' "$AICODING_SHARED_CONSUMERS_FILE" > "$TMP/ok"
  mv "$TMP/ok" "$AICODING_SHARED_CONSUMERS_FILE"
  run aicoding_config_is_compatible "$HOME/.codex/config.toml"
  [ "$status" -eq 0 ]

  jq '.roots[0].inventory_complete=false' "$AICODING_SHARED_CONSUMERS_FILE" > "$TMP/incomplete"
  mv "$TMP/incomplete" "$AICODING_SHARED_CONSUMERS_FILE"
  run aicoding_config_is_compatible "$HOME/.codex/config.toml"
  [ "$status" -ne 0 ]
}

@test "local host config does not require fleet evidence" {
  _tool codex 'codex-cli 0.200.0'
  mkdir -p "$HOME/.codex"
  export AICODING_REQUIRE_SHARED_COMPATIBILITY=1
  export AICODING_SHARED_CONSUMERS_FILE="$TMP/missing-consumers.json"
  unset AICODING_SHARED_CONFIG_ROOTS
  run aicoding_config_shared_root "$HOME/.codex/config.toml"
  [ "$status" -ne 0 ]
  run aicoding_config_is_compatible "$HOME/.codex/config.toml"
  [ "$status" -eq 0 ]
}

@test "shared authorization fails closed when mount classification is unavailable" {
  mkdir -p "$HOME/.codex"
  export AICODING_REQUIRE_SHARED_COMPATIBILITY=1
  export AICODING_SHARED_CONSUMERS_FILE="$TMP/missing-consumers.json"
  unset AICODING_SHARED_CONFIG_ROOTS
  findmnt() { return 1; }

  run _aicoding_shared_consumers_allow codex 0.148.0 "$HOME/.codex/config.toml"

  [ "$status" -ne 0 ]
}

@test "redirected known config root requires shared inventory" {
  mkdir -p "$TMP/redirected-codex"
  ln -s "$TMP/redirected-codex" "$HOME/.codex"
  export AICODING_REQUIRE_SHARED_COMPATIBILITY=1
  export AICODING_SHARED_CONSUMERS_FILE="$TMP/missing-consumers.json"
  unset AICODING_SHARED_CONFIG_ROOTS
  findmnt() { printf '/\n'; }

  run _aicoding_shared_consumers_allow codex 0.148.0 "$HOME/.codex/config.toml"

  [ "$status" -ne 0 ]
}

@test "consumer evidence is bound independently to each shared root and freshness" {
  _tool codex 'codex-cli 0.200.0'
  _tool claude '2.1.50 (Claude Code)'
  mkdir -p "$HOME/.codex" "$HOME/.claude"
  local codex_root claude_root expires
  codex_root=$(readlink -f "$HOME/.codex")
  claude_root=$(readlink -f "$HOME/.claude")
  expires=$(( $(date +%s) + 3600 ))
  export AICODING_SHARED_CONFIG_ROOTS="$codex_root:$claude_root"
  export AICODING_REQUIRE_SHARED_COMPATIBILITY=1
  export AICODING_SHARED_CONSUMERS_FILE="$TMP/consumers.json"
  export AICODING_SELF_CONTAINER_ID=dormant
  jq -n --arg cr "$codex_root" --arg ar "$claude_root" --argjson expires "$expires" \
    '{schema:1,generated_at:($expires - 3600),newest_container_started_at:0,roots:[
    {shared_root:$cr,inventory_complete:true,expires_at:$expires,consumers:[
      {id:"dormant",components:{codex:{version:"0.148.0",config_compatible:true}}}]},
    {shared_root:$ar,inventory_complete:true,expires_at:0,consumers:[
      {id:"dormant",components:{claude:{version:"2.1.50",config_compatible:true}}}]}
  ]}' > "$AICODING_SHARED_CONSUMERS_FILE"
  run aicoding_config_is_compatible "$HOME/.codex/config.toml"
  [ "$status" -eq 0 ]
  run aicoding_config_is_compatible "$HOME/.claude/settings.json"
  [ "$status" -ne 0 ]
  [ "$output" = claude_shared_consumers_incompatible ]
  jq --arg root "$TMP/unknown" '.roots[1].shared_root=$root | .roots[1].expires_at=9999999999' \
    "$AICODING_SHARED_CONSUMERS_FILE" > "$TMP/unknown.json"
  mv "$TMP/unknown.json" "$AICODING_SHARED_CONSUMERS_FILE"
  run aicoding_config_is_compatible "$HOME/.claude/settings.json"
  [ "$status" -ne 0 ]
}

@test "explicit shared OpenCode config requires its own consumer inventory" {
  _tool opencode 'opencode 1.2.3'
  mkdir -p "$HOME/.config/opencode"
  export AICODING_REQUIRE_SHARED_COMPATIBILITY=1
  export AICODING_SHARED_CONFIG_ROOTS="$HOME/.config/opencode"
  export AICODING_SHARED_CONSUMERS_FILE="$TMP/consumers.json"
  run aicoding_config_shared_root "$HOME/.config/opencode/opencode.json"
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/.config/opencode" ]
  run aicoding_config_is_compatible "$HOME/.config/opencode/opencode.json"
  [ "$status" -ne 0 ]
  [ "$output" = opencode_shared_consumers_incompatible ]
  export AICODING_SELF_CONTAINER_ID=other
  jq -n --arg root "$HOME/.config/opencode" --argjson expires "$(( $(date +%s) + 3600 ))" \
    '{schema:1,generated_at:($expires - 60),newest_container_started_at:0,
      roots:[{shared_root:$root,inventory_complete:true,expires_at:$expires,
      consumers:[{id:"other",components:{opencode:{version:"1.2.3",config_compatible:true}}}]}]}' \
    > "$AICODING_SHARED_CONSUMERS_FILE"
  run aicoding_config_is_compatible "$HOME/.config/opencode/opencode.json"
  [ "$status" -eq 0 ]
}

@test "mounted OpenCode config requires inventory independently of runtime data" {
  _tool opencode 'opencode 1.2.3'
  mkdir -p "$HOME/.config/opencode" "$HOME/.local/share/opencode"
  unset AICODING_SHARED_CONFIG_ROOTS
  export AICODING_REQUIRE_SHARED_COMPATIBILITY=1
  export AICODING_SHARED_CONSUMERS_FILE="$TMP/missing-consumers.json"
  findmnt() { printf '%s\n' "$HOME/.config/opencode"; }
  run aicoding_config_shared_root "$HOME/.config/opencode/opencode.json"
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/.config/opencode" ]
  run aicoding_config_is_compatible "$HOME/.config/opencode/opencode.json"
  [ "$status" -ne 0 ]
  [ "$output" = opencode_shared_consumers_incompatible ]
}

@test "shared OpenCode runtime data does not classify local config as shared" {
  _tool opencode 'opencode 1.2.3'
  mkdir -p "$HOME/.config/opencode" "$HOME/.local/share/opencode"
  export AICODING_REQUIRE_SHARED_COMPATIBILITY=1
  export AICODING_SHARED_CONFIG_ROOTS="$(readlink -f "$HOME/.local/share/opencode")"
  export AICODING_SHARED_CONSUMERS_FILE="$TMP/missing-consumers.json"
  findmnt() { printf '/\n'; }
  run aicoding_config_shared_root "$HOME/.config/opencode/opencode.json"
  [ "$status" -eq 1 ]
  run aicoding_config_is_compatible "$HOME/.config/opencode/opencode.json"
  [ "$status" -eq 0 ]
}

_stub_npm_codex() {
  cat > "$TMP/stubs/npm" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$NPM_LOG"
if [ "$1" = view ]; then echo '"0.151.0"'; exit 0; fi
prefix=
while [ $# -gt 0 ]; do
  [ "$1" = --prefix ] && { prefix=$2; shift 2; continue; }
  shift
done
mkdir -p "$prefix/node_modules/.bin" "$prefix/node_modules/@openai/codex-linux-x64/bin"
cat > "$prefix/node_modules/.bin/codex" <<'BIN'
#!/bin/sh
echo 'codex-cli 0.151.0'
BIN
cat > "$prefix/node_modules/@openai/codex-linux-x64/bin/codex-code-mode-host" <<'BIN'
#!/bin/sh
exit 0
BIN
chmod +x "$prefix/node_modules/.bin/codex" "$prefix/node_modules/@openai/codex-linux-x64/bin/codex-code-mode-host"
EOF
  chmod +x "$TMP/stubs/npm"
  export NPM_LOG="$TMP/npm.log"
}

_managed_codex_release() {
  local version=$1 sidecar=${2:-present}
  local release="$AICODING_DATA_DIR/versions/codex/$version"
  mkdir -p "$release/node_modules/.bin" \
    "$release/node_modules/@openai/codex-linux-x64/bin"
  cat > "$release/node_modules/.bin/codex" <<EOF
#!/bin/sh
echo 'codex-cli $version'
EOF
  chmod +x "$release/node_modules/.bin/codex"
  if [ "$sidecar" = present ]; then
    printf '#!/bin/sh\nexit 0\n' \
      > "$release/node_modules/@openai/codex-linux-x64/bin/codex-code-mode-host"
    chmod +x "$release/node_modules/@openai/codex-linux-x64/bin/codex-code-mode-host"
  fi
  aicoding_activate_version codex "$version" codex node_modules/.bin/codex
}

_stub_npm_view_then_fail_install() {
  cat > "$TMP/stubs/npm" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$NPM_LOG"
if [ "$1" = view ]; then printf '"0.151.0"\n'; exit 0; fi
exit 91
EOF
  chmod +x "$TMP/stubs/npm"
  export NPM_LOG="$TMP/npm.log"
}

@test "matching managed Codex verifies its sidecar in the physical active release" {
  _managed_codex_release 0.151.0
  _stub_npm_view_then_fail_install

  run aicoding_update_npm_component codex codex @openai/codex
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$NPM_LOG")" -eq 1 ]
  grep -q '^view @openai/codex version --json$' "$NPM_LOG"
  jq -e '.components.codex.state == "current" and .components.codex.successful_version == "0.151.0"' \
    "$AICODING_STATE_DIR/update-results.json"
}

@test "managed Codex with a missing active sidecar still attempts repair" {
  _managed_codex_release 0.151.0 missing
  _stub_npm_view_then_fail_install

  run aicoding_update_npm_component codex codex @openai/codex
  [ "$status" -ne 0 ]
  grep -q '^install --prefix ' "$NPM_LOG"
  [ "$(readlink "$AICODING_DATA_DIR/current/codex")" = "../versions/codex/0.151.0" ]
  jq -e '.components.codex.state == "failed" and .components.codex.reason == "stage_install_failed"' \
    "$AICODING_STATE_DIR/update-results.json"
}

@test "matching legacy Codex still verifies a sidecar beside its resolved binary" {
  _tool codex 'codex-cli 0.151.0'
  printf '#!/bin/sh\nexit 0\n' > "$TMP/stubs/codex-code-mode-host"
  chmod +x "$TMP/stubs/codex-code-mode-host"
  _stub_npm_view_then_fail_install

  run aicoding_update_npm_component codex codex @openai/codex
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$NPM_LOG")" -eq 1 ]
  jq -e '.components.codex.state == "current" and .components.codex.successful_version == "0.151.0"' \
    "$AICODING_STATE_DIR/update-results.json"
}

@test "Codex stages an exact npm version, validates its sidecar, then atomically activates" {
  _tool codex 'codex-cli 0.150.0'
  _stub_npm_codex

  run aicoding_update_npm_component codex codex @openai/codex
  [ "$status" -eq 0 ]
  grep -q -- '--prefix .* @openai/codex@0.151.0' "$NPM_LOG"
  [ -L "$AICODING_DATA_DIR/current/codex" ]
  [ "$(readlink "$AICODING_DATA_DIR/current/codex")" = "../versions/codex/0.151.0" ]
  [ -x "$AICODING_DATA_DIR/versions/codex/0.151.0/node_modules/@openai/codex-linux-x64/bin/codex-code-mode-host" ]
  [ -x "$HOME/.local/bin/codex" ]
  jq -e '.components.codex.state == "updated" and .components.codex.successful_version == "0.151.0"' \
    "$AICODING_STATE_DIR/update-results.json"
}

@test "activation restores an unknown launcher when the pointer switch fails" {
  mkdir -p "$AICODING_DATA_DIR/versions/codex/0.151.0/bin" "$AICODING_DATA_DIR/current"
  printf '#!/bin/sh\necho original\n' > "$HOME/.local/bin/codex"
  chmod +x "$HOME/.local/bin/codex"
  printf '#!/bin/sh\nexit 0\n' > "$AICODING_DATA_DIR/versions/codex/0.151.0/bin/codex"
  chmod +x "$AICODING_DATA_DIR/versions/codex/0.151.0/bin/codex"
  mv() {
    local last=${!#}
    [ "$last" = "$AICODING_DATA_DIR/current/codex" ] && return 8
    command mv "$@"
  }
  run _aicoding_activate_vendor_release codex 0.151.0 codex bin/codex
  [ "$status" -ne 0 ]
  [ "$(cat "$HOME/.local/bin/codex")" = $'#!/bin/sh\necho original' ]
  [ ! -e "$HOME/.local/bin/codex.pre-aicoding" ]
  [ ! -e "$AICODING_DATA_DIR/current/codex" ]
}

@test "multi-launcher activation rolls back every launcher and current pointer" {
  mkdir -p "$AICODING_DATA_DIR/versions/bw-AICode/old" "$AICODING_DATA_DIR/versions/bw-AICode/new" \
    "$AICODING_DATA_DIR/current"
  ln -s ../versions/bw-AICode/old "$AICODING_DATA_DIR/current/bw-AICode"
  for name in first second; do
    printf '#!/bin/sh\necho old-%s\n' "$name" > "$HOME/.local/bin/$name"
    printf '#!/bin/sh\necho new-%s\n' "$name" > "$AICODING_DATA_DIR/versions/bw-AICode/new/$name"
    chmod +x "$HOME/.local/bin/$name" "$AICODING_DATA_DIR/versions/bw-AICode/new/$name"
  done
  mv() {
    local last=${!#}
    [ "$last" = "$HOME/.local/bin/second" ] && return 8
    command mv "$@"
  }
  run _aicoding_activate_vendor_release bw-AICode new first first second second
  [ "$status" -ne 0 ]
  [ "$(readlink "$AICODING_DATA_DIR/current/bw-AICode")" = ../versions/bw-AICode/old ]
  [ "$(tail -1 "$HOME/.local/bin/first")" = 'echo old-first' ]
  [ "$(tail -1 "$HOME/.local/bin/second")" = 'echo old-second' ]
  [ ! -e "$HOME/.local/bin/first.pre-aicoding" ]
  [ ! -e "$HOME/.local/bin/second.pre-aicoding" ]
}

@test "failed staged validation leaves the active version and success receipt unchanged" {
  mkdir -p "$AICODING_DATA_DIR/versions/codex/0.150.0" "$AICODING_DATA_DIR/current"
  ln -s ../versions/codex/0.150.0 "$AICODING_DATA_DIR/current/codex"
  aicoding_result_record codex current 0.150.0 current 0.150.0
  _tool codex 'codex-cli 0.150.0'
  _stub_npm_codex
  rm -f "$TMP/stubs/npm"
  cat > "$TMP/stubs/npm" <<'EOF'
#!/bin/sh
if [ "$1" = view ]; then echo '"0.151.0"'; exit 0; fi
prefix=
while [ $# -gt 0 ]; do [ "$1" = --prefix ] && { prefix=$2; shift 2; continue; }; shift; done
mkdir -p "$prefix/node_modules/.bin"
printf '#!/bin/sh\necho codex-cli 0.151.0\n' > "$prefix/node_modules/.bin/codex"
chmod +x "$prefix/node_modules/.bin/codex"
EOF
  chmod +x "$TMP/stubs/npm"

  run aicoding_update_npm_component codex codex @openai/codex
  [ "$status" -ne 0 ]
  [ "$(readlink "$AICODING_DATA_DIR/current/codex")" = "../versions/codex/0.150.0" ]
  jq -e '.components.codex.state == "failed" and .components.codex.successful_version == "0.150.0"' \
    "$AICODING_STATE_DIR/update-results.json"
}

@test "a failed component does not prevent an unrelated installed component update" {
  unset AICODINGSETUP_SKIP_NETWORK
  aicoding_update_component() {
    printf '%s\n' "$1" >> "$TMP/attempts"
    [ "$1" != claude ]
  }
  aicoding_installed_components() { printf 'aicoding\nclaude\npi\n'; }

  run aicoding_update_installed_components
  [ "$status" -ne 0 ]
  [ "$(cat "$TMP/attempts")" = $'claude\npi' ]
}

@test "MCP npm package stages exact metadata and entrypoint without a version command" {
  _tool firecrawl-mcp 'usage only'
  cat > "$TMP/stubs/npm" <<'EOF'
#!/bin/sh
if [ "$1" = view ]; then echo '"1.2.3"'; exit 0; fi
prefix=
while [ $# -gt 0 ]; do [ "$1" = --prefix ] && { prefix=$2; shift 2; continue; }; shift; done
mkdir -p "$prefix/node_modules/firecrawl-mcp/dist"
printf '{"lockfileVersion":3,"packages":{"node_modules/firecrawl-mcp":{"version":"1.2.3","integrity":"sha512-fixture"}}}\n' > "$prefix/package-lock.json"
cat > "$prefix/node_modules/firecrawl-mcp/package.json" <<'JSON'
{"name":"firecrawl-mcp","version":"1.2.3","bin":{"firecrawl-mcp":"dist/index.js"}}
JSON
printf '#!/bin/sh\nexit 0\n' > "$prefix/node_modules/firecrawl-mcp/dist/index.js"
chmod +x "$prefix/node_modules/firecrawl-mcp/dist/index.js"
EOF
  chmod +x "$TMP/stubs/npm"
  run aicoding_update_npm_entry_component mcp-firecrawl firecrawl-mcp firecrawl-mcp
  [ "$status" -eq 0 ]
  [ -x "$HOME/.local/bin/firecrawl-mcp" ]
  jq -e '.components["mcp-firecrawl"].successful_version == "1.2.3"' "$AICODING_STATE_DIR/update-results.json"
}

@test "registered Context7 and Playwright are discovered without installing absent harnesses" {
  mkdir -p "$HOME/.codex" "$HOME/.cursor"
  cat > "$HOME/.codex/config.toml" <<'EOF'
[mcp_servers.context7]
command = "npx"
EOF
  cat > "$HOME/.cursor/mcp.json" <<'EOF'
{"mcpServers":{"playwright":{"command":"npx"}}}
EOF
  run aicoding_installed_components
  [ "$status" -eq 0 ]
  [ "$output" = $'aicoding\nmcp-context7\nmcp-playwright' ]
}

_stub_exact_mcp_npm() {
  cat > "$TMP/stubs/npm" <<'EOF'
#!/bin/sh
case "$*" in
  'view @upstash/context7-mcp version --json') echo '"4.1.0"'; exit 0 ;;
  'view @playwright/mcp version --json') echo '"0.0.80"'; exit 0 ;;
esac
printf '%s\n' "$*" >> "$TMP/npm-mcp-args"
prefix=
package=
while [ $# -gt 0 ]; do
  [ "$1" = --prefix ] && { prefix=$2; shift 2; continue; }
  case "$1" in @upstash/context7-mcp@*) package=context7 ;; @playwright/mcp@*) package=playwright ;; esac
  shift
done
printf '%s\n' "$package" >> "$TMP/npm-mcp-installs"
mkdir -p "$prefix"
if [ -f "$prefix/package.json" ]; then
  root_name=$(jq -r .name "$prefix/package.json")
else
  root_name=${prefix##*/}
  printf '{"name":"%s","private":true}\n' "$root_name" > "$prefix/package.json"
fi
if [ "$package" = context7 ]; then
  dir="$prefix/node_modules/@upstash/context7-mcp"
  mkdir -p "$dir/dist"
  printf '{"name":"%s","lockfileVersion":3,"packages":{"":{"name":"%s"},"node_modules/@upstash/context7-mcp":{"version":"4.1.0","integrity":"sha512-fixture"}}}\n' "$root_name" "$root_name" > "$prefix/package-lock.json"
  printf '{"name":"@upstash/context7-mcp","version":"4.1.0","bin":{"context7-mcp":"dist/index.js"}}\n' > "$dir/package.json"
  if [ "${MCP_LIFECYCLE:-}" = top ]; then
    jq '.scripts.postinstall="node build.js"' "$dir/package.json" > "$dir/package.tmp"
    mv "$dir/package.tmp" "$dir/package.json"
  elif [ "${MCP_LIFECYCLE:-}" = dependency ]; then
    mkdir -p "$prefix/node_modules/lifecycle-dep"
    printf '{"name":"lifecycle-dep","version":"1.0.0","scripts":{"install":"node install.js"}}\n' \
      > "$prefix/node_modules/lifecycle-dep/package.json"
    jq '.packages["node_modules/lifecycle-dep"]={"version":"1.0.0","hasInstallScript":true,"integrity":"sha512-fixture"}' \
      "$prefix/package-lock.json" > "$prefix/lock.tmp" && mv "$prefix/lock.tmp" "$prefix/package-lock.json"
  fi
  if [ -n "${MCP_DEP_PAYLOAD:-}" ]; then
    mkdir -p "$prefix/node_modules/stable-dep"
    printf '{"name":"stable-dep","version":"1.0.0"}\n' > "$prefix/node_modules/stable-dep/package.json"
    jq '.packages["node_modules/stable-dep"]={"version":"1.0.0","integrity":"sha512-fixture"}' \
      "$prefix/package-lock.json" > "$prefix/lock.tmp" && mv "$prefix/lock.tmp" "$prefix/package-lock.json"
    printf '%s\n' "$MCP_DEP_PAYLOAD" > "$prefix/node_modules/stable-dep/index.js"
  fi
  printf '#!/bin/sh\nexit 0\n' > "$dir/dist/index.js"
  chmod +x "$dir/dist/index.js"
else
  dir="$prefix/node_modules/@playwright/mcp"
  mkdir -p "$dir" "$prefix/node_modules/playwright-core"
  printf '{"lockfileVersion":3,"packages":{"node_modules/@playwright/mcp":{"version":"0.0.80","integrity":"sha512-fixture"}}}\n' > "$prefix/package-lock.json"
  printf '{"name":"@playwright/mcp","version":"0.0.80","bin":{"playwright-mcp":"cli.js"}}\n' > "$dir/package.json"
  cat > "$dir/cli.js" <<'CLI'
#!/bin/sh
if [ "$1" = install-browser ]; then
  mkdir -p "$PLAYWRIGHT_BROWSERS_PATH/chromium-123/chrome-linux64"
  printf '#!/bin/sh\nexit 0\n' > "$PLAYWRIGHT_BROWSERS_PATH/chromium-123/chrome-linux64/chrome"
  chmod +x "$PLAYWRIGHT_BROWSERS_PATH/chromium-123/chrome-linux64/chrome"
fi
exit 0
CLI
  printf '#!/bin/sh\nexit 0\n' > "$prefix/node_modules/playwright-core/cli.js"
  chmod +x "$dir/cli.js" "$prefix/node_modules/playwright-core/cli.js"
fi
EOF
  chmod +x "$TMP/stubs/npm"
}

_stub_kanban_git_uv() {
  # The suite-wide guard stays enabled unless a test explicitly installs these
  # network-free Git/uv doubles. The updater must still honor a test that sets
  # the guard back to 1 after calling this helper.
  export AICODINGSETUP_SKIP_NETWORK=0
  cat > "$TMP/stubs/git" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TMP/git.log"
if [ "$1" = clone ]; then
  destination=${4:?missing clone destination}
  mkdir -p "$destination"
  cat > "$destination/pyproject.toml" <<'TOML'
[project]
name = "kanban"
version = "0.1.0"
TOML
  : > "$destination/uv.lock"
  exit 0
fi
if [ "$1" = -C ] && [ "$3" = checkout ] && [ "$4" = --detach ]; then
  printf '%s\n' "$5" > "$2/.fake-head"
  exit 0
fi
if [ "$1" = -C ] && [ "$3" = rev-parse ] && [ "$4" = HEAD ]; then
  cat "$2/.fake-head"
  exit 0
fi
exit 2
EOF
  cat > "$TMP/stubs/uv" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TMP/uv.log"
printf '%s\n' "${UV_NO_EDITABLE:-}" >> "$TMP/uv-no-editable.log"
printf '%s\n' "${UV_CACHE_DIR:-}" >> "$TMP/uv-cache-dir.log"
if [ "${1:-}" = venv ]; then
  if [ "${KANBAN_UV_FAIL_VENV:-0}" = 1 ]; then
    printf 'error: Failed to initialize cache at /home/x/.cache/uv\n' >&2
    exit 2
  fi
  [ "$*" = 'venv --relocatable .venv' ] || exit 2
  mkdir -p "$PWD/.venv/bin"
  : > "$PWD/.venv/.relocatable"
  exit 0
fi
[ -f "$PWD/.venv/.relocatable" ] || exit 3
mkdir -p "$PWD/.venv/bin"
cat > "$PWD/.venv/bin/python" <<'PYTHON'
#!/bin/sh
printf '0.1.0\n'
PYTHON
chmod +x "$PWD/.venv/bin/python"
version=0.1.0
[ "${KANBAN_UV_BAD_VERSION:-0}" != 1 ] || version=9.9.9
cat > "$PWD/.venv/bin/kanban-mcp" <<SCRIPT
#!/bin/sh
case "\${1:-}" in
  --version)
    printf 'kanban-mcp %s\\n' '$version'
    [ "${KANBAN_UV_EXTRA_VERSION_LINE:-0}" != 1 ] || printf 'unexpected\\n'
    ;;
  --instructions)
    [ "${KANBAN_UV_EMPTY_INSTRUCTIONS:-0}" = 1 ] || printf 'Canonical claim workflow.\\n'
    ;;
  *) exit 0 ;;
esac
SCRIPT
chmod +x "$PWD/.venv/bin/kanban-mcp"
EOF
  chmod +x "$TMP/stubs/git" "$TMP/stubs/uv"
}

_seed_old_kanban_release() {
  local old="$AICODING_DATA_DIR/versions/mcp-kanban/old"
  mkdir -p "$old/.venv/bin"
  printf '%s\n' old > "$old/.aicoding-version"
  cat > "$old/.venv/bin/kanban-mcp" <<'EOF'
#!/bin/sh
case "${1:-}" in
  --version) printf 'kanban-mcp 0.0.1\n' ;;
  --instructions) printf 'Old workflow.\n' ;;
esac
EOF
  chmod +x "$old/.venv/bin/kanban-mcp"
  _aicoding_release_integrity_write "$old"
  aicoding_activate_version mcp-kanban old kanban-mcp .venv/bin/kanban-mcp
}

@test "Kanban MCP pin is one reviewed immutable revision" {
  run _aicoding_kanban_pinned_revision
  [ "$status" -eq 0 ]
  [ "$output" = a71a8bdcd12e39fcb74be3ecc0e45f757118f0e3 ]
}

@test "Kanban MCP stages the pinned repository revision and frozen lock" {
  _stub_kanban_git_uv

  AICODING_MCP_REGISTRATION_DISABLE=1 run aicoding_update_component mcp-kanban

  [ "$status" -eq 0 ]
  local revision
  revision=$(cat "$BLUEPRINT_ROOT/configs/versions/kanban-mcp.rev")
  grep -Fq -- "checkout --detach $revision" "$TMP/git.log"
  grep -Fxq 'sync --frozen --extra mcp --no-dev' "$TMP/uv.log"
  grep -Fxq 'venv --relocatable .venv' "$TMP/uv.log"
  [ "$(tail -n 1 "$TMP/uv-no-editable.log")" = 1 ]
  [ "$(readlink "$AICODING_DATA_DIR/current/mcp-kanban")" = "../versions/mcp-kanban/$revision" ]
  [ -x "$HOME/.local/bin/kanban-mcp" ]
  [ "$("$HOME/.local/bin/kanban-mcp" --version)" = 'kanban-mcp 0.1.0' ]
  grep -Fq 'PYTHONDONTWRITEBYTECODE=1' \
    "$AICODING_DATA_DIR/versions/mcp-kanban/$revision/.venv/bin/kanban-mcp"
  [ -x "$AICODING_DATA_DIR/versions/mcp-kanban/$revision/.venv/bin/kanban-mcp.runtime" ]
  jq -e --arg revision "$revision" '.components["mcp-kanban"].state == "updated"
    and .components["mcp-kanban"].successful_version == $revision' "$AICODING_RESULTS_FILE"
}

@test "Kanban MCP builds with a private uv cache, not the user's" {
  _stub_kanban_git_uv
  mkdir -p "$HOME/.cache/uv"
  export UV_CACHE_DIR="$HOME/.cache/uv"

  AICODING_MCP_REGISTRATION_DISABLE=1 run aicoding_update_component mcp-kanban

  [ "$status" -eq 0 ]
  [ "$(sort -u "$TMP/uv-cache-dir.log")" = "$AICODING_DATA_DIR/cache/uv" ]
  [ "$(wc -l < "$TMP/uv-cache-dir.log")" -eq 2 ]
  [ ! -e "$AICODING_STATE_DIR/diagnostics/mcp-kanban-uv.log" ]
}

@test "Kanban MCP keeps uv's error output after a failed build" {
  _stub_kanban_git_uv
  export KANBAN_UV_FAIL_VENV=1

  AICODING_MCP_REGISTRATION_DISABLE=1 run aicoding_update_component mcp-kanban

  [ "$status" -ne 0 ]
  jq -e '.components["mcp-kanban"].reason == "relocatable_venv_failed"' "$AICODING_RESULTS_FILE"
  grep -Fq 'Failed to initialize cache' "$AICODING_STATE_DIR/diagnostics/mcp-kanban-uv.log"
  [ "$(stat -c %a "$AICODING_STATE_DIR/diagnostics/mcp-kanban-uv.log")" = 600 ]
  [[ "$output" == *"$AICODING_STATE_DIR/diagnostics/mcp-kanban-uv.log"* ]]
  if find "$AICODING_DATA_DIR/versions/mcp-kanban" -maxdepth 1 -name '.staging.*' \
      -print -quit 2>/dev/null | grep -q .; then
    false
  fi
}

@test "Kanban MCP clears a stale uv diagnostic after a successful build" {
  _stub_kanban_git_uv
  mkdir -p "$AICODING_STATE_DIR/diagnostics"
  printf 'old failure\n' > "$AICODING_STATE_DIR/diagnostics/mcp-kanban-uv.log"

  AICODING_MCP_REGISTRATION_DISABLE=1 run aicoding_update_component mcp-kanban

  [ "$status" -eq 0 ]
  [ ! -e "$AICODING_STATE_DIR/diagnostics/mcp-kanban-uv.log" ]
}

@test "Kanban MCP never trusts a mutable same-revision source cache" {
  _stub_kanban_git_uv
  local revision source_cache
  revision=$(cat "$BLUEPRINT_ROOT/configs/versions/kanban-mcp.rev")
  source_cache="$AICODING_DATA_DIR/sources/kanban/$revision"
  mkdir -p "$source_cache"
  printf '%s\n' "$revision" > "$source_cache/.aicoding-version"
  printf 'altered same-SHA payload\n' > "$source_cache/pyproject.toml"

  AICODING_MCP_REGISTRATION_DISABLE=1 run aicoding_update_component mcp-kanban

  [ "$status" -eq 0 ]
  grep -Fq 'clone --no-checkout https://github.com/vossiman/kanban.git' "$TMP/git.log"
  grep -Fq "/sources/kanban/.attempt.$revision." "$TMP/git.log"
  [ "$(cat "$source_cache/pyproject.toml")" = 'altered same-SHA payload' ]
  [ "$(cat "$AICODING_DATA_DIR/versions/mcp-kanban/$revision/pyproject.toml")" != \
    'altered same-SHA payload' ]
  if find "$AICODING_DATA_DIR/sources/kanban" -maxdepth 1 \
      -name ".attempt.$revision.*" -print -quit | grep -q .; then
    false
  fi
}

@test "Kanban MCP direct updater blocks offline before git or uv" {
  _stub_kanban_git_uv
  export AICODINGSETUP_SKIP_NETWORK=1

  AICODING_MCP_REGISTRATION_DISABLE=1 run aicoding_update_component mcp-kanban

  [ "$status" -ne 0 ]
  [ ! -e "$TMP/git.log" ]
  [ ! -e "$TMP/uv.log" ]
  jq -e '.components["mcp-kanban"].state == "blocked"
    and .components["mcp-kanban"].reason == "offline_exact_package_not_ready"' \
    "$AICODING_RESULTS_FILE"
}

@test "Kanban MCP refuses a non-immutable revision before git or uv" {
  _stub_kanban_git_uv
  _aicoding_kanban_pinned_revision() { printf 'main\n'; }

  AICODING_MCP_REGISTRATION_DISABLE=1 run aicoding_update_component mcp-kanban

  [ "$status" -ne 0 ]
  [ ! -e "$TMP/git.log" ]
  [ ! -e "$TMP/uv.log" ]
  jq -e '.components["mcp-kanban"].reason == "pinned_revision_invalid"' "$AICODING_RESULTS_FILE"
}

@test "Kanban MCP validates version and instructions before activation" {
  _stub_kanban_git_uv
  _seed_old_kanban_release
  export KANBAN_UV_BAD_VERSION=1

  AICODING_MCP_REGISTRATION_DISABLE=1 run aicoding_update_component mcp-kanban

  [ "$status" -ne 0 ]
  [ "$(readlink "$AICODING_DATA_DIR/current/mcp-kanban")" = '../versions/mcp-kanban/old' ]
  [ "$("$HOME/.local/bin/kanban-mcp" --version)" = 'kanban-mcp 0.0.1' ]
  jq -e '.components["mcp-kanban"].reason == "staged_controller_invalid"' "$AICODING_RESULTS_FILE"
}

@test "Kanban MCP rejects extra version output and empty instructions" {
  _stub_kanban_git_uv
  export KANBAN_UV_EXTRA_VERSION_LINE=1
  AICODING_MCP_REGISTRATION_DISABLE=1 run aicoding_update_component mcp-kanban
  [ "$status" -ne 0 ]
  [ ! -e "$AICODING_DATA_DIR/current/mcp-kanban" ]

  rm -rf "$AICODING_DATA_DIR/sources/kanban" "$AICODING_DATA_DIR/versions/mcp-kanban"
  : > "$TMP/git.log"; : > "$TMP/uv.log"
  unset KANBAN_UV_EXTRA_VERSION_LINE
  export KANBAN_UV_EMPTY_INSTRUCTIONS=1
  AICODING_MCP_REGISTRATION_DISABLE=1 run aicoding_update_component mcp-kanban
  [ "$status" -ne 0 ]
  [ ! -e "$AICODING_DATA_DIR/current/mcp-kanban" ]
}

@test "Kanban MCP reuses a verified release without git or uv and repairs its launcher" {
  _stub_kanban_git_uv
  AICODING_MCP_REGISTRATION_DISABLE=1 run aicoding_update_component mcp-kanban
  [ "$status" -eq 0 ]
  rm "$HOME/.local/bin/kanban-mcp"
  : > "$TMP/git.log"; : > "$TMP/uv.log"

  AICODING_MCP_REGISTRATION_DISABLE=1 run aicoding_update_component mcp-kanban

  [ "$status" -eq 0 ]
  [ ! -s "$TMP/git.log" ]
  [ ! -s "$TMP/uv.log" ]
  [ -x "$HOME/.local/bin/kanban-mcp" ]
}

@test "Kanban MCP rejects a corrupt retained release before network work" {
  _stub_kanban_git_uv
  AICODING_MCP_REGISTRATION_DISABLE=1 run aicoding_update_component mcp-kanban
  [ "$status" -eq 0 ]
  local revision release
  revision=$(cat "$BLUEPRINT_ROOT/configs/versions/kanban-mcp.rev")
  release="$AICODING_DATA_DIR/versions/mcp-kanban/$revision"
  printf '\n# corrupt\n' >> "$release/.venv/bin/kanban-mcp"
  : > "$TMP/git.log"; : > "$TMP/uv.log"

  AICODING_MCP_REGISTRATION_DISABLE=1 run aicoding_update_component mcp-kanban

  [ "$status" -ne 0 ]
  [ ! -s "$TMP/git.log" ]
  [ ! -s "$TMP/uv.log" ]
  jq -e '.components["mcp-kanban"].reason == "existing_release_invalid"' "$AICODING_RESULTS_FILE"
}

@test "Kanban MCP rejects retained file and dangling symlink before network work" {
  _stub_kanban_git_uv
  _seed_old_kanban_release
  local revision release kind
  revision=$(cat "$BLUEPRINT_ROOT/configs/versions/kanban-mcp.rev")
  release="$AICODING_DATA_DIR/versions/mcp-kanban/$revision"
  mkdir -p "$(dirname "$release")"

  for kind in file dangling-symlink; do
    rm -f "$release" "$TMP/git.log" "$TMP/uv.log" "$AICODING_RESULTS_FILE"
    if [ "$kind" = file ]; then
      printf 'corrupt\n' > "$release"
    else
      ln -s "$TMP/missing-retained-release" "$release"
    fi

    AICODING_MCP_REGISTRATION_DISABLE=1 run aicoding_update_component mcp-kanban

    [ "$status" -ne 0 ]
    [ ! -e "$TMP/git.log" ]
    [ ! -e "$TMP/uv.log" ]
    [ "$(readlink "$AICODING_DATA_DIR/current/mcp-kanban")" = '../versions/mcp-kanban/old' ]
    jq -e '.components["mcp-kanban"].reason == "existing_release_invalid"' \
      "$AICODING_RESULTS_FILE"
  done
}

@test "unchanged exact MCP release survives npm prefix-derived lock names across passes" {
  _stub_exact_mcp_npm
  run aicoding_update_component mcp-context7
  [ "$status" -eq 0 ]
  jq -e '.name == "aicoding-mcp-context7" and .packages[""].name == "aicoding-mcp-context7"' \
    "$AICODING_DATA_DIR/versions/mcp-context7/4.1.0/package-lock.json"

  run aicoding_update_component mcp-context7
  [ "$status" -eq 0 ]
  jq -e '.components["mcp-context7"].state == "updated"' "$AICODING_STATE_DIR/update-results.json"
}

@test "verified retained lock wins when the same top-level version resolves new dependency bytes" {
  export MCP_DEP_PAYLOAD=first
  _stub_exact_mcp_npm
  run aicoding_update_component mcp-context7
  [ "$status" -eq 0 ]

  export MCP_DEP_PAYLOAD=second
  run aicoding_update_component mcp-context7
  [ "$status" -eq 0 ]
  [ "$(cat "$AICODING_DATA_DIR/versions/mcp-context7/4.1.0/node_modules/stable-dep/index.js")" = first ]
  [ "$(wc -l < "$TMP/npm-mcp-installs")" -eq 1 ]
}

@test "retained MCP package repairs its launcher and registration without another download" {
  _stub_exact_mcp_npm
  AICODING_MCP_REGISTRATION_DISABLE=1 run aicoding_update_component mcp-context7
  [ "$status" -eq 0 ]
  rm "$HOME/.local/bin/context7-mcp"
  cat > "$TMP/stubs/claude" <<'EOF'
#!/bin/sh
case "$*" in
  --version) echo '2.1.50 (Claude Code)' ;;
  'mcp get context7')
    [ -f "$TMP/registered" ] || exit 1
    printf 'Command: %s/.local/bin/context7-mcp\nArgs: \n' "$HOME" ;;
  'mcp add '*) touch "$TMP/registered" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$TMP/stubs/claude"
  AICODING_MCP_REGISTRATION_FORCE=1 run aicoding_update_component mcp-context7
  [ "$status" -eq 0 ]
  [ -x "$HOME/.local/bin/context7-mcp" ]
  jq -e '.components["mcp-registration-claude-context7"].successful_version == "4.1.0"' "$AICODING_RESULTS_FILE"
  [ "$(wc -l < "$TMP/npm-mcp-installs")" -eq 1 ]
}

@test "retained Playwright package restores a missing browser without another download" {
  _stub_exact_mcp_npm
  _tool ldd 'libgbm.so.1 => /lib/libgbm.so.1'
  run aicoding_update_component mcp-playwright
  [ "$status" -eq 0 ]
  rm -rf "$AICODING_DATA_DIR/browser-cache/mcp-playwright/0.0.80"
  run aicoding_update_component mcp-playwright
  [ "$status" -eq 0 ]
  [ -x "$AICODING_DATA_DIR/browser-cache/mcp-playwright/0.0.80/chromium-123/chrome-linux64/chrome" ]
  [ "$(wc -l < "$TMP/npm-mcp-installs")" -eq 1 ]
}

@test "a newer MCP target downloads and activates while retaining the previous release" {
  _stub_exact_mcp_npm
  run aicoding_update_component mcp-context7
  [ "$status" -eq 0 ]
  sed -i 's/4\.1\.0/4.2.0/g' "$TMP/stubs/npm"
  run aicoding_update_component mcp-context7
  [ "$status" -eq 0 ]
  [ "$(readlink -f "$AICODING_DATA_DIR/current/mcp-context7")" = "$AICODING_DATA_DIR/versions/mcp-context7/4.2.0" ]
  [ -d "$AICODING_DATA_DIR/versions/mcp-context7/4.1.0" ]
  [ "$(wc -l < "$TMP/npm-mcp-installs")" -eq 2 ]
}

@test "exact MCP staging rejects ignored install lifecycle scripts in package dependencies" {
  export MCP_LIFECYCLE=dependency
  _stub_exact_mcp_npm

  run aicoding_update_component mcp-context7
  [ "$status" -ne 0 ]
  [ ! -e "$AICODING_DATA_DIR/current/mcp-context7" ]
  jq -e '.components["mcp-context7"].reason == "lifecycle_scripts_required"' \
    "$AICODING_STATE_DIR/update-results.json"
}

@test "failed MCP package enumeration is a failure rather than a successful or deferred install" {
  _stub_exact_mcp_npm
  find() { return 1; }
  run aicoding_update_component mcp-context7
  [ "$status" -ne 0 ]
  [ ! -e "$AICODING_DATA_DIR/current/mcp-context7" ]
  jq -e '.components["mcp-context7"].state == "failed"
    and .components["mcp-context7"].reason == "package_inventory_unavailable"' \
    "$AICODING_STATE_DIR/update-results.json"
}

@test "corrupt retained MCP release is rejected before download or activation" {
  _stub_exact_mcp_npm
  run aicoding_update_component mcp-context7
  [ "$status" -eq 0 ]
  mkdir -p "$AICODING_DATA_DIR/versions/mcp-context7/old"
  ln -sfn ../versions/mcp-context7/old "$AICODING_DATA_DIR/current/mcp-context7"
  printf '#!/bin/sh\necho corrupted\n' \
    > "$AICODING_DATA_DIR/versions/mcp-context7/4.1.0/node_modules/@upstash/context7-mcp/dist/index.js"

  run aicoding_update_component mcp-context7
  [ "$status" -ne 0 ]
  [ "$(readlink "$AICODING_DATA_DIR/current/mcp-context7")" = ../versions/mcp-context7/old ]
  jq -e '.components["mcp-context7"].reason == "existing_release_invalid"' \
    "$AICODING_STATE_DIR/update-results.json"
  [ "$(wc -l < "$TMP/npm-mcp-installs")" -eq 1 ]
}

@test "failed exact MCP release commit replaces an old success receipt" {
  _stub_exact_mcp_npm
  aicoding_result_record mcp-context7 current 4.0.0 installed 4.0.0
  mv() {
    local last=${!#}
    [[ "$last" == "$AICODING_DATA_DIR/versions/mcp-context7/4.1.0" ]] && return 8
    command mv "$@"
  }

  run aicoding_update_component mcp-context7
  [ "$status" -ne 0 ]
  jq -e '.components["mcp-context7"].state == "failed"
    and .components["mcp-context7"].reason == "release_commit_failed"
    and .components["mcp-context7"].successful_version == "4.0.0"' \
    "$AICODING_STATE_DIR/update-results.json"
}

@test "failed Playwright browser marker commit replaces an old success receipt" {
  _stub_exact_mcp_npm
  aicoding_result_record mcp-playwright current 0.0.79 installed 0.0.79
  cat > "$TMP/stubs/ldd" <<'EOF'
#!/bin/sh
echo 'libgbm.so.1 => /lib/libgbm.so.1'
EOF
  chmod +x "$TMP/stubs/ldd"
  mv() {
    local last=${!#}
    [[ "$last" == */browser-cache/mcp-playwright/0.0.80/.browser-bin ]] && return 8
    command mv "$@"
  }

  run aicoding_update_component mcp-playwright
  [ "$status" -ne 0 ]
  jq -e '.components["mcp-playwright"].state == "failed"
    and .components["mcp-playwright"].reason == "browser_marker_commit_failed"
    and .components["mcp-playwright"].successful_version == "0.0.79"' \
    "$AICODING_STATE_DIR/update-results.json"
}

@test "Context7 stages an exact immutable tree and activates its stable launcher" {
  _stub_exact_mcp_npm
  run aicoding_update_component mcp-context7
  [ "$status" -eq 0 ]
  [ -x "$AICODING_DATA_DIR/versions/mcp-context7/4.1.0/node_modules/@upstash/context7-mcp/dist/index.js" ]
  [ "$(readlink "$AICODING_DATA_DIR/current/mcp-context7")" = ../versions/mcp-context7/4.1.0 ]
  [ -x "$HOME/.local/bin/context7-mcp" ]
  grep -q -- '--engine-strict' "$TMP/npm-mcp-args"
  jq -e '.components["mcp-context7"].successful_version == "4.1.0"' "$AICODING_STATE_DIR/update-results.json"
}

@test "Playwright uses its exact staged CLI and a version-specific retained browser cache" {
  _stub_exact_mcp_npm
  mkdir -p "$AICODING_DATA_DIR/browser-cache/mcp-playwright/old/chromium-old"
  cat > "$TMP/stubs/ldd" <<'EOF'
#!/bin/sh
echo 'libgbm.so.1 => /lib/libgbm.so.1'
EOF
  chmod +x "$TMP/stubs/ldd"
  run aicoding_update_component mcp-playwright
  [ "$status" -eq 0 ]
  [ -x "$AICODING_DATA_DIR/browser-cache/mcp-playwright/0.0.80/chromium-123/chrome-linux64/chrome" ]
  [ -d "$AICODING_DATA_DIR/browser-cache/mcp-playwright/old/chromium-old" ]
  [ -x "$HOME/.local/bin/playwright-mcp" ]
  grep -q '^playwright$' "$TMP/npm-mcp-installs"
  if rg -q '@latest|npx' "$HOME/.local/bin/playwright-mcp" "$TMP/npm-mcp-installs"; then false; fi
}

@test "Playwright leaves the old active release selected when exact browser libraries are unavailable" {
  _stub_exact_mcp_npm
  mkdir -p "$AICODING_DATA_DIR/current" "$AICODING_DATA_DIR/versions/mcp-playwright/old"
  ln -s ../versions/mcp-playwright/old "$AICODING_DATA_DIR/current/mcp-playwright"
  cat > "$TMP/stubs/ldd" <<'EOF'
#!/bin/sh
echo 'libmissing.so => not found'
EOF
  printf '#!/bin/sh\nexit 1\n' > "$TMP/stubs/sudo"
  chmod +x "$TMP/stubs/ldd" "$TMP/stubs/sudo"
  run aicoding_update_component mcp-playwright
  [ "$status" -ne 0 ]
  [ "$(readlink "$AICODING_DATA_DIR/current/mcp-playwright")" = ../versions/mcp-playwright/old ]
  jq -e '.components["mcp-playwright"].state == "blocked"
    and (.components["mcp-playwright"].reason | contains("system_libs"))' "$AICODING_STATE_DIR/update-results.json"
}

@test "an old container Node runtime reports a manual rebuild prerequisite" {
  _tool node 'v18.20.0'
  _sync_profile() { echo container; }
  run aicoding_update_component mcp-context7
  [ "$status" -ne 0 ]
  jq -e '.components["mcp-context7"].state == "blocked"
    and .components["mcp-context7"].reason == "manual_rebuild_required_node"' \
    "$AICODING_STATE_DIR/update-results.json"
}

@test "an engine-strict npm rejection is classified as a container Node prerequisite" {
  _sync_profile() { echo container; }
  cat > "$TMP/stubs/npm" <<'EOF'
#!/bin/sh
if [ "$1" = view ]; then echo '"4.1.0"'; exit 0; fi
echo 'npm ERR! code EBADENGINE' >&2
exit 1
EOF
  chmod +x "$TMP/stubs/npm"
  run aicoding_update_component mcp-context7
  [ "$status" -ne 0 ]
  jq -e '.components["mcp-context7"].state == "blocked"
    and .components["mcp-context7"].reason == "manual_rebuild_required_node"' \
    "$AICODING_STATE_DIR/update-results.json"
}

@test "Claude uses the documented exact-version installer in an isolated HOME before activation" {
  _tool claude '2.1.49 (Claude Code)'
  cat > "$TMP/stubs/npm" <<'EOF'
#!/bin/sh
[ "$1" = view ] && { echo '"2.1.50"'; exit 0; }
exit 1
EOF
  cat > "$TMP/stubs/curl" <<'EOF'
#!/bin/sh
cat <<'INSTALLER'
#!/bin/sh
version=$1
mkdir -p "$HOME/.local/share/claude/versions" "$HOME/.local/bin"
cat > "$HOME/.local/share/claude/versions/$version" <<BIN
#!/bin/sh
echo '$version (Claude Code)'
BIN
chmod +x "$HOME/.local/share/claude/versions/$version"
ln -s "../share/claude/versions/$version" "$HOME/.local/bin/claude"
INSTALLER
EOF
  chmod +x "$TMP/stubs/npm" "$TMP/stubs/curl"

  run aicoding_update_claude
  [ "$status" -eq 0 ]
  [ -x "$AICODING_DATA_DIR/versions/claude/2.1.50/bin/claude" ]
  [ "$(readlink "$AICODING_DATA_DIR/current/claude")" = "../versions/claude/2.1.50" ]
  jq -e '.components.claude.state == "updated"' "$AICODING_STATE_DIR/update-results.json"
}

@test "Claude refuses to activate a corrupt preexisting release" {
  _tool claude '2.1.49 (Claude Code)'
  mkdir -p "$AICODING_DATA_DIR/versions/claude/2.1.50/bin"
  printf '#!/bin/sh\necho 0.0.1\n' > "$AICODING_DATA_DIR/versions/claude/2.1.50/bin/claude"
  chmod +x "$AICODING_DATA_DIR/versions/claude/2.1.50/bin/claude"
  cat > "$TMP/stubs/npm" <<'EOF'
#!/bin/sh
[ "$1" = view ] && { echo '"2.1.50"'; exit 0; }
exit 1
EOF
  cat > "$TMP/stubs/curl" <<'EOF'
#!/bin/sh
cat <<'INSTALLER'
#!/bin/sh
version=$1
mkdir -p "$HOME/.local/share/claude/versions"
printf '#!/bin/sh\necho "%s (Claude Code)"\n' "$version" > "$HOME/.local/share/claude/versions/$version"
chmod +x "$HOME/.local/share/claude/versions/$version"
INSTALLER
EOF
  chmod +x "$TMP/stubs/npm" "$TMP/stubs/curl"
  run aicoding_update_claude
  [ "$status" -ne 0 ]
  [ ! -e "$AICODING_DATA_DIR/current/claude" ]
  jq -e '.components.claude.reason == "existing_release_invalid"' "$AICODING_STATE_DIR/update-results.json"
}

@test "dvw exact staged source invokes only its unattended managed adapter" {
  _tool dvw 'dvw 1.0.0'
  local sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  aicoding_select_ci_sha() { printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; }
  _aicoding_stage_git_source() {
    mkdir -p "$3/lib"; printf '%s\n' "$2" > "$3/.aicoding-version"
    cat > "$3/lib/managed-install.sh" <<'ADAPTER'
dvw_managed_install() { printf '%s|%s\n' "$1" "$2" > "$TMP/dvw-adapter"; }
ADAPTER
  }
  export -f aicoding_select_ci_sha _aicoding_stage_git_source
  run aicoding_update_dvw
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/dvw-adapter")" = "$AICODING_DATA_DIR/sources/dvw/$sha|$sha" ]
  jq -e --arg s "$sha" '.components.dvw.state == "updated" and .components.dvw.successful_version == $s' "$AICODING_STATE_DIR/update-results.json"
}

@test "bw-AICode exact stage validates and activates wrappers and guard" {
  local sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  aicoding_select_ci_sha() { printf '%s\n' bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; }
  _aicoding_stage_git_source() {
    mkdir -p "$3/cmd/bw-docker-guard"
    for s in claude-bw opencode-bw pi-bw; do printf '#!/bin/sh\nexit 0\n' > "$3/$s.sh"; chmod +x "$3/$s.sh"; done
    : > "$3/go.mod"; printf '%s\n' "$2" > "$3/.aicoding-version"
  }
  cat > "$TMP/stubs/go" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TMP/go-calls"
case "$1" in
  test) exit 0 ;;
  build) while [ $# -gt 0 ]; do [ "$1" = -o ] && { out=$2; break; }; shift; done; printf '#!/bin/sh\nexit 0\n' > "$out"; chmod +x "$out" ;;
esac
EOF
  chmod +x "$TMP/stubs/go"
  export -f aicoding_select_ci_sha _aicoding_stage_git_source
  run aicoding_update_bw
  [ "$status" -eq 0 ]
  [ "$(readlink "$AICODING_DATA_DIR/current/bw-AICode")" = "../versions/bw-AICode/$sha" ]
  [ -x "$HOME/.local/bin/claude-bw" ]
  [ -x "$HOME/.local/bin/bw-docker-guard" ]
  : > "$TMP/go-calls"
  run aicoding_update_bw
  [ "$status" -eq 0 ]
  [ ! -s "$TMP/go-calls" ]
}

@test "bw-AICode identifies missing Go in a container as a rebuild prerequisite" {
  # An ambient Go installation must not change this missing-runtime scenario.
  printf '#!/bin/sh\necho unexpected-go-call >> "$TMP/go-calls"\nexit 1\n' > "$TMP/stubs/go"
  chmod +x "$TMP/stubs/go"
  local sha=cccccccccccccccccccccccccccccccccccccccc
  aicoding_select_ci_sha() { printf '%s\n' cccccccccccccccccccccccccccccccccccccccc; }
  _aicoding_stage_git_source() {
    mkdir -p "$3/cmd/bw-docker-guard"
    for s in claude-bw opencode-bw pi-bw; do printf '#!/bin/sh\nexit 0\n' > "$3/$s.sh"; chmod +x "$3/$s.sh"; done
    : > "$3/go.mod"; printf '%s\n' "$2" > "$3/.aicoding-version"
  }
  _sync_profile() { echo container; }
  command() { [ "$1 ${2:-}" != '-v go' ] || return 1; builtin command "$@"; }
  export -f aicoding_select_ci_sha _aicoding_stage_git_source _sync_profile command
  run aicoding_update_bw
  [ "$status" -ne 0 ]
  [ ! -e "$TMP/go-calls" ]
  jq -e '.components["bw-AICode"].state == "blocked"
    and .components["bw-AICode"].reason == "manual_rebuild_required_go"' \
    "$AICODING_STATE_DIR/update-results.json"
}

_stub_ai_usage_source() {  # $1 = test outcome (pass|fail)
  export AI_USAGE_TESTS=${1:-pass}
  aicoding_select_ci_sha() { printf '%s\n' dddddddddddddddddddddddddddddddddddddddd; }
  _aicoding_stage_git_source() {
    mkdir -p "$3"
    printf '#!/usr/bin/env python3\nprint("ai-usage ok")\n' > "$3/ai_usage.py"
    chmod +x "$3/ai_usage.py"
    printf 'import sys\nsys.exit(0 if "%s" == "pass" else 1)\n' "$AI_USAGE_TESTS" > "$3/test_ai_usage.py"
    printf '%s\n' "$2" > "$3/.aicoding-version"
    printf '%s\n' "$3" >> "$TMP/ai-usage-staged"
  }
  export -f aicoding_select_ci_sha _aicoding_stage_git_source
}

@test "ai-usage stages the CI-selected commit, tests it, and activates the launcher" {
  local sha=dddddddddddddddddddddddddddddddddddddddd
  _stub_ai_usage_source pass
  ln -s /nonexistent/ai_usage.py "$HOME/.local/bin/ai-usage"

  run aicoding_update_component ai-usage

  [ "$status" -eq 0 ]
  [ "$(readlink "$AICODING_DATA_DIR/current/ai-usage")" = "../versions/ai-usage/$sha" ]
  [ "$("$HOME/.local/bin/ai-usage")" = 'ai-usage ok' ]
  [ "$(readlink "$HOME/.local/bin/ai-usage.pre-aicoding")" = /nonexistent/ai_usage.py ]
  [ ! -e "$AICODING_DATA_DIR/versions/ai-usage/$sha/test_ai_usage.py" ]
  jq -e --arg s "$sha" '.components["ai-usage"].state == "updated"
    and .components["ai-usage"].successful_version == $s' "$AICODING_RESULTS_FILE"
}

@test "ai-usage reuses an existing release without fetching or testing again" {
  _stub_ai_usage_source pass
  run aicoding_update_component ai-usage
  [ "$status" -eq 0 ]
  : > "$TMP/ai-usage-staged"

  run aicoding_update_component ai-usage

  [ "$status" -eq 0 ]
  [ ! -s "$TMP/ai-usage-staged" ]
}

@test "ai-usage refuses a retained release whose bytes changed" {
  local sha=dddddddddddddddddddddddddddddddddddddddd release
  _stub_ai_usage_source pass
  run aicoding_update_component ai-usage
  [ "$status" -eq 0 ]
  release="$AICODING_DATA_DIR/versions/ai-usage/$sha"
  chmod u+w "$release" "$release/ai_usage.py"
  printf '#!/usr/bin/env python3\nprint("tampered")\n' > "$release/ai_usage.py"

  run aicoding_update_component ai-usage

  [ "$status" -ne 0 ]
  jq -e '.components["ai-usage"].state == "failed"
    and .components["ai-usage"].reason == "existing_release_invalid"' "$AICODING_RESULTS_FILE"
}

@test "ai-usage refuses a commit whose tests fail" {
  local sha=dddddddddddddddddddddddddddddddddddddddd
  _stub_ai_usage_source fail

  run aicoding_update_component ai-usage

  [ "$status" -ne 0 ]
  [ ! -e "$AICODING_DATA_DIR/versions/ai-usage/$sha" ]
  [ ! -e "$AICODING_DATA_DIR/current/ai-usage" ]
  jq -e '.components["ai-usage"].state == "failed"
    and .components["ai-usage"].reason == "tests_failed"' "$AICODING_RESULTS_FILE"
}

@test "ai-usage is deferred, not failed, when CI selection is unavailable" {
  aicoding_select_ci_sha() { return 2; }
  export -f aicoding_select_ci_sha

  run aicoding_update_component ai-usage

  [ "$status" -ne 0 ]
  jq -e '.components["ai-usage"].state == "blocked"
    and .components["ai-usage"].reason == "ci_selection_unavailable"' "$AICODING_RESULTS_FILE"
}

@test "installed component discovery selects ai-usage on the container profile" {
  _sync_profile() { echo container; }
  run aicoding_installed_components
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Fxq ai-usage
}

@test "installed component discovery selects ai-usage on a host only when installed" {
  _sync_profile() { echo host; }
  run aicoding_installed_components
  if printf '%s\n' "$output" | grep -Fxq ai-usage; then false; fi
  _tool ai-usage 'unused'
  run aicoding_installed_components
  printf '%s\n' "$output" | grep -Fxq ai-usage
}

_fleet_proof() {  # $1 root, $2 consumer id, [$3 generated_at], [$4 newest start]
  local now; now=$(date +%s)
  jq -n --arg r "$1" --arg id "$2" --argjson g "${3:-$now}" --argjson n "${4:-$((now - 60))}" \
    --argjson e "$((now + 300))" '{schema:1,generated_at:$g,newest_container_started_at:$n,roots:[
      {shared_root:$r,inventory_complete:true,expires_at:$e,consumers:[
        {id:$id,components:{codex:{version:"0.200.0",config_compatible:true}}}]}]}' \
    > "$AICODING_SHARED_CONSUMERS_FILE"
}

_fleet_env() {
  mkdir -p "$HOME/.codex"
  export AICODING_REQUIRE_SHARED_COMPATIBILITY=1
  export AICODING_SHARED_CONSUMERS_FILE="$TMP/consumers.json"
  export AICODING_SHARED_CONFIG_ROOTS; AICODING_SHARED_CONFIG_ROOTS=$(readlink -f "$HOME/.codex")
  export AICODING_SELF_CONTAINER_ID=selfid
}

@test "fleet proof listing this container opens the gate" {
  _fleet_env
  _fleet_proof "$AICODING_SHARED_CONFIG_ROOTS" selfid
  run _aicoding_shared_consumers_allow codex 0.148.0 "$HOME/.codex/config.toml"
  [ "$status" -eq 0 ]
}

@test "fleet proof that does not list this container keeps the gate closed" {
  _fleet_env
  _fleet_proof "$AICODING_SHARED_CONFIG_ROOTS" someoneelse
  run _aicoding_shared_consumers_allow codex 0.148.0 "$HOME/.codex/config.toml"
  [ "$status" -ne 0 ]
}

@test "unknown own container id fails closed on a shared root" {
  _fleet_env
  unset AICODING_SELF_CONTAINER_ID
  export AICODING_MOUNTINFO="$TMP/mountinfo"; : > "$AICODING_MOUNTINFO"
  _fleet_proof "$AICODING_SHARED_CONFIG_ROOTS" selfid
  run _aicoding_shared_consumers_allow codex 0.148.0 "$HOME/.codex/config.toml"
  [ "$status" -ne 0 ]
}

@test "proof generated before the newest container start is rejected" {
  _fleet_env
  local now; now=$(date +%s)
  _fleet_proof "$AICODING_SHARED_CONFIG_ROOTS" selfid "$((now - 10))" "$now"
  run _aicoding_shared_consumers_allow codex 0.148.0 "$HOME/.codex/config.toml"
  [ "$status" -ne 0 ]
}

@test "proof without generated_at is rejected" {
  _fleet_env
  _fleet_proof "$AICODING_SHARED_CONFIG_ROOTS" selfid
  jq 'del(.generated_at)' "$AICODING_SHARED_CONSUMERS_FILE" > "$TMP/x" && mv "$TMP/x" "$AICODING_SHARED_CONSUMERS_FILE"
  run _aicoding_shared_consumers_allow codex 0.148.0 "$HOME/.codex/config.toml"
  [ "$status" -ne 0 ]
}

@test "own container id is read from mountinfo" {
  unset AICODING_SELF_CONTAINER_ID
  export AICODING_MOUNTINFO="$TMP/mountinfo"
  printf '1 2 0:1 /var/lib/docker/containers/%s/hostname /etc/hostname rw - ext4 /dev/x rw\n' \
    "$(printf 'a%.0s' {1..64})" > "$AICODING_MOUNTINFO"
  run _aicoding_self_container_id
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'a%.0s' {1..64})" ]
}

@test "own container id ignores inner DinD container paths listed before the hostname mount" {
  set -o pipefail
  unset AICODING_SELF_CONTAINER_ID
  export AICODING_MOUNTINFO="$TMP/mountinfo"
  local inner self
  inner=$(printf 'b%.0s' {1..64}); self=$(printf 'a%.0s' {1..64})
  {
    printf '1 2 0:1 /var/lib/docker/containers/%s/mounts/shm /var/lib/docker/containers/%s/mounts/shm rw - tmpfs shm rw\n' "$inner" "$inner"
    printf '2 2 0:1 /docker/containers/%s/resolv.conf /etc/resolv.conf rw - ext4 /dev/x rw\n' "$self"
    printf '3 2 0:1 /docker/containers/%s/hostname /etc/hostname rw - ext4 /dev/x rw\n' "$self"
    printf '4 2 0:1 /var/lib/docker/containers/%s/hostname /var/lib/docker/containers/%s/hostname rw - ext4 /dev/x rw\n' "$inner" "$inner"
    # Enough trailing lines that an early-exiting reader would SIGPIPE a writer.
    for i in $(seq 1 5000); do printf '%s 2 0:1 /x /y%s rw - ext4 /dev/x rw\n' "$((i + 4))" "$i"; done
  } > "$AICODING_MOUNTINFO"
  run _aicoding_self_container_id
  [ "$status" -eq 0 ]
  [ "$output" = "$self" ]
}

@test "own container id skips an inner hostname root field at a non-etc mount point listed first" {
  unset AICODING_SELF_CONTAINER_ID
  export AICODING_MOUNTINFO="$TMP/mountinfo"
  local inner self
  inner=$(printf 'b%.0s' {1..64}); self=$(printf 'a%.0s' {1..64})
  {
    # The inner container's own /containers/<id>/hostname root field, but
    # mounted at its own mount point, not /etc/hostname. An unanchored
    # match on the root field alone would pick this line up first.
    printf '1 2 0:1 /var/lib/docker/containers/%s/hostname /var/lib/docker/containers/%s/hostname rw - ext4 /dev/x rw\n' "$inner" "$inner"
    printf '2 2 0:1 /docker/containers/%s/hostname /etc/hostname rw - ext4 /dev/x rw\n' "$self"
  } > "$AICODING_MOUNTINFO"
  run _aicoding_self_container_id
  [ "$status" -eq 0 ]
  [ "$output" = "$self" ]
}

@test "mountinfo without a hostname mount gives no own container id" {
  unset AICODING_SELF_CONTAINER_ID
  export AICODING_MOUNTINFO="$TMP/mountinfo"
  printf '1 2 0:1 /var/lib/docker/containers/%s/mounts/shm /dev/shm rw - tmpfs shm rw\n' \
    "$(printf 'b%.0s' {1..64})" > "$AICODING_MOUNTINFO"
  run _aicoding_self_container_id
  [ -z "$output" ]
}

@test "proof without newest_container_started_at is rejected" {
  _fleet_env
  _fleet_proof "$AICODING_SHARED_CONFIG_ROOTS" selfid
  jq 'del(.newest_container_started_at)' "$AICODING_SHARED_CONSUMERS_FILE" > "$TMP/x" && mv "$TMP/x" "$AICODING_SHARED_CONSUMERS_FILE"
  run _aicoding_shared_consumers_allow codex 0.148.0 "$HOME/.codex/config.toml"
  [ "$status" -ne 0 ]
}

@test "proof generated in the same second as the newest container start is rejected" {
  _fleet_env
  local now; now=$(date +%s)
  _fleet_proof "$AICODING_SHARED_CONFIG_ROOTS" selfid "$now" "$now"
  run _aicoding_shared_consumers_allow codex 0.148.0 "$HOME/.codex/config.toml"
  [ "$status" -ne 0 ]
}

# tests/bats/fixtures/fleet-proof-contract.json is a copy of dvw's
# catalog-service/tests/fixtures/fleet-proof-contract.json, which dvw's
# test_cross_repo_contract_fixture_matches_build_proof keeps equal to what
# build_proof writes. If this test fails after copying a new version over,
# the catalog and this gate disagree on the proof format.
@test "the dvw catalog contract fixture opens the gate for every component" {
  mkdir -p "$HOME/.claude" "$HOME/.codex" "$HOME/.cursor"
  export AICODING_REQUIRE_SHARED_COMPATIBILITY=1
  export AICODING_SHARED_CONSUMERS_FILE="$TMP/consumers.json"
  local claude codex cursor now
  claude=$(readlink -f "$HOME/.claude"); codex=$(readlink -f "$HOME/.codex"); cursor=$(readlink -f "$HOME/.cursor")
  export AICODING_SHARED_CONFIG_ROOTS="$claude:$codex:$cursor"
  now=$(date +%s)
  jq --argjson now "$now" --arg home "$(readlink -f "$HOME")" '
    (.generated_at - .newest_container_started_at) as $age
    | .generated_at = $now | .newest_container_started_at = ($now - $age)
    | .roots |= map(.expires_at = ($now + 300)
        | .shared_root |= sub("^/home/codespace"; $home))' \
    "$BLUEPRINT_ROOT/tests/bats/fixtures/fleet-proof-contract.json" > "$AICODING_SHARED_CONSUMERS_FILE"
  AICODING_SELF_CONTAINER_ID=$(jq -r '.roots[0].consumers[1].id' "$AICODING_SHARED_CONSUMERS_FILE")
  export AICODING_SELF_CONTAINER_ID
  [[ "$AICODING_SELF_CONTAINER_ID" =~ ^[0-9a-f]{64}$ ]]
  local component root minimum
  for root in "$claude" "$codex" "$cursor"; do
    for component in claude codex cursor mcp-context7 mcp-playwright mcp-kanban; do
      minimum=""; [ "$component" != codex ] || minimum=0.148.0
      _aicoding_shared_consumers_allow "$component" "$minimum" "$root/config" \
        || { echo "gate closed: $component on $root"; return 1; }
    done
  done
  # Same proof, but this container is not a consumer: closed.
  AICODING_SELF_CONTAINER_ID=$(printf 'c%.0s' {1..64})
  run _aicoding_shared_consumers_allow claude "" "$claude/config"
  [ "$status" -ne 0 ]
}

@test "default proof path is the fleet directory" {
  unset AICODING_SHARED_CONSUMERS_FILE
  run bash -c ". '$BLUEPRINT_ROOT/lib/update-results.sh'; . '$BLUEPRINT_ROOT/lib/update-components.sh'; declare -f _aicoding_shared_consumers_allow"
  [[ "$output" == *'/.aicodingsetup/fleet/consumer-versions.json'* ]]
}
