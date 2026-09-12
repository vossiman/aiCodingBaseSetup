#!/usr/bin/env bats

setup() {
  : "${BLUEPRINT_ROOT:?unset — run via tests/bats/run.sh; refusing to default to / and copy the whole filesystem}"
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  export AICODING_MANIFEST="$TMPDIR/.aicodingsetup/manifest.json"
  export AICODINGSETUP_NONINTERACTIVE=1
  export CODEX_MANAGED_DIR="$TMPDIR/etc-codex"
  export AICODING_TMUX_COMMIT_FILE="$TMPDIR/tmux-commit"
  export BASHRC_BLOCK_START_LIT='# >>> aicoding managed block — do not edit between markers >>>'
  export BASHRC_BLOCK_END_LIT='# <<< aicoding managed block <<<'
  # Stub apt etc. so install.sh's prereq steps no-op.
  export PATH="$TMPDIR/stubs:$PATH"
  mkdir -p "$TMPDIR/stubs" "$TMPDIR/.local/bin"
  # Stub the prereq tools so install.sh's ensure_*/check_* steps no-op instead of
  # doing real work on every test (the biggest suite cost):
  #  - npx: check_playwright runs `npx playwright install chromium` (~22s Chromium
  #    re-download into the fresh per-test $HOME cache).
  #  - claude/opencode: prereq ensure_* invoke the real binaries (migration /
  #    version calls) when present on PATH.
  # NOT stubbed here: codex / agent / cursor-agent — dedicated ensure_codex /
  # ensure_cursor_agent tests set up their own present/absent scenarios for those.
  for cmd in apt-get sudo curl npm npx bash-build-tmux opencode; do
    cat > "$TMPDIR/stubs/$cmd" <<'STUB'
#!/bin/sh
exit 0
STUB
    chmod +x "$TMPDIR/stubs/$cmd"
  done
  cat > "$TMPDIR/stubs/sudo" <<'STUB'
#!/bin/sh
[ "${1:-}" != -n ] || shift
exec "$@"
STUB
  chmod +x "$TMPDIR/stubs/sudo"
  cat > "$TMPDIR/stubs/claude" <<'STUB'
#!/bin/sh
case "$*" in
  --version) echo '2.1.0' ;;
  "mcp get logfire") printf '  URL: https://logfire-eu.pydantic.dev/mcp\n' ;;
esac
exit 0
STUB
  chmod +x "$TMPDIR/stubs/claude"
  # The real test host may have any tmux build. Keep installer tests offline
  # by presenting the exact pinned build through the test-owned marker.
  cat > "$TMPDIR/stubs/tmux" <<'STUB'
#!/bin/sh
if [ "${1:-}" = "-V" ]; then
  echo "tmux next-3.8"
fi
exit 0
STUB
  chmod +x "$TMPDIR/stubs/tmux"
  ln -s "$(command -v node)" "$TMPDIR/stubs/node"
  printf '%s\n' '13c10f672c7a6bc64b2d4829ae550d8d6caf61fe' > "$AICODING_TMUX_COMMIT_FILE"
}

teardown() {
  rm -rf "$TMPDIR"
}

# For tests that MUTATE blueprint sources (simulating "blueprint changed
# upstream"): work on a per-test copy, never on $BLUEPRINT_ROOT itself. The
# suite runs in parallel — an in-place edit of the real checkout is visible to
# every concurrently running test (deploys pick up the marker line → flaky
# hash mismatches), and a killed run leaks the edit into the working tree.
# Sets $BP; run install as `bash "$BP/install.sh"` for every run in the test.
blueprint_copy() {
  BP="$TMPDIR/blueprint"
  rsync -a --exclude=.git "$BLUEPRINT_ROOT/" "$BP/"
  (cd "$BP" && git init -q && git add -A && \
    git -c user.email=t@t -c user.name=t commit -q -m test-copy)
}

@test "install.sh mode: first-deploy when no manifest and no managed files" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ -f "$AICODING_MANIFEST" ]
  [ -f "$HOME/.tmux.conf" ]
}

@test "install.sh: container flow writes no profile key to the manifest" {
  # Regression pin (spec 2026-08-12-host-install-design.md): absent profile
  # key IS the container contract — only install-host.sh may write one.
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  run jq 'has("profile")' "$AICODING_MANIFEST"
  [ "$output" = "false" ]
}

@test "persistent install reports expected preparation deferrals without failing enrollment or stamping provision" {
  export AICODING_PERSISTENT_ENROLLMENT=1
  run env _AICODINGSETUP_NVS_STRIPPED=1 bash -c '
    source "$1"
    aicoding_prepare_installed_config_tools() {
      _AICODING_PREPARATION_DEFERRED=1
      _provision_record_blocked provision-claude claude_shared_consumers_incompatible
    }
    aicoding_prepare_exact_mcps() {
      _AICODING_PREPARATION_DEFERRED=1
      _provision_record_blocked mcp-context7 manual_rebuild_required_node
      _provision_record_blocked mcp-playwright manual_rebuild_required_playwright_system_libs
    }
    main
  ' _ "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"=== Enrolled with deferrals ==="* ]]
  [[ "$output" != *"=== Done! ==="* ]]
  jq -e '(.provision_commit // null) == null' "$AICODING_MANIFEST"
  jq -e '.components.provision.state == "blocked"
    and .components.provision.reason == "preparation_deferred"' \
    "$HOME/.local/state/aicoding/update-results.json"
}

@test "persistent install has both Kanban helpers and immutable MCP before managed config deploys" {
  export AICODING_PERSISTENT_ENROLLMENT=1
  run env _AICODINGSETUP_NVS_STRIPPED=1 bash -c '
    source "$1"
    aicoding_prepare_installed_config_tools() { :; }
    aicoding_prepare_exact_mcps() {
      printf "#!/bin/sh\nexit 0\n" > "$HOME/.local/bin/kanban-mcp"
      chmod +x "$HOME/.local/bin/kanban-mcp"
    }
    install_claude_mcps() { :; }
    install_claude_plugins() { :; }
    install_codex_plugins() { :; }
    deploy_all_managed_files() {
      [ -x "$HOME/.local/bin/kanban-post" ]
      [ -x "$HOME/.local/bin/kanban-work" ]
      [ -x "$HOME/.local/bin/kanban-mcp" ]
      : > "$HOME/kanban-config-ready"
    }
    main
  ' _ "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]
  [ -f "$HOME/kanban-config-ready" ]
}

@test "persistent install propagates an injected preparation failure" {
  export AICODING_PERSISTENT_ENROLLMENT=1
  run env _AICODINGSETUP_NVS_STRIPPED=1 bash -c '
    source "$1"
    aicoding_prepare_installed_config_tools() {
      aicoding_result_record claude failed 2.1.51 stage_install_failed
      return 1
    }
    aicoding_prepare_exact_mcps() { return 0; }
    main
  ' _ "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"=== Incomplete ==="* ]]
  jq -e '.components.provision.state == "failed"
    and .components.provision.reason == "partial_provision_failure"' \
    "$HOME/.local/state/aicoding/update-results.json"
}

@test "direct first-deploy preserves shared config without consumer evidence and does not stamp success" {
  local shared_root="$TMPDIR/shared-codex"
  mkdir -p "$shared_root"
  ln -s "$shared_root" "$HOME/.codex"
  printf 'user-owned = true\n' > "$shared_root/config.toml"
  export AICODING_SHARED_CONFIG_ROOTS="$shared_root"
  export AICODING_SHARED_CONSUMERS_FILE="$TMPDIR/missing-consumers.json"

  run bash "$BLUEPRINT_ROOT/install.sh" --force-reinstall </dev/null

  [ "$status" -eq 0 ]
  [ "$(cat "$shared_root/config.toml")" = "user-owned = true" ]
  [[ "$output" == *"=== Completed with deferrals ==="* ]]
  [[ "$output" != *"=== Done! ==="* ]]
  jq -e '(.provision_commit // null) == null' "$AICODING_MANIFEST"
}

@test "direct adopt does not create missing config below a shared root without evidence" {
  local shared_root="$TMPDIR/shared-codex"
  mkdir -p "$shared_root"
  ln -s "$shared_root" "$HOME/.codex"
  printf 'existing local file\n' > "$HOME/.tmux.conf"
  export AICODING_SHARED_CONFIG_ROOTS="$shared_root"
  export AICODING_SHARED_CONSUMERS_FILE="$TMPDIR/missing-consumers.json"

  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null

  [ "$status" -eq 0 ]
  [ ! -e "$shared_root/config.toml" ]
  [[ "$output" == *"=== Completed with deferrals ==="* ]]
  [[ "$output" != *"=== Done! ==="* ]]
  jq -e '(.provision_commit // null) == null' "$AICODING_MANIFEST"
}

@test "direct reconcile does not restore config into a shared root without evidence" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  rm -rf "$HOME/.codex"
  local shared_root="$TMPDIR/shared-codex" tmp_manifest
  mkdir -p "$shared_root"
  ln -s "$shared_root" "$HOME/.codex"
  export AICODING_SHARED_CONFIG_ROOTS="$shared_root"
  export AICODING_SHARED_CONSUMERS_FILE="$TMPDIR/missing-consumers.json"
  tmp_manifest=$(mktemp)
  jq 'del(.provision_commit)' "$AICODING_MANIFEST" > "$tmp_manifest"
  mv "$tmp_manifest" "$AICODING_MANIFEST"

  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null

  [ "$status" -eq 0 ]
  [ ! -e "$shared_root/config.toml" ]
  [[ "$output" == *"=== Completed with deferrals ==="* ]]
  [[ "$output" != *"=== Done! ==="* ]]
  jq -e '(.provision_commit // null) == null' "$AICODING_MANIFEST"
}

@test "direct first-deploy still writes a missing confirmed-local config root" {
  export AICODING_SHARED_CONSUMERS_FILE="$TMPDIR/missing-consumers.json"
  [ ! -e "$HOME/.codex" ]

  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null

  [ "$status" -eq 0 ]
  [ -f "$HOME/.codex/config.toml" ]
  [[ "$output" == *"=== Done! ==="* ]]
}

@test "direct first-deploy treats an unclassifiable existing config root as guarded" {
  mkdir -p "$HOME/.codex"
  printf 'user-owned = true\n' > "$HOME/.codex/config.toml"
  export AICODING_SHARED_CONSUMERS_FILE="$TMPDIR/missing-consumers.json"
  cat > "$TMPDIR/stubs/findmnt" <<'STUB'
#!/bin/sh
exit 1
STUB
  chmod +x "$TMPDIR/stubs/findmnt"

  run bash "$BLUEPRINT_ROOT/install.sh" --force-reinstall </dev/null

  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.codex/config.toml")" = "user-owned = true" ]
  [[ "$output" == *"=== Completed with deferrals ==="* ]]
  [[ "$output" != *"=== Done! ==="* ]]
  jq -e '(.provision_commit // null) == null' "$AICODING_MANIFEST"
}

@test "direct first-deploy uses a shared config root when complete evidence is present" {
  local shared_root="$TMPDIR/shared-codex" expires results revision release
  mkdir -p "$shared_root" "$HOME/.local/state/aicoding"
  ln -s "$shared_root" "$HOME/.codex"
  export AICODING_SHARED_CONFIG_ROOTS="$shared_root"
  export AICODING_SHARED_CONSUMERS_FILE="$TMPDIR/consumers.json"
  expires=$(( $(date +%s) + 3600 ))
  revision=$(cat "$BLUEPRINT_ROOT/configs/versions/kanban-mcp.rev")
  jq -n --arg root "$shared_root" --arg revision "$revision" --argjson expires "$expires" \
    '{schema:1,roots:[{shared_root:$root,inventory_complete:true,expires_at:$expires,
      consumers:[{id:"known",components:{
        codex:{version:"0.200.0",config_compatible:true},
        "mcp-context7":{version:"1.0.0",config_compatible:true},
        "mcp-playwright":{version:"1.0.0",config_compatible:true},
        "mcp-kanban":{version:$revision,config_compatible:true}
      }}]}]}' > "$AICODING_SHARED_CONSUMERS_FILE"
  results="$HOME/.local/state/aicoding/update-results.json"
  jq -n --arg revision "$revision" '{schema:1,components:{
    codex:{state:"current"},
    "mcp-context7":{state:"current"},
    "mcp-playwright":{state:"current"},
    "mcp-kanban":{state:"current",successful_version:$revision}
  }}' > "$results"
  cat > "$TMPDIR/stubs/codex" <<'STUB'
