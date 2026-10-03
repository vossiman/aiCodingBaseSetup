#!/usr/bin/env bats
load blueprint-snapshot

setup() {
  : "${BLUEPRINT_ROOT:?run via run.sh}"
  export TMP; TMP=$(mktemp -d); export HOME="$TMP"
  export AICODING_BLUEPRINT_CLONE="$BLUEPRINT_ROOT"
  # Tests deliberately execute the checked-out blueprint, including the
  # task's uncommitted implementation while driving TDD. Treat it as the
  # explicit local-blueprint workflow; production tracking clones remain
  # subject to the engine's clean-origin provenance checks.
  export AICODING_BLUEPRINT_LOCAL=1
  export AICODING_UPDATE_STATE="$TMP/state/updates"
  export CODEX_MANAGED_DIR="$TMP/etc-codex"
  export AICODINGSETUP_NONINTERACTIVE=1
  mkdir -p "$TMP/stubs"
  # install.sh's ensure_cursor_agent ends on `[[ -d "$HOME/.local/bin" ]]`,
  # which returns 1 under set -e when the dir is absent. The real first-deploy
  # creates it as a side effect of the native `claude install`; here claude is
  # stubbed, so pre-create the dir (as install.bats's granular tests do).
  mkdir -p "$TMP/.local/bin"
  # Neutralise install.sh's prereq installers so install.sh no-ops them and
  # leaves our logging stubs (claude/opencode/agent) on PATH untouched.
  for cmd in apt-get sudo curl npm npx bwrap bash-build-tmux cursor-agent nohup; do
    printf '#!/bin/sh\nexit 0\n' > "$TMP/stubs/$cmd"
    chmod +x "$TMP/stubs/$cmd"
  done
  # Managed-hook tests write only below the per-test CODEX_MANAGED_DIR. Make
  # the sudo seam execute those isolated mkdir/install/cp operations rather
  # than reporting success without creating the artifacts sync verifies.
  cat > "$TMP/stubs/sudo" <<'EOF'
#!/bin/sh
[ "${1:-}" != -n ] || shift
exec "$@"
EOF
  chmod +x "$TMP/stubs/sudo"
  cat > "$TMP/stubs/claude" <<'EOF'
#!/bin/sh
echo "claude $*" >> "$TMP/ran.log"
case "$*" in
  --version) printf '2.1.0\n' ;;
  "mcp get logfire") printf '  URL: https://logfire-eu.pydantic.dev/mcp\n' ;;
esac
exit 0
EOF
  chmod +x "$TMP/stubs/claude"
  for c in opencode agent codex; do
    printf '#!/bin/sh\necho "%s $*" >> "$TMP/ran.log"\n' "$c" > "$TMP/stubs/$c"
    chmod +x "$TMP/stubs/$c"
  done
  export PATH="$TMP/stubs:$PATH"
  . "$BLUEPRINT_ROOT/lib/sync.sh"
  # This HOME is an isolated test root, not one of the estate's shared mounts.
  # Production update-components supplies the physical-root implementation.
  aicoding_config_is_shared() { return 1; }
  # cwd must leave the real checkout: _sync_devcontainer_pin targets the
  # cwd's repo, and tests must never write into $BLUEPRINT_ROOT.
  cd "$TMP"
}
teardown() { cd /; rm -rf "$TMP"; }

_smart_blueprint_copy() {
  BP="$TMP/smart-blueprint"
  rsync -a --exclude=.git "$BLUEPRINT_ROOT/" "$BP/"
  # These tests exercise smart-merge semantics, not update qualification. Main's
  # compatibility gate has dedicated coverage and would otherwise require each
  # fixture commit to carry a synthetic runtime receipt.
  cat >> "$BP/lib/update-components.sh" <<'EOF'

aicoding_config_is_compatible() { return 0; }
EOF
  git -C "$BP" init -q
  git -C "$BP" add -A
  git -C "$BP" -c user.email=t@t -c user.name=t commit -q -m baseline
  git -C "$BP" remote add origin "$BLUEPRINT_ROOT"
  git -C "$BP" update-ref refs/remotes/origin/main HEAD
  export AICODING_BLUEPRINT_CLONE="$BP"
}

@test "provision artifact validation defaults the data directory under nounset" {
  printf '#!/bin/sh\nexit 0\n' > "$TMP/source"
  printf '#!/bin/sh\nexit 0\n' > "$TMP/dest"
  chmod +x "$TMP/source" "$TMP/dest"

  run env -u AICODING_DATA_DIR HOME="$HOME" bash -uc '
    . "$1/lib/sync.sh"
    _sync_provision_artifact_matches aicoding-status "$2" "$3"
  ' _ "$BLUEPRINT_ROOT" "$TMP/source" "$TMP/dest"

  [ "$status" -eq 1 ]
  [[ "$output" != *'unbound variable'* ]]
}

@test "sync --boot is non-interactive and honors the suite network guard" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  AICODING_UPDATE_TTL=0 aicoding_sync --boot
  if grep -qE 'claude update|opencode upgrade|agent update' "$TMP/ran.log"; then false; fi
}

@test "sync --boot skips binaries when the throttle stamp is fresh" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  : > "$TMP/ran.log"                       # ignore anything install.sh logged
  mkdir -p "$AICODING_UPDATE_STATE"; : > "$AICODING_UPDATE_STATE/.binaries.stamp"
  AICODING_UPDATE_TTL=3600 aicoding_sync --boot
  if grep -Eq 'claude update|opencode upgrade|agent update|codex update' "$TMP/ran.log"; then false; fi
}

@test "sync provisioning defers selected exact MCPs when staging is absent without invoking npx" {
  printf '#!/bin/sh\necho "$*" >> "$TMP/npx-calls"\n' > "$TMP/stubs/npx"
  mkdir -p "$HOME/.claude"
  jq -n '{enabledPlugins: {
    "context7@claude-plugins-official": true,
    "playwright@claude-plugins-official": true
  }}' > "$HOME/.claude/settings.json"
  export SCRIPT_DIR="$BLUEPRINT_ROOT"
  _sync_source_update_libraries "$BLUEPRINT_ROOT"
  # Exercise missing exact packages after the independent tool prerequisite.
  aicoding_result_record claude current 2.1.0 installed 2.1.0
  AICODINGSETUP_SKIP_NETWORK= run _sync_provision yes
  [ "$status" -eq 0 ]
  [ ! -s "$TMP/npx-calls" ]
  jq -e '.components["mcp-context7"].state == "blocked"
    and .components["mcp-context7"].reason == "exact_package_not_staged"
    and .components["mcp-playwright"].state == "blocked"
    and .components["mcp-playwright"].reason == "exact_package_not_staged"' \
    "$AICODING_STATE_DIR/update-results.json"
}

@test "a successful package step with deferrals keeps provision blocked without failing the pass" {
  local clone="$TMP/package-deferral-blueprint"
  mkdir -p "$clone/lib"
  printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa > "$clone/.aicoding-version"
  cat > "$clone/lib/provision.sh" <<'EOF'
install_mcp_packages() { _AICODING_PREPARATION_DEFERRED=1; return 0; }
install_claude_mcps() { return 0; }
install_claude_plugins() { return 0; }
install_codex_plugins() { return 0; }
remove_deprecated_shims() { return 0; }
EOF
  export AICODING_BLUEPRINT_CLONE="$clone"
  source "$BLUEPRINT_ROOT/lib/update-results.sh"

  run _sync_provision boot

  [ "$status" -eq 0 ]
  jq -e '.components.provision.state == "blocked"
    and .components.provision.reason == "preparation_deferred"' \
    "$AICODING_RESULTS_FILE"
}

@test "a blocked package plus a genuine package failure remains failed" {
  local clone="$TMP/package-mixed-blueprint"
  mkdir -p "$clone/lib"
  printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa > "$clone/.aicoding-version"
  cat > "$clone/lib/provision.sh" <<'EOF'
install_mcp_packages() { _AICODING_PREPARATION_DEFERRED=1; return 1; }
install_claude_mcps() { return 0; }
install_claude_plugins() { return 0; }
install_codex_plugins() { return 0; }
remove_deprecated_shims() { return 0; }
EOF
  export AICODING_BLUEPRINT_CLONE="$clone"
  source "$BLUEPRINT_ROOT/lib/update-results.sh"

  run _sync_provision boot

  [ "$status" -ne 0 ]
  jq -e '.components.provision.state == "failed"
    and .components.provision.reason == "partial_provision_failure"' \
    "$AICODING_RESULTS_FILE"
}

@test "Playwright capability return 3 records a provision deferral" {
  local clone="$TMP/playwright-deferral-blueprint"
  mkdir -p "$clone/lib"
  printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa > "$clone/.aicoding-version"
  cat > "$clone/lib/provision.sh" <<'EOF'
install_mcp_packages() { return 0; }
install_claude_mcps() { return 0; }
install_claude_plugins() { return 0; }
install_codex_plugins() { return 0; }
remove_deprecated_shims() { return 0; }
EOF
  cat > "$clone/lib/provision-system.sh" <<'EOF'
ensure_codex_managed_hooks() { return 0; }
ensure_playwright_browsers() { return 3; }
EOF
  export AICODING_BLUEPRINT_CLONE="$clone"
  . "$BLUEPRINT_ROOT/lib/update-results.sh"

  run _sync_provision boot

  [ "$status" -eq 0 ]
  jq -e '.components.provision.state == "blocked"
    and .components.provision.reason == "preparation_deferred"' \
    "$AICODING_RESULTS_FILE"
}

_root_runner_clone() {
  local clone="$TMP/root-runner-blueprint"
  mkdir -p "$clone/lib"
  printf '%s\n' cccccccccccccccccccccccccccccccccccccccc > "$clone/.aicoding-version"
  cat > "$clone/lib/provision.sh" <<'EOF'
install_mcp_packages() { return 0; }
install_claude_mcps() { return 0; }
install_claude_plugins() { return 0; }
install_codex_plugins() { return 0; }
remove_deprecated_shims() { return 0; }
EOF
  printf 'ensure_codex_managed_hooks() { codex_managed_defer_reason=%s; return 0; }\nensure_playwright_browsers() { return 0; }\n' \
    "$1" > "$clone/lib/provision-system.sh"
  export AICODING_BLUEPRINT_CLONE="$clone"
  . "$BLUEPRINT_ROOT/lib/update-results.sh"
  _aicoding_command_is_linux() { return 0; }
}

