#!/usr/bin/env bats
setup() {
  : "${BLUEPRINT_ROOT:?run via run.sh}"
  export TMP; TMP=$(mktemp -d); export HOME="$TMP"
  export AICODING_BLUEPRINT_CLONE="$BLUEPRINT_ROOT"
  export AICODING_MANIFEST="$TMP/.aicodingsetup/manifest.json"
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
  before=$(jq -r '.provision_commit' "$AICODING_MANIFEST")
  local clone="$TMP/provision-failure-blueprint"
  rsync -a --exclude=.git "$BLUEPRINT_ROOT/" "$clone/"
  cat >> "$clone/lib/provision.sh" <<'EOF'
install_claude_mcps() { return 1; }
EOF
  export AICODING_BLUEPRINT_CLONE="$clone"
  run _sync_provision boot
  [ "$status" -ne 0 ]
  [ "$(jq -r '.provision_commit' "$AICODING_MANIFEST")" = "$before" ]
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

@test "_sync_binaries: host profile refreshes claude only" {
  printf '#!/bin/sh\necho "codex $*" >> "$TMP/ran.log"\n' > "$TMP/stubs/codex"; chmod +x "$TMP/stubs/codex"
  mkdir -p "$(dirname "$AICODING_MANIFEST")"
  echo '{"profile":"host"}' > "$AICODING_MANIFEST"
  : > "$TMP/ran.log"
  . "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  _sync_binaries
  grep -q "^claude update" "$TMP/ran.log"
  [ "$(grep -c '^opencode' "$TMP/ran.log")" = 0 ]
  [ "$(grep -c '^agent' "$TMP/ran.log")" = 0 ]
  [ "$(grep -c '^codex' "$TMP/ran.log")" = 0 ]
}

@test "_sync_binaries: container/absent profile refreshes all CLIs" {
  : > "$TMP/ran.log"
  . "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  _sync_binaries
  grep -q "^claude update" "$TMP/ran.log"
  grep -q "^opencode upgrade" "$TMP/ran.log"
  grep -q "^agent update" "$TMP/ran.log"
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
  # clone whose sync library loads first. Do not pre-source blueprint-deploy or
  # define manifest_get_profile; plumbing is exactly where the host used to be
  # misclassified as a container.
  local clone="$TMP/tracking-clone"
  git clone -q "$BLUEPRINT_ROOT" "$clone"
  mkdir -p "$(dirname "$AICODING_MANIFEST")" \
    "$TMP/.claude/jobs" "$TMP/.claude/sessions" "$TMP/.claude/daemon" \
    "$AICODING_UPDATE_STATE"
  echo '{"schema_version":1,"profile":"host","files":{}}' > "$AICODING_MANIFEST"
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
@test "clean sync still advances the manifest blueprint_commit stamp" {
  # Regression: "Nothing to do." returned before stamping, so a sync with no
  # file changes left blueprint_commit stale and aicoding-status stuck on
  # "behind" until some file actually changed.
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  # Simulate an older recorded commit (blueprint advanced, no file deltas).
  local tmp; tmp=$(mktemp)
  jq '.blueprint_commit = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"' "$AICODING_MANIFEST" > "$tmp"
  mv "$tmp" "$AICODING_MANIFEST"
  run bash -c '. "$BLUEPRINT_ROOT/lib/sync.sh"; aicoding_sync --yes'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Nothing to do."
  local stamped head
  stamped=$(jq -r '.blueprint_commit' "$AICODING_MANIFEST")
  head=$(git -C "$BLUEPRINT_ROOT" rev-parse HEAD)
  [ "$stamped" = "$head" ]
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
  echo "$output" | grep -q "Nothing to do."
}

@test "sync --boot preserves a user-edited non-owned file (conservative apply set)" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  # ~/.tmux.conf is deployed and non-owned. Editing it makes on-disk differ from
  # both deployed_hash and blueprint -> drifted_and_updating, which boot's
  # conservative apply set excludes, so it must NOT be reverted.
  echo "# user edit" >> "$HOME/.tmux.conf"
  local before; before=$(sha256sum "$HOME/.tmux.conf" | awk '{print $1}')
  run env AICODING_UPDATE_TTL=0 bash -c '. "$BLUEPRINT_ROOT/lib/sync.sh"; aicoding_sync --boot'
  [ "$status" -eq 0 ]
  [[ "$output" == *"aicoding-sync: completed with deferrals"* ]]
  [ "$(sha256sum "$HOME/.tmux.conf" | awk '{print $1}')" = "$before" ]
}

@test "boot records preserved user drift as a conflict without advancing blueprint stamp" {
  local clone="$TMP/conflict-blueprint"
  rsync -a --exclude=.git "$BLUEPRINT_ROOT/" "$clone/"
  export AICODING_BLUEPRINT_CLONE="$clone" AICODING_BLUEPRINT_LOCAL=1 SCRIPT_DIR="$clone"
  bash "$clone/install.sh" </dev/null
  local old_commit new_commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  old_commit=$(jq -r '.blueprint_commit' "$AICODING_MANIFEST")
  printf '%s\n' "$new_commit" > "$clone/.aicoding-version"
  printf '\n# blueprint update\n' >> "$clone/configs/tmux/tmux.conf"
  printf '\n# user edit\n' >> "$HOME/.tmux.conf"
  _sync_source_update_libraries "$clone"
  _SYNC_REFRESHED=1 run _sync_reconcile boot

  [ "$status" -eq 0 ]
  [ "$(jq -r '.blueprint_commit' "$AICODING_MANIFEST")" = "$old_commit" ]
  jq -e --arg target "$new_commit" \
    '.components.config.state == "conflict"
      and .components.config.target_version == $target
      and .components.config.reason == "managed_config_conflict"' \
    "$AICODING_STATE_DIR/update-results.json"
  grep -q '# user edit' "$HOME/.tmux.conf"
}

@test "reconcile acquires shared writer locks before classifying destination state" {
  local clone="$TMP/lock-blueprint" holder
  rsync -a --exclude=.git "$BLUEPRINT_ROOT/" "$clone/"
  cat >> "$clone/lib/blueprint-deploy.sh" <<'EOF'
classify_managed_files() { : > "$CLASSIFY_MARKER"; }
EOF
  export AICODING_BLUEPRINT_CLONE="$clone" AICODING_BLUEPRINT_LOCAL=1
  export CLASSIFY_MARKER="$TMP/classified" _SYNC_REFRESHED=1
  mkdir -p "$HOME/.claude" "$(dirname "$AICODING_MANIFEST")"
  echo '{"schema_version":1,"files":{},"blueprint_commit":"old"}' > "$AICODING_MANIFEST"
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

@test "every config-writing mode carries tool receipts and shared compatibility authorization" {
  local clone="$TMP/shared-gate-blueprint" dest="$HOME/.codex/config.toml"
  rsync -a --exclude=.git "$BLUEPRINT_ROOT/" "$clone/"
  cat >> "$clone/lib/blueprint-deploy.sh" <<EOF
classify_managed_files() {
  FILE_MODE["$dest"]=overwrite
  FILE_SOURCE["$dest"]=configs/codex/config.toml
  BUCKETS["$dest"]=will_update
}
EOF
  export AICODING_BLUEPRINT_CLONE="$clone" AICODING_BLUEPRINT_LOCAL=1 _SYNC_REFRESHED=1
  mkdir -p "$(dirname "$AICODING_MANIFEST")" "$(dirname "$dest")"
  echo '{"schema_version":1,"files":{},"blueprint_commit":"old"}' > "$AICODING_MANIFEST"
  printf 'old\n' > "$dest"
  aicoding_config_is_shared() { return 0; }
  aicoding_config_is_compatible() {
    printf '%s:%s\n' "${AICODING_REQUIRE_UPDATE_RECEIPT:-0}" \
      "${AICODING_REQUIRE_SHARED_COMPATIBILITY:-0}" >> "$TMP/compat-calls"
    [ "${AICODING_REQUIRE_UPDATE_RECEIPT:-0}" = 1 ] \
      && [ "${AICODING_REQUIRE_SHARED_COMPATIBILITY:-0}" = 1 ] \
      || { echo shared_authorization_missing; return 1; }
  }

  local sync_mode
  for sync_mode in boot yes first; do
    : > "$TMP/compat-calls"
    printf 'old\n' > "$dest"
    run _sync_reconcile "$sync_mode"
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP/compat-calls")" = 1:1 ]
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

@test "selected Gitless release retains historical generated-file provenance" {
  local repo="$TMP/provenance-repo" sha release source_path=configs/claude/hooks/bw-deny-files.sh
  git clone -q "$BLUEPRINT_ROOT" "$repo"
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name test
  printf '1\n' > "$repo/.aicoding-bootstrap-version"
  printf '#!/bin/sh\necho historical\n' > "$repo/$source_path"
  git -C "$repo" add "$source_path" .aicoding-bootstrap-version
  git -C "$repo" commit -qm historical
  mkdir -p "$HOME/.claude/hooks"
  cp "$repo/$source_path" "$HOME/.claude/hooks/bw-deny-files.sh"
  printf '#!/bin/sh\necho selected\n' > "$repo/$source_path"
  git -C "$repo" commit -qam selected
  sha=$(git -C "$repo" rev-parse HEAD)
  export AICODING_BLUEPRINT_REMOTE="$repo" AICODING_DATA_DIR="$TMP/data"

  release=$(_sync_stage_selected_blueprint "$sha")
  [ ! -d "$release/.git" ]
  export AICODING_BLUEPRINT_CLONE="$release"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run owned_file_has_generated_provenance "$HOME/.claude/hooks/bw-deny-files.sh" "$source_path"
  [ "$status" -eq 0 ]
}

@test "sync --boot leaves an existing unmanaged file at a newly managed path alone" {
  # Regression (unified review 2026-08-20, HIGH): dest exists + manifest
  # exists + path untracked used to bucket as new_file, which boot's
  # unattended apply set deploys — clobbering a personal file with no backup.
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  jq 'del(.files["'"$HOME"'/.codex/config.toml"])' "$AICODING_MANIFEST" \
    > "$AICODING_MANIFEST.t" && mv "$AICODING_MANIFEST.t" "$AICODING_MANIFEST"
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
  export AICODING_BLUEPRINT_CLONE="$clone" AICODING_BLUEPRINT_LOCAL=1 SCRIPT_DIR="$clone"
  bash "$clone/install.sh" </dev/null
  local old_codex old_tmux
  old_codex=$(cat "$HOME/.codex/config.toml")
  old_tmux=$(cat "$HOME/.tmux.conf")
  sed -i 's/model = "gpt-5.6-sol"/model = "future-model"/' "$clone/configs/codex/config.toml"
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
  [[ "$output" == *"aicoding-sync: completed with deferrals"* ]]
  [ "$(cat "$HOME/.codex/config.toml")" = "$old_codex" ]
  [ "$(cat "$HOME/.tmux.conf")" != "$old_tmux" ]
  grep -q 'unrelated safe update' "$HOME/.tmux.conf"
  jq -e '.components.config.state == "blocked" and .components.config.reason == "partial_config_blocked"' \
    "$AICODING_STATE_DIR/update-results.json"
}

@test "sync --yes backs up an existing unmanaged file before managing it" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  jq 'del(.files["'"$HOME"'/.codex/config.toml"])' "$AICODING_MANIFEST" \
    > "$AICODING_MANIFEST.t" && mv "$AICODING_MANIFEST.t" "$AICODING_MANIFEST"
  printf 'model = "my-personal-model"\n' > "$HOME/.codex/config.toml"

  run bash -c '. "$BLUEPRINT_ROOT/lib/sync.sh"; aicoding_sync --yes'
  [ "$status" -eq 0 ]
  # Blueprint version deployed, personal content preserved in the backup.
  if grep -q 'my-personal-model' "$HOME/.codex/config.toml"; then false; fi
  bak=$(ls "$HOME"/.codex/config.toml.bak.* 2>/dev/null | head -1)
  [ -n "$bak" ]
  grep -q 'my-personal-model' "$bak"
}

@test "aicoding-install: pulls the blueprint and re-runs the installer (reconcile)" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  run "$BLUEPRINT_ROOT/bin/aicoding-install" --blueprint "$BLUEPRINT_ROOT" </dev/null
  [ "$status" -eq 0 ]
  echo "$output" | grep -Fq "Blueprint source: local $BLUEPRINT_ROOT"
  echo "$output" | grep -q "Mode: reconcile"
  [ "$(jq -r '.blueprint_origin' "$AICODING_MANIFEST")" = "local:$BLUEPRINT_ROOT" ]
}

