#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load t3-helpers

setup() { t3_test_setup; t3_make_db; }
teardown() { t3_test_teardown; }

S() { printf '%s\n' "$T3_ENVS_ROOT/demo/aicoding"; }
U() { printf '%s\n' "$T3_ENVS_ROOT/demo/userdata"; }
running() { bash -c '. "$BLUEPRINT_ROOT/lib/t3.sh"; t3_env 2>/dev/null; t3_running' >/dev/null 2>&1; }

@test "update: switches an idle server to npm's newest, mode latest, with a backup" {
  t3_fake_setup 0.0.42
  "$B/t3-start"
  run "$B/t3-update"
  [ "$status" -eq 0 ]
  [ "$(jq -c . "$(S)/version.json")" = '{"mode":"latest","version":"0.0.50"}' ]
  [ "$(t3_owner version)" = 0.0.50 ]
  b=$(ls -d "$(S)"/backups/0.0.42-*)
  [ -f "$b/state.sqlite" ] && [ -f "$b/environment-id" ] && [ -f "$b/secrets/cloud-cli-oauth-token.bin" ]
  [ "$(stat -c %a "$b")" = 700 ]
  [ ! -f "$(S)/switch.json" ]
}

@test "update VERSION: holds that version; --latest follows releases again without switching" {
  t3_fake_setup 0.0.42
  "$B/t3-start"
  run "$B/t3-update" 0.0.45
  [ "$status" -eq 0 ]
  [ "$(jq -c . "$(S)/version.json")" = '{"mode":"held","version":"0.0.45"}' ]
  pid=$(t3_owner pid)
  run "$B/t3-update" --latest
  [ "$status" -eq 0 ]
  [ "$(jq -c . "$(S)/version.json")" = '{"mode":"latest","version":"0.0.45"}' ]
  [ "$(t3_owner pid)" = "$pid" ]
}

@test "update: the same version restarts nothing" {
  t3_fake_setup 0.0.50
  "$B/t3-start"
  pid=$(t3_owner pid)
  run "$B/t3-update"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already on t3 0.0.50"* ]]
  [ "$(t3_owner pid)" = "$pid" ]
}

@test "update: running work without a terminal needs --yes" {
  t3_bin_as make sleep
  t3_fake_setup 0.0.42
  T3_TEST_CHILDREN=make "$B/t3-start"
  run "$B/t3-update" </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *process_make* ]]
  [ "$(t3_owner version)" = 0.0.42 ]
  run "$B/t3-update" --yes </dev/null
  [ "$status" -eq 0 ]
  [ "$(t3_owner version)" = 0.0.50 ]
}

@test "update: an install failure leaves the running server and version.json untouched" {
  t3_fake_setup 0.0.42
  "$B/t3-start"
  pid=$(t3_owner pid)
  export T3_TEST_NPM_FAIL=1
  run "$B/t3-update"
  [ "$status" -eq 1 ]
  [ "$(t3_owner pid)" = "$pid" ]
  [ "$(jq -r .version "$(S)/version.json")" = 0.0.42 ]
}

@test "update: a target that changes identity is rolled back with identity restored" {
  t3_fake_setup 0.0.42
  "$B/t3-start"
  export T3_TEST_CHANGE_ENVID=0.0.50
  run "$B/t3-update"
  [ "$status" -eq 1 ]
  [ "$(cat "$(U)/environment-id")" = env-test-1 ]
  [ "$(jq -r .version "$(S)/version.json")" = 0.0.42 ]
  [ "$(t3_owner version)" = 0.0.42 ]
  [ "$(jq -r .reason "$(S)/last-result.json")" = switch_failed ]
  [ ! -f "$(S)/switch.json" ]
  [ -z "$(ls -d "$T3_ENVS_ROOT/demo"/userdata.* 2>/dev/null)" ]
}

@test "update: a target that never starts is rolled back and the database restored" {
  t3_fake_setup 0.0.42
  "$B/t3-start"
  t3_sql "INSERT INTO projection_thread_messages VALUES('keep','t',NULL,'user','x',0,'$(t3_iso '-2 hours')','$(t3_iso '-2 hours')');"
  export T3_TEST_SERVE_FAIL=0.0.50
  run "$B/t3-update"
  [ "$status" -eq 1 ]
  run python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("select count(*) from projection_thread_messages").fetchone()[0])' "$(t3_db)"
  [ "$output" = 1 ]
  running
}

@test "update from inside the scope detaches and completes" {
  t3_fake_setup 0.0.42
  "$B/t3-start"
  run env T3_AICODING_OWNER="$(t3_owner token)" "$B/t3-update"
  [ "$status" -eq 0 ]
  [[ "$output" == *"continuing in the background"* ]]
  for i in $(seq 1 100); do [ "$(jq -r .version "$(S)/version.json")" = 0.0.50 ] && break; sleep 0.2; done
  [ "$(jq -r .version "$(S)/version.json")" = 0.0.50 ]
}

@test "update on a stopped, disabled workspace switches and leaves it stopped" {
  t3_fake_setup 0.0.42
  run "$B/t3-update"
  [ "$status" -eq 0 ]
  [ "$(jq -r .version "$(S)/version.json")" = 0.0.50 ]
  if running; then false; fi
}

