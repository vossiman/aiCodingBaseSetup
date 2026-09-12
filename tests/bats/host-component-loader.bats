#!/usr/bin/env bats
setup() {
  export TEST_ROOT; TEST_ROOT=$(mktemp -d)
  export HOME="$TEST_ROOT/home" AICODING_STATE_DIR="$TEST_ROOT/state" AICODING_DATA_DIR="$TEST_ROOT/data"
  export _AICODINGSETUP_NVS_STRIPPED=1
  export SCRIPT_DIR="$BLUEPRINT_ROOT"
  mkdir -p "$HOME"
}
teardown() { rm -rf "$TEST_ROOT"; }
@test "host provisioning loads the actual CI selector required by bw staging" {
  run bash -c 'source "$BLUEPRINT_ROOT/install-host.sh"; _provision_ensure_update_components; declare -F aicoding_select_ci_sha'
  printf "%s\n" "$output"
  [ "$status" -eq 0 ]
}
@test "provisioning repairs selector dependency when adapters were already loaded" {
  source "$BLUEPRINT_ROOT/lib/provision.sh"
  source "$BLUEPRINT_ROOT/lib/update-components.sh"
  unset -f aicoding_select_ci_sha
  _provision_ensure_update_components
  declare -F aicoding_select_ci_sha
}

@test "both installers recover legacy scheduler locks before taking shared writer locks" {
  local installer
  for installer in install.sh install-host.sh; do
    export INSTALLER_TEST_PATH="$BLUEPRINT_ROOT/$installer"
    rm -f "$TEST_ROOT/recovery-attempted"
    run bash -c '
      source "$INSTALLER_TEST_PATH"
      ENV_TYPE=container
      seed_github_known_host() { :; }
      load_or_prompt_secrets() { :; }
      ensure_gh_credential_helper() { :; }
      ensure_gh_stored_auth() { :; }
      ensure_git_credential_file_fallback() { :; }
      _provision_recover_scheduler_locks() { touch "$TEST_ROOT/recovery-attempted"; }
      aicoding_shared_locks_acquire_managed_roots() {
        [ -f "$TEST_ROOT/recovery-attempted" ] || exit 43
        exit 42
      }
      main
    '
    [ "$status" -eq 42 ]
  done
}

@test "competing scheduler enrollment alone does not mark provisioning deferred" {
  source "$BLUEPRINT_ROOT/lib/provision.sh"
  export AICODINGSETUP_SKIP_NETWORK=0
  _aicoding_auto_recover_shared_lock_worker() { return 4; }
  _AICODING_PREPARATION_DEFERRED=0
  _provision_recover_scheduler_locks
  [ "$_AICODING_PREPARATION_DEFERRED" -eq 0 ]
}