@test "aicoding-install: passes --force-reinstall through (first-deploy)" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  run "$BLUEPRINT_ROOT/bin/aicoding-install" --force-reinstall \
      --blueprint="$BLUEPRINT_ROOT" </dev/null
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Mode: first"
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
  manifest_get_profile() { echo host; }
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
  manifest_get_profile() { echo container; }
  export AICODING_KVM_DEVICE=/dev/null
  ensure_kvm_group_access
  grep -q "sudo -n usermod -aG kvm " "$TMP/ran.log"
}

@test "claude runtime scope is skipped on the host profile" {
  # Premise of the scoping is several containers sharing one bind-mounted home;
  # a bare host has one home, and relocating live ~/.claude state there is
  # unrequested. #69 final-review deferred follow-up.
  export AICODING_CLAUDE_RUNTIME_DIR="$TMP/runtime"
  manifest_get_profile() { echo host; }
  mkdir -p "$TMP/.claude/jobs"
  run ensure_claude_runtime_scope
  [ "$status" -eq 0 ]
  [ -d "$TMP/.claude/jobs" ]                       # left a real dir
  if [ -L "$TMP/.claude/jobs" ]; then false; fi    # not symlinked away
  if [ -e "$TMP/.claude/jobs.premigrate" ]; then false; fi
}