#!/bin/sh
[ "$*" != --version ] || printf 'codex-cli 0.200.0\n'
exit 0
STUB
  chmod +x "$TMPDIR/stubs/codex"

  source "$BLUEPRINT_ROOT/lib/runtime.sh"
  source "$BLUEPRINT_ROOT/lib/update-results.sh"
  source "$BLUEPRINT_ROOT/lib/update-components.sh"
  release="$AICODING_DATA_DIR/versions/mcp-kanban/$revision"
  mkdir -p "$release/.venv/bin"
  printf '%s\n' "$revision" > "$release/.aicoding-version"
  cat > "$release/.venv/bin/python" <<'STUB'
#!/bin/sh
printf '0.1.0\n'
STUB
  cat > "$release/.venv/bin/kanban-mcp" <<'STUB'
#!/bin/sh
case "${1:-}" in
  --version) printf 'kanban-mcp 0.1.0\n' ;;
  --instructions) printf 'Canonical work instructions.\n' ;;
esac
STUB
  chmod +x "$release/.venv/bin/python" "$release/.venv/bin/kanban-mcp"
  _aicoding_release_integrity_write "$release"
  aicoding_activate_version mcp-kanban "$revision" kanban-mcp .venv/bin/kanban-mcp

  run bash "$BLUEPRINT_ROOT/install.sh" --force-reinstall </dev/null

  [ "$status" -eq 0 ]
  [ -f "$shared_root/config.toml" ]
  grep -q '^approval_policy = "never"$' "$shared_root/config.toml"
}

@test "legacy Claude provisioning defers shared mutation without consumer evidence" {
  local shared_root="$TMPDIR/shared-claude"
  mkdir -p "$shared_root"
  ln -s "$shared_root" "$HOME/.claude"
  export AICODING_SHARED_CONFIG_ROOTS="$shared_root"
  export AICODING_SHARED_CONSUMERS_FILE="$TMPDIR/missing-consumers.json"
  export AICODING_RESULTS_FILE="$TMPDIR/results.json"
  cat > "$TMPDIR/stubs/claude" <<'STUB'
#!/bin/sh
echo "$*" >> "$TMPDIR/claude-calls"
[ "$*" != --version ] || printf '2.1.0\n'
exit 0
STUB
  chmod +x "$TMPDIR/stubs/claude"
  export _AICODINGSETUP_NVS_STRIPPED=1
  source "$BLUEPRINT_ROOT/install.sh"
  _provision_ensure_update_components
  aicoding_result_record claude current 2.1.0 verified 2.1.0

  run install_claude_plugins

  [ "$status" -eq 0 ]
  if grep -q '^plugin ' "$TMPDIR/claude-calls" 2>/dev/null; then false; fi
  jq -e '.components["provision-claude"].state == "blocked"
    and .components["provision-claude"].reason == "claude_shared_consumers_incompatible"' \
    "$AICODING_RESULTS_FILE"
}

@test "legacy guarded Codex provisioning defers on writer lock contention" {
  local shared_root="$TMPDIR/shared-codex" expires
  mkdir -p "$shared_root"
  ln -s "$shared_root" "$HOME/.codex"
  export AICODING_SHARED_CONFIG_ROOTS="$shared_root"
  export AICODING_SHARED_CONSUMERS_FILE="$TMPDIR/consumers.json"
  export AICODING_RESULTS_FILE="$TMPDIR/results.json"
  expires=$(( $(date +%s) + 3600 ))
  jq -n --arg root "$shared_root" --argjson expires "$expires" \
    '{schema:1,roots:[{shared_root:$root,inventory_complete:true,expires_at:$expires,
      consumers:[{id:"known",components:{codex:{version:"0.200.0",config_compatible:true}}}]}]}' \
    > "$AICODING_SHARED_CONSUMERS_FILE"
  cat > "$TMPDIR/stubs/codex" <<'STUB'
#!/bin/sh
echo "$*" >> "$TMPDIR/codex-calls"
[ "$*" != --version ] || printf 'codex-cli 0.200.0\n'
exit 0
STUB
  chmod +x "$TMPDIR/stubs/codex"
  export AICODINGSETUP_SKIP_NETWORK=
  export _AICODINGSETUP_NVS_STRIPPED=1
  source "$BLUEPRINT_ROOT/install.sh"
  _provision_ensure_update_components
  aicoding_result_record codex current 0.200.0 verified 0.200.0
  aicoding_shared_locks_acquire() { return 1; }

  run install_codex_plugins

  [ "$status" -eq 0 ]
  if grep -q '^plugin ' "$TMPDIR/codex-calls" 2>/dev/null; then false; fi
  jq -e '.components["provision-codex"].state == "blocked"
    and .components["provision-codex"].reason == "codex_shared_config_busy"' \
    "$AICODING_RESULTS_FILE"
}

@test "shared legacy Codex provisioning requires a receipt even with complete consumer evidence" {
  local shared_root="$TMPDIR/shared-codex" expires
  mkdir -p "$shared_root"
  ln -s "$shared_root" "$HOME/.codex"
  export AICODING_SHARED_CONFIG_ROOTS="$shared_root"
  export AICODING_SHARED_CONSUMERS_FILE="$TMPDIR/consumers.json"
  export AICODING_RESULTS_FILE="$TMPDIR/results.json"
  expires=$(( $(date +%s) + 3600 ))
  jq -n --arg root "$shared_root" --argjson expires "$expires" \
    '{schema:1,roots:[{shared_root:$root,inventory_complete:true,expires_at:$expires,
      consumers:[{id:"known",components:{codex:{version:"0.200.0",config_compatible:true}}}]}]}' \
    > "$AICODING_SHARED_CONSUMERS_FILE"
  cat > "$TMPDIR/stubs/codex" <<'STUB'
#!/bin/sh
echo "$*" >> "$TMPDIR/codex-calls"
[ "$*" != --version ] || printf 'codex-cli 0.200.0\n'
exit 0
STUB
  chmod +x "$TMPDIR/stubs/codex"
  export AICODINGSETUP_SKIP_NETWORK=
  export _AICODINGSETUP_NVS_STRIPPED=1
  source "$BLUEPRINT_ROOT/install.sh"
  _provision_ensure_update_components

  run install_codex_plugins

  [ "$status" -eq 0 ]
  if grep -q '^plugin ' "$TMPDIR/codex-calls" 2>/dev/null; then false; fi
  jq -e '.components["provision-codex"].state == "blocked"
    and .components["provision-codex"].reason == "codex_update_not_verified"' \
    "$AICODING_RESULTS_FILE"
}

@test "persistent and sync tool readiness require receipts on a confirmed-local root" {
  mkdir -p "$HOME/.codex"
  export AICODING_RESULTS_FILE="$TMPDIR/results.json"
  cat > "$TMPDIR/stubs/codex" <<'STUB'
#!/bin/sh
[ "$*" != --version ] || printf 'codex-cli 0.200.0\n'
exit 0
STUB
  chmod +x "$TMPDIR/stubs/codex"
  export _AICODINGSETUP_NVS_STRIPPED=1
  source "$BLUEPRINT_ROOT/install.sh"
  _provision_ensure_update_components

  export AICODING_PERSISTENT_ENROLLMENT=1
  unset AICODING_SYNC_MODE AICODING_REQUIRE_UPDATE_RECEIPT
  run _provision_tool_ready codex codex 0.148.0 "$HOME/.codex"
  [ "$status" -eq 3 ]
  jq -e '.components["provision-codex"].reason == "codex_update_not_verified"' "$AICODING_RESULTS_FILE"

  rm -f "$AICODING_RESULTS_FILE"
  export AICODING_PERSISTENT_ENROLLMENT=0 AICODING_SYNC_MODE=boot
  unset AICODING_REQUIRE_UPDATE_RECEIPT
  run _provision_tool_ready codex codex 0.148.0 "$HOME/.codex"
  [ "$status" -eq 3 ]
  jq -e '.components["provision-codex"].reason == "codex_update_not_verified"' "$AICODING_RESULTS_FILE"
}

@test "a shared guard does not make later confirmed-local legacy provisioning strict" {
  local shared_root="$TMPDIR/shared-claude" expires
  mkdir -p "$shared_root"
  ln -s "$shared_root" "$HOME/.claude"
  export AICODING_SHARED_CONFIG_ROOTS="$shared_root"
  export AICODING_SHARED_CONSUMERS_FILE="$TMPDIR/consumers.json"
  export AICODING_RESULTS_FILE="$TMPDIR/results.json"
  expires=$(( $(date +%s) + 3600 ))
  jq -n --arg root "$shared_root" --argjson expires "$expires" \
    '{schema:1,roots:[{shared_root:$root,inventory_complete:true,expires_at:$expires,
      consumers:[{id:"known",components:{claude:{version:"2.1.0",config_compatible:true}}}]}]}' \
    > "$AICODING_SHARED_CONSUMERS_FILE"
  cat > "$TMPDIR/stubs/claude" <<'STUB'
#!/bin/sh
[ "$*" != --version ] || printf '2.1.0\n'
exit 0
STUB
  cat > "$TMPDIR/stubs/codex" <<'STUB'
#!/bin/sh
case "$*" in
  --version) printf 'codex-cli 0.200.0\n'; exit 0 ;;
  "plugin add"*) exit 1 ;;
esac
exit 0
STUB
  chmod +x "$TMPDIR/stubs/claude" "$TMPDIR/stubs/codex"
  export AICODINGSETUP_SKIP_NETWORK=
  export _AICODINGSETUP_NVS_STRIPPED=1
  source "$BLUEPRINT_ROOT/install.sh"
  _provision_ensure_update_components
  aicoding_result_record claude current 2.1.0 verified 2.1.0
  _provision_tool_ready claude claude "" "$HOME/.claude"
  [ "${_AICODING_PROVISION_GUARDED:-0}" -eq 1 ]

  run install_codex_plugins

  [ "$status" -eq 0 ]
}

@test "genuine failure in guarded legacy Codex provisioning is truthful" {
  local shared_root="$TMPDIR/shared-codex" expires
  mkdir -p "$shared_root"
  ln -s "$shared_root" "$HOME/.codex"
  export AICODING_SHARED_CONFIG_ROOTS="$shared_root"
  export AICODING_SHARED_CONSUMERS_FILE="$TMPDIR/consumers.json"
  export AICODING_RESULTS_FILE="$TMPDIR/results.json"
  expires=$(( $(date +%s) + 3600 ))
  jq -n --arg root "$shared_root" --argjson expires "$expires" \
    '{schema:1,roots:[{shared_root:$root,inventory_complete:true,expires_at:$expires,
      consumers:[{id:"known",components:{codex:{version:"0.200.0",config_compatible:true}}}]}]}' \
    > "$AICODING_SHARED_CONSUMERS_FILE"
  cat > "$TMPDIR/stubs/codex" <<'STUB'
#!/bin/sh
case "$*" in
  --version) printf 'codex-cli 0.200.0\n'; exit 0 ;;
  "plugin add"*) exit 1 ;;
esac
exit 0
STUB
  chmod +x "$TMPDIR/stubs/codex"
  export AICODINGSETUP_SKIP_NETWORK=
  export _AICODINGSETUP_NVS_STRIPPED=1
  source "$BLUEPRINT_ROOT/install.sh"
  _provision_ensure_update_components
  aicoding_result_record codex current 0.200.0 verified 0.200.0

  run install_codex_plugins

  [ "$status" -ne 0 ]
}

@test "install.sh mode: adopt when managed files exist but no manifest" {
  mkdir -p "$HOME"
  echo "user-customised tmux config" > "$HOME/.tmux.conf"
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  # File content must be untouched.
  grep -q "user-customised" "$HOME/.tmux.conf"
  # Manifest must record the user's hash.
  local user_hash blueprint_hash
  user_hash=$(sha256sum "$HOME/.tmux.conf" | awk '{print $1}')
  blueprint_hash=$(jq -r '.files["'"$HOME"'/.tmux.conf"].deployed_hash' "$AICODING_MANIFEST")
  [ "$user_hash" = "$blueprint_hash" ]
}

@test "install.sh mode: reconcile when manifest exists" {
  # First-deploy populates a real manifest, then a re-run hits reconcile.
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]
  # Output announces reconcile mode (replaces the old "Container already initialized" line).
  echo "$output" | grep -q "Mode: reconcile"
}