@test "Codex hooks waiting for the root runner defer provisioning instead of failing it" {
  _root_runner_clone root_runner_pending
  run _sync_provision boot
  [ "$status" -eq 0 ]
  jq -e '.components.provision.state == "blocked"
    and .components.provision.reason == "preparation_deferred"
    and .components["root-runner"].state == "blocked"
    and .components["root-runner"].reason == "root_runner_pending"' "$AICODING_RESULTS_FILE"
  run python3 "$BLUEPRINT_ROOT/lib/status-report.py" --provision-actionable
  [ "$status" -eq 1 ]
}

@test "a host without the root runner records an actionable blocker, not a failure" {
  _root_runner_clone root_runner_not_installed
  run _sync_provision boot
  [ "$status" -eq 0 ]
  jq -e '.components.provision.state == "blocked"
    and .components["root-runner"].reason == "root_runner_not_installed"' "$AICODING_RESULTS_FILE"
  run python3 "$BLUEPRINT_ROOT/lib/status-report.py" --provision-actionable
  [ "$status" -eq 0 ]
}

@test "Codex hook drift with no runner deferral still fails provisioning" {
  _root_runner_clone ""
  run _sync_provision boot
  [ "$status" -ne 0 ]
  jq -e '.components.provision.state == "failed"' "$AICODING_RESULTS_FILE"
}

@test "Playwright failure remains failed even when it also marks preparation deferred" {
  local clone="$TMP/playwright-failure-blueprint"
  mkdir -p "$clone/lib"
  printf '%s\n' bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb > "$clone/.aicoding-version"
  cat > "$clone/lib/provision.sh" <<'EOF'
install_mcp_packages() { return 0; }
install_claude_mcps() { return 0; }
install_claude_plugins() { return 0; }
install_codex_plugins() { return 0; }
remove_deprecated_shims() { return 0; }
EOF
  cat > "$clone/lib/provision-system.sh" <<'EOF'
ensure_codex_managed_hooks() { return 0; }
ensure_playwright_browsers() { _AICODING_PREPARATION_DEFERRED=1; return 1; }
EOF
  export AICODING_BLUEPRINT_CLONE="$clone"
  . "$BLUEPRINT_ROOT/lib/update-results.sh"

  run _sync_provision boot

  [ "$status" -ne 0 ]
  jq -e '.components.provision.state == "failed"
    and .components.provision.reason == "partial_provision_failure"' \
    "$AICODING_RESULTS_FILE"
}

@test "unattended provisioning preserves an injected aggregate failure receipt and does not stamp" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  _sync_source_update_libraries "$BLUEPRINT_ROOT"
  local before
  before=$(cat "$HOME/.local/state/aicoding/provision_commit")
  local clone="$TMP/provision-failure-blueprint"
  rsync -a --exclude=.git "$BLUEPRINT_ROOT/" "$clone/"
  cat >> "$clone/lib/provision.sh" <<'EOF'
install_claude_mcps() { return 1; }
EOF
  export AICODING_BLUEPRINT_CLONE="$clone"
  run _sync_provision boot
  [ "$status" -ne 0 ]
  [ "$(cat "$HOME/.local/state/aicoding/provision_commit")" = "$before" ]
  jq -e '.components.provision.state == "failed" and .components.provision.reason == "partial_provision_failure"' \
    "$AICODING_STATE_DIR/update-results.json"
}

@test "unattended provisioning skips Claude work when Claude is not installed" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  _sync_source_update_libraries "$BLUEPRINT_ROOT"
  rm -f "$TMP/stubs/claude"
  PATH="$TMP/stubs:/usr/bin:/bin" run _sync_provision boot

  [ "$status" -eq 0 ]
  jq -e '.components.provision.state == "current"' "$AICODING_STATE_DIR/update-results.json"
}

@test "sync continues after a component failure but returns aggregate failure" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  local clone="$TMP/sync-failure-blueprint"
  rsync -a --exclude=.git "$BLUEPRINT_ROOT/" "$clone/"
  cat >> "$clone/lib/provision.sh" <<'EOF'
install_claude_mcps() { return 1; }
EOF
  run env AICODING_BLUEPRINT_CLONE="$clone" AICODING_BLUEPRINT_LOCAL=1 \
      AICODING_UPDATE_TTL=0 bash -c '. "$BLUEPRINT_ROOT/lib/sync.sh"; aicoding_sync --boot'
  [ "$status" -ne 0 ]
}

@test "aicoding-sync --boot runs end to end (exit 0)" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  run env AICODING_BLUEPRINT_CLONE="$BLUEPRINT_ROOT" AICODING_UPDATE_TTL=0 \
      "$BLUEPRINT_ROOT/bin/aicoding-sync" --boot
  [ "$status" -eq 0 ]
}

@test "aicoding-sync --boot sees host profile before reconcile sources deploy helpers" {
  # Production order regression: invoke the real entrypoint with a refreshed
  # clone whose sync library loads first. The host profile exists only in a
  # legacy manifest, so plumbing must run after its migration.
  local clone="$TMP/tracking-clone"
  git clone -q "$BLUEPRINT_ROOT" "$clone"
  mkdir -p "$HOME/.local/state/aicoding" \
    "$TMP/.claude/jobs" "$TMP/.claude/sessions" "$TMP/.claude/daemon" \
    "$AICODING_UPDATE_STATE"
  echo '{"schema_version":1,"profile":"host","files":{}}' > "$HOME/.local/state/aicoding/manifest.json"
  local runtime_dir
  for runtime_dir in jobs sessions daemon; do
    echo "live-host-$runtime_dir" > "$TMP/.claude/$runtime_dir/live"
  done
  : > "$AICODING_UPDATE_STATE/.binaries.stamp"
  # This entrypoint regression is about profile ordering. Model a completed
  # prior update so boot-time capability gates do not obscure that behavior.
  . "$BLUEPRINT_ROOT/lib/update-results.sh"
  local component
  for component in claude codex opencode cursor pi mcp-context7 mcp-playwright \
      mcp-registration-claude-context7 mcp-registration-claude-playwright; do
    aicoding_result_record "$component" current 2.1.0 installed 2.1.0
  done
  cat > "$TMP/stubs/codex" <<'EOF'
#!/bin/sh
echo "codex $*" >> "$TMP/ran.log"
[ "$*" != --version ] || printf 'codex-cli 0.148.0\n'
exit 0
EOF
  chmod +x "$TMP/stubs/codex"
  printf '#!/bin/sh\nprintf "pi 0.50.0\\n"\n' > "$TMP/stubs/pi"
  chmod +x "$TMP/stubs/pi"
  _kvm_stub_sudo; _kvm_stub_stat 994

  AICODING_KVM_DEVICE=/dev/null AICODING_UPDATE_TTL=3600 \
    run "$BLUEPRINT_ROOT/bin/aicoding-sync" --blueprint "$clone" --boot
  [ "$status" -eq 0 ]
  [ "$(readlink "$HOME/.local/bin/dvw-probe")" = "$clone/bin/dvw-probe" ]
  for runtime_dir in jobs sessions daemon; do
    [ -d "$TMP/.claude/$runtime_dir" ]
    [ ! -L "$TMP/.claude/$runtime_dir" ]
    [ "$(cat "$TMP/.claude/$runtime_dir/live")" = "live-host-$runtime_dir" ]
    if [ -e "$TMP/.claude/$runtime_dir.premigrate" ]; then false; fi
  done
  if grep -q -e groupadd -e usermod "$TMP/ran.log" 2>/dev/null; then false; fi
}
@test "a dry run that cannot compute its plan fails" {
  local clone="$TMP/broken-blueprint"
  rsync -a --exclude=.git "$BLUEPRINT_ROOT/" "$clone/"
  printf '{broken\n' > "$clone/configs/managed-config.json"
  export AICODING_BLUEPRINT_CLONE="$clone" AICODING_BLUEPRINT_LOCAL=1 _SYNC_REFRESHED=1
  run _sync_reconcile dry-run
  [ "$status" -ne 0 ]
}

@test "clean sync still advances the blueprint_commit stamp" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  echo deadbeefdeadbeefdeadbeefdeadbeefdeadbeef > "$HOME/.local/state/aicoding/blueprint_commit"
  run bash -c '. "$BLUEPRINT_ROOT/lib/sync.sh"; aicoding_sync --yes'
  [ "$status" -eq 0 ]
  [[ "$output" == *"managed config already current"* ]]
  [ "$(cat "$HOME/.local/state/aicoding/blueprint_commit")" = "$(git -C "$BLUEPRINT_ROOT" rev-parse HEAD)" ]
}

@test "sync --yes reconciles MCPs and plugins (provision step)" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  # The offline fixture has a working Claude stub; record its verified version
  # so this test exercises provisioning beyond the tool-update gate.
  _sync_source_update_libraries "$BLUEPRINT_ROOT"
  aicoding_result_record claude current 2.1.0 installed 2.1.0
  : > "$TMP/ran.log"
  run bash -c '. "$BLUEPRINT_ROOT/lib/sync.sh"; aicoding_sync --yes'
  [ "$status" -eq 0 ]
  grep -q "claude mcp get logfire" "$TMP/ran.log"
  if grep -q "claude mcp add" "$TMP/ran.log"; then false; fi
  grep -q "claude plugin install" "$TMP/ran.log"
}

@test "sync --boot runs provision when the throttle is stale" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  # The offline fixture has a working Claude stub; record its verified version
  # so this test exercises provisioning beyond the tool-update gate.
  _sync_source_update_libraries "$BLUEPRINT_ROOT"
  aicoding_result_record claude current 2.1.0 installed 2.1.0
  : > "$TMP/ran.log"
  AICODING_UPDATE_TTL=0 aicoding_sync --boot
  grep -q "claude mcp get logfire" "$TMP/ran.log"
  if grep -q "claude mcp add" "$TMP/ran.log"; then false; fi
  grep -q "claude plugin install" "$TMP/ran.log"
}

@test "sync removes the retired shim symlinks (aicoding-update, update-status)" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  ln -sf /bin/true "$HOME/.local/bin/aicoding-update"
  ln -sf /bin/true "$HOME/.local/bin/update-status"
  AICODING_UPDATE_TTL=0 aicoding_sync --boot
  [ ! -e "$HOME/.local/bin/aicoding-update" ]
  [ ! -e "$HOME/.local/bin/update-status" ]
}