@test "claude runtime scope still runs on the container profile" {
  export AICODING_CLAUDE_RUNTIME_DIR="$TMP/runtime"
  manifest_get_profile() { echo container; }
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

  AICODINGSETUP_SKIP_NETWORK= run aicoding_sync --yes
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
  mkdir -p "$clone" "$(dirname "$AICODING_MANIFEST")"
  # A full non-git tracking snapshot: installer inputs are real, but refresh
  # cannot contact an origin. Add untracked/dirty content to prove local-mode
  # snapshots are copied verbatim rather than reconstructed from git.
  tar -C "$BLUEPRINT_ROOT" --exclude=.git -cf - . | tar -C "$clone" -xf -
  git -C "$clone" init -q -b main
  git -C "$clone" add -A
  git -C "$clone" -c user.email=t@t -c user.name=t commit -q -m tracking-snapshot
  echo dirty-local-content > "$clone/dirty-sentinel"
  echo '{"schema_version":1,"profile":"host","files":{}}' > "$AICODING_MANIFEST"

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
  mkdir -p "$clone" "$(dirname "$AICODING_MANIFEST")"
  tar -C "$BLUEPRINT_ROOT" --exclude=.git -cf - . | tar -C "$clone" -xf -
  # Same-suffix decoy: only the EXACT nested destination may be dropped from
  # the snapshot. tar patterns are unanchored by default, so an un-anchored
  # --exclude=.runtime/blueprint would silently drop this deeper file too.
  mkdir -p "$clone/project/.runtime/blueprint"
  echo survives > "$clone/project/.runtime/blueprint/keepme.txt"
  echo '{"schema_version":1,"profile":"host","files":{}}' > "$AICODING_MANIFEST"

  AICODING_HOST_BLUEPRINT_DIR="$durable" \
    run bash "$clone/install-host.sh"
  [ "$status" -eq 0 ]
  [ -x "$durable/bin/aicoding-install" ]
  [ ! -e "$durable/.runtime/blueprint" ]   # no recursive self-copy
  [ "$(cat "$durable/project/.runtime/blueprint/keepme.txt")" = survives ]
}

