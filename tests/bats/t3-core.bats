#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load t3-helpers

setup() { t3_test_setup; }
teardown() { t3_test_teardown; }

@test "env: T3CODE_HOME is per workspace under the mount, and the path is printed" {
  run bash -c '. "$BLUEPRINT_ROOT/lib/t3.sh"; t3_env; echo "$T3CODE_HOME|$T3_STATE"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"t3: state: $T3_ENVS_ROOT/demo"* ]]
  [[ "$output" == *"$T3_ENVS_ROOT/demo|$T3_ENVS_ROOT/demo/aicoding" ]]
  [ -d "$T3_ENVS_ROOT/demo/aicoding" ]
}

@test "env: refuses without the mount and writes nothing" {
  export T3_TEST_UNMOUNTED=1
  run t3_lib t3_env
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a host mount"* ]]
  [ ! -e "$T3_ENVS_ROOT/demo" ]
}

@test "env: refuses a tmpfs mount" {
  export T3_TEST_FSTYPE=tmpfs
  run t3_lib t3_env
  [ "$status" -eq 1 ]
  [[ "$output" == *"on tmpfs"* ]]
}

@test "env: refuses an unwritable mount" {
  chmod 555 "$T3_ENVS_ROOT"
  run t3_lib t3_env
  chmod 755 "$T3_ENVS_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not writable"* ]]
}

@test "env: refuses a missing or unsafe workspace key" {
  run env -u DEVPOD_WORKSPACE_ID bash -c '. "$BLUEPRINT_ROOT/lib/t3.sh"; t3_env'
  [ "$status" -eq 1 ]
  [[ "$output" == *"DEVPOD_WORKSPACE_ID"* ]]
  for bad in '../x' '.hidden' 'a/b' ''; do
    run env DEVPOD_WORKSPACE_ID="$bad" bash -c '. "$BLUEPRINT_ROOT/lib/t3.sh"; t3_env'
    [ "$status" -eq 1 ]
  done
}

@test "versions: order is numeric, parsing strips the t3 prefix" {
  run t3_lib t3_version_lt 0.0.9 0.0.10
  [ "$status" -eq 0 ]
  run t3_lib t3_version_lt 0.0.10 0.0.9
  [ "$status" -eq 1 ]
  run t3_lib t3_version_lt 0.0.10 0.0.10
  [ "$status" -eq 1 ]
  run bash -c '. "$BLUEPRINT_ROOT/lib/t3.sh"; echo "t3 v0.0.42" | t3_parse_version'
  [ "$output" = 0.0.42 ]
}

@test "state: version.json round-trips atomically; junk reads as nothing" {
  run bash -c '. "$BLUEPRINT_ROOT/lib/t3.sh"; t3_env 2>/dev/null; t3_write_version held 0.0.41; t3_mode; t3_selected_version'
  [ "$output" = $'held\n0.0.41' ]
  [ -z "$(ls -A "$T3_ENVS_ROOT/demo/aicoding" | grep '^\.version')" ]
  echo '{not json' > "$T3_ENVS_ROOT/demo/aicoding/version.json"
  run bash -c '. "$BLUEPRINT_ROOT/lib/t3.sh"; t3_env 2>/dev/null; t3_mode; t3_selected_version'
  [ -z "$output" ]
}

@test "state: set up only when setup-done matches the environment-id" {
  mkdir -p "$T3_ENVS_ROOT/demo/aicoding" "$T3_ENVS_ROOT/demo/userdata"
  echo env-a > "$T3_ENVS_ROOT/demo/userdata/environment-id"
  run bash -c '. "$BLUEPRINT_ROOT/lib/t3.sh"; t3_env 2>/dev/null; t3_set_up'
  [ "$status" -eq 1 ]
  echo env-a > "$T3_ENVS_ROOT/demo/aicoding/setup-done"
  run bash -c '. "$BLUEPRINT_ROOT/lib/t3.sh"; t3_env 2>/dev/null; t3_set_up'
  [ "$status" -eq 0 ]
  echo env-b > "$T3_ENVS_ROOT/demo/userdata/environment-id"
  run bash -c '. "$BLUEPRINT_ROOT/lib/t3.sh"; t3_env 2>/dev/null; t3_set_up'
  [ "$status" -eq 1 ]
}

@test "control lock: a second command waits, then fails naming the holder" {
  bash -c '. "$BLUEPRINT_ROOT/lib/t3.sh"; t3_entry 2>/dev/null; sleep 6' &
  local holder=$!
  sleep 1
  run t3_lib t3_entry
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
  [ "$status" -eq 1 ]
  [[ "$output" == *"holds the control lock"* ]]
}

@test "control lock: freed when the holder exits" {
  bash -c '. "$BLUEPRINT_ROOT/lib/t3.sh"; t3_entry 2>/dev/null; sleep 1' &
  sleep 0.3
  run t3_lib t3_entry
  wait
  [ "$status" -eq 0 ]
}