@test "sync --boot restores a missing dvw-probe symlink" {
  # Regression: the dvw catalog service execs `dvw-probe` inside the
  # container through its docker proxy. install.sh only creates the
  # symlink at container creation; a restart that wipes the tmpfs
  # blueprint clone (or a dropped ~/.local/bin entry) must not strand it
  # until someone re-runs install.sh by hand.
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  rm -f "$HOME/.local/bin/dvw-probe"
  AICODING_UPDATE_TTL=0 aicoding_sync --boot
  [ -L "$HOME/.local/bin/dvw-probe" ]
  [ -x "$HOME/.local/bin/dvw-probe" ]
  readlink "$HOME/.local/bin/dvw-probe" | grep -q "bin/dvw-probe"
}

@test "sync --boot restores a missing agent-notify symlink" {
  # install.sh creates it once; a container whose ~/.local/bin lost the
  # entry (or predates the tool) must heal on the next boot sync, not wait
  # for a full aicoding-install.
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  rm -f "$HOME/.local/bin/agent-notify"
  AICODING_UPDATE_TTL=0 aicoding_sync --boot
  [ -L "$HOME/.local/bin/agent-notify" ]
  [ -x "$HOME/.local/bin/agent-notify" ]
  readlink "$HOME/.local/bin/agent-notify" | grep -q "bin/agent-notify"
}

@test "sync --boot restores a missing aicoding-status symlink" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  rm -f "$HOME/.local/bin/aicoding-status"
  AICODING_UPDATE_TTL=0 aicoding_sync --boot
  [ -L "$HOME/.local/bin/aicoding-status" ]
  [ -x "$HOME/.local/bin/aicoding-status" ]
  readlink "$HOME/.local/bin/aicoding-status" | grep -q "bin/aicoding-status"
}

@test "managed aicoding-status wrapper satisfies provision artifact verification" {
  local sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa source="$TMP/managed-source" release
  mkdir -p "$source/bin" "$source/lib"
  cp "$BLUEPRINT_ROOT/bin/aicoding-status" "$source/bin/aicoding-status"
  chmod +x "$source/bin/aicoding-status"
  printf '%s\n' "$sha" > "$source/.aicoding-version"
  cat > "$source/lib/provision.sh" <<'EOF'
install_mcp_packages() { return 0; }
install_claude_mcps() { return 0; }
install_claude_plugins() { return 0; }
install_codex_plugins() { return 0; }
remove_deprecated_shims() { return 0; }
EOF
  . "$BLUEPRINT_ROOT/lib/runtime.sh"
  aicoding_stage_source aicoding "$source" "$sha"
  aicoding_activate_version aicoding "$sha" aicoding-status bin/aicoding-status
  release="$AICODING_DATA_DIR/versions/aicoding/$sha"
  [ -f "$HOME/.local/bin/aicoding-status" ]
  [ ! -L "$HOME/.local/bin/aicoding-status" ]
  grep -qF '# Managed by aicoding immutable runtime.' "$HOME/.local/bin/aicoding-status"
  export AICODING_BLUEPRINT_CLONE="$release"
  . "$BLUEPRINT_ROOT/lib/update-results.sh"

  run _sync_provision boot

  [ "$status" -eq 0 ]
  jq -e --arg sha "$sha" '.components.provision.state == "current"
    and .components.provision.successful_version == $sha' "$AICODING_RESULTS_FILE"
}

@test "sync --boot restores missing Kanban helper symlinks" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  rm -f "$HOME/.local/bin/kanban-post" "$HOME/.local/bin/kanban-work"
  AICODING_UPDATE_TTL=0 aicoding_sync --boot
  for h in kanban-post kanban-work; do
    [ -L "$HOME/.local/bin/$h" ]
    [ -x "$HOME/.local/bin/$h" ]
    readlink "$HOME/.local/bin/$h" | grep -q "bin/$h"
  done
}

@test "sync --boot restores the managed Claude and Codex Kanban lifecycle wrappers" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  rm -f "$HOME/.claude/hooks/kanban-work-hook.sh" \
    "$CODEX_MANAGED_DIR/hooks/kanban-work-hook.sh"
  AICODING_UPDATE_TTL=0 aicoding_sync --boot
  [ -x "$HOME/.claude/hooks/kanban-work-hook.sh" ]
  [ -x "$CODEX_MANAGED_DIR/hooks/kanban-work-hook.sh" ]
  cmp "$BLUEPRINT_ROOT/configs/claude/hooks/kanban-work-hook.sh" \
    "$CODEX_MANAGED_DIR/hooks/kanban-work-hook.sh"
}

@test "sync --boot restores missing dokploy-api and kuma-admin symlinks" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  rm -f "$HOME/.local/bin/dokploy-api" "$HOME/.local/bin/kuma-admin" "$HOME/.local/bin/bugsink-api"
  AICODING_UPDATE_TTL=0 aicoding_sync --boot
  for h in dokploy-api kuma-admin bugsink-api; do
    [ -L "$HOME/.local/bin/$h" ]
    readlink "$HOME/.local/bin/$h" | grep -q "bin/$h"
  done
}

@test "sync right after install reports Nothing to do (no phantom drift)" {
  # Regression: substituted files (raw-source hash compare) and merge targets
  # (unconditional re-merge bucket) used to classify as actionable on every
  # run, so back-to-back syncs never converged to "Nothing to do."
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  run bash -c '. "$BLUEPRINT_ROOT/lib/sync.sh"; aicoding_sync --yes'
  [ "$status" -eq 0 ]
  [[ "$output" == *"managed config already current"* ]]
  [[ "$output" != *"updated:"* ]]
}

@test "reconcile acquires shared writer locks before reading destination state" {
  local clone="$TMP/lock-blueprint" holder
  rsync -a --exclude=.git "$BLUEPRINT_ROOT/" "$clone/"
  cat >> "$clone/lib/blueprint-deploy.sh" <<'EOF'
managed_config_apply() { : > "$CLASSIFY_MARKER"; }
EOF
  export AICODING_BLUEPRINT_CLONE="$clone" AICODING_BLUEPRINT_LOCAL=1
  export CLASSIFY_MARKER="$TMP/classified" _SYNC_REFRESHED=1
  mkdir -p "$HOME/.claude"
  (
    exec 9> "$HOME/.claude/.aicoding-update.lock"
    flock 9
    : > "$TMP/lock-ready"
    sleep 30
  ) &
  holder=$!
  while [ ! -f "$TMP/lock-ready" ]; do sleep 0.01; done

  run _sync_reconcile yes
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  [ "$status" -ne 0 ]
  [ ! -e "$CLASSIFY_MARKER" ]
}

@test "every config-writing mode carries tool receipt authorization" {
  local dest="$HOME/.codex/config.toml" sync_mode
  export AICODING_BLUEPRINT_LOCAL=1 _SYNC_REFRESHED=1
  aicoding_config_is_compatible() {
    printf '%s\n' "${AICODING_REQUIRE_UPDATE_RECEIPT:-0}" >> "$TMP/compat-calls"
    [ "${AICODING_REQUIRE_UPDATE_RECEIPT:-0}" = 1 ] || { echo receipt_authorization_missing; return 1; }
  }
  for sync_mode in boot yes first default; do
    : > "$TMP/compat-calls"
    mkdir -p "$(dirname "$dest")"; printf 'old = 1\n' > "$dest"
    run _sync_reconcile "$sync_mode"
    [ "$status" -eq 0 ]
    [ -s "$TMP/compat-calls" ]
    if grep -qv '^1$' "$TMP/compat-calls"; then false; fi
    grep -q '^model' "$dest"
  done
}

@test "provisioning defers shared mutations on lock contention but continues local work" {
  local clone="$TMP/provision-lock-blueprint" holder
  mkdir -p "$clone/lib" "$HOME/.claude"
  printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa > "$clone/.aicoding-version"
  cat > "$clone/lib/provision.sh" <<'EOF'
install_mcp_packages() { echo packages >> "$PROVISION_LOG"; }
install_claude_mcps() { echo claude-mcps >> "$PROVISION_LOG"; }
install_claude_plugins() { echo claude-plugins >> "$PROVISION_LOG"; }
install_codex_plugins() { echo codex-plugins >> "$PROVISION_LOG"; }
remove_deprecated_shims() { echo local-cleanup >> "$PROVISION_LOG"; }
EOF
  export AICODING_BLUEPRINT_CLONE="$clone" PROVISION_LOG="$TMP/provision.log"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  source "$BLUEPRINT_ROOT/lib/update-results.sh"
  (
    exec 9> "$HOME/.claude/.aicoding-update.lock"
    flock 9
    : > "$TMP/provision-lock-ready"
    sleep 30
  ) &
  holder=$!
  while [ ! -f "$TMP/provision-lock-ready" ]; do sleep 0.01; done

  run _sync_provision boot
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  [ "$status" -eq 0 ]
  jq -e '.components.provision.state == "blocked"
    and .components.provision.reason == "preparation_deferred"' \
    "$AICODING_STATE_DIR/update-results.json"
  grep -q '^packages$' "$PROVISION_LOG"
  grep -q '^local-cleanup$' "$PROVISION_LOG"
  if grep -qE 'claude-|codex-' "$PROVISION_LOG"; then false; fi
}

@test "a component config failure defers only its matching shared provisioning" {
  local clone="$TMP/provision-component-blueprint"
  mkdir -p "$clone/lib"
  printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa > "$clone/.aicoding-version"
  cat > "$clone/lib/provision.sh" <<'EOF'
install_mcp_packages() { echo packages >> "$PROVISION_LOG"; }
install_claude_mcps() { echo claude-mcps >> "$PROVISION_LOG"; }
install_claude_plugins() { echo claude-plugins >> "$PROVISION_LOG"; }
install_codex_plugins() { echo codex-plugins >> "$PROVISION_LOG"; }
remove_deprecated_shims() { echo local-cleanup >> "$PROVISION_LOG"; }
EOF
  export AICODING_BLUEPRINT_CLONE="$clone" PROVISION_LOG="$TMP/provision.log"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  declare -gA _SYNC_DEFERRED_PROVISION_COMPONENTS=([claude]=1)

  run _sync_provision boot

  [ "$status" -eq 0 ]
  if grep -q '^claude-' "$PROVISION_LOG"; then false; fi
  grep -q '^codex-plugins$' "$PROVISION_LOG"
  grep -q '^local-cleanup$' "$PROVISION_LOG"
}