# --- change report (per-file rulers + coloured diff) -------------------------

@test "change report: ruler header, verb, path, diff body; no colour when piped" {
  printf 'a\nb\n' > "$TMP/dest"; printf 'a\nc\n' > "$TMP/src"
  run _sync_change_report "updated" "$TMP/dest" "$(_sync_diff_body "$TMP/dest" "$TMP/src")"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf '═%.0s' $(seq 1 72))" ]
  [ "${lines[1]}" = " updated: $TMP/dest" ]
  [ "${lines[2]}" = "${lines[0]}" ]
  echo "$output" | grep -qx '    -b'
  echo "$output" | grep -qx '    +c'
  if printf '%s' "$output" | grep -q $'\e\['; then false; fi
}

@test "change report: FORCE_COLOR paints verb, rulers and diff lines" {
  printf 'a\nb\n' > "$TMP/dest"; printf 'a\nc\n' > "$TMP/src"
  unset NO_COLOR; export FORCE_COLOR=1
  run _sync_change_report "new" "$TMP/dest" "$(_sync_diff_body "$TMP/dest" "$TMP/src")"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q $'\e\[32m'            # green: added line
  printf '%s' "$output" | grep -q $'\e\[31m'            # red: removed line
  printf '%s' "$output" | grep -q $'\e\[36m'            # cyan ruler
  printf '%s' "${lines[1]}" | grep -q $'\e\[1;32mnew\e\[0m: '
}

@test "change report: verb colour follows the action (removed=red, updated=yellow)" {
  unset NO_COLOR; export FORCE_COLOR=1
  run _sync_change_report "removed" "$TMP/x" ""
  printf '%s' "${lines[1]}" | grep -q $'\e\[1;31mremoved'
  run _sync_change_report "updated (with backup)" "$TMP/x" ""
  printf '%s' "${lines[1]}" | grep -q $'\e\[1;33mupdated (with backup)'
}

