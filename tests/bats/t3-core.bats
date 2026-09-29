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