@test "selected Gitless release retains the shipped bytes of retired files" {
  local repo="$TMP/provenance-repo" sha release source_path=commands/scaffold-project.md
  blueprint_snapshot "$repo"
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name test
  # Ship then retire the source here: CI checks out a shallow clone.
  printf 'shipped scaffold command\n' > "$repo/$source_path"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m ship
  git -C "$repo" rm -q "$source_path"
  printf '1\n' > "$repo/.aicoding-bootstrap-version"
  git -C "$repo" add -A
  git -C "$repo" commit -q --allow-empty -m release
  mkdir -p "$HOME/.claude/commands"
  printf 'shipped scaffold command\n' > "$HOME/.claude/commands/scaffold-project.md"
  sha=$(git -C "$repo" rev-parse HEAD)
  export AICODING_BLUEPRINT_REMOTE="$repo" AICODING_DATA_DIR="$TMP/data"

  release=$(_sync_stage_selected_blueprint "$sha")
  [ ! -d "$release/.git" ]
  [ "$(cat "$release/.aicoding-release-ordinal")" = "$(git -C "$repo" rev-list --count HEAD)" ]
  export AICODING_BLUEPRINT_CLONE="$release"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run owned_file_has_generated_provenance "$HOME/.claude/commands/scaffold-project.md" "$source_path"
  [ "$status" -eq 0 ]
  run _managed_retire_files 0
  [[ "$output" == *"removed retired file"* ]]
}

@test "sync activation converts legacy clone-symlinked launchers into managed wrappers" {
  local repo="$TMP/legacy-repo" clone="$TMP/legacy-clone" sha release name
  git clone -q "$BLUEPRINT_ROOT" "$repo"
  sha=$(git -C "$repo" rev-parse HEAD)
  # Old layout: launchers are symlinks into the tracking clone, and the
  # scheduler launcher was never installed.
  mkdir -p "$clone/bin" "$HOME/.local/bin"
  for name in aicoding-sync aicoding-install; do
    printf '#!/bin/sh\necho legacy %s\n' "$name" > "$clone/bin/$name"
    chmod +x "$clone/bin/$name"
    ln -sfn "$clone/bin/$name" "$HOME/.local/bin/$name"
  done
  rm -f "$HOME/.local/bin/aicoding-auto-update" "$HOME/.local/bin/aicoding-status" \
    "$HOME/.local/bin/aicoding-select"
  local before
  before=$(cd "$clone" && md5sum bin/*)
  export AICODING_BLUEPRINT_REMOTE="$repo" AICODING_DATA_DIR="$TMP/data"

  release=$(_sync_stage_selected_blueprint "$sha")

  [ "$release" = "$AICODING_DATA_DIR/versions/aicoding/$sha" ]
  for name in aicoding-sync aicoding-install aicoding-status aicoding-select aicoding-auto-update; do
    [ -f "$HOME/.local/bin/$name" ] && [ ! -L "$HOME/.local/bin/$name" ]
    [ -x "$HOME/.local/bin/$name" ]
    grep -qF '# Managed by aicoding immutable runtime.' "$HOME/.local/bin/$name"
  done
  [ "$(cd "$clone" && md5sum bin/*)" = "$before" ]
  [ "$(readlink "$AICODING_DATA_DIR/current/aicoding")" = "../versions/aicoding/$sha" ]
}

@test "a sync re-executed by legacy code heals the stable launchers before provisioning" {
  local repo="$TMP/handoff-repo" source="$TMP/handoff-source" clone="$TMP/handoff-clone"
  local sha release name before
  git clone -q "$BLUEPRINT_ROOT" "$repo"
  sha=$(git -C "$repo" rev-parse HEAD)
  cp -a "$repo" "$source"; rm -rf "$source/.git"
  printf '%s\n' "$sha" > "$source/.aicoding-version"
  export AICODING_DATA_DIR="$TMP/data" AICODING_STATE_DIR="$TMP/state"
  . "$BLUEPRINT_ROOT/lib/runtime.sh"
  aicoding_stage_source aicoding "$source" "$sha"
  # Legacy code activated the new release without any launchers.
  aicoding_activate_version aicoding "$sha"
  release="$AICODING_DATA_DIR/versions/aicoding/$sha"
  mkdir -p "$clone/bin" "$HOME/.local/bin"
  for name in aicoding-sync aicoding-install; do
    printf '#!/bin/sh\necho legacy %s\n' "$name" > "$clone/bin/$name"
    chmod +x "$clone/bin/$name"
    ln -sfn "$clone/bin/$name" "$HOME/.local/bin/$name"
  done
  rm -f "$HOME/.local/bin/aicoding-auto-update"
  before=$(cd "$clone" && md5sum bin/*)

  # The re-executed new release: non-local, REEXECED, running from the release.
  export AICODING_BLUEPRINT_LOCAL=0 AICODING_SYNC_REEXECED=1
  export AICODING_BLUEPRINT_CLONE="$release" AICODING_SELECTED_AICODING_SHA="$sha"
  _sync_refresh_and_reexec --boot

  for name in aicoding-sync aicoding-install aicoding-status aicoding-select aicoding-auto-update; do
    [ -f "$HOME/.local/bin/$name" ] && [ ! -L "$HOME/.local/bin/$name" ]
    grep -qF '# Managed by aicoding immutable runtime.' "$HOME/.local/bin/$name"
  done
  [ "$(cd "$clone" && md5sum bin/*)" = "$before" ]

  # Provisioning's enrollment step now finds the launcher (offline it stops
  # before starting the scheduler, so no real enrollment is spawned).
  header() { :; }; info() { echo "$*"; }; ok() { echo "$*"; }; warn() { echo "WARN $*"; }
  . "$BLUEPRINT_ROOT/lib/provision-integrations.sh"
  run ensure_aicoding_auto_update
  [ "$status" -eq 0 ]
  [[ "$output" != *unavailable* ]]
  [[ "$output" == *"Skipping scheduler start"* ]]

  # Already reconciled: a second pass performs no activation at all.
  aicoding_activate_version() { : > "$TMP/activated-again"; return 1; }
  _sync_refresh_and_reexec --boot
  [ ! -e "$TMP/activated-again" ]
}

@test "provisioning enrolls the automatic updater when its launcher exists" {
  local clone="$TMP/enroll-blueprint"
  mkdir -p "$clone/lib"
  printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa > "$clone/.aicoding-version"
  cat > "$clone/lib/provision.sh" <<'STUB'
install_mcp_packages() { return 0; }
install_claude_mcps() { return 0; }
install_claude_plugins() { return 0; }
install_codex_plugins() { return 0; }
remove_deprecated_shims() { return 0; }
header() { :; }; info() { :; }; ok() { :; }; warn() { :; }
STUB
  cp "$BLUEPRINT_ROOT/lib/provision-integrations.sh" "$clone/lib/"
  cat > "$HOME/.local/bin/aicoding-auto-update" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$HOME/auto-update.log"
STUB
  chmod +x "$HOME/.local/bin/aicoding-auto-update"
  export AICODING_BLUEPRINT_CLONE="$clone"
  . "$BLUEPRINT_ROOT/lib/update-results.sh"

  run env AICODINGSETUP_SKIP_NETWORK= bash -c '. "$BLUEPRINT_ROOT/lib/sync.sh"; aicoding_config_is_shared() { return 1; }; _sync_provision yes'
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/auto-update.log")" = --ensure ]
}

@test "provisioning skips enrollment in a sync started by the automatic updater" {
  local clone="$TMP/enroll-marker-blueprint" marker
  mkdir -p "$clone/lib"
  printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa > "$clone/.aicoding-version"
  cat > "$clone/lib/provision.sh" <<'STUB'
install_mcp_packages() { return 0; }
install_claude_mcps() { return 0; }
install_claude_plugins() { return 0; }
install_codex_plugins() { return 0; }
remove_deprecated_shims() { return 0; }
header() { :; }; info() { :; }; ok() { :; }; warn() { :; }
STUB
  cp "$BLUEPRINT_ROOT/lib/provision-integrations.sh" "$clone/lib/"
  cat > "$HOME/.local/bin/aicoding-auto-update" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$HOME/auto-update.log"
STUB
  chmod +x "$HOME/.local/bin/aicoding-auto-update"
  export AICODING_BLUEPRINT_CLONE="$clone"
  . "$BLUEPRINT_ROOT/lib/update-results.sh"
  local body='. "$BLUEPRINT_ROOT/lib/sync.sh"; aicoding_config_is_shared() { return 1; }; _sync_provision boot'

  # A new updater marks its sync; an older fallback worker or the systemd
  # unit is recognized by AICODING_AUTO_UPDATE_SOURCE.
  for marker in AICODING_AUTO_UPDATE_RUN=1 AICODING_AUTO_UPDATE_SOURCE=fallback \
      AICODING_AUTO_UPDATE_SOURCE=systemd; do
    run env -u AICODING_AUTO_UPDATE_RUN -u AICODING_AUTO_UPDATE_SOURCE \
      AICODINGSETUP_SKIP_NETWORK= "$marker" bash -c "$body"
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/auto-update.log" ]
  done

  run env -u AICODING_AUTO_UPDATE_RUN -u AICODING_AUTO_UPDATE_SOURCE \
    AICODINGSETUP_SKIP_NETWORK= bash -c "$body"
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/auto-update.log")" = --ensure ]
}

@test "enrollment from a re-executed sync drops the sync handoff variables" {
  cat > "$HOME/.local/bin/aicoding-auto-update" <<'STUB'
#!/bin/sh
env | grep -E '^(AICODING_SYNC_REEXECED|AICODING_SELECTED_AICODING_SHA|_SYNC_REFRESHED)=' > "$HOME/enroll-env"
printf '%s\n' "$*" > "$HOME/enroll-args"
STUB
  chmod +x "$HOME/.local/bin/aicoding-auto-update"
  header() { :; }; info() { :; }; ok() { :; }; warn() { :; }
  . "$BLUEPRINT_ROOT/lib/provision-integrations.sh"
  export AICODING_SYNC_REEXECED=1 _SYNC_REFRESHED=1
  export AICODING_SELECTED_AICODING_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  AICODINGSETUP_SKIP_NETWORK= run ensure_aicoding_auto_update
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/enroll-args")" = --ensure ]
  [ ! -s "$HOME/enroll-env" ]
}

@test "sync --boot keeps a personal Codex model and makes no backup" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  printf 'model = "my-personal-model"\n' > "$HOME/.codex/config.toml"

  run env AICODING_UPDATE_TTL=0 bash -c '. "$BLUEPRINT_ROOT/lib/sync.sh"; aicoding_sync --boot'
  [ "$status" -eq 0 ]
  [[ "$output" == *"aicoding-sync: completed with deferrals"* ]]
  grep -q 'my-personal-model' "$HOME/.codex/config.toml"
  run ls "$HOME/.codex/config.toml.bak."*
  [ "$status" -ne 0 ]
}

@test "boot blocks incompatible Codex config while unrelated config advances" {
  local clone="$TMP/compat-blueprint"
  rsync -a --exclude=.git "$BLUEPRINT_ROOT/" "$clone/"
  ( cd "$clone" && git init -q && git add -A &&
    git -c user.email=t@t -c user.name=t commit -q -m initial )
  git -C "$clone" remote add origin "$BLUEPRINT_ROOT"
  git -C "$clone" update-ref refs/remotes/origin/main HEAD
  export AICODING_BLUEPRINT_CLONE="$clone" AICODING_BLUEPRINT_LOCAL=1 SCRIPT_DIR="$clone"
  bash "$clone/install.sh" </dev/null
  local old_codex old_tmux
  old_codex=$(cat "$HOME/.codex/config.toml")
  old_tmux=$(cat "$HOME/.tmux.conf")
  sed -i 's/^multi_agent_v2 = true/multi_agent_v2 = false/' "$clone/configs/codex/config.toml"
  printf '\n# unrelated safe update\n' >> "$clone/configs/tmux/tmux.conf"
  ( cd "$clone" && git add -A &&
    git -c user.email=t@t -c user.name=t commit -q -m update )
  cat > "$TMP/stubs/codex" <<'EOF'
#!/bin/sh
echo 'codex-cli 0.147.0'
EOF
  chmod +x "$TMP/stubs/codex"
  _sync_source_update_libraries "$clone"

  run aicoding_config_is_compatible "$HOME/.codex/config.toml"
  [ "$status" -ne 0 ]
  [ "$output" = codex_requires_0.148 ]

  run aicoding_sync --boot
  [ "$status" -eq 0 ]
  [[ "$output" == *"blocked ("*"): $HOME/.codex/config.toml"* ]]
  [[ "$output" == *"aicoding-sync: completed with deferrals"* ]]
  [ "$(cat "$HOME/.codex/config.toml")" = "$old_codex" ]
  [ "$(cat "$HOME/.tmux.conf")" != "$old_tmux" ]
  grep -q 'unrelated safe update' "$HOME/.tmux.conf"
  jq -e '.components.config.state == "blocked" and .components.config.reason == "partial_config_blocked"' \
    "$AICODING_STATE_DIR/update-results.json"
}

@test "aicoding-install: pulls the blueprint and re-runs the installer (reconcile)" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  run "$BLUEPRINT_ROOT/bin/aicoding-install" --blueprint "$BLUEPRINT_ROOT" </dev/null
  [ "$status" -eq 0 ]
  echo "$output" | grep -Fq "Blueprint source: local $BLUEPRINT_ROOT"
  echo "$output" | grep -q "=== Managed config ==="
  echo "$output" | grep -q "^INSTALL OK  blueprint "
}

@test "aicoding-install: still accepts --force-reinstall" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  run "$BLUEPRINT_ROOT/bin/aicoding-install" --force-reinstall \
      --blueprint="$BLUEPRINT_ROOT" </dev/null
  [ "$status" -eq 0 ]
}

@test "aicoding-install: managed enrollment forwards --force-reinstall to the selected installer" {
  local defs="$TMP/aicoding-install-definitions" harness="$TMP/install-harness"
  sed '/^source_path=/,$d' "$BLUEPRINT_ROOT/bin/aicoding-install" > "$defs"
  mkdir -p "$harness/lib"
  cat > "$harness/lib/ci-selector.sh" <<'EOF'
aicoding_ci_qualified() { return 0; }
EOF
  cat > "$harness/lib/runtime.sh" <<'EOF'
aicoding_stage_source() {
  mkdir -p "$AICODING_DATA_DIR/versions/aicoding/$3"
  cp "$2/install.sh" "$AICODING_DATA_DIR/versions/aicoding/$3/install.sh"
}
aicoding_activate_version() { return 0; }
EOF
  local source="$TMP/managed-source" sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  mkdir -p "$source"
  cat > "$source/install.sh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$TMP/selected-installer-args"
EOF
  chmod +x "$source/install.sh"

  run bash -c '
    source "$1"
    SCRIPT_DIR=$2
    _aicoding_install_validate_source() { return 0; }
    _aicoding_install_enroll "$3" "$4" container --force-reinstall
  ' _ "$defs" "$harness" "$source" "$sha"
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/selected-installer-args")" = "--unattended --force-reinstall" ]
}

@test "aicoding-install --blueprint rejects a non-checkout directory" {
  mkdir -p "$TMP/not-a-blueprint"
  run "$BLUEPRINT_ROOT/bin/aicoding-install" --blueprint "$TMP/not-a-blueprint"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "invalid local blueprint"
}

@test "on-start.sh runs the boot path (exit 0)" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  run env AICODING_BLUEPRINT_CLONE="$BLUEPRINT_ROOT" AICODING_UPDATE_TTL=0 \
      bash "$BLUEPRINT_ROOT/on-start.sh"
  [ "$status" -eq 0 ]
}

# 2026-08-20: ~/.local/bin/aicoding-sync is a symlink into the tmpfs blueprint
# clone. A container restart wipes /tmp, the link dangles, `command -v` fails,
# and on-start.sh used to skip the sync silently — the very step that would
# have re-cloned /tmp/aicoding. Every aicoding-* command stayed "not found"
# until someone ran the submodule copy by hand.
# The developer's real ~/.local/bin (with a working aicoding-sync) is inherited
# on PATH; drop it so `command -v` sees only the test HOME's copy.
_path_without_real_local_bin() {
  printf '%s' "$PATH" | tr ':' '\n' | grep -v '/home/[^/]*/\.local/bin$' | paste -sd:
}

@test "on-start.sh asks the durable updater to ensure scheduling without running sync" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  rm -f "$HOME/.local/bin/aicoding-auto-update"
  cat > "$HOME/.local/bin/aicoding-auto-update" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$HOME/ensure-ran"
EOF
  chmod +x "$HOME/.local/bin/aicoding-auto-update"
  run env PATH="$(_path_without_real_local_bin)" \
      bash "$BLUEPRINT_ROOT/on-start.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/ensure-ran")" = --ensure ]
}