# A provisioning run that advances blueprint_commit must invalidate the
# aicoding-status cache, exactly as the two sync paths do (lib/sync.sh). Without
# it the badge keeps the pre-run verdict and _cache_fresh suppresses any
# re-check for the full 6h TTL, so an already-current container shows a phantom
# ⬆aicoding until the TTL lapses. Hit for real 2026-07-26.
@test "install.sh reconcile: advancing blueprint_commit drops the stale aicoding-status cache" {
  export AICODING_UPDATE_STATE="$TMPDIR/state/updates"
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  # Rewind the recorded commit so the reconcile run genuinely advances it.
  local tmp
  tmp=$(mktemp)
  jq '.blueprint_commit = "old"' "$AICODING_MANIFEST" > "$tmp"
  mv "$tmp" "$AICODING_MANIFEST"
  # Seed a stale "behind" verdict, as aicoding-status would have cached it.
  mkdir -p "$AICODING_UPDATE_STATE"
  echo '{"tool":"aicoding","status":"behind"}' > "$AICODING_UPDATE_STATE/aicoding.json"

  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]

  [ "$(jq -r .blueprint_commit "$AICODING_MANIFEST")" != "old" ]
  [ ! -e "$AICODING_UPDATE_STATE/aicoding.json" ]
}

@test "install.sh detects a stale next-3.8 tmux commit marker" {
  printf '%s\n' '5356c62eadf8650ad1ffc95f52755d6f66029a20' > "$AICODING_TMUX_COMMIT_FILE"
  _run_install_fn "$(_isolated_path)" ensure_tmux
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "tmux 3.8 is not pinned commit 13c10f6"
  echo "$output" | grep -q "Skipping tmux rebuild while network operations are disabled"
}

@test "install.sh --force-reinstall: deletes manifest and re-deploys" {
  mkdir -p "$HOME/.aicodingsetup"
  echo '{"schema_version":1,"files":{}}' > "$AICODING_MANIFEST"
  echo "user-edit-that-should-be-clobbered" > "$HOME/.tmux.conf"
  run bash "$BLUEPRINT_ROOT/install.sh" --force-reinstall </dev/null
  [ "$status" -eq 0 ]
  # File must be overwritten from blueprint.
  if grep -q "user-edit-that-should-be-clobbered" "$HOME/.tmux.conf"; then false; fi
  # Manifest must record blueprint-hash, not user's hash.
  local blueprint_hash deployed_hash
  blueprint_hash=$(sha256sum "$BLUEPRINT_ROOT/configs/tmux/tmux.conf" | awk '{print $1}')
  deployed_hash=$(jq -r '.files["'"$HOME"'/.tmux.conf"].deployed_hash' "$AICODING_MANIFEST")
  [ "$blueprint_hash" = "$deployed_hash" ]
}

@test "install.sh adopt: strips standalone Go-PATH export from ~/.bashrc" {
  mkdir -p "$HOME"
  cat > "$HOME/.bashrc" <<'EOF'
export PATH="/usr/local/go/bin:$PATH"
echo hello
EOF
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  # Standalone line is gone; managed block contains it inside markers.
  local outside_block
  outside_block=$(awk -v s="$BASHRC_BLOCK_START_LIT" -v e="$BASHRC_BLOCK_END_LIT" '
    $0 == s { in_block = 1; next }
    $0 == e { in_block = 0; next }
    !in_block { print }
  ' "$HOME/.bashrc")
  if echo "$outside_block" | grep -qF 'export PATH="/usr/local/go/bin:$PATH"'; then
    echo "Go-PATH export still present outside managed block:"
    echo "$outside_block"
    return 1
  fi
  grep -qF 'export PATH="/usr/local/go/bin:$PATH"' "$HOME/.bashrc"
}

@test "install.sh: does not install the removed shims (aicoding-update, update-status)" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ ! -e "$HOME/.local/bin/aicoding-update" ]
  [ ! -e "$HOME/.local/bin/update-status" ]
}

@test "install.sh symlinks aicoding-sync into ~/.local/bin" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ -L "$HOME/.local/bin/aicoding-sync" ]
  [ -x "$HOME/.local/bin/aicoding-sync" ]
  readlink "$HOME/.local/bin/aicoding-sync" | grep -q "bin/aicoding-sync"
}

@test "install.sh symlinks aicoding-install into ~/.local/bin" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ -L "$HOME/.local/bin/aicoding-install" ]
  [ -x "$HOME/.local/bin/aicoding-install" ]
  readlink "$HOME/.local/bin/aicoding-install" | grep -q "bin/aicoding-install"
}

@test "install.sh symlinks agent-notify into ~/.local/bin" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ -L "$HOME/.local/bin/agent-notify" ]
  [ -x "$HOME/.local/bin/agent-notify" ]
  readlink "$HOME/.local/bin/agent-notify" | grep -q "bin/agent-notify"
}

@test "install.sh symlinks dvw-probe into ~/.local/bin" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ -L "$HOME/.local/bin/dvw-probe" ]
  [ -x "$HOME/.local/bin/dvw-probe" ]
  readlink "$HOME/.local/bin/dvw-probe" | grep -q "bin/dvw-probe"
}

@test "install.sh reconcile mode: restores missing files without touching edited ones" {
  # First-deploy populates the manifest and all managed files.
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ -f "$AICODING_MANIFEST" ]
  [ -f "$HOME/.tmux.conf" ]
  [ -f "$HOME/.bashrc.d/aicoding-env.sh" ]

  # Simulate a rebuild: manifest persists (bind-mount), one file is wiped,
  # another (user-editable, non-owned) is locally edited.
  rm -f "$HOME/.bashrc.d/aicoding-env.sh"
  echo "user edit" >> "$HOME/.tmux.conf"
  local edited_hash
  edited_hash=$(sha256sum "$HOME/.tmux.conf" | awk '{print $1}')

  # Re-run install.sh — should enter reconcile mode.
  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]

  # Missing file restored.
  [ -f "$HOME/.bashrc.d/aicoding-env.sh" ]
  # Edited non-owned file untouched.
  local after_hash
  after_hash=$(sha256sum "$HOME/.tmux.conf" | awk '{print $1}')
  [ "$after_hash" = "$edited_hash" ]
  # Output mentions reconcile mode and restored count.
  echo "$output" | grep -q "Mode: reconcile"
  echo "$output" | grep -qE "restored [1-9]"
}

@test "install.sh reconcile mode: applies will_update for unedited file" {
  blueprint_copy
  bash "$BP/install.sh" </dev/null
  # Snapshot the deployed tmux.conf hash and overwrite the blueprint source
  # to simulate a blueprint update.
  local deployed_hash
  deployed_hash=$(jq -r '.files["'"$HOME"'/.tmux.conf"].deployed_hash' "$AICODING_MANIFEST")
  local blueprint_src="$BP/configs/tmux/tmux.conf"
  local original_blueprint
  original_blueprint=$(cat "$blueprint_src")
  echo "${original_blueprint}
# new blueprint addition" > "$blueprint_src"

  # Re-run; should auto-update since user hasn't touched ~/.tmux.conf.
  run bash "$BP/install.sh" </dev/null
  [ "$status" -eq 0 ]

  # File now matches new blueprint, not old deployed_hash.
  grep -q "# new blueprint addition" "$HOME/.tmux.conf"
  local new_hash
  new_hash=$(sha256sum "$HOME/.tmux.conf" | awk '{print $1}')
  [ "$new_hash" != "$deployed_hash" ]
  # Manifest deployed_hash refreshed.
  local manifest_hash
  manifest_hash=$(jq -r '.files["'"$HOME"'/.tmux.conf"].deployed_hash' "$AICODING_MANIFEST")
  [ "$manifest_hash" = "$new_hash" ]
}

@test "install.sh reconcile mode: does not auto-resolve drifted_and_updating" {
  blueprint_copy
  bash "$BP/install.sh" </dev/null
  # Edit the deployed file (user drift).
  echo "user local change" >> "$HOME/.tmux.conf"
  local edited_hash
  edited_hash=$(sha256sum "$HOME/.tmux.conf" | awk '{print $1}')

  # Also change the blueprint so the bucket is drifted_and_updating, not drifted_but_aligned.
  echo "
# blueprint also changed" >> "$BP/configs/tmux/tmux.conf"

  run bash "$BP/install.sh" </dev/null
  [ "$status" -eq 0 ]

  # User's edit must be preserved byte-for-byte.
  local after_hash
  after_hash=$(sha256sum "$HOME/.tmux.conf" | awk '{print $1}')
  [ "$after_hash" = "$edited_hash" ]
  # No .bak.* file created (reconcile didn't back up + overwrite).
  [ -z "$(ls "$HOME"/.tmux.conf.bak.* 2>/dev/null)" ]
}

@test "reconcile force-restores a drifted owned bashrc.d snippet (with backup)" {
  blueprint_copy
  bash "$BP/install.sh" </dev/null
  echo "# STALE old version" > "$HOME/.bashrc.d/aicoding-env.sh"
  printf '\n# blueprint moved\n' >> "$BP/configs/bash/env.sh"
  run bash "$BP/install.sh" </dev/null
  [ "$status" -eq 0 ]
  if grep -q "STALE old version" "$HOME/.bashrc.d/aicoding-env.sh"; then false; fi
  grep -q "blueprint moved" "$HOME/.bashrc.d/aicoding-env.sh"
  ls "$HOME"/.bashrc.d/aicoding-env.sh.bak.* >/dev/null 2>&1
}

@test "reconcile still preserves an edited non-owned overwrite file" {
  blueprint_copy
  bash "$BP/install.sh" </dev/null
  echo "# user tweak" >> "$HOME/.tmux.conf"
  local edited; edited=$(sha256sum "$HOME/.tmux.conf" | awk '{print $1}')
  printf '\n# blueprint moved\n' >> "$BP/configs/tmux/tmux.conf"
  run bash "$BP/install.sh" </dev/null
  [ "$status" -eq 0 ]
  [ "$(sha256sum "$HOME/.tmux.conf" | awk '{print $1}')" = "$edited" ]
}

@test "install.sh reconcile mode: does not delete to_remove entries" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  # Inject a manifest entry not present in the blueprint inventory.
  local fake_hash
  fake_hash=$(echo "junk" | sha256sum | awk '{print $1}')
  echo "obsolete content" > "$HOME/.obsolete"
  jq --arg p "$HOME/.obsolete" --arg h "$fake_hash" \
     '.files[$p] = {mode:"overwrite",source:"configs/obsolete",deployed_hash:$h}' \
     "$AICODING_MANIFEST" > "$AICODING_MANIFEST.tmp" && mv "$AICODING_MANIFEST.tmp" "$AICODING_MANIFEST"

  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]

  # File must still exist (to_remove is report-only in reconcile).
  [ -f "$HOME/.obsolete" ]
  # Manifest entry should still be there too — removal is aicoding-sync's job.
  jq -e '.files["'"$HOME"'/.obsolete"]' "$AICODING_MANIFEST"
}

@test "install.sh: prints summary line in expected format" {
  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^INSTALL OK  blueprint [0-9a-f]+  new [0-9]+  restored [0-9]+  updated [0-9]+  merged [0-9]+  drifted [0-9]+  to_review [0-9]+$'
}

@test "install summary identifies a Gitless immutable release" {
  mkdir -p "$TMPDIR/release"
  printf '%s\n' 50120b9b97a4233263e33c9b73932ff5b28506f3 > "$TMPDIR/release/.aicoding-version"
  run bash -c '
    source "$1/lib/provision-managed-files.sh"
    SCRIPT_DIR=$2
    _print_install_summary DEFERRED
  ' _ "$BLUEPRINT_ROOT" "$TMPDIR/release"
  [ "$status" -eq 0 ]
  [[ "$output" == "INSTALL DEFERRED  blueprint 50120b9  new "* ]]
}

@test "install.sh: prints NOTE follow-up when drifted or to_review > 0" {
  blueprint_copy
  bash "$BP/install.sh" </dev/null
  # Force a drifted_and_updating bucket.
  echo "user local change" >> "$HOME/.tmux.conf"
  echo "
# blueprint also changed" >> "$BP/configs/tmux/tmux.conf"

  run bash "$BP/install.sh" </dev/null
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^NOTE: [0-9]+ drifted file\(s\), [0-9]+ file\(s\) to review'
  [[ "$output" == *"INSTALL OK  blueprint"* ]]
}

