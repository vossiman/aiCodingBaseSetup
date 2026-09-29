#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load t3-helpers

setup() {
  t3_test_setup
  # a hand-installed legacy t3 and its state in ~/.t3, as on balance-extract
  mkdir -p "$TMP/legacy"
  npm install --prefix "$TMP/legacy" t3@0.0.40 >/dev/null
  L="$TMP/legacy/node_modules/.bin/t3"
  mkdir -p "$HOME/.t3/userdata/secrets"
  echo env-legacy > "$HOME/.t3/userdata/environment-id"
  : > "$HOME/.t3/userdata/secrets/cloud-cli-oauth-token.bin"
  echo '{}' > "$HOME/.t3/userdata/settings.json"
}
teardown() { t3_test_teardown; }

S() { printf '%s\n' "$T3_ENVS_ROOT/demo/aicoding"; }

start_legacy() {
  env -u T3CODE_HOME nohup "$L" serve "$TMP/work" </dev/null >/dev/null 2>&1 &
  for i in $(seq 1 50); do [ -f "$HOME/.t3/userdata/server-runtime.json" ] && break; sleep 0.1; done
}

@test "export: stops the hand-started server, records its version, writes archive and manifest" {
  start_legacy
  run "$B/t3-migrate" --export
  [ "$status" -eq 0 ]
  if pgrep -f "$TMP/legacy" >/dev/null; then false; fi
  [ -f "$T3_MIGRATE_DIR/demo.tgz" ]
  [ "$(jq -r .version "$T3_MIGRATE_DIR/demo.json")" = 0.0.40 ]
  [ "$(jq -r .environment_id "$T3_MIGRATE_DIR/demo.json")" = env-legacy ]
  [ "$(jq -r .sha256 "$T3_MIGRATE_DIR/demo.json")" = "$(sha256sum "$T3_MIGRATE_DIR/demo.tgz" | cut -d' ' -f1)" ]
  [ "$(stat -c %a "$T3_MIGRATE_DIR/demo.tgz")" = 600 ]
}

@test "export: works without the t3-envs mount but refuses a non-persistent archive folder" {
  export T3_TEST_UNMOUNTED=1
  run "$B/t3-migrate" --export --version 0.0.40
  [ "$status" -eq 0 ]
  rm -f "$T3_MIGRATE_DIR"/demo.*
  export T3_TEST_MIGRATE_UNMOUNTED=1
  run "$B/t3-migrate" --export --version 0.0.40
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a host bind mount"* ]]
}

@test "export: resolves ~/.t3 even when T3CODE_HOME points at the new layout" {
  run env T3CODE_HOME="$T3_ENVS_ROOT/demo" "$B/t3-migrate" --export --version 0.0.40
  [ "$status" -eq 0 ]
  [ "$(jq -r .environment_id "$T3_MIGRATE_DIR/demo.json")" = env-legacy ]
}

@test "export: refuses while any process holds a file under the source open" {
  exec 5<"$HOME/.t3/userdata/settings.json"
  run "$B/t3-migrate" --export --version 0.0.40
  exec 5<&-
  [ "$status" -eq 1 ]
  [[ "$output" == *"files under"* ]]
  [ ! -f "$T3_MIGRATE_DIR/demo.tgz" ]
}

@test "export: without a running server or --version it refuses" {
  run "$B/t3-migrate" --export
  [ "$status" -eq 1 ]
  [[ "$output" == *"--version"* ]]
}

@test "restore: unpacks, adopts at the exported version, enables and starts" {
  "$B/t3-migrate" --export --version 0.0.40
  run "$B/t3-migrate" --restore
  [ "$status" -eq 0 ]
  [ "$(cat "$T3_ENVS_ROOT/demo/userdata/environment-id")" = env-legacy ]
  [ "$(jq -c . "$(S)/version.json")" = '{"mode":"latest","version":"0.0.40"}' ]
  [ -f "$(S)/enabled" ]
  [ "$(t3_owner version)" = 0.0.40 ]
  [ -f "$T3_MIGRATE_DIR/demo.tgz" ]
}

@test "restore: refuses a target with state, a checksum mismatch, and a mismatched environment-id" {
  "$B/t3-migrate" --export --version 0.0.40
  mkdir -p "$T3_ENVS_ROOT/demo/userdata"
  run "$B/t3-migrate" --restore
  [ "$status" -eq 1 ]
  [[ "$output" == *"already holds"* ]]
  rm -rf "$T3_ENVS_ROOT/demo/userdata"
  echo junk >> "$T3_MIGRATE_DIR/demo.tgz"
  run "$B/t3-migrate" --restore
  [ "$status" -eq 1 ]
  [[ "$output" == *checksum* ]]
  rm -f "$T3_MIGRATE_DIR"/demo.*
  "$B/t3-migrate" --export --version 0.0.40
  jq '.environment_id = "other"' "$T3_MIGRATE_DIR/demo.json" > "$TMP/m" && mv "$TMP/m" "$T3_MIGRATE_DIR/demo.json"
  run "$B/t3-migrate" --restore
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not match"* ]]
}

@test "restore: a retry after a crash before the userdata rename succeeds" {
  "$B/t3-migrate" --export --version 0.0.40
  mkdir -p "$T3_ENVS_ROOT/demo.restore/partial" "$T3_ENVS_ROOT/demo/caches"
  run "$B/t3-migrate" --restore
  [ "$status" -eq 0 ]
  [ ! -e "$T3_ENVS_ROOT/demo.restore" ]
}

@test "confirm: deletes the archive and manifest only" {
  "$B/t3-migrate" --export --version 0.0.40
  run "$B/t3-migrate" --confirm
  [ "$status" -eq 0 ]
  [ ! -e "$T3_MIGRATE_DIR/demo.tgz" ]
  [ ! -e "$T3_MIGRATE_DIR/demo.json" ]
}

@test "export: a hand-started server under another HOME is not ours and is left running" {
  mkdir -p "$TMP/other/.t3/userdata"
  env -u T3CODE_HOME HOME="$TMP/other" nohup "$L" serve "$TMP/work" </dev/null >/dev/null 2>&1 &
  for i in $(seq 1 50); do [ -f "$TMP/other/.t3/userdata/server-runtime.json" ] && break; sleep 0.1; done
  other=$(jq -r .pid "$TMP/other/.t3/userdata/server-runtime.json")
  run "$B/t3-migrate" --export --version 0.0.40
  [ "$status" -eq 0 ]
  kill -0 "$other"
  [[ "$output" != *"stopping the hand-started"* ]]
}