@test "on-start.sh never clones source when persistent enrollment is missing" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  rm -f "$HOME/.local/bin/aicoding-auto-update"
  mkdir -p "$TMP/stash"; cp "$BLUEPRINT_ROOT/on-start.sh" "$TMP/stash/on-start.sh"
  run env PATH="$(_path_without_real_local_bin)" \
      AICODING_BLUEPRINT_CLONE="$TMP/fresh-clone" \
      AICODING_BLUEPRINT_REMOTE="$BLUEPRINT_ROOT" AICODING_UPDATE_TTL=0 \
      AICODINGSETUP_SKIP_NETWORK= bash "$TMP/stash/on-start.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$TMP/fresh-clone" ]
  [[ "$output" == *"persistent automatic updater is not enrolled"* ]]
}

# ~/.local/share/uv is a host bind mount; a persisted .venv whose interpreter
# link dangles (image bump, .python-version bump) must be rebuilt at boot
# rather than failing every .venv/bin/* with exit 127 until someone runs uv.
@test "on-start.sh runs uv sync when the workspace .venv interpreter dangles" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  printf '#!/bin/sh\necho "uv $*" >> "$TMP/ran.log"\n' > "$TMP/stubs/uv"; chmod +x "$TMP/stubs/uv"
  mkdir -p "$TMP/ws/.venv/bin"; : > "$TMP/ws/uv.lock"
  ln -s "$TMP/gone/python3.14" "$TMP/ws/.venv/bin/python"
  run env -C "$TMP/ws" PATH="$(_path_without_real_local_bin)" \
      AICODING_BLUEPRINT_CLONE="$BLUEPRINT_ROOT" AICODING_UPDATE_TTL=0 \
      AICODINGSETUP_SKIP_NETWORK= bash "$BLUEPRINT_ROOT/on-start.sh"
  [ "$status" -eq 0 ]
  grep -q "^uv sync" "$TMP/ran.log"
  echo "$output" | grep -q "missing interpreter"
}

@test "on-start.sh runs uv sync when .python-version asks for another interpreter" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  printf '#!/bin/sh\necho "uv $*" >> "$TMP/ran.log"\n' > "$TMP/stubs/uv"; chmod +x "$TMP/stubs/uv"
  mkdir -p "$TMP/ws/.venv/bin"; : > "$TMP/ws/uv.lock"
  printf '#!/bin/sh\necho 3.12.7\n' > "$TMP/fake-py"; chmod +x "$TMP/fake-py"
  ln -s "$TMP/fake-py" "$TMP/ws/.venv/bin/python"
  echo "3.14" > "$TMP/ws/.python-version"
  run env -C "$TMP/ws" PATH="$(_path_without_real_local_bin)" \
      AICODING_BLUEPRINT_CLONE="$BLUEPRINT_ROOT" AICODING_UPDATE_TTL=0 \
      AICODINGSETUP_SKIP_NETWORK= bash "$BLUEPRINT_ROOT/on-start.sh"
  [ "$status" -eq 0 ]
  grep -q "^uv sync" "$TMP/ran.log"
  echo "$output" | grep -q "runs 3.12.7, .python-version wants 3.14"
}

@test "on-start.sh leaves a healthy .venv alone" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  printf '#!/bin/sh\necho "uv $*" >> "$TMP/ran.log"\n' > "$TMP/stubs/uv"; chmod +x "$TMP/stubs/uv"
  mkdir -p "$TMP/ws/.venv/bin"; : > "$TMP/ws/uv.lock"
  printf '#!/bin/sh\necho 3.12.7\n' > "$TMP/fake-py"; chmod +x "$TMP/fake-py"
  ln -s "$TMP/fake-py" "$TMP/ws/.venv/bin/python"
  echo "3.12" > "$TMP/ws/.python-version"
  run env -C "$TMP/ws" AICODING_BLUEPRINT_CLONE="$BLUEPRINT_ROOT" AICODING_UPDATE_TTL=0 \
      AICODINGSETUP_SKIP_NETWORK= bash "$BLUEPRINT_ROOT/on-start.sh"
  [ "$status" -eq 0 ]
  if grep -q "^uv sync" "$TMP/ran.log" 2>/dev/null; then false; fi
}

# --- gh credential helper plumbing -------------------------------------------
# Rebuilt containers lose the container-local ~/.gitconfig, and with it the gh
# credential helper — HTTPS git then prompts "Username for 'https://github.com'".
# _sync_plumbing must (re)register it on every boot. 2026-07-06 dataenv incident.