@test "install.sh: ERR trap announces step name on failure" {
  # Force a failure by stubbing jq to exit nonzero. install.sh uses jq heavily.
  cat > "$TMPDIR/stubs/jq" <<'STUB'
#!/bin/sh
exit 1
STUB
  chmod +x "$TMPDIR/stubs/jq"

  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -ne 0 ]
  echo "$output" | grep -qE '^INSTALL FAILED  step=.*  line=[0-9]+$'
}

# ---------------------------------------------------------------------------
# ensure_codex / ensure_cursor_agent — function-level unit tests.
#
# These source install.sh and call the two functions directly instead of
# booting the whole installer. That makes them fast and — crucially — hermetic.
# Both functions start with `command -v codex` / `command -v agent` existence
# checks, so the only way to test their "tool missing" paths is to control PATH
# so those binaries don't resolve. You cannot stub a command into *non-existence*
# (a stub file only makes it look present); the previous `bash install.sh` tests
# left the host's real codex/cursor-agent on PATH, so every "missing" assertion
# silently exercised the "already installed" short-circuit instead.
# ---------------------------------------------------------------------------

# Invoke one install.sh function in an isolated subshell with a pinned PATH.
#   - _AICODINGSETUP_NVS_STRIPPED=1 skips install.sh's nvs self-reexec.
#   - sourcing defines the functions; the `BASH_SOURCE != $0` guards keep
#     check_prerequisites()/main() from running as a side effect.
#   - we disarm install.sh's global `set -eEuo`/ERR-trap after sourcing so a
#     function's exit status is reported to `run` instead of killing the test.
# HOME and any per-test stubs are inherited from the test environment.
_run_install_fn() {
  local fn_path="$1"; shift
  run env _AICODINGSETUP_NVS_STRIPPED=1 PATH="$fn_path" \
    bash -c 'source "$1"; trap - ERR; set +eEu +o pipefail; shift; "$@"' \
    _ "$BLUEPRINT_ROOT/install.sh" "$@"
}

# Like _run_install_fn but runs the function under install.sh's REAL shell
# options (`set -euo pipefail`, install.sh:2). _run_install_fn deliberately
# disables them, which is fine for most assertions but blind to the whole class
# of bug where a helper's failing pipeline aborts provisioning instead of
# warning. Use this whenever a function must degrade gracefully.
_run_install_fn_strict() {
  local fn_path="$1"; shift
  run env _AICODINGSETUP_NVS_STRIPPED=1 PATH="$fn_path" \
    bash -c 'source "$1"; trap - ERR; shift; set -euo pipefail; "$@"' \
    _ "$BLUEPRINT_ROOT/install.sh" "$@"
}

# A PATH with only the tools install.sh touches before the curl check — and
# deliberately NO curl — so `command -v curl` genuinely fails. (curl shares
# /usr/bin with coreutils, so we curate a dir rather than drop one.) It also
# omits the host bin dirs, so codex/cursor-agent/agent don't resolve either.
_curl_less_path() {
  local d="$TMPDIR/nocurl"
  mkdir -p "$d"
  local t
  for t in bash sh dirname uname id; do ln -sf "$(command -v "$t")" "$d/$t"; done
  printf '%s' "$d"
}

# A PATH that keeps real coreutils + curl but excludes the host's user-bin dirs
# (~/.local/bin et al.), so only the *injected* stubs decide whether
# codex/cursor-agent/agent exist.
_isolated_path() { printf '%s' "$TMPDIR/stubs:/usr/bin:/bin"; }

@test "ensure_codex: warns and skips (non-fatal) when curl is unavailable" {
  _run_install_fn "$(_curl_less_path)" ensure_codex
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "WARN.*codex|skipping codex install"
}

@test "ensure_codex: runs the installer and keeps codex when curl works and codex is absent" {
  cat > "$TMPDIR/stubs/curl" <<EOF
#!/bin/sh
echo "(stub) curl-pipe-sh for codex installer ran" > "$TMPDIR/codex-install-attempted"
# Mimic the upstream installer dropping the binary in ~/.local/bin.
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/codex" <<'BIN'
#!/bin/sh
echo "codex 0.0.0-stub"
BIN
chmod +x "$HOME/.local/bin/codex"
EOF
  chmod +x "$TMPDIR/stubs/curl"

  _run_install_fn "$(_isolated_path)" ensure_codex
  [ -f "$TMPDIR/codex-install-attempted" ]
  [ -x "$HOME/.local/bin/codex" ]
}

@test "ensure_codex: pipes the installer into a non-interactive sh (CODEX_NON_INTERACTIVE=1)" {
  # Upstream install.sh grew y/N prompts (reads /dev/tty, so piping alone
  # doesn't suppress them). Stub curl to emit a script that records what the
  # piped sh sees in CODEX_NON_INTERACTIVE.
  # The quoted inner heredoc keeps \$CODEX_NON_INTERACTIVE unexpanded in the
  # stub's output, so the piped sh (not the stub) resolves it.
  cat > "$TMPDIR/stubs/curl" <<EOF
#!/bin/sh
cat <<'SCRIPT'
echo "\$CODEX_NON_INTERACTIVE" > '$TMPDIR/codex-noninteractive'
SCRIPT
EOF
  chmod +x "$TMPDIR/stubs/curl"

  _run_install_fn "$(_isolated_path)" ensure_codex
  [ -f "$TMPDIR/codex-noninteractive" ]
  [ "$(cat "$TMPDIR/codex-noninteractive")" = "1" ]
}

@test "install_claude_mcps: registers logfire at the EU endpoint, user scope" {
  # Recording stub: capture every claude invocation's args.
  cat > "$TMPDIR/stubs/claude" <<EOF
#!/bin/sh
echo "\$@" >> '$TMPDIR/claude-calls'
exit 0
EOF
  chmod +x "$TMPDIR/stubs/claude"

  _run_install_fn "$(_isolated_path)" install_claude_mcps
  [ "$status" -eq 0 ]
  grep -E "mcp add .*logfire" "$TMPDIR/claude-calls" | grep -q "https://logfire-eu.pydantic.dev/mcp"
}

@test "install_claude_mcps: registers memory-router over http with bearer auth" {
  cat > "$TMPDIR/stubs/claude" <<EOF
#!/bin/sh
echo "\$@" >> '$TMPDIR/claude-calls'
exit 0
EOF
  chmod +x "$TMPDIR/stubs/claude"
  export MEMORY_ROUTER_TOKEN=testtoken

  _run_install_fn "$(_isolated_path)" install_claude_mcps
  [ "$status" -eq 0 ]
  line=$(grep -E "mcp add .*memory-router" "$TMPDIR/claude-calls")
  echo "$line" | grep -q -- "--transport http"
  echo "$line" | grep -q "http://10.0.0.249:8091/mcp"
  echo "$line" | grep -q "Authorization: Bearer testtoken"
}

@test "install_claude_mcps: skips memory-router when MEMORY_ROUTER_TOKEN is unset" {
  cat > "$TMPDIR/stubs/claude" <<EOF
#!/bin/sh
echo "\$@" >> '$TMPDIR/claude-calls'
exit 0
EOF
  chmod +x "$TMPDIR/stubs/claude"
  unset MEMORY_ROUTER_TOKEN

  _run_install_fn "$(_isolated_path)" install_claude_mcps
  [ "$status" -eq 0 ]
  if grep -qE "mcp add .*memory-router" "$TMPDIR/claude-calls"; then false; fi
  echo "$output" | grep -q "MEMORY_ROUTER_TOKEN not set"
}

@test "install_claude_mcps: heals memory-router URL drift by remove + re-add" {
  # Stub: `mcp get memory-router` reports the pre-#85 localhost URL until an
  # add for that name has run (marker file), then the new URL — so the
  # read-back verification sees what a real re-add would produce. Every call
  # is logged so we can assert the remove/re-add sequence.
  cat > "$TMPDIR/stubs/claude" <<EOF
#!/bin/sh
echo "\$@" >> '$TMPDIR/claude-calls'
case "\$*" in
  "mcp get memory-router")
    if [ -f '$TMPDIR/mr-added' ]; then
      printf 'memory-router:\n  Type: http\n  URL: http://10.0.0.249:8091/mcp\n'
    else
      printf 'memory-router:\n  Type: http\n  URL: http://localhost:8091/mcp\n'
    fi
    ;;
  "mcp add"*"memory-router"*)
    touch '$TMPDIR/mr-added'
    ;;
esac
exit 0
EOF
  chmod +x "$TMPDIR/stubs/claude"
  export MEMORY_ROUTER_TOKEN=testtoken

  _run_install_fn "$(_isolated_path)" install_claude_mcps
  [ "$status" -eq 0 ]
  grep -q "mcp remove -s user memory-router" "$TMPDIR/claude-calls"
  grep -E "mcp add .*memory-router" "$TMPDIR/claude-calls" | grep -q "http://10.0.0.249:8091/mcp"
  # Remove must precede the re-add.
  remove_line=$(grep -n "mcp remove -s user memory-router" "$TMPDIR/claude-calls" | head -1 | cut -d: -f1)
  add_line=$(grep -nE "mcp add .*memory-router" "$TMPDIR/claude-calls" | head -1 | cut -d: -f1)
  [ "$remove_line" -lt "$add_line" ]
  # Verified re-add reports configured and records the args fingerprint.
  echo "$output" | grep -q "memory-router MCP configured"
  [ -f "$HOME/.local/state/aicoding/mcp-fingerprints/memory-router.sha256" ]
}

# Seed the stored fingerprint ensure_http_mcp would have written for
# memory-router with this token, so "already configured" short-circuits.
_seed_mr_fingerprint() {
  local token=$1
  mkdir -p "$HOME/.local/state/aicoding/mcp-fingerprints"
  printf '%s\n' "-H" "Authorization: Bearer $token" | sha256sum | awk '{print $1}' \
    > "$HOME/.local/state/aicoding/mcp-fingerprints/memory-router.sha256"
}

@test "install_claude_mcps: does not touch memory-router when URL and token unchanged" {
  cat > "$TMPDIR/stubs/claude" <<EOF
#!/bin/sh
echo "\$@" >> '$TMPDIR/claude-calls'
case "\$*" in
  "mcp get memory-router")
    printf 'memory-router:\n  Type: http\n  URL: http://10.0.0.249:8091/mcp\n'
    ;;
esac
exit 0
EOF
  chmod +x "$TMPDIR/stubs/claude"
  export MEMORY_ROUTER_TOKEN=testtoken
  _seed_mr_fingerprint testtoken

  _run_install_fn "$(_isolated_path)" install_claude_mcps
  [ "$status" -eq 0 ]
  if grep -q "mcp remove -s user memory-router" "$TMPDIR/claude-calls"; then false; fi
  echo "$output" | grep -q "memory-router MCP already configured"
}

@test "ensure_http_mcp: re-registers when the token rotated at an unchanged URL" {
  # URL matches, but the stored fingerprint was taken with the OLD token —
  # the registration silently carries stale credentials and must be redone.
  cat > "$TMPDIR/stubs/claude" <<EOF
#!/bin/sh
echo "\$@" >> '$TMPDIR/claude-calls'
case "\$*" in
  "mcp get memory-router")
    printf 'memory-router:\n  Type: http\n  URL: http://10.0.0.249:8091/mcp\n'
    ;;
esac
exit 0
EOF
  chmod +x "$TMPDIR/stubs/claude"
  export MEMORY_ROUTER_TOKEN=rotated-token
  _seed_mr_fingerprint old-token

  _run_install_fn "$(_isolated_path)" install_claude_mcps
  [ "$status" -eq 0 ]
  grep -q "mcp remove -s user memory-router" "$TMPDIR/claude-calls"
  grep -E "mcp add .*memory-router" "$TMPDIR/claude-calls" \
    | grep -q "Bearer rotated-token"
}

@test "ensure_http_mcp: failed removal must not report success" {
  # `mcp remove` fails and `mcp get` keeps returning the stale URL — the
  # old code fell through to the get-based "already configured" fallback.
  cat > "$TMPDIR/stubs/claude" <<EOF
#!/bin/sh
echo "\$@" >> '$TMPDIR/claude-calls'
case "\$*" in
  "mcp get memory-router")
    printf 'memory-router:\n  Type: http\n  URL: http://localhost:8091/mcp\n'
    ;;
  "mcp remove"*)
    exit 1
    ;;
