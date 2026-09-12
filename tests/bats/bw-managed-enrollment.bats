#!/usr/bin/env bats

setup() {
  : "${BLUEPRINT_ROOT:?run via tests/bats/run.sh}"
  export TMP; TMP=$(mktemp -d)
  export HOME="$TMP/home" SCRIPT_DIR="$BLUEPRINT_ROOT"
  export AICODING_STATE_DIR="$TMP/state" AICODING_DATA_DIR="$TMP/data"
  export AICODING_VENDOR_DIR="$TMP/vendor" AICODING_PERSISTENT_ENROLLMENT=1
  mkdir -p "$HOME/.local/bin" "$TMP/stubs" "$AICODING_VENDOR_DIR/bw-AICode/.git"
  export PATH="$HOME/.local/bin:$TMP/stubs:/usr/bin:/bin"
  . "$BLUEPRINT_ROOT/lib/provision.sh"
  . "$BLUEPRINT_ROOT/lib/provision-integrations.sh"
  _provision_ensure_update_components
  aicoding_select_ci_sha() { echo bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; }
  _aicoding_stage_git_source() {
    mkdir -p "$3"
    local name
    for name in claude-bw opencode-bw pi-bw; do
      printf '#!/bin/sh\necho managed\n' > "$3/$name.sh"
      chmod +x "$3/$name.sh"
    done
    printf '%s\n' "$2" > "$3/.aicoding-version"
  }
  cat > "$TMP/stubs/go" <<'SH'
#!/bin/sh
[ "$1" != test ] || exit 0
[ "${FAIL_BUILD:-0}" != 1 ] || exit 42
printf '#!/bin/sh\necho managed-guard\n' > "$3"
chmod +x "$3"
SH
  cat > "$TMP/stubs/git" <<'SH'
#!/bin/sh
echo legacy-git >> "$TMP/legacy-called"
SH
  cat > "$AICODING_VENDOR_DIR/bw-AICode/install.sh" <<'SH'
#!/bin/sh
echo legacy-install >> "$TMP/legacy-called"
for name in claude-bw opencode-bw pi-bw; do
  ln -sf "$AICODING_VENDOR_DIR/bw-AICode/$name.sh" "$HOME/.local/bin/$name"
done
echo 'bw-docker-guard build failed'
exit 0
SH
  chmod +x "$TMP/stubs/"*
}

teardown() { rm -rf "$TMP"; }

@test "persistent provisioning preserves managed launchers and never executes legacy installer" {
  aicoding_update_bw
  AICODINGSETUP_SKIP_NETWORK=0 run install_bubblewrap
  [ "$status" -eq 0 ]
  [ ! -e "$TMP/legacy-called" ]
  local name
  for name in claude-bw opencode-bw pi-bw bw-docker-guard; do
    [ ! -L "$HOME/.local/bin/$name" ]
    run "$HOME/.local/bin/$name"
    [ "$status" -eq 0 ]
    [[ "$output" == managed* ]]
  done
}

@test "persistent provisioning propagates managed build failure without reporting installed" {
  export FAIL_BUILD=1
  AICODINGSETUP_SKIP_NETWORK=0 run install_bubblewrap
  [ "$status" -ne 0 ]
  [[ "$output" != *'OK: bw-AICode installed'* ]]
  [ ! -e "$TMP/legacy-called" ]
  jq -e '.components["bw-AICode"].state == "failed" and .components["bw-AICode"].reason == "build_failed"' "$AICODING_RESULTS_FILE"
}

@test "persistent provisioning records unavailable source as a deferral" {
  aicoding_select_ci_sha() { return 1; }
  AICODINGSETUP_SKIP_NETWORK=0 install_bubblewrap
  [ "${_AICODING_PREPARATION_DEFERRED:-0}" = 1 ]
  [ ! -e "$TMP/legacy-called" ]
  jq -e '.components["bw-AICode"].state == "blocked"' "$AICODING_RESULTS_FILE"
}

@test "stale blocked bw receipt cannot hide a new unclassified failure" {
  _aicoding_record_deferred bw-AICode blocked '' ci_selection_unavailable
  aicoding_update_bw() { return 42; }
  AICODINGSETUP_SKIP_NETWORK=0 run install_bubblewrap
  [ "$status" -ne 0 ]
  [ ! -e "$TMP/legacy-called" ]
}

@test "persistent container installer rejects direct WSL before provisioning mutations" {
  run bash -c '
    export _AICODINGSETUP_NVS_STRIPPED=1
    . "$SCRIPT_DIR/install.sh"
    ENV_TYPE=wsl
    seed_github_known_host() { touch "$TMP/provision-mutated"; return 42; }
    main
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *'use --profile host'* ]]
  [ ! -e "$TMP/provision-mutated" ]
}

@test "persistent container installer permits a container even on a WSL kernel" {
  run bash -c '
    export _AICODINGSETUP_NVS_STRIPPED=1
    . "$SCRIPT_DIR/install.sh"
    ENV_TYPE=container
    seed_github_known_host() { touch "$TMP/provision-mutated"; return 42; }
    main
  '
  [ "$status" -eq 42 ]
  [ -e "$TMP/provision-mutated" ]
  [[ "$output" != *'use --profile host'* ]]
}

@test "local blueprint provisioning retains existing managed bw ownership" {
  aicoding_update_bw
  unset AICODING_PERSISTENT_ENROLLMENT
  AICODINGSETUP_SKIP_NETWORK=0 run install_bubblewrap
  [ "$status" -eq 0 ]
  [ ! -e "$TMP/legacy-called" ]
  [ ! -L "$HOME/.local/bin/claude-bw" ]
  run "$HOME/.local/bin/claude-bw"
  [ "$output" = managed ]
}

@test "unenrolled local provisioning retains the legacy installer route" {
  unset AICODING_PERSISTENT_ENROLLMENT
  printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/claude-bw"
  AICODINGSETUP_SKIP_NETWORK=0 run install_bubblewrap
  [ "$status" -eq 0 ]
  [ -e "$TMP/legacy-called" ]
}

@test "local managed bw deferral prevents a complete provisioning stamp" {
  aicoding_update_bw
  unset AICODING_PERSISTENT_ENROLLMENT
  aicoding_select_ci_sha() { return 1; }
  AICODINGSETUP_SKIP_NETWORK=0 install_bubblewrap
  [ "${_AICODING_GUARDED_PROVISION_DEFERRED:-0}" = 1 ]
  [ ! -e "$TMP/legacy-called" ]
}

@test "local blueprint container installer rejects direct WSL before provisioning mutations" {
  run bash -c '
    export _AICODINGSETUP_NVS_STRIPPED=1
    . "$SCRIPT_DIR/install.sh"
    unset AICODING_PERSISTENT_ENROLLMENT
    ENV_TYPE=wsl
    seed_github_known_host() { touch "$TMP/provision-mutated"; return 42; }
    main
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *'use --profile host'* ]]
  [ ! -e "$TMP/provision-mutated" ]
}
