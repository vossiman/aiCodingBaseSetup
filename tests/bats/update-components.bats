#!/usr/bin/env bats

setup() {
  : "${BLUEPRINT_ROOT:?run via tests/bats/run.sh}"
  export TMP; TMP=$(mktemp -d)
  export HOME="$TMP/home"
  export AICODING_STATE_DIR="$TMP/state"
  export AICODING_DATA_DIR="$TMP/data"
  export AICODING_EXACT_MCP_CONFIG_READY=1
  mkdir -p "$HOME/.local/bin" "$TMP/stubs"
  export PATH="$HOME/.local/bin:$TMP/stubs:/usr/bin:/bin"
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
  export AICODING_EXACT_MCP_CONFIG_READY=0
  export AICODING_REQUIRE_UPDATE_RECEIPT=1
  unset AICODINGSETUP_SKIP_NETWORK
  _tool codex 'codex-cli 0.200.0'
  run aicoding_config_is_compatible "$HOME/.codex/config.toml"
  [ "$status" -ne 0 ]
  [ "$output" = mcp_exact_version_staging_unavailable ]
  run aicoding_config_is_compatible "$HOME/.codex/AGENTS.md"
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