@test "install: puts the version in its own folder and verifies it" {
  run t3_lib t3_install 0.0.42
  [ "$status" -eq 0 ]
  [ -x "$T3_RUNTIME_ROOT/0.0.42/node_modules/.bin/t3" ]
  run t3_lib t3_installed 0.0.42
  [ "$status" -eq 0 ]
  run bash -c '. "$BLUEPRINT_ROOT/lib/t3.sh"; t3_exe 0.0.42'
  [[ "$output" == "$T3_RUNTIME_ROOT/0.0.42/node_modules/@t3code/t3-linux-"*"/t3" ]]
}

@test "install: a failed npm leaves no folder behind" {
  export T3_TEST_NPM_FAIL=1
  run t3_lib t3_install 0.0.42
  [ "$status" -eq 1 ]
  [ ! -e "$T3_RUNTIME_ROOT/0.0.42" ]
  [ -z "$(ls -A "$T3_RUNTIME_ROOT" 2>/dev/null)" ]
}

@test "install: a package reporting the wrong version is rejected" {
  export T3_TEST_NPM_REPORTS=0.0.41
  run t3_lib t3_install 0.0.42
  [ "$status" -eq 1 ]
  [[ "$output" == *"expected 0.0.42"* ]]
  [ ! -e "$T3_RUNTIME_ROOT/0.0.42" ]
}

@test "install: an installed version is not reinstalled" {
  t3_lib t3_install 0.0.42
  : > "$T3_STUB_LOG"
  run t3_lib t3_install 0.0.42
  [ "$status" -eq 0 ]
  if grep -q '^npm install' "$T3_STUB_LOG"; then false; fi
}

@test "latest: reads npm, rejects junk and failures" {
  run t3_lib t3_latest
  [ "$output" = 0.0.50 ]
  export T3_TEST_LATEST=latest
  run t3_lib t3_latest
  [ "$status" -eq 1 ]
  export T3_TEST_NPM_VIEW_FAIL=1
  run t3_lib t3_latest
  [ "$status" -eq 1 ]
}

@test "status: reports server, selection, auto, pending and attention without taking the lock" {
  t3_fake_setup 0.0.42
  "$BLUEPRINT_ROOT/bin/t3-start"
  echo '{"candidate":"0.0.50","base":"0.0.42"}' > "$T3_ENVS_ROOT/demo/aicoding/pending.json"
  echo "restore did not complete" > "$T3_ENVS_ROOT/demo/aicoding/attention"
  bash -c '. "$BLUEPRINT_ROOT/lib/t3.sh"; t3_env 2>/dev/null; t3_control_lock; sleep 4' &
  sleep 0.5
  run "$BLUEPRINT_ROOT/bin/t3-status" --offline
  wait
  [ "$status" -eq 0 ]
  [[ "$output" == *"server:     running"* ]]
  [[ "$output" == *"selected:   latest 0.0.42"* ]]
  [[ "$output" == *"auto:       on"* ]]
  [[ "$output" == *'"candidate":"0.0.50"'* ]]
  [[ "$output" == *"ATTENTION"* ]]
  [[ "$output" == *"Environment link: provisioned"* ]]
}

@test "wiring: install_t3_symlinks links every bin/t3-* wrapper, and sync checks each" {
  run bash -c 'header(){ :; }; warn(){ echo "W $*"; }; ok(){ :; }; SCRIPT_DIR="$BLUEPRINT_ROOT"
    . "$BLUEPRINT_ROOT/lib/provision-integrations.sh"; install_t3_symlinks'
  [ "$status" -eq 0 ]
  local f n
  for f in "$BLUEPRINT_ROOT"/bin/t3-*; do
    n=${f##*/}
    [ "$(readlink "$HOME/.local/bin/$n")" = "$f" ]
    sed -n '/for name in dvw-probe/,/do$/p' "$BLUEPRINT_ROOT/lib/sync.sh" | grep -qw "$n"
  done
  grep -q 'install_t3_symlinks || rc=1' "$BLUEPRINT_ROOT/lib/sync.sh"
  grep -q '^  install_t3_symlinks$' "$BLUEPRINT_ROOT/install.sh"
}

@test "boot: on-start dispatches t3-start --boot only where enabled" {
  mkdir -p "$HOME/.local/bin"
  printf '#!/bin/sh\necho "$@" > "%s/boot-called"\n' "$TMP" > "$HOME/.local/bin/t3-start"
  chmod +x "$HOME/.local/bin/t3-start"
  cd "$TMP"
  run env -u AICODINGSETUP_SKIP_NETWORK PATH="$HOME/.local/bin:$TMP/stubs:/usr/local/bin:/usr/bin:/bin" bash "$BLUEPRINT_ROOT/on-start.sh"
  sleep 0.5
  [ ! -e "$TMP/boot-called" ]
  mkdir -p "$T3_ENVS_ROOT/demo/aicoding"; : > "$T3_ENVS_ROOT/demo/aicoding/enabled"
  run env -u AICODINGSETUP_SKIP_NETWORK PATH="$HOME/.local/bin:$TMP/stubs:/usr/local/bin:/usr/bin:/bin" bash "$BLUEPRINT_ROOT/on-start.sh"
  for i in $(seq 1 25); do [ -e "$TMP/boot-called" ] && break; sleep 0.2; done
  [ "$(cat "$TMP/boot-called")" = --boot ]
}