@test "plumbing registers gh as git credential helper when missing" {
  printf '#!/bin/sh\necho "gh $*" >> "$TMP/ran.log"\n' > "$TMP/stubs/gh"; chmod +x "$TMP/stubs/gh"
  _sync_plumbing
  grep -q "gh auth setup-git" "$TMP/ran.log"
}

@test "plumbing skips gh auth setup-git when the helper is already configured" {
  printf '#!/bin/sh\necho "gh $*" >> "$TMP/ran.log"\n' > "$TMP/stubs/gh"; chmod +x "$TMP/stubs/gh"
  git config --global credential.https://github.com.helper '!/usr/bin/gh auth git-credential'
  _sync_plumbing
  if grep -q "gh auth setup-git" "$TMP/ran.log" 2>/dev/null; then false; fi
}

@test "plumbing sources the secrets file so gh sees GH_TOKEN in non-interactive boot" {
  # postStart shells never source ~/.bashrc.d/aicoding-env.sh, so GH_TOKEN is
  # absent — and `gh auth setup-git` refuses without an authenticated host.
  printf '#!/bin/sh\necho "token=${GH_TOKEN:-unset}" >> "$TMP/ran.log"\n' > "$TMP/stubs/gh"; chmod +x "$TMP/stubs/gh"
  mkdir -p "$TMP/.aicodingsetup"
  echo 'GH_TOKEN=test-token-123' > "$TMP/.aicodingsetup/.secrets.env"
  run env GH_TOKEN= bash -c '. "$BLUEPRINT_ROOT/lib/sync.sh"; ensure_gh_credential_helper'
  [ "$status" -eq 0 ]
  grep -q "token=test-token-123" "$TMP/ran.log"
}

@test "plumbing is fail-open when gh auth setup-git fails" {
  printf '#!/bin/sh\nexit 1\n' > "$TMP/stubs/gh"; chmod +x "$TMP/stubs/gh"
  run bash -c '. "$BLUEPRINT_ROOT/lib/sync.sh"; ensure_gh_credential_helper'
  [ "$status" -eq 0 ]
}

# --- file-based GH_TOKEN credential fallback ----------------------------------
# codex strips *TOKEN* env vars from spawned commands, so the gh helper fails
# inside codex sessions; git must fall through to the file-based helper.

@test "plumbing registers the file-fallback credential helper (idempotent)" {
  printf '#!/bin/sh\nexit 0\n' > "$TMP/stubs/gh"; chmod +x "$TMP/stubs/gh"
  _sync_plumbing
  _sync_plumbing
  run bash -c 'git config --global --get-all credential.https://github.com.helper | grep -c git-credential-aicoding'
  [ "$output" = "1" ]
}

@test "credential helper: answers get for https/github.com from the secrets file" {
  mkdir -p "$TMP/.aicodingsetup"
  echo 'GH_TOKEN=file-token-456' > "$TMP/.aicodingsetup/.secrets.env"
  run bash -c 'printf "protocol=https\nhost=github.com\n\n" | bash "$BLUEPRINT_ROOT/configs/git/git-credential-aicoding" get'
  [ "$status" -eq 0 ]
  [[ "$output" == *"username=x-access-token"* ]]
  [[ "$output" == *"password=file-token-456"* ]]
}

@test "plumbing symlinks ~/.agents/skills to ~/.claude/skills (idempotent)" {
  printf '#!/bin/sh\nexit 0\n' > "$TMP/stubs/gh"; chmod +x "$TMP/stubs/gh"
  _sync_plumbing
  _sync_plumbing
  [ -L "$TMP/.agents/skills" ]
  [ "$(readlink "$TMP/.agents/skills")" = "$TMP/.claude/skills" ]
}

@test "plumbing leaves a real ~/.agents/skills dir untouched (user's own adoption)" {
  printf '#!/bin/sh\nexit 0\n' > "$TMP/stubs/gh"; chmod +x "$TMP/stubs/gh"
  mkdir -p "$TMP/.agents/skills/my-skill"
  _sync_plumbing
  [ ! -L "$TMP/.agents/skills" ]
  [ -d "$TMP/.agents/skills/my-skill" ]
}

@test "credential helper: silent for other hosts, other actions, empty/missing token" {
  mkdir -p "$TMP/.aicodingsetup"
  echo 'GH_TOKEN=file-token-456' > "$TMP/.aicodingsetup/.secrets.env"
  run bash -c 'printf "protocol=https\nhost=gitlab.com\n\n" | bash "$BLUEPRINT_ROOT/configs/git/git-credential-aicoding" get'
  [ "$status" -eq 0 ]; [ -z "$output" ]
  run bash -c 'printf "protocol=https\nhost=github.com\n\n" | bash "$BLUEPRINT_ROOT/configs/git/git-credential-aicoding" store'
  [ "$status" -eq 0 ]; [ -z "$output" ]
  echo 'GH_TOKEN=' > "$TMP/.aicodingsetup/.secrets.env"
  run bash -c 'printf "protocol=https\nhost=github.com\n\n" | bash "$BLUEPRINT_ROOT/configs/git/git-credential-aicoding" get'
  [ "$status" -eq 0 ]; [ -z "$output" ]
  rm "$TMP/.aicodingsetup/.secrets.env"
  run bash -c 'printf "protocol=https\nhost=github.com\n\n" | bash "$BLUEPRINT_ROOT/configs/git/git-credential-aicoding" get'
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

# ensure_claude_runtime_scope: ~/.claude/{jobs,sessions,daemon} must become
# symlinks into a container-local base so a home dir shared across devpod
# containers stops leaking background agents between agents views (and stops
# daemons clobbering each other's roster). See the function comment in sync.sh.
@test "plumbing scopes claude runtime dirs into the container-local base" {
  export AICODING_CLAUDE_RUNTIME_DIR="$TMP/runtime"
  _sync_plumbing
  for d in jobs sessions daemon; do
    [ -L "$TMP/.claude/$d" ]
    [ "$(readlink "$TMP/.claude/$d")" = "$TMP/runtime/$d" ]
    [ -d "$TMP/runtime/$d" ]
  done
  _sync_plumbing                                   # idempotent re-run
  [ "$(readlink "$TMP/.claude/jobs")" = "$TMP/runtime/jobs" ]
}

@test "claude runtime scope adopts own jobs, leaves foreign ones in the backup" {
  export AICODING_CLAUDE_RUNTIME_DIR="$TMP/runtime"
  mkdir -p "$TMP/.claude/jobs/ownjob" "$TMP/.claude/jobs/foreignjob" "$TMP/mywork"
  printf '{"cwd":"%s"}' "$TMP/mywork" > "$TMP/.claude/jobs/ownjob/state.json"
  printf '{"cwd":"/no/such/workspace"}' > "$TMP/.claude/jobs/foreignjob/state.json"
  echo '{}' > "$TMP/.claude/jobs/pins.json"
  _sync_plumbing
  [ -d "$TMP/runtime/jobs/ownjob" ]                # ours: migrated
  [ -f "$TMP/runtime/jobs/pins.json" ]
  [ -d "$TMP/.claude/jobs.premigrate/foreignjob" ] # theirs: stays in backup
  [ ! -e "$TMP/.claude/jobs.premigrate/ownjob" ]
}

@test "claude runtime scope heals a dangling symlink after container rebuild" {
  export AICODING_CLAUDE_RUNTIME_DIR="$TMP/runtime"
  mkdir -p "$TMP/.claude"
  ln -s "$TMP/runtime/jobs" "$TMP/.claude/jobs"    # rebuild wiped the base
  _sync_plumbing
  [ -d "$TMP/runtime/jobs" ]
}

@test "claude runtime scope is fail-open when the base is uncreatable" {
  export AICODING_CLAUDE_RUNTIME_DIR=/proc/nonexistent/base
  mkdir -p "$TMP/.claude/jobs"
  run ensure_claude_runtime_scope
  [ "$status" -eq 0 ]
  [ ! -L "$TMP/.claude/jobs" ]                     # left untouched
}

# --- uv cache ownership ------------------------------------------------------
# devbox-base images built 2026-09-09..2026-09-25 baked a root-owned
# ~/.cache/uv (a root build step ran uv with HOME=/home/codespace), so every
# uv call as the user failed. Plumbing hands the cache back on each pass.
# A non-root test cannot create root-owned files, so `find` is stubbed to
# report a foreign-owned entry where needed.

_uvc_stub_sudo() {   # $1 = exit status; logs every call
  printf '#!/bin/sh\necho "sudo $*" >> "%s/ran.log"\nexit %s\n' "$TMP" "${1:-0}" > "$TMP/stubs/sudo"
  chmod +x "$TMP/stubs/sudo"
}
_uvc_stub_find_foreign() {
  printf '#!/bin/sh\necho "$1/sdists-v9/.git"\n' > "$TMP/stubs/find"; chmod +x "$TMP/stubs/find"
}

@test "uv cache heal is a no-op when the cache is missing" {
  _uvc_stub_sudo
  run ensure_uv_cache_ownership
  [ "$status" -eq 0 ]
  if grep -q chown "$TMP/ran.log" 2>/dev/null; then false; fi
}

@test "uv cache heal is a no-op when the user owns everything" {
  _uvc_stub_sudo
  mkdir -p "$HOME/.cache/uv/sdists-v9"
  run ensure_uv_cache_ownership
  [ "$status" -eq 0 ]
  if grep -q chown "$TMP/ran.log" 2>/dev/null; then false; fi
}

@test "uv cache heal chowns a foreign-owned cache without following symlinks" {
  _uvc_stub_sudo; _uvc_stub_find_foreign
  mkdir -p "$HOME/.cache/uv"
  run ensure_uv_cache_ownership
  [ "$status" -eq 0 ]
  grep -Fxq "sudo -n chown -R -P $(id -u):$(id -g) $HOME/.cache/uv" "$TMP/ran.log"
}

@test "uv cache heal never chowns a path taken from UV_CACHE_DIR" {
  _uvc_stub_sudo; _uvc_stub_find_foreign
  mkdir -p "$TMP/other-uv"
  UV_CACHE_DIR="$TMP/other-uv" XDG_CACHE_HOME="$TMP" run ensure_uv_cache_ownership
  [ "$status" -eq 0 ]
  if grep -q chown "$TMP/ran.log" 2>/dev/null; then false; fi
}

@test "uv cache heal refuses when ~/.cache is a symlink out of the home" {
  _uvc_stub_sudo; _uvc_stub_find_foreign
  mkdir -p "$TMP/outside/uv"
  ln -s "$TMP/outside" "$HOME/.cache"
  run ensure_uv_cache_ownership
  [ "$status" -eq 0 ]
  if grep -q chown "$TMP/ran.log" 2>/dev/null; then false; fi
}

@test "uv cache heal skips a symlinked cache" {
  _uvc_stub_sudo; _uvc_stub_find_foreign
  mkdir -p "$TMP/elsewhere" "$HOME/.cache"
  ln -s "$TMP/elsewhere" "$HOME/.cache/uv"
  run ensure_uv_cache_ownership
  [ "$status" -eq 0 ]
  if grep -q chown "$TMP/ran.log" 2>/dev/null; then false; fi
}

@test "uv cache heal warns and continues when sudo is refused" {
  _uvc_stub_sudo 1; _uvc_stub_find_foreign
  mkdir -p "$HOME/.cache/uv"
  run ensure_uv_cache_ownership
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN:"*".cache/uv"* ]]
  [ -d "$HOME/.cache/uv" ] && [ ! -L "$HOME/.cache/uv" ]
}

@test "uv cache heal is skipped on the host profile" {
  _uvc_stub_sudo; _uvc_stub_find_foreign
  mkdir -p "$HOME/.cache/uv"
  export AICODING_PROFILE=host
  run ensure_uv_cache_ownership
  [ "$status" -eq 0 ]
  if grep -q chown "$TMP/ran.log" 2>/dev/null; then false; fi
}

@test "sync plumbing heals the uv cache before any uv-backed step" {
  local body first
  body=$(declare -f _sync_plumbing)
  first=$(printf '%s\n' "$body" | grep -oE 'ensure_uv_cache_ownership|clip-x11-bridge' | head -n 1)
  [ "$first" = ensure_uv_cache_ownership ]
}

# --- /dev/kvm group access ----------------------------------------------------
# Privileged devpods carry the host's /dev, but /dev/kvm is 0660 root:<host gid>
# with no matching container group — so the Android emulator / qemu can't open it
# without sudo. Plumbing joins the owning group on every boot (membership is
# container state and dies with a rebuild). /dev/null stands in for the device:
# it is a char device on every host, and `stat` is stubbed for the gid.

_kvm_stub_stat() {   # $1 = gid the fake device reports
  printf '#!/bin/sh\necho "%s"\n' "$1" > "$TMP/stubs/stat"; chmod +x "$TMP/stubs/stat"
}
_kvm_stub_sudo() {   # log calls instead of running them
  cat > "$TMP/stubs/sudo" <<'EOF'
#!/bin/sh
echo "sudo $*" >> "$TMP/ran.log"
[ "${1:-}" != -n ] || shift
case "${1:-}" in
  groupadd|usermod) exit 0 ;;
  *) exec "$@" ;;