esac
exit 0
EOF
  chmod +x "$TMPDIR/stubs/claude"
  export MEMORY_ROUTER_TOKEN=testtoken

  _run_install_fn "$(_isolated_path)" install_claude_mcps
  [ "$status" -eq 0 ]
  if echo "$output" | grep -qE "memory-router MCP (already )?configured"; then false; fi
  echo "$output" | grep -q "memory-router MCP: failed to remove stale registration"
  if grep -qE "mcp add .*memory-router" "$TMPDIR/claude-calls"; then false; fi
}

@test "ensure_http_mcp: add that does not verify warns instead of reporting configured" {
  # add exits 0 but the read-back still shows the stale URL (e.g. the add
  # half-failed against a lingering registration).
  cat > "$TMPDIR/stubs/claude" <<EOF
#!/bin/sh
echo "\$@" >> '$TMPDIR/claude-calls'
case "\$*" in
  "mcp get memory-router")
    printf 'memory-router:\n  Type: http\n  URL: http://localhost:8091/mcp\n'
    ;;
esac
exit 0
EOF
  chmod +x "$TMPDIR/stubs/claude"
  export MEMORY_ROUTER_TOKEN=testtoken

  _run_install_fn "$(_isolated_path)" install_claude_mcps
  [ "$status" -eq 0 ]
  if echo "$output" | grep -qE "memory-router MCP (already )?configured"; then false; fi
  echo "$output" | grep -q "memory-router MCP: registration did not verify"
}

@test "install_claude_mcps: heals logfire URL drift by remove + re-add" {
  cat > "$TMPDIR/stubs/claude" <<EOF
#!/bin/sh
echo "\$@" >> '$TMPDIR/claude-calls'
case "\$*" in
  "mcp get logfire")
    printf 'logfire:\n  Type: http\n  URL: https://mcp.pydantic.dev/mcp\n'
    ;;
esac
exit 0
EOF
  chmod +x "$TMPDIR/stubs/claude"

  _run_install_fn "$(_isolated_path)" install_claude_mcps
  [ "$status" -eq 0 ]
  grep -q "mcp remove -s user logfire" "$TMPDIR/claude-calls"
  grep -E "mcp add .*logfire" "$TMPDIR/claude-calls" | grep -q "https://logfire-eu.pydantic.dev/mcp"
}

@test "install_claude_plugins: does not install the logfire plugin, uninstalls it if present" {
  # The plugin's bundled MCP server hardcodes the US URL (no repoint, no
  # per-server disable) — we run the EU hosted MCP at user scope instead.
  cat > "$TMPDIR/stubs/claude" <<EOF
#!/bin/sh
echo "\$@" >> '$TMPDIR/claude-calls'
exit 0
EOF
  chmod +x "$TMPDIR/stubs/claude"

  _run_install_fn "$(_isolated_path)" install_claude_plugins
  [ "$status" -eq 0 ]
  if grep -q "plugin install logfire@claude-plugins-official" "$TMPDIR/claude-calls"; then false; fi
  grep -q "plugin uninstall logfire@claude-plugins-official" "$TMPDIR/claude-calls"
}

@test "ensure_cursor_agent: warns and skips (non-fatal) when curl is unavailable" {
  _run_install_fn "$(_curl_less_path)" ensure_cursor_agent
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "WARN.*cursor|skipping cursor-agent install"
}

@test "ensure_cursor_agent: symlinks agent -> cursor-agent when only cursor-agent is dropped" {
  # Stub curl to drop the binary as 'cursor-agent' (the older-release name).
  cat > "$TMPDIR/stubs/curl" <<EOF
#!/bin/sh
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/cursor-agent" <<'BIN'
#!/bin/sh
echo "cursor-agent 0.0.0-stub"
BIN
chmod +x "$HOME/.local/bin/cursor-agent"
EOF
  chmod +x "$TMPDIR/stubs/curl"

  _run_install_fn "$(_isolated_path)" ensure_cursor_agent
  # Both names must resolve so downstream tooling (on-start.sh) can call either.
  [ -x "$HOME/.local/bin/cursor-agent" ]
  [ -L "$HOME/.local/bin/agent" ] || [ -x "$HOME/.local/bin/agent" ]
}

@test "ensure_cursor_agent: skips the installer when 'agent' is already on PATH" {
  # Inject an 'agent' stub so the function's existence check trips.
  cat > "$TMPDIR/stubs/agent" <<'STUB'
#!/bin/sh
echo "agent 0.0.0-stub"
STUB
  chmod +x "$TMPDIR/stubs/agent"

  _run_install_fn "$(_isolated_path)" ensure_cursor_agent
  echo "$output" | grep -qE "cursor-agent already installed"
  # The install attempt must be short-circuited before it starts.
  if echo "$output" | grep -qE "Installing Cursor CLI"; then false; fi
}

@test "install.sh non-interactive: never rewrites an existing .secrets.env (no host-secret clobber)" {
  # ~/.aicodingsetup/.secrets.env is a host bind mount — the single source of
  # truth across containers. A non-interactive container install must NOT
  # regenerate it; doing so blanks keys it can't prompt for and destroys the
  # user's real tokens on the host. The file must come out byte-identical.
  mkdir -p "$HOME/.aicodingsetup"
  cat > "$HOME/.aicodingsetup/.secrets.env" <<'EOF'
# my host secrets — hand maintained, do not let a container touch this
GH_TOKEN=github_pat_REALTOKENVALUE
FIRECRAWL_API_KEY=fc-abc
MY_CUSTOM_KEY=keepme
EOF
  chmod 600 "$HOME/.aicodingsetup/.secrets.env"
  local before after
  before=$(sha256sum "$HOME/.aicodingsetup/.secrets.env" | awk '{print $1}')

  bash "$BLUEPRINT_ROOT/install.sh" </dev/null

  after=$(sha256sum "$HOME/.aicodingsetup/.secrets.env" | awk '{print $1}')
  [ "$before" = "$after" ]
  # The real token and a non-blueprint custom key must both survive verbatim.
  grep -qx 'GH_TOKEN=github_pat_REALTOKENVALUE' "$HOME/.aicodingsetup/.secrets.env"
  grep -qx 'MY_CUSTOM_KEY=keepme' "$HOME/.aicodingsetup/.secrets.env"
}

@test "first-deploy: codex config.toml deploys with substituted FIRECRAWL_API_KEY" {
  # Seed a secrets file so substitution has a value to inject.
  mkdir -p "$HOME/.aicodingsetup"
  cat > "$HOME/.aicodingsetup/.secrets.env" <<EOF
FIRECRAWL_API_KEY=fake-firecrawl-123
BRAVE_API_KEY=fake-brave-456
CLOUDFLARE_API_TOKEN=
CLOUDFLARE_ACCOUNT_ID=
EOF
  chmod 600 "$HOME/.aicodingsetup/.secrets.env"

  bash "$BLUEPRINT_ROOT/install.sh" </dev/null

  # File deployed under bind-mount target ~/.codex/.
  [ -f "$HOME/.codex/config.toml" ]
  # Secret substituted (no {{...}} placeholder survives).
  grep -qF 'FIRECRAWL_API_KEY = "fake-firecrawl-123"' "$HOME/.codex/config.toml"
  if grep -qF '{{FIRECRAWL_API_KEY}}' "$HOME/.codex/config.toml"; then false; fi
  # Manifest records overwrite mode + deployed_hash.
  local mode
  mode=$(jq -r '.files["'"$HOME"'/.codex/config.toml"].mode' "$AICODING_MANIFEST")
  [ "$mode" = "overwrite" ]
  local hash
  hash=$(jq -r '.files["'"$HOME"'/.codex/config.toml"].deployed_hash' "$AICODING_MANIFEST")
  [ -n "$hash" ]
  [ "$hash" != "null" ]
}

@test "container profile keeps codex automode" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  run grep -E '^approval_policy = "never"$' "$HOME/.codex/config.toml"
  [ "$status" -eq 0 ]
  run grep -E '^sandbox_mode = "danger-full-access"$' "$HOME/.codex/config.toml"
  [ "$status" -eq 0 ]
}

@test "first-deploy: cursor mcp.json merges 5 blueprint servers without dropping user adds" {
  # Pre-create ~/.cursor/mcp.json with one user-added server. The merge
  # pipeline must preserve it while adding the blueprint's 5 servers.
  mkdir -p "$HOME/.cursor"
  cat > "$HOME/.cursor/mcp.json" <<'EOF'
{
  "mcpServers": {
    "user-custom": {
      "command": "my-custom-mcp",
      "args": ["--flag"]
    }
  }
}
EOF
  # Make sure first-deploy fires (no manifest yet); Plan 1's detect_install_mode
  # picks 'adopt' when a managed file exists but no manifest is present, so
  # cursor mcp.json on disk -> mode=adopt. Use --force-reinstall to force first.
  mkdir -p "$HOME/.aicodingsetup"
  cat > "$HOME/.aicodingsetup/.secrets.env" <<EOF
FIRECRAWL_API_KEY=fake-firecrawl-123
BRAVE_API_KEY=fake-brave-456
CLOUDFLARE_API_TOKEN=
CLOUDFLARE_ACCOUNT_ID=
MEMORY_ROUTER_TOKEN=fake-memtoken-789
EOF

  bash "$BLUEPRINT_ROOT/install.sh" --force-reinstall </dev/null

  [ -f "$HOME/.cursor/mcp.json" ]
  # All 5 blueprint servers present.
  jq -e '.mcpServers.firecrawl'    "$HOME/.cursor/mcp.json"
  jq -e '.mcpServers["brave-search"]' "$HOME/.cursor/mcp.json"
  jq -e '.mcpServers.context7'     "$HOME/.cursor/mcp.json"
  jq -e '.mcpServers.playwright'   "$HOME/.cursor/mcp.json"
  jq -e '.mcpServers["memory-router"].url == "http://10.0.0.249:8091/mcp"' "$HOME/.cursor/mcp.json"
  # User's custom server preserved.
  jq -e '.mcpServers["user-custom"]' "$HOME/.cursor/mcp.json"
  # Substitution applied.
  jq -r '.mcpServers.firecrawl.env.FIRECRAWL_API_KEY' "$HOME/.cursor/mcp.json" | grep -qF 'fake-firecrawl-123'
  jq -r '.mcpServers["memory-router"].headers.Authorization' "$HOME/.cursor/mcp.json" | grep -qF 'Bearer fake-memtoken-789'
}

@test "first-deploy: opencode.json mcp field populated with 5 servers and substituted secrets" {
  mkdir -p "$HOME/.aicodingsetup"
  cat > "$HOME/.aicodingsetup/.secrets.env" <<EOF
FIRECRAWL_API_KEY=fake-firecrawl-123
BRAVE_API_KEY=fake-brave-456
CLOUDFLARE_API_TOKEN=
CLOUDFLARE_ACCOUNT_ID=
MEMORY_ROUTER_TOKEN=fake-memtoken-789
EOF

  bash "$BLUEPRINT_ROOT/install.sh" </dev/null

  [ -f "$HOME/.config/opencode/opencode.json" ]
  # All 5 servers present under the 'mcp' (not 'mcpServers') top-level key.
  jq -e '.mcp.firecrawl.type == "local"'                  "$HOME/.config/opencode/opencode.json"
  jq -e '.mcp["brave-search"].type == "local"'            "$HOME/.config/opencode/opencode.json"
  jq -e '.mcp.context7.type == "local"'                   "$HOME/.config/opencode/opencode.json"
  jq -e '.mcp.playwright.type == "local"'                 "$HOME/.config/opencode/opencode.json"
  # opencode schema uses 'environment' not 'env' and 'command' is an array.
  jq -e '.mcp.firecrawl.environment.FIRECRAWL_API_KEY == "fake-firecrawl-123"' "$HOME/.config/opencode/opencode.json"
  jq -e '.mcp.firecrawl.command | type == "array"'        "$HOME/.config/opencode/opencode.json"
  # memory-router is a remote server with substituted bearer auth; oauth off
  # (API-key-style shared secret, not an OAuth server).
  jq -e '.mcp["memory-router"].type == "remote"'          "$HOME/.config/opencode/opencode.json"
  jq -e '.mcp["memory-router"].url == "http://10.0.0.249:8091/mcp"' "$HOME/.config/opencode/opencode.json"
  jq -e '.mcp["memory-router"].headers.Authorization == "Bearer fake-memtoken-789"' "$HOME/.config/opencode/opencode.json"
  jq -e '.mcp["memory-router"].oauth == false'            "$HOME/.config/opencode/opencode.json"
}

