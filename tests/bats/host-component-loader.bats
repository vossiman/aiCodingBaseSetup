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