@test "journal: an interrupted stop is rolled back to the old version, and an enabled server restarts" {
  t3_fake_setup 0.0.42
  "$B/t3-start"
  jq -cn --argjson old "$(cat "$(S)/version.json")" '{id:"j1",old:$old,new:{mode:"latest",version:"0.0.50"},backup:"none",kind:"manual",phase:"stopping"}' > "$(S)/switch.json"
  run "$B/t3-auto" on
  [ "$status" -eq 0 ]
  [ ! -f "$(S)/switch.json" ]
  [ "$(jq -r .version "$(S)/version.json")" = 0.0.42 ]
  running
  [ "$(t3_owner version)" = 0.0.42 ]
}

@test "journal: committed is finished forward" {
  t3_fake_setup 0.0.42
  jq -cn --argjson old "$(cat "$(S)/version.json")" '{id:"j2",old:$old,new:{mode:"held",version:"0.0.45"},backup:"none",kind:"manual",phase:"committed"}' > "$(S)/switch.json"
  echo '{"candidate":"0.0.50","base":"0.0.42"}' > "$(S)/pending.json"
  run "$B/t3-auto" on
  [ "$(jq -c . "$(S)/version.json")" = '{"mode":"held","version":"0.0.45"}' ]
  [ ! -f "$(S)/pending.json" ]
}

@test "journal: a crash between the two renames is finished from the filesystem state" {
  t3_fake_setup 0.0.42
  mkdir -p "$(S)/backups/b"; echo env-test-1 > "$(S)/backups/b/environment-id"
  jq -cn --argjson old "$(cat "$(S)/version.json")" '{id:"j3",old:$old,new:{mode:"latest",version:"0.0.50"},backup:"'"$(S)/backups/b"'",kind:"manual",phase:"rolling-back"}' > "$(S)/switch.json"
  cp -a "$(U)" "$T3_ENVS_ROOT/demo/userdata.restore-j3"
  echo j3 > "$T3_ENVS_ROOT/demo/userdata.restore-j3.complete"
  mv "$(U)" "$T3_ENVS_ROOT/demo/userdata.old-j3"
  run "$B/t3-auto" on
  [ "$status" -eq 0 ]
  [ -d "$(U)" ]
  [ -z "$(ls -d "$T3_ENVS_ROOT/demo"/userdata.* 2>/dev/null)" ]
}

@test "journal: an unknown filesystem combination needs attention and blocks commands" {
  t3_fake_setup 0.0.42
  mkdir -p "$(S)/backups/b"
  jq -cn --argjson old "$(cat "$(S)/version.json")" '{id:"j4",old:$old,new:{mode:"latest",version:"0.0.50"},backup:"'"$(S)/backups/b"'",kind:"manual",phase:"starting-target"}' > "$(S)/switch.json"
  mv "$(U)" "$TMP/gone"
  run "$B/t3-auto" on
  [ "$status" -eq 1 ]
  [[ "$output" == *"manual attention"* ]]
  run "$B/t3-start"
  [ "$status" -eq 1 ]
  [[ "$output" == *"manual attention"* ]]
  [ -f "$(S)/switch.json" ]
}

@test "pending: applied at start when idle; kept when the database shows recent work" {
  t3_fake_setup 0.0.42
  echo '{"candidate":"0.0.50","base":"0.0.42"}' > "$(S)/pending.json"
  t3_sql "INSERT INTO projection_thread_messages VALUES('m','t',NULL,'user','x',0,'$(t3_iso '-5 minutes')','$(t3_iso '-5 minutes')');"
  run "$B/t3-start"
  [ "$status" -eq 0 ]
  [ "$(t3_owner version)" = 0.0.42 ]
  [ -f "$(S)/pending.json" ]
  "$B/t3-stop"
  t3_sql "DELETE FROM projection_thread_messages;"
  run "$B/t3-start"
  [ "$status" -eq 0 ]
  [ "$(t3_owner version)" = 0.0.50 ]
  [ ! -f "$(S)/pending.json" ]
}

@test "pending: dropped when the base no longer matches, when held, or when auto is off" {
  t3_fake_setup 0.0.42
  echo '{"candidate":"0.0.50","base":"0.0.41"}' > "$(S)/pending.json"
  "$B/t3-start"
  [ "$(t3_owner version)" = 0.0.42 ]
  [ ! -f "$(S)/pending.json" ]
  "$B/t3-stop"
  echo '{"candidate":"0.0.50","base":"0.0.42"}' > "$(S)/pending.json"
  run "$B/t3-update" 0.0.45
  [ ! -f "$(S)/pending.json" ]
  echo '{"candidate":"0.0.50","base":"0.0.45"}' > "$(S)/pending.json"
  "$B/t3-auto" off
  [ ! -f "$(S)/pending.json" ]
}

@test "auto: on and off toggle the auto file" {
  t3_fake_setup
  "$B/t3-auto" off
  [ ! -f "$(S)/auto" ]
  "$B/t3-auto" on
  [ -f "$(S)/auto" ]
  run "$B/t3-auto" maybe
  [ "$status" -eq 1 ]
}

@test "backups: only the last three are kept" {
  t3_fake_setup 0.0.42
  "$B/t3-start"
  for v in 0.0.43 0.0.44 0.0.45 0.0.46; do "$B/t3-update" "$v" >/dev/null 2>&1; sleep 1; done
  [ "$(ls -d "$(S)"/backups/*/ | wc -l)" -eq 3 ]
}