@test "first-deploy: codex config.toml registers memory-router with substituted token" {
  mkdir -p "$HOME/.aicodingsetup"
  cat > "$HOME/.aicodingsetup/.secrets.env" <<EOF
FIRECRAWL_API_KEY=fake-firecrawl-123
BRAVE_API_KEY=fake-brave-456
CLOUDFLARE_API_TOKEN=
CLOUDFLARE_ACCOUNT_ID=
MEMORY_ROUTER_TOKEN=fake-memtoken-789
EOF

  bash "$BLUEPRINT_ROOT/install.sh" </dev/null

  [ -f "$HOME/.codex/config.toml" ]
  grep -q '^\[mcp_servers.memory-router\]' "$HOME/.codex/config.toml"
  grep -q 'url = "http://10.0.0.249:8091/mcp"' "$HOME/.codex/config.toml"
  grep -qF 'Authorization = "Bearer fake-memtoken-789"' "$HOME/.codex/config.toml"
}

@test "first-deploy: codex global AGENTS.md deployed with memory retrieval instructions" {
  # Codex reads global guidance from ~/.codex/AGENTS.md (CODEX_HOME). Unlike
  # opencode, it has no fallback to ~/.claude/CLAUDE.md, so the memory
  # read-path instructions need their own managed file.
  mkdir -p "$HOME/.aicodingsetup"
  cat > "$HOME/.aicodingsetup/.secrets.env" <<EOF
FIRECRAWL_API_KEY=fake-firecrawl-123
BRAVE_API_KEY=fake-brave-456
EOF

  bash "$BLUEPRINT_ROOT/install.sh" </dev/null

  [ -f "$HOME/.codex/AGENTS.md" ]
  grep -q 'memory_search' "$HOME/.codex/AGENTS.md"
  grep -q 'homelab-wiki' "$HOME/.codex/AGENTS.md"
  grep -q 'kanban-post' "$HOME/.codex/AGENTS.md"
  # Deployment is manifest-tracked (managed file, not a one-shot copy).
  hash=$(jq -r '.files["'"$HOME"'/.codex/AGENTS.md"].deployed_hash' "$AICODING_MANIFEST")
  [ -n "$hash" ]
}

@test "first-deploy: cursor global skill carries memory, kanban and secrets guidance" {
  # Cursor has no file-backed global rules; ~/.cursor/skills/ is its only
  # user-level instruction surface, so the estate guidance ships as a skill.
  mkdir -p "$HOME/.aicodingsetup"
  cat > "$HOME/.aicodingsetup/.secrets.env" <<EOF
FIRECRAWL_API_KEY=fake-firecrawl-123
BRAVE_API_KEY=fake-brave-456
EOF

  bash "$BLUEPRINT_ROOT/install.sh" </dev/null

  local skill="$HOME/.cursor/skills/aicoding-estate/SKILL.md"
  [ -f "$skill" ]
  head -1 "$skill" | grep -q '^---$'
  grep -q '^name: aicoding-estate$' "$skill"
  grep -q 'memory_search' "$skill"
  grep -q 'kanban-post' "$skill"
  grep -q 'secrets-check' "$skill"
  hash=$(jq -r '.files["'"$skill"'"].deployed_hash' "$AICODING_MANIFEST")
  [ -n "$hash" ]
  [ "$hash" != "null" ]
}

@test "merge: opencode.json mcp field preserves user-added server" {
  # Pre-populate opencode.json with an existing user-added mcp entry.
  mkdir -p "$HOME/.config/opencode"
  cat > "$HOME/.config/opencode/opencode.json" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "anthropic/claude-opus-5",
  "mcp": {
    "user-server": {
      "type": "local",
      "command": ["my-custom"],
      "enabled": true
    }
  }
}
EOF
  mkdir -p "$HOME/.aicodingsetup"
  cat > "$HOME/.aicodingsetup/.secrets.env" <<EOF
FIRECRAWL_API_KEY=fake-firecrawl-123
BRAVE_API_KEY=fake-brave-456
CLOUDFLARE_API_TOKEN=
CLOUDFLARE_ACCOUNT_ID=
MEMORY_ROUTER_TOKEN=fake-memtoken-789
EOF

  bash "$BLUEPRINT_ROOT/install.sh" --force-reinstall </dev/null

  # User server + all 5 blueprint servers both present.
  jq -e '.mcp["user-server"]'   "$HOME/.config/opencode/opencode.json"
  jq -e '.mcp.firecrawl'        "$HOME/.config/opencode/opencode.json"
  jq -e '.mcp["brave-search"]'  "$HOME/.config/opencode/opencode.json"
  jq -e '.mcp.context7'         "$HOME/.config/opencode/opencode.json"
  jq -e '.mcp.playwright'       "$HOME/.config/opencode/opencode.json"
  jq -e '.mcp["memory-router"]' "$HOME/.config/opencode/opencode.json"
}

@test "managed model defaults use the current pinned families" {
  grep -qx 'model = "gpt-5.6-sol"' "$BLUEPRINT_ROOT/configs/codex/config.toml"
  jq -e '.model == "anthropic/claude-opus-5"' "$BLUEPRINT_ROOT/configs/opencode/opencode.json"
}

@test "reconcile: restores deleted ~/.codex/config.toml on rebuild" {
  mkdir -p "$HOME/.aicodingsetup"
  cat > "$HOME/.aicodingsetup/.secrets.env" <<EOF
FIRECRAWL_API_KEY=fake-firecrawl-123
BRAVE_API_KEY=fake-brave-456
CLOUDFLARE_API_TOKEN=
CLOUDFLARE_ACCOUNT_ID=
EOF
  # First-deploy seeds the manifest.
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ -f "$HOME/.codex/config.toml" ]
  local first_hash
  first_hash=$(sha256sum "$HOME/.codex/config.toml" | awk '{print $1}')

  # Simulate a rebuild: manifest persists (bind-mount), file is wiped.
  rm -f "$HOME/.codex/config.toml"
  [ ! -f "$HOME/.codex/config.toml" ]

  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]
  # File restored, content byte-identical to pre-wipe.
  [ -f "$HOME/.codex/config.toml" ]
  local restored_hash
  restored_hash=$(sha256sum "$HOME/.codex/config.toml" | awk '{print $1}')
  [ "$restored_hash" = "$first_hash" ]
  # Plan 1's summary line shows restored count >= 1.
  echo "$output" | grep -qE 'restored [1-9][0-9]* '
  # Mode line announces reconcile.
  echo "$output" | grep -q "Mode: reconcile"
}

@test "reconcile: leaves edited ~/.codex/config.toml byte-unchanged" {
  mkdir -p "$HOME/.aicodingsetup"
  cat > "$HOME/.aicodingsetup/.secrets.env" <<EOF
FIRECRAWL_API_KEY=fake-firecrawl-123
BRAVE_API_KEY=fake-brave-456
CLOUDFLARE_API_TOKEN=
CLOUDFLARE_ACCOUNT_ID=
EOF
  blueprint_copy
  bash "$BP/install.sh" </dev/null

  # User edits the file (drift).
  echo "# user-added line" >> "$HOME/.codex/config.toml"
  local edited_hash
  edited_hash=$(sha256sum "$HOME/.codex/config.toml" | awk '{print $1}')

  # Also change the blueprint source so the bucket is drifted_and_updating
  # (not drifted_but_aligned), which is the conservatism case we care about.
  echo "# blueprint also changed" >> "$BP/configs/codex/config.toml"

  run bash "$BP/install.sh" </dev/null
  [ "$status" -eq 0 ]
  # User's edit preserved byte-for-byte (reconcile excludes drifted_and_updating).
  local after_hash
  after_hash=$(sha256sum "$HOME/.codex/config.toml" | awk '{print $1}')
  [ "$after_hash" = "$edited_hash" ]
  # Summary shows drifted >= 1.
  echo "$output" | grep -qE 'drifted [1-9][0-9]* '
  # NOTE line surfaces.
  echo "$output" | grep -qE '^NOTE: [0-9]+ drifted file'
}