@test "change report: no diff body prints header only, no blank diff block" {
  run _sync_change_report "restored" "$TMP/x" ""
  [ "${#lines[@]}" -eq 3 ]                # bats drops the trailing blank separator line
  if echo "$output" | grep -q '^    '; then false; fi
}

@test "diff body: renders the source like deploy does and scrubs secrets-file values" {
  mkdir -p "$TMP/.aicodingsetup"
  printf 'FIRECRAWL_API_KEY=fc-supersecret-value-123\n' > "$TMP/.aicodingsetup/.secrets.env"
  . "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"; load_secrets_env
  printf 'key = "fc-supersecret-value-123"\nold = 1\n' > "$HOME/dest.toml"
  printf 'key = "{{FIRECRAWL_API_KEY}}"\nnew = 1\n' > "$TMP/src.toml"
  run _sync_diff_body "$HOME/dest.toml" "$TMP/src.toml"
  [ "$status" -eq 0 ]
  if echo "$output" | grep -q 'fc-supersecret'; then false; fi
  if echo "$output" | grep -q '{{FIRECRAWL'; then false; fi   # substituted, so the key line is unchanged
  echo "$output" | grep -qx -- '-old = 1'
  echo "$output" | grep -qx -- '+new = 1'
}

@test "sync --yes prints a change report with the diff for each applied file" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  # Prepend: the deployed file has no trailing newline, so an append would
  # glue onto the last line instead of adding one.
  printf '# user edit\n%s' "$(cat "$HOME/.tmux.conf")" > "$HOME/.tmux.conf"
  run bash -c '. "$BLUEPRINT_ROOT/lib/sync.sh"; aicoding_sync --yes'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx " updated (with backup): $HOME/.tmux.conf"
  echo "$output" | grep -qx '    -# user edit'
  echo "$output" | grep -q '^═══'
}

@test "diff body: withholds the diff when the secrets file exists but rules cannot be built" {
  mkdir -p "$TMP/.aicodingsetup"
  printf 'GH_TOKEN=some-long-token-value\n' > "$TMP/.aicodingsetup/.secrets.env"
  chmod 000 "$TMP/.aicodingsetup/.secrets.env"
  printf 'old = some-long-token-value\n' > "$TMP/dest"; printf 'new = 1\n' > "$TMP/src"
  run _sync_diff_body "$TMP/dest" "$TMP/src"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'diff withheld'
  if echo "$output" | grep -q 'some-long-token'; then false; fi
}

@test "diff body: colour decision pinned in _SYNC_COLOR survives command substitution" {
  unset NO_COLOR FORCE_COLOR
  printf 'a\nb\n' > "$TMP/dest"; printf 'a\nc\n' > "$TMP/src"
  _SYNC_COLOR=1
  body=$(_sync_diff_body "$TMP/dest" "$TMP/src")
  printf '%s' "$body" | grep -q $'\e\[32m'
  _SYNC_COLOR=0
  FORCE_COLOR=1 body=$(_sync_diff_body "$TMP/dest" "$TMP/src")
  if printf '%s' "$body" | grep -q $'\e\['; then false; fi
}

@test "diff body: scrubs values from a custom AICODING_SECRETS_FILE" {
  printf 'BRAVE_API_KEY=brave-custom-secret-9876\n' > "$TMP/custom-secrets"
  export AICODING_SECRETS_FILE="$TMP/custom-secrets"
  printf 'key = brave-custom-secret-9876\nold = 1\n' > "$TMP/dest"
  printf 'key = brave-custom-secret-9876\nnew = 1\n' > "$TMP/src"
  run _sync_diff_body "$TMP/dest" "$TMP/src"
  [ "$status" -eq 0 ]
  if echo "$output" | grep -q 'brave-custom'; then false; fi
  echo "$output" | grep -qx -- '+new = 1'
}

@test "diff body: overwrite_raw sources are compared verbatim, placeholders untouched" {
  . "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  printf 'path={{HOME}}/x\nold\n' > "$TMP/dest"
  printf 'path={{HOME}}/x\nnew\n' > "$TMP/src"
  run _sync_diff_body "$TMP/dest" "$TMP/src" overwrite_raw
  [ "$status" -eq 0 ]
  if echo "$output" | grep -q '^[-+]path='; then false; fi   # context only, never a change
  echo "$output" | grep -qx -- '-old'
  echo "$output" | grep -qx -- '+new'
  run _sync_diff_body "$TMP/dest" "$TMP/src" overwrite
  echo "$output" | grep -q -- "-path={{HOME}}/x"          # rendered mode substitutes, so it shows as changed
}