esac
EOF
  chmod +x "$TMP/stubs/sudo"
}
_kvm_unused_gid() {
  local gid=42424 groups=" $(id -G) "
  while [[ "$groups" == *" $gid "* ]]; do
    gid=$((gid + 1))
  done
  printf '%s\n' "$gid"
}

@test "kvm access is skipped on a host without /dev/kvm" {
  _kvm_stub_sudo
  export AICODING_KVM_DEVICE="$TMP/no-such-kvm"
  run ensure_kvm_group_access
  [ "$status" -eq 0 ]
  if grep -q usermod "$TMP/ran.log" 2>/dev/null; then false; fi
}

@test "kvm access creates the missing group and joins it" {
  local gid
  gid=$(_kvm_unused_gid)
  _kvm_stub_sudo; _kvm_stub_stat "$gid"
  printf '#!/bin/sh\nexit 2\n' > "$TMP/stubs/getent"; chmod +x "$TMP/stubs/getent"   # no group, any name
  export AICODING_KVM_DEVICE=/dev/null
  run ensure_kvm_group_access
  [ "$status" -eq 0 ]
  grep -q "sudo -n groupadd -g $gid kvm" "$TMP/ran.log"
  grep -q "sudo -n usermod -aG kvm " "$TMP/ran.log"
}

@test "kvm access reuses an existing group with the device's gid" {
  local gid
  gid=$(_kvm_unused_gid)
  _kvm_stub_sudo; _kvm_stub_stat "$gid"
  printf '#!/bin/sh\necho "kvm:x:%s:"\n' "$gid" > "$TMP/stubs/getent"; chmod +x "$TMP/stubs/getent"
  export AICODING_KVM_DEVICE=/dev/null
  ensure_kvm_group_access
  if grep -q groupadd "$TMP/ran.log" 2>/dev/null; then false; fi
  grep -q "sudo -n usermod -aG kvm " "$TMP/ran.log"
}

@test "kvm access picks a distinct name when 'kvm' is taken by another gid" {
  local gid
  gid=$(_kvm_unused_gid)
  _kvm_stub_sudo; _kvm_stub_stat "$gid"
  # gid lookup misses; the NAME lookup hits (a different gid already owns 'kvm')
  printf '#!/bin/sh\n[ "$2" = kvm ] && { echo "kvm:x:108:"; exit 0; }\nexit 2\n' \
    > "$TMP/stubs/getent"; chmod +x "$TMP/stubs/getent"
  export AICODING_KVM_DEVICE=/dev/null
  ensure_kvm_group_access
  grep -q "sudo -n groupadd -g $gid kvm$gid" "$TMP/ran.log"
}

@test "kvm access is a no-op when the user is already a member" {
  _kvm_stub_sudo; _kvm_stub_stat "$(id -g)"
  export AICODING_KVM_DEVICE=/dev/null
  ensure_kvm_group_access
  if grep -q -e groupadd -e usermod "$TMP/ran.log" 2>/dev/null; then false; fi
}

@test "kvm access is fail-open when groupadd is not permitted" {
  printf '#!/bin/sh\nexit 1\n' > "$TMP/stubs/sudo"; chmod +x "$TMP/stubs/sudo"
  _kvm_stub_stat 994
  printf '#!/bin/sh\nexit 2\n' > "$TMP/stubs/getent"; chmod +x "$TMP/stubs/getent"
  export AICODING_KVM_DEVICE=/dev/null
  run ensure_kvm_group_access
  [ "$status" -eq 0 ]
}

@test "kvm access is skipped on the host profile (bare-metal thin client)" {
  # /dev/kvm often exists on a real desktop; joining a system group there is an
  # unrequested privilege change, and the core profile runs no emulator.
  _kvm_stub_sudo; _kvm_stub_stat 994
  printf '#!/bin/sh\nexit 2\n' > "$TMP/stubs/getent"; chmod +x "$TMP/stubs/getent"
  export AICODING_PROFILE=host
  export AICODING_KVM_DEVICE=/dev/null
  run ensure_kvm_group_access
  [ "$status" -eq 0 ]
  if grep -q -e groupadd -e usermod "$TMP/ran.log" 2>/dev/null; then false; fi
}

@test "kvm access still runs on the container profile" {
  local gid
  gid=$(_kvm_unused_gid)
  _kvm_stub_sudo; _kvm_stub_stat "$gid"
  printf '#!/bin/sh\nexit 2\n' > "$TMP/stubs/getent"; chmod +x "$TMP/stubs/getent"
  export AICODING_PROFILE=container
  export AICODING_KVM_DEVICE=/dev/null
  ensure_kvm_group_access
  grep -q "sudo -n usermod -aG kvm " "$TMP/ran.log"
}

@test "claude runtime scope is skipped on the host profile" {
  # Premise of the scoping is several containers sharing one bind-mounted home;
  # a bare host has one home, and relocating live ~/.claude state there is
  # unrequested. #69 final-review deferred follow-up.
  export AICODING_CLAUDE_RUNTIME_DIR="$TMP/runtime"
  export AICODING_PROFILE=host
  mkdir -p "$TMP/.claude/jobs"
  run ensure_claude_runtime_scope
  [ "$status" -eq 0 ]
  [ -d "$TMP/.claude/jobs" ]                       # left a real dir
  if [ -L "$TMP/.claude/jobs" ]; then false; fi    # not symlinked away
  if [ -e "$TMP/.claude/jobs.premigrate" ]; then false; fi
}

@test "claude runtime scope still runs on the container profile" {
  export AICODING_CLAUDE_RUNTIME_DIR="$TMP/runtime"
  export AICODING_PROFILE=container
  mkdir -p "$TMP/.claude"
  ensure_claude_runtime_scope
  [ -L "$TMP/.claude/jobs" ]
}

@test "_sync_profile defaults to container when the clone predates profiles" {
  run bash -c '. "$BLUEPRINT_ROOT/lib/sync.sh"; _sync_profile'
  [ "$output" = container ]
}

@test "minimal-pi sync updates selected components without config or machine plumbing" {
  mkdir -p "$AICODING_STATE_DIR"
  printf '{"schema":1,"profile":"minimal-pi","components":["aicoding","dvw"]}\n' \
    > "$AICODING_STATE_DIR/component-selection.json"
  local calls="$TMP/minimal-pi.calls"
  _sync_source_update_libraries() { :; }
  _sync_refresh_and_reexec() { :; }
  _sync_plumbing() { echo plumbing >> "$calls"; }
  _sync_reconcile() { echo reconcile >> "$calls"; }
  _sync_provision() { echo provision >> "$calls"; }
  _sync_binaries_fresh() { return 1; }
  aicoding_update_installed_components() { echo components >> "$calls"; }
  _sync_binaries_stamp() { echo stamp >> "$calls"; }

  AICODINGSETUP_SKIP_NETWORK= run aicoding_sync --boot
  [ "$status" -eq 0 ]
  [ "$(cat "$calls")" = $'components\nstamp' ]
}

@test "normal manual sync selects an exact qualified source before other work" {
  local calls="$TMP/manual-selected.calls" sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  _sync_source_update_libraries() { :; }
  aicoding_select_ci_sha() { printf '%s\n' "$sha"; }
  _sync_refresh_and_reexec() { printf '%s\n' "$AICODING_SELECTED_AICODING_SHA" > "$calls"; }
  _sync_plumbing() { :; }
  _sync_binaries_fresh() { return 0; }
  _sync_reconcile() { :; }
  _sync_provision() { :; }
  _sync_system_provision() { :; }

  AICODING_BLUEPRINT_LOCAL=0 AICODINGSETUP_SKIP_NETWORK= run aicoding_sync --yes
  [ "$status" -eq 0 ]
  [ "$(cat "$calls")" = "$sha" ]
}