@test "install.sh first-deploy: installs slash commands and tracks them in the manifest" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  # Every blueprint command lands in ~/.claude/commands and is manifest-tracked.
  local cmd_file cmd_name
  for cmd_file in "$BLUEPRINT_ROOT/commands"/*.md; do
    cmd_name=$(basename "$cmd_file")
    [ -f "$HOME/.claude/commands/$cmd_name" ]
    local h
    h=$(jq -r '.files["'"$HOME"'/.claude/commands/'"$cmd_name"'"].deployed_hash' "$AICODING_MANIFEST")
    [ "$h" != "null" ] && [ -n "$h" ]
  done
}

@test "install.sh first-deploy: installs check-archived-docs hook so settings.json reference is not dangling" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  # The SessionStart hook wired in settings.json must actually exist on disk.
  [ -f "$HOME/.claude/hooks/check-archived-docs.sh" ]
  [ -x "$HOME/.claude/hooks/check-archived-docs.sh" ]
  grep -q "check-archived-docs.sh" "$HOME/.claude/settings.json"
  # Manifest tracks it as a managed overwrite file.
  local h
  h=$(jq -r '.files["'"$HOME"'/.claude/hooks/check-archived-docs.sh"].deployed_hash' "$AICODING_MANIFEST")
  [ "$h" != "null" ] && [ -n "$h" ]
}

@test "install.sh: removes the legacy project-template mirror from ~/.aicodingsetup" {
  # /scaffold-project is retired; the templates stay in the repo only. A
  # pre-existing mirror (from an older install) must be cleaned up, since it
  # lives outside the manifest and would otherwise persist in the host mount.
  local legacy="$HOME/.aicodingsetup/templates/project"
  mkdir -p "$legacy/dot-claude"
  echo "stale" > "$legacy/CLAUDE.md.tpl"

  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ ! -e "$legacy" ]
  [ ! -e "$HOME/.aicodingsetup/templates" ]
}

@test "reference templates: repo tree keeps the canonical layout" {
  # No deploy step involved anymore; agents copy these straight from the
  # blueprint checkout. Guard the contract the global CLAUDE.md documents.
  local src="$BLUEPRINT_ROOT/templates/project"
  [ -f "$src/CLAUDE.md.tpl" ]
  [ -f "$src/AGENTS.md.tpl" ]
  [ -f "$src/dot-claude/settings.json.tpl" ]
  [ -f "$src/docs/specs/active/.gitkeep" ]
  # AGENTS.md is the canonical, agent-agnostic conventions file; CLAUDE.md
  # imports it via `@AGENTS.md` so Claude Code and the other CLIs share one
  # source of truth.
  grep -q "@AGENTS.md" "$src/CLAUDE.md.tpl"
  grep -q "{{PROJECT_NAME}}" "$src/AGENTS.md.tpl"
}

@test "install.sh reconcile mode: restores a deleted slash command" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  local one
  one=$(basename "$(ls "$BLUEPRINT_ROOT/commands"/*.md | head -1)")
  [ -f "$HOME/.claude/commands/$one" ]
  rm -f "$HOME/.claude/commands/$one"

  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Mode: reconcile"
  # The deleted command is restored by reconcile (classify → restore bucket).
  [ -f "$HOME/.claude/commands/$one" ]
}

@test "install.sh first-deploy: deploys update-notify snippet and aicoding-status symlink" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ -f "$HOME/.bashrc.d/aicoding-update-notify.sh" ]
  grep -q "aicoding-status --banner" "$HOME/.bashrc.d/aicoding-update-notify.sh"
  [ -x "$HOME/.local/bin/aicoding-status" ]
  local h
  h=$(jq -r '.files["'"$HOME"'/.bashrc.d/aicoding-update-notify.sh"].deployed_hash' "$AICODING_MANIFEST")
  [ "$h" != "null" ] && [ -n "$h" ]
}

@test "install.sh reconcile: stamps blueprint_commit to the current blueprint HEAD" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null            # first-deploy stamps it
  # Simulate a stale recorded commit (as if installed from an older blueprint).
  local tmp; tmp=$(mktemp)
  jq '.blueprint_commit = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"' "$AICODING_MANIFEST" > "$tmp"
  mv "$tmp" "$AICODING_MANIFEST"

  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null        # reconcile
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Mode: reconcile"
  # Manifest must now record the actual deployed blueprint HEAD, not the stale one.
  local head stamped
  head=$(git -C "$BLUEPRINT_ROOT" rev-parse HEAD)
  stamped=$(jq -r '.blueprint_commit' "$AICODING_MANIFEST")
  [ "$stamped" = "$head" ]
}

# ---------------------------------------------------------------------------
# Exact Playwright MCP browser provisioning.
# ---------------------------------------------------------------------------

# Create an immutable exact package release and version-specific browser cache.
# $1: ldd result — missing, resolved, or unreadable.
_playwright_fixture() {
  local libs="$1" version=0.0.80
  export AICODINGSETUP_SKIP_NETWORK=
  export AICODING_DATA_DIR="$TMPDIR/aicoding-data"
  export PLAYWRIGHT_TEST_REVISION=1234
  local release="$AICODING_DATA_DIR/versions/mcp-playwright/$version"
  local cache="$AICODING_DATA_DIR/browser-cache/mcp-playwright/$version"
  mkdir -p "$release/node_modules/@playwright/mcp" "$release/node_modules/playwright-core" \
    "$AICODING_DATA_DIR/current" "$cache/chromium-1234/chrome-linux64"
  ln -s ../versions/mcp-playwright/$version "$AICODING_DATA_DIR/current/mcp-playwright"
  cat > "$release/node_modules/@playwright/mcp/cli.js" <<'CLI'
#!/bin/sh
echo "mcp $*" >> "$HOME/playwright-exact-calls"
[ -z "${PLAYWRIGHT_TEST_INSTALL_FAIL:-}" ] || exit 37
if [ "$1" = install-browser ]; then
  [ -z "${PLAYWRIGHT_TEST_NO_BROWSER:-}" ] || exit 0
  bin="$PLAYWRIGHT_BROWSERS_PATH/chromium-$PLAYWRIGHT_TEST_REVISION/chrome-linux64/chrome"
  mkdir -p "$(dirname "$bin")"
  printf '#!/bin/sh\nexit 0\n' > "$bin"
  chmod +x "$bin"
fi
CLI
  cat > "$release/node_modules/playwright-core/cli.js" <<'CLI'
const fs = require('fs');
fs.appendFileSync(process.env.HOME + '/playwright-exact-calls', 'core ' + process.argv.slice(2).join(' ') + '\n');
CLI
  chmod +x "$release/node_modules/@playwright/mcp/cli.js" "$release/node_modules/playwright-core/cli.js"
  local bin="$cache/chromium-1234/chrome-linux64/chrome"
  printf '#!/bin/sh\nexit 0\n' > "$bin"
  chmod +x "$bin"
  printf '%s\n' "$bin" > "$cache/.browser-bin"

  cat > "$TMPDIR/stubs/sudo" <<'SUDO'
#!/bin/sh
[ "${1:-}" != -n ] || shift
exec "$@"
SUDO
  if [ "$libs" = unreadable ]; then
    cat > "$TMPDIR/stubs/ldd" <<'LDD'
#!/bin/sh
echo "$*" >> "$HOME/ldd-calls"
exit 1
LDD
  elif [ "$libs" = missing ]; then
    cat > "$TMPDIR/stubs/ldd" <<'LDD'
#!/bin/sh
echo "$*" >> "$HOME/ldd-calls"
echo 'libatk-1.0.so.0 => not found'
LDD
  else
    cat > "$TMPDIR/stubs/ldd" <<'LDD'
#!/bin/sh
echo "$*" >> "$HOME/ldd-calls"
echo 'libgbm.so.1 => /lib/libgbm.so.1'
LDD
  fi
  chmod +x "$TMPDIR/stubs/sudo" "$TMPDIR/stubs/ldd"
}

@test "ensure_playwright_browsers uses only the exact active package and dependency CLI" {
  _playwright_fixture missing
  _run_install_fn "$(_isolated_path)" ensure_playwright_browsers
  [ "$status" -eq 0 ]
  grep -q '^mcp install-browser --no-remove chromium$' "$HOME/playwright-exact-calls"
  grep -q '^core install-deps chromium$' "$HOME/playwright-exact-calls"
  [ ! -e "$TMPDIR/npx-calls" ]
}

@test "ensure_playwright_browsers skips system installation when exact Chromium resolves" {
  _playwright_fixture resolved
  _run_install_fn "$(_isolated_path)" ensure_playwright_browsers
  [ "$status" -eq 0 ]
  grep -q '^mcp install-browser --no-remove chromium$' "$HOME/playwright-exact-calls"
  if grep -q '^core ' "$HOME/playwright-exact-calls"; then false; fi
}

@test "ensure_playwright_browsers retains another package version's browser cache" {
  _playwright_fixture resolved
  mkdir -p "$AICODING_DATA_DIR/browser-cache/mcp-playwright/0.0.79/chromium-old"
  rm -rf "$AICODING_DATA_DIR/browser-cache/mcp-playwright/0.0.80/chromium-1234"
  rm -f "$AICODING_DATA_DIR/browser-cache/mcp-playwright/0.0.80/.browser-bin"
  export PLAYWRIGHT_TEST_REVISION=1243
  _run_install_fn_strict "$(_isolated_path)" ensure_playwright_browsers
  [ "$status" -eq 0 ]
  [ -x "$AICODING_DATA_DIR/browser-cache/mcp-playwright/0.0.80/chromium-1243/chrome-linux64/chrome" ]
  [ -d "$AICODING_DATA_DIR/browser-cache/mcp-playwright/0.0.79/chromium-old" ]
  grep -q '/0.0.80/chromium-1243/' "$AICODING_DATA_DIR/browser-cache/mcp-playwright/0.0.80/.browser-bin"
}

@test "ensure_playwright_browsers does not accept a failed exact browser install" {
  _playwright_fixture resolved
  export PLAYWRIGHT_TEST_INSTALL_FAIL=1
  rm -f "$AICODING_DATA_DIR/browser-cache/mcp-playwright/0.0.80/.browser-bin" "$HOME/ldd-calls"
  _run_install_fn "$(_isolated_path)" ensure_playwright_browsers
  [ "$status" -eq 0 ]
  [[ "$output" == *"browser install failed"* ]]
  [ ! -e "$HOME/ldd-calls" ]
}

@test "scheduled Playwright provisioning reports unresolved system libraries" {
  _playwright_fixture missing
  export AICODING_SYNC_MODE=boot
  _run_install_fn "$(_isolated_path)" ensure_playwright_browsers
  [ "$status" -eq 3 ]
  [[ "$output" == *"still missing"* ]]
}

@test "scheduled Playwright provisioning defers an unreadable browser" {
  _playwright_fixture unreadable
  export AICODING_SYNC_MODE=boot

  _run_install_fn "$(_isolated_path)" ensure_playwright_browsers

  [ "$status" -eq 3 ]
  [[ "$output" == *"Could not inspect"* ]]
}

@test "scheduled Playwright provisioning skips an unselected package" {
  export AICODINGSETUP_SKIP_NETWORK=
  export AICODING_DATA_DIR="$TMPDIR/aicoding-data"
  mkdir -p "$AICODING_DATA_DIR/current"

  _run_install_fn "$(_isolated_path)" ensure_playwright_browsers

  [ "$status" -eq 0 ]
  [[ "$output" != *"CLI is unavailable"* ]]
}

@test "scheduled Playwright provisioning defers a dangling selected package" {
  export AICODINGSETUP_SKIP_NETWORK= AICODING_SYNC_MODE=boot
  export AICODING_DATA_DIR="$TMPDIR/aicoding-data"
  mkdir -p "$AICODING_DATA_DIR/current"
  ln -s ../versions/mcp-playwright/missing "$AICODING_DATA_DIR/current/mcp-playwright"

  _run_install_fn "$(_isolated_path)" ensure_playwright_browsers

  [ "$status" -eq 3 ]
  [[ "$output" == *"CLI is unavailable"* ]]
}

@test "scheduled Playwright browser installation failure remains a failure" {
  _playwright_fixture resolved
  export AICODING_SYNC_MODE=boot PLAYWRIGHT_TEST_INSTALL_FAIL=1

  _run_install_fn "$(_isolated_path)" ensure_playwright_browsers

  [ "$status" -eq 1 ]
  [[ "$output" == *"browser install failed"* ]]
}

@test "scheduled Playwright browser validation failure remains a failure" {
  _playwright_fixture resolved
  export AICODING_SYNC_MODE=boot PLAYWRIGHT_TEST_NO_BROWSER=1 PLAYWRIGHT_TEST_REVISION=missing
  rm -rf "$AICODING_DATA_DIR/browser-cache/mcp-playwright/0.0.80"/chromium-* \
    "$AICODING_DATA_DIR/browser-cache/mcp-playwright/0.0.80/.browser-bin"

  _run_install_fn "$(_isolated_path)" ensure_playwright_browsers

  [ "$status" -eq 1 ]
  [[ "$output" == *"browser did not validate"* ]]
}

@test "ensure_playwright_browsers respects the offline provisioning guard" {
  _playwright_fixture resolved
  export AICODINGSETUP_SKIP_NETWORK=1
  _run_install_fn_strict "$(_isolated_path)" ensure_playwright_browsers
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/playwright-exact-calls" ]
}

@test "check_playwright validates only the active version's retained marker" {
  _playwright_fixture resolved
  _run_install_fn_strict "$(_isolated_path)" check_playwright
  [ "$status" -eq 0 ]
  [[ "$output" == *"Chromium revision is installed"* ]]
  rm "$AICODING_DATA_DIR/browser-cache/mcp-playwright/0.0.80/.browser-bin"
  _run_install_fn_strict "$(_isolated_path)" check_playwright
  [ "$status" -eq 0 ]
  [[ "$output" == *"required by Playwright MCP is unavailable"* ]]
}

@test "Playwright health check reports an unreadable exact browser" {
  _playwright_fixture unreadable
  _run_install_fn_strict "$(_isolated_path)" check_playwright
  [ "$status" -eq 0 ]
  [[ "$output" == *"ldd failed"* ]]
}

@test "install stamps provision_commit in the container-local manifest" {
  # Directly exercise the helper + the install.sh call site wiring.
  TMP=$(mktemp -d)
  export AICODING_MANIFEST="$TMP/state/manifest.json"
  run bash -c '. "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"; manifest_stamp_provision deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
  [ "$status" -eq 0 ]
  [ "$(jq -r .provision_commit "$AICODING_MANIFEST")" = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" ]
  # The source helper accepts both immutable Gitless releases and checkouts.
  grep -qF 'manifest_stamp_provision "$(_aicoding_managed_source_version "$SCRIPT_DIR")"' "$BLUEPRINT_ROOT/install.sh"
  rm -rf "$TMP"
}

@test "install.sh main(): registers the git credential helpers and logs gh in" {
  # Deliberately structural. A full network-enabled install.sh run is exactly
  # what the suite's AICODINGSETUP_SKIP_NETWORK=1 exists to prevent (and
  # ensure_gh_stored_auth honours that flag, so it would no-op anyway). The
  # regression being guarded is pure wiring — main() simply never called these,
  # so a container rebuild left gh unauthenticated until someone ran
  # aicoding-sync by hand — and an absent call cannot survive this assertion.
  export _AICODINGSETUP_NVS_STRIPPED=1   # or sourcing re-execs $0, which is bats
  source "$BLUEPRINT_ROOT/install.sh"
  run declare -f main
  [ "$status" -eq 0 ]
  [[ "$output" == *"ensure_gh_credential_helper"* ]]
  [[ "$output" == *"ensure_gh_stored_auth"* ]]
  [[ "$output" == *"ensure_git_credential_file_fallback"* ]]
}

@test "report_unmanaged: ignores the installer's own .bak.<stamp> backups" {
  # Regression: _backup_file leaves timestamped siblings next to managed
  # hooks; the unmanaged-components scan then reported every one as a
  # foreign hook ("Found hook 'bw-deny-files.sh.bak.20260821-191316' ...").
  export _AICODINGSETUP_NVS_STRIPPED=1   # or sourcing re-execs $0, which is bats
  source "$BLUEPRINT_ROOT/install.sh"
  mkdir -p "$CLAUDE_DIR/hooks"
  printf '#!/bin/sh\n' > "$CLAUDE_DIR/hooks/bw-deny-files.sh.bak.20260821-191316"
  printf '#!/bin/sh\n' > "$CLAUDE_DIR/hooks/my-own-hook.sh"
  run report_unmanaged
  [ "$status" -eq 0 ]
  # A genuinely personal hook is still reported…
  [[ "$output" == *"my-own-hook.sh"* ]]
  # …but the installer's own backups are not.
  if echo "$output" | grep -q "bak"; then false; fi
}

@test "install.sh symlinks the clipboard-bridge shims (xclip, wl-paste)" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  for name in xclip wl-paste; do
    [ -L "$HOME/.local/bin/$name" ]
    [ -x "$HOME/.local/bin/$name" ]
    readlink "$HOME/.local/bin/$name" | grep -q "bin/clip-shim"
  done
}

@test "install.sh symlinks the kanban board client" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  for h in kanban-post kanban-work; do
    [ -L "$HOME/.local/bin/$h" ]
    [ -x "$HOME/.local/bin/$h" ]
    [ "$(readlink -f "$HOME/.local/bin/$h")" = "$BLUEPRINT_ROOT/bin/$h" ]
  done
  for h in dokploy-api kuma-admin bugsink-api; do
    [ -L "$HOME/.local/bin/$h" ]
    [ -x "$HOME/.local/bin/$h" ]
    readlink "$HOME/.local/bin/$h" | grep -q "bin/$h"
  done
}

@test "install.sh deploys the Claude Kanban lifecycle wrapper as managed executable" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  local hook="$HOME/.claude/hooks/kanban-work-hook.sh" hash
  [ -x "$hook" ]
  cmp "$BLUEPRINT_ROOT/configs/claude/hooks/kanban-work-hook.sh" "$hook"
  hash=$(jq -r '.files["'"$hook"'"].deployed_hash' "$AICODING_MANIFEST")
  [ -n "$hash" ]
  [ "$hash" != null ]
}

@test "install.sh deploys Cursor hooks as managed overwrite with Kanban lifecycle wiring" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  local hooks="$HOME/.cursor/hooks.json" hash mode
  [ -f "$hooks" ]
  if grep -q '{{HOME}}' "$hooks"; then false; fi
  jq -e --arg home "$HOME" '.hooks.preToolUse |
    any(.command == ("bash \"" + $home + "/.claude/hooks/kanban-work-hook.sh\" cursor preToolUse"))' "$hooks"
  jq -e '.hooks.preToolUse | any(.failClosed == true)' "$hooks"
  jq -e '(.hooks.beforeMCPExecution // null) == null and
    (.hooks.afterMCPExecution // null) == null' "$hooks"
  hash=$(jq -r '.files["'"$hooks"'"].deployed_hash' "$AICODING_MANIFEST")
  mode=$(jq -r '.files["'"$hooks"'"].mode' "$AICODING_MANIFEST")
  [ -n "$hash" ]
  [ "$hash" != null ]
  [ "$mode" = overwrite ]
}

@test "install.sh deploys the auto-discovered OpenCode Kanban plugin as managed overwrite" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  local plugin="$HOME/.config/opencode/plugins/kanban-work.js" hash mode
  [ -f "$plugin" ]
  cmp "$BLUEPRINT_ROOT/configs/opencode/plugins/kanban-work.js" "$plugin"
  hash=$(jq -r '.files["'"$plugin"'"].deployed_hash' "$AICODING_MANIFEST")
  mode=$(jq -r '.files["'"$plugin"'"].mode' "$AICODING_MANIFEST")
  [ -n "$hash" ]
  [ "$hash" != null ]
  [ "$mode" = overwrite ]
  jq -e 'has("plugin") | not' "$HOME/.config/opencode/opencode.json"
}

@test "install.sh reconcile updates the managed OpenCode plugin and preserves personal plugins" {
  blueprint_copy
  mkdir -p "$HOME/.config/opencode/plugins"
  printf '%s\n' 'export const PersonalPlugin = async () => ({})' \
    > "$HOME/.config/opencode/plugins/personal.js"
  bash "$BP/install.sh" --force-reinstall </dev/null

  printf '%s\n' '// reconcile fixture' >> "$BP/configs/opencode/plugins/kanban-work.js"
  run bash "$BP/install.sh" </dev/null
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Mode: reconcile"
  cmp "$BP/configs/opencode/plugins/kanban-work.js" \
    "$HOME/.config/opencode/plugins/kanban-work.js"
  grep -qx 'export const PersonalPlugin = async () => ({})' \
    "$HOME/.config/opencode/plugins/personal.js"
}

@test "install.sh reconcile updates managed Cursor hooks and preserves personal MCP servers" {
  blueprint_copy
  mkdir -p "$HOME/.cursor"
  cat > "$HOME/.cursor/mcp.json" <<'EOF'
{"mcpServers":{"personal":{"command":"personal-mcp","args":["--safe"]}}}
EOF
  bash "$BP/install.sh" --force-reinstall </dev/null
  jq -e '.mcpServers.personal.command == "personal-mcp"' "$HOME/.cursor/mcp.json"

  jq '.hooks.preCompact[0].timeout = 17' "$BP/configs/cursor/hooks.json" \
    > "$BP/configs/cursor/hooks.json.new"
  mv "$BP/configs/cursor/hooks.json.new" "$BP/configs/cursor/hooks.json"
  run bash "$BP/install.sh" </dev/null
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Mode: reconcile"
  jq -e '.hooks.preCompact[0].timeout == 17' "$HOME/.cursor/hooks.json"
  jq -e '.mcpServers.personal.command == "personal-mcp"' "$HOME/.cursor/mcp.json"
}

@test "install.sh symlinks clip-x11-bridge into ~/.local/bin" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ -L "$HOME/.local/bin/clip-x11-bridge" ]
  [ -x "$HOME/.local/bin/clip-x11-bridge" ]
  readlink "$HOME/.local/bin/clip-x11-bridge" | grep -q "bin/clip-x11-bridge"
}

@test "no deployed agent-readable markdown contains a substituted secret" {
  # The regression test that would have caught CAF-003: every *.md skill went
  # through the secret-substitution path, so the live Cloudflare token sat in
  # a file an agent must READ to use the skill.
  #
  # It guards the ROUTE, not today's content. Every agent-readable source
  # below gets a probe placeholder planted in the blueprint copy first, so a
  # routing regression alone trips this test — without the probes it could
  # only fail if someone ALSO reintroduced a placeholder into a real source,
  # which makes it an assertion that cannot fail on its own.
  blueprint_copy

  # Fingerprinted fakes, seeded into the STORE rather than the environment:
  # load_or_prompt_secrets re-exports every key from the secrets file, so an
  # exported value is clobbered to empty before substitution ever runs and
  # the assertion below would pass for the wrong reason.
  mkdir -p "$HOME/.aicodingsetup"
  cat > "$HOME/.aicodingsetup/.secrets.env" <<'EOF'
CLOUDFLARE_API_TOKEN=FPRINT-CF-TOKEN-2b9d41
CLOUDFLARE_ACCOUNT_ID=FPRINT-CF-ACCT-2b9d41
FIRECRAWL_API_KEY=FPRINT-FC-2b9d41
BRAVE_API_KEY=FPRINT-BR-2b9d41
MEMORY_ROUTER_TOKEN=FPRINT-MR-2b9d41
EOF
  chmod 600 "$HOME/.aicodingsetup/.secrets.env"

  # One probe per agent-readable destination in the managed set: a skill, a
  # slash command, the global CLAUDE.md, codex's AGENTS.md, and a subagent
  # definition. BRAVE_API_KEY is a live substitution placeholder, so a probe
  # that renders becomes FPRINT-BR-2b9d41 on disk.
  local probe='PROBE (test fixture, not real guidance): {{BRAVE_API_KEY}}'
  local src
  for src in skills/cloudflare-browser/SKILL.md \
             commands/housekeep.md \
             configs/claude/CLAUDE.md \
             configs/codex/AGENTS.md \
             configs/claude/agents/llmwiki-distiller.md; do
    [ -f "$BP/$src" ]
    printf '\n%s\n' "$probe" >> "$BP/$src"
  done

  run bash "$BP/install.sh" </dev/null
  [ "$status" -eq 0 ]

  # Every probe must have survived VERBATIM: reaching the deployed file with
  # the placeholder intact is the proof it never went through substitution.
  local dest
  for dest in "$HOME/.claude/skills/cloudflare-browser/SKILL.md" \
              "$HOME/.claude/commands/housekeep.md" \
              "$HOME/.claude/CLAUDE.md" \
              "$HOME/.codex/AGENTS.md" \
              "$HOME/.claude/agents/llmwiki-distiller.md"; do
    [ -f "$dest" ]
    grep -qF '{{BRAVE_API_KEY}}' "$dest"
  done

  [ -d "$HOME/.claude/skills" ]
  [ -d "$HOME/.claude/commands" ]
  [ -d "$HOME/.claude/agents" ]
  run grep -rl 'FPRINT-' \
    "$HOME/.claude/skills" "$HOME/.claude/commands" "$HOME/.claude/agents" \
    "$HOME/.claude/CLAUDE.md" "$HOME/.codex/AGENTS.md"
  # grep exits 1 when it finds nothing, which is the passing case.
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "a sync right after install leaves the prose probes untouched" {
  # The install path and the sync path must agree on prose-vs-config, or
  # every agent-readable file reports phantom drift forever (and a sync would
  # re-substitute secrets into files install.sh had kept clean).
  #
  # This is the only test in this file that runs the REAL sync.sh, so it owns
  # two obligations the rest of the file does not have:
  #
  #  1. _sync_binaries (lib/sync.sh) runs `agent update` / `cursor-agent
  #     update` / the codex updater whenever those binaries are on PATH.
  #     setup() deliberately leaves codex/agent/cursor-agent unstubbed so the
  #     dedicated ensure_codex / ensure_cursor_agent tests can stage their own
  #     present/absent scenarios, so the stubs go HERE rather than there.
  #     Unstubbed, this test makes live agent-CLI network calls (2026-08-08,
  #     #56: five tests hitting a live CLI at 146-175s each set the suite
  #     wall). CI has no such binaries, so an unstubbed reference fails there.
  #  2. _sync_devcontainer_pin sed -i's the CWD repo's
  #     .devcontainer/devcontainer.json, and run.sh leaves the cwd at
  #     $BLUEPRINT_ROOT. See the cd below.
  local cmd
  for cmd in codex agent cursor-agent; do
    printf '#!/bin/sh\nexit 0\n' > "$TMPDIR/stubs/$cmd"
    chmod +x "$TMPDIR/stubs/$cmd"
  done

  # cwd must leave the real checkout: _sync_devcontainer_pin targets the
  # cwd's repo, and tests must never write into $BLUEPRINT_ROOT. It is inert
  # only because this repo happens to have no .devcontainer/ — luck, not
  # design. (Same guard as tests/bats/e2e.bats.) Everything below uses
  # absolute paths, so this is safe from here on.
  cd "$TMPDIR"

  blueprint_copy
  mkdir -p "$HOME/.aicodingsetup"
  printf 'BRAVE_API_KEY=FPRINT-BR-2b9d41\n' > "$HOME/.aicodingsetup/.secrets.env"
  chmod 600 "$HOME/.aicodingsetup/.secrets.env"

  local probe='PROBE (test fixture, not real guidance): {{BRAVE_API_KEY}}'
  printf '\n%s\n' "$probe" >> "$BP/configs/claude/CLAUDE.md"
  printf '\n%s\n' "$probe" >> "$BP/skills/cloudflare-browser/SKILL.md"
  (cd "$BP" && git add -A && git -c user.email=t@t -c user.name=t commit -q -m probes)

  bash "$BP/install.sh" </dev/null
  grep -qF '{{BRAVE_API_KEY}}' "$HOME/.claude/CLAUDE.md"

  export AICODING_UPDATE_STATE="$TMPDIR/state/updates"
  run env AICODING_BLUEPRINT_CLONE="$BP" \
    bash -c ". \"$BP/lib/sync.sh\"; aicoding_sync --yes"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # The probes are still verbatim afterwards: sync did not re-substitute.
  grep -qF '{{BRAVE_API_KEY}}' "$HOME/.claude/CLAUDE.md"
  grep -qF '{{BRAVE_API_KEY}}' "$HOME/.claude/skills/cloudflare-browser/SKILL.md"
  run grep -rl 'FPRINT-' "$HOME/.claude/CLAUDE.md" "$HOME/.claude/skills"
  [ "$status" -eq 1 ]
  # teardown rm -rf's $TMPDIR; do not sit in it.
  cd /
}

@test "install.sh deploys the cloudflare-render broker as an executable" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ -x "$HOME/.local/bin/cloudflare-render" ]
  # The skill documents the command; the command owns the credential.
  grep -q 'cloudflare-render' "$HOME/.claude/skills/cloudflare-browser/SKILL.md"
}
