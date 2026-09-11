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
  [ "$output" = $'aicoding\nclaude\ncodex\npi' ]
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

@test "known Cursor staging limitation is a completed component deferral" {
  unset AICODINGSETUP_SKIP_NETWORK
  _tool agent 'cursor-agent 2026.08.01'

  run aicoding_update_installed_components
  [ "$status" -eq 0 ]
  jq -e '.components.cursor.state == "blocked"
    and .components.cursor.reason == "versioned_staging_unavailable"' \
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
  for component in mcp-context7 mcp-playwright; do
    aicoding_result_record "$component" current 1.0.0 installed 1.0.0
  done
  run aicoding_exact_mcp_config_ready "$HOME/.codex/config.toml"
  [ "$status" -eq 0 ]
  run aicoding_exact_mcp_config_ready "$HOME/.claude/settings.json"
  [ "$status" -ne 0 ]
  for component in mcp-registration-claude-context7 mcp-registration-claude-playwright; do
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
  mkdir -p "$HOME/.codex"
  local expires=$(( $(date +%s) + 3600 )) root
  root=$(readlink -f "$HOME/.codex")
  export AICODING_SHARED_CONFIG_ROOTS="$root"
  cat > "$AICODING_SHARED_CONSUMERS_FILE" <<'EOF'
{"schema":1,"roots":[{"inventory_complete":true,"shared_root":"ROOT","expires_at":EXPIRES,"consumers":[
  {"id":"new","components":{"codex":{"version":"0.200.0","config_compatible":true}}},
  {"id":"old","components":{"codex":{"version":"0.147.0","config_compatible":true}}}
]}]}
EOF
  sed -i "s|ROOT|$root|; s|EXPIRES|$expires|" "$AICODING_SHARED_CONSUMERS_FILE"
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
  jq -n --arg cr "$codex_root" --arg ar "$claude_root" --argjson expires "$expires" '{schema:1,roots:[
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

@test "shared OpenCode runtime data does not classify local config as shared" {
  _tool opencode 'opencode 1.2.3'
  mkdir -p "$HOME/.config/opencode" "$HOME/.local/share/opencode"
  export AICODING_REQUIRE_SHARED_COMPATIBILITY=1
  export AICODING_SHARED_CONFIG_ROOTS="$(readlink -f "$HOME/.local/share/opencode")"
  export AICODING_SHARED_CONSUMERS_FILE="$TMP/missing-consumers.json"
  run aicoding_config_shared_root "$HOME/.config/opencode/opencode.json"
  [ "$status" -ne 0 ]
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
  fi
  if [ -n "${MCP_DEP_PAYLOAD:-}" ]; then
    mkdir -p "$prefix/node_modules/stable-dep"
    printf '{"name":"stable-dep","version":"1.0.0"}\n' > "$prefix/node_modules/stable-dep/package.json"
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

@test "corrupt retained MCP release is rejected against the fresh exact stage" {
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
  local sha=cccccccccccccccccccccccccccccccccccccccc
  aicoding_select_ci_sha() { printf '%s\n' cccccccccccccccccccccccccccccccccccccccc; }
  _aicoding_stage_git_source() {
    mkdir -p "$3/cmd/bw-docker-guard"
    for s in claude-bw opencode-bw pi-bw; do printf '#!/bin/sh\nexit 0\n' > "$3/$s.sh"; chmod +x "$3/$s.sh"; done
    : > "$3/go.mod"; printf '%s\n' "$2" > "$3/.aicoding-version"
  }
  _sync_profile() { echo container; }
  command() { [ "$1 $2" != 'command -v' ] || return 1; builtin command "$@"; }
  export -f aicoding_select_ci_sha _aicoding_stage_git_source _sync_profile command
  run aicoding_update_bw
  [ "$status" -ne 0 ]
  jq -e '.components["bw-AICode"].state == "blocked"
    and .components["bw-AICode"].reason == "manual_rebuild_required_go"' \
    "$AICODING_STATE_DIR/update-results.json"
}