# WARNING: the two host-install tests below run the FULL install-host.sh main
# flow. They are offline-safe only under tests/bats/run.sh, which exports
# AICODINGSETUP_SKIP_NETWORK=1 suite-wide; invoking bats on this file directly
# would clone homelab-wiki and clone AND EXECUTE the real vendored bw-AICode
# installer (Go toolchain download, read-only files that break teardown).
@test "aicoding-install host commands survive tracking-clone deletion" {
  local clone="$TMP/tracking-clone" durable="$TMP/durable/blueprint"
  mkdir -p "$clone" "$HOME/.local/state/aicoding"
  # A full non-git tracking snapshot: installer inputs are real, but refresh
  # cannot contact an origin. Add untracked/dirty content to prove local-mode
  # snapshots are copied verbatim rather than reconstructed from git.
  tar -C "$BLUEPRINT_ROOT" --exclude=.git -cf - . | tar -C "$clone" -xf -
  git -C "$clone" init -q -b main
  git -C "$clone" add -A
  git -C "$clone" -c user.email=t@t -c user.name=t commit -q -m tracking-snapshot
  git -C "$clone" remote add origin "$BLUEPRINT_ROOT"
  git -C "$clone" update-ref refs/remotes/origin/main HEAD
  echo dirty-local-content > "$clone/dirty-sentinel"
  echo host > "$HOME/.local/state/aicoding/profile"

  AICODING_HOST_BLUEPRINT_DIR="$durable" \
    run env AICODING_BLUEPRINT_CLONE="$clone" \
      bash "$clone/bin/aicoding-install" --blueprint "$clone"
  [ "$status" -eq 0 ]
  [ "$(cat "$durable/dirty-sentinel")" = dirty-local-content ]
  [ -x "$durable/install-host.sh" ]
  local command
  for command in aicoding-sync aicoding-install aicoding-status; do
    [ -L "$HOME/.local/bin/$command" ]
    [[ "$(readlink -f "$HOME/.local/bin/$command")" == "$durable/bin/$command" ]]
  done

  rm -rf -- "$clone"
  for command in aicoding-sync aicoding-install aicoding-status; do
    run "$HOME/.local/bin/$command" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"usage:"* ]]
  done
  run "$HOME/.local/bin/aicoding-sync" --blueprint "$durable" --dry-run
  [ "$status" -eq 0 ]
  run "$HOME/.local/bin/aicoding-status" --print
  [ "$status" -eq 0 ]
  AICODING_HOST_BLUEPRINT_DIR="$durable" \
    run "$HOME/.local/bin/aicoding-install" --blueprint "$durable"
  [ "$status" -eq 0 ]
}

@test "host durable snapshot excludes a destination nested in its source" {
  local clone="$TMP/parent-checkout" durable="$TMP/parent-checkout/.runtime/blueprint"
  mkdir -p "$clone" "$HOME/.local/state/aicoding"
  tar -C "$BLUEPRINT_ROOT" --exclude=.git -cf - . | tar -C "$clone" -xf -
  # Same-suffix decoy: only the EXACT nested destination may be dropped from
  # the snapshot. tar patterns are unanchored by default, so an un-anchored
  # --exclude=.runtime/blueprint would silently drop this deeper file too.
  mkdir -p "$clone/project/.runtime/blueprint"
  echo survives > "$clone/project/.runtime/blueprint/keepme.txt"
  echo host > "$HOME/.local/state/aicoding/profile"

  AICODING_HOST_BLUEPRINT_DIR="$durable" \
    run bash "$clone/install-host.sh"
  [ "$status" -eq 0 ]
  [ -x "$durable/bin/aicoding-install" ]
  [ ! -e "$durable/.runtime/blueprint" ]   # no recursive self-copy
  [ "$(cat "$durable/project/.runtime/blueprint/keepme.txt")" = survives ]
}

@test "host enrollment followed by boot preserves a consistent Codex baseline" {
  blueprint_snapshot "$TMP/host-blueprint"
  bash "$TMP/host-blueprint/install-host.sh" </dev/null
  bash "$TMP/host-blueprint/install-host.sh" </dev/null
  local dest="$HOME/.codex/config.toml" before
  before=$(sha256sum "$dest")
  _sync_source_update_libraries "$BLUEPRINT_ROOT"
  run _sync_reconcile boot
  [ "$status" -eq 0 ]
  [ "$(sha256sum "$dest")" = "$before" ]
  grep -qx 'approval_policy = "on-request"' "$dest"
  [ ! -e "$HOME/.codex/.aicoding-sync" ]
}

@test "host enrollment silently preserves Codex comment edits without leaking values" {
  blueprint_snapshot "$TMP/host-blueprint"
  bash "$TMP/host-blueprint/install-host.sh" </dev/null
  local dest="$HOME/.codex/config.toml" before
  printf '\n# synthetic-private-value-9284\n' >> "$dest"
  before=$(sha256sum "$dest")
  run bash "$TMP/host-blueprint/install-host.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *"synthetic-private-value-9284"* ]]
  [ "$(sha256sum "$dest")" = "$before" ]
  _sync_source_update_libraries "$BLUEPRINT_ROOT"
  run _sync_reconcile boot
  [ "$status" -eq 0 ]
  [[ "$output" != *"synthetic-private-value-9284"* ]]
  [ "$(sha256sum "$dest")" = "$before" ]
}

@test "sync step 5 is skipped under the suite network guard and records nothing" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  AICODING_UPDATE_TTL=0 aicoding_sync --boot
  if jq -e '.components["provision-system"]' "$HOME/.local/state/aicoding/update-results.json" >/dev/null 2>&1; then false; fi
}

@test "sync step 5 runs on the container profile after releasing shared locks" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  _sync_system_provision() {
    if ! flock -n "$HOME/.claude/.aicoding-update.lock" true; then echo LOCK_HELD >> "$TMP/ran.log"; fi
    echo STEP5 >> "$TMP/ran.log"
    return 0
  }
  # Forces the container-runtime seam: without it this test only passes on a
  # box with /.dockerenv (or one of the other real signals), which a bare CI
  # VM does not have.
  AICODING_CONTAINER_RUNTIME=1 AICODING_UPDATE_TTL=0 aicoding_sync --boot
  grep -q STEP5 "$TMP/ran.log"
  if grep -q LOCK_HELD "$TMP/ran.log"; then false; fi
}

@test "sync step 5 is not run on the host profile or under --dry-run" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  _sync_system_provision() { echo STEP5 >> "$TMP/ran.log"; return 0; }
  AICODING_PROFILE=host AICODING_UPDATE_TTL=0 aicoding_sync --boot || true
  aicoding_sync --dry-run || true
  if grep -q STEP5 "$TMP/ran.log"; then false; fi
}

@test "a blocked step 5 marks the pass deferred without failing it" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  _sync_system_provision() { return 3; }
  run env AICODING_UPDATE_TTL=0 bash -c '. "$1/lib/sync.sh"; aicoding_config_is_shared() { return 1; }; _sync_system_provision() { return 3; }; aicoding_sync --boot' _ "$BLUEPRINT_ROOT"
  [[ "$output" == *"aicoding-sync: completed with deferrals"* ]]
}

@test "sync step 5 does not run without a recorded profile off a container runtime" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  _sync_system_provision() { echo STEP5 >> "$TMP/ran.log"; return 0; }
  # No recorded profile and the runtime seam forced off: this must look
  # exactly like a host to step 5, even though _sync_profile defaults to
  # container.
  rm -f "$HOME/.local/state/aicoding/profile"
  AICODING_CONTAINER_RUNTIME=0 AICODING_UPDATE_TTL=0 aicoding_sync --boot
  if grep -q STEP5 "$TMP/ran.log"; then false; fi
}

@test "sync step 5 runs without a recorded profile on a container runtime" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  _sync_system_provision() { echo STEP5 >> "$TMP/ran.log"; return 0; }
  rm -f "$HOME/.local/state/aicoding/profile"
  AICODING_CONTAINER_RUNTIME=1 AICODING_UPDATE_TTL=0 aicoding_sync --boot
  grep -q STEP5 "$TMP/ran.log"
}

@test "sync step 5 runs on an explicit container profile even off a container runtime" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  _sync_system_provision() { echo STEP5 >> "$TMP/ran.log"; return 0; }
  AICODING_PROFILE=container AICODING_CONTAINER_RUNTIME=0 AICODING_UPDATE_TTL=0 aicoding_sync --boot
  grep -q STEP5 "$TMP/ran.log"
}

@test "a fresh container with a stale shared manifest ends with no config blocker" {
  _smart_blueprint_copy
  local shared="$HOME/.aicodingsetup" results="$HOME/.local/state/aicoding/update-results.json"
  mkdir -p "$shared"
  jq -n --arg h "$HOME" '{schema_version:1, blueprint_commit:"old",
    files:{($h + "/.claude/commands/scaffold-project.md"):
      {mode:"overwrite", source:"commands/scaffold-project.md", deployed_hash:"x"}}}' \
    > "$shared/manifest.json"
  _sync_source_update_libraries "$BP"
  aicoding_result_record config-claude conflict old managed_config_conflict
  aicoding_result_record config conflict old managed_config_conflict
  aicoding_result_record provision blocked old preparation_deferred "" "deferred by claude"

  run env AICODING_BLUEPRINT_CLONE="$BP" AICODING_UPDATE_TTL=0 \
    bash -c '. "$1/lib/sync.sh"; aicoding_sync --boot' _ "$BP"
  [[ "$output" != *"managed config conflict"* ]]
  [[ "$output" != *"deferred by claude"* ]]
  [ ! -e "$shared/manifest.json" ]
  [ ! -e "$HOME/.local/state/aicoding/manifest.json" ]
  jq -e '[.components | to_entries[] | select(.key | startswith("config"))
          | select(.value.state != "current")] == []' "$results"
  jq -e '(.components.provision.detail // "") | test("claude|codex|cursor|opencode") | not' "$results"
}

@test "an existing container's first pass migrates the manifest profile and deletes it" {
  _smart_blueprint_copy
  local state="$HOME/.local/state/aicoding"
  mkdir -p "$state"
  echo '{"schema_version":2,"profile":"host","provision_commit":"p","blueprint_commit":"b","files":{}}' \
    > "$state/manifest.json"
  run env AICODING_BLUEPRINT_CLONE="$BP" AICODING_UPDATE_TTL=0 \
    bash -c '. "$1/lib/sync.sh"; aicoding_sync --boot' _ "$BP"
  [ "$(cat "$state/profile")" = host ]
  [ ! -e "$state/manifest.json" ]
  grep -qx 'approval_policy = "on-request"' "$HOME/.codex/config.toml"
  grep -qx 'sandbox_mode = "workspace-write"' "$HOME/.codex/config.toml"
}
