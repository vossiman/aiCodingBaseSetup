#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load t3-helpers

setup() { t3_test_setup; t3_make_db; }
teardown() { t3_test_teardown; }

S() { printf '%s\n' "$T3_ENVS_ROOT/demo/aicoding"; }
pass() { "$B/t3-update" --scheduled 2>>"$TMP/pass.log"; }

@test "scheduled: a workspace that is not enabled is a no-op" {
  t3_fake_setup
  run pass
  [ "$status" -eq 0 ]
  [ "$output" = "result current t3_not_enabled - -" ]
}

@test "scheduled: held never switches" {
  t3_fake_setup 0.0.42
  "$B/t3-start"
  jq '.mode = "held"' "$(S)/version.json" > "$TMP/v" && mv "$TMP/v" "$(S)/version.json"
  run pass
  [ "$output" = "result current t3_held 0.0.42 -" ]
  [ "$(t3_owner version)" = 0.0.42 ]
}

@test "scheduled: already newest" {
  t3_fake_setup 0.0.50
  "$B/t3-start"
  run pass
  [ "$output" = "result current t3_current 0.0.50 -" ]
}

@test "scheduled: an idle running server is switched" {
  t3_fake_setup 0.0.42
  "$B/t3-start"
  run pass
  [ "$status" -eq 0 ]
  [ "$output" = "result updated t3_switched 0.0.50 -" ]
  [ "$(t3_owner version)" = 0.0.50 ]
}

@test "scheduled: a running turn waits; nothing is restarted, the newest is installed" {
  t3_fake_setup 0.0.42
  "$B/t3-start"
  pid=$(t3_owner pid)
  t3_sql "INSERT INTO projection_thread_sessions VALUES('t','running',NULL,NULL,NULL,'x',NULL,'$(t3_iso '-2 hours')');"
  run pass
  [ "$status" -eq 1 ]
  [[ "$output" == "result blocked t3_idle_wait 0.0.42 busy:"* ]]
  [ "$(t3_owner pid)" = "$pid" ]
  [ -x "$T3_RUNTIME_ROOT/0.0.50/node_modules/.bin/t3" ]
}

@test "scheduled: auto off installs but never restarts" {
  t3_fake_setup 0.0.42
  "$B/t3-start"
  rm "$(S)/auto"
  run pass
  [ "$output" = "result blocked t3_auto_off 0.0.42 available=0.0.50" ]
  [ "$(t3_owner version)" = 0.0.42 ]
}

@test "scheduled: a stopped enabled workspace records a candidate that the next start applies" {
  t3_fake_setup 0.0.42
  "$B/t3-start"; "$B/t3-stop"; : > "$(S)/enabled"
  run pass
  [ "$output" = "result current t3_candidate_pending 0.0.42 candidate=0.0.50" ]
  [ "$(jq -c . "$(S)/pending.json")" = '{"candidate":"0.0.50","base":"0.0.42"}' ]
  [ "$(jq -r .version "$(S)/version.json")" = 0.0.42 ]
  "$B/t3-start"
  [ "$(t3_owner version)" = 0.0.50 ]
}

@test "scheduled: npm unavailable" {
  t3_fake_setup 0.0.42
  "$B/t3-start"
  export T3_TEST_NPM_VIEW_FAIL=1
  run pass
  [ "$output" = "result blocked t3_npm_unavailable 0.0.42 -" ]
}

@test "scheduled: no disturbance; only our own idle supervisor is replaced" {
  local c
  export FORBIDDEN="$TMP/forbidden"; : > "$FORBIDDEN"
  for c in docker devpod dvw reboot shutdown poweroff pkill killall tmux; do
    printf '#!/bin/sh\necho "%s $*" >> "$FORBIDDEN"\nexit 0\n' "$c" > "$TMP/stubs/$c"
    chmod +x "$TMP/stubs/$c"
  done
  t3_fake_setup 0.0.42
  "$B/t3-start"
  old=$(t3_owner pid)
  setsid sleep 300 & decoy=$!
  run pass
  [ "$output" = "result updated t3_switched 0.0.50 -" ]
  [ ! -s "$FORBIDDEN" ]
  kill -0 "$decoy"
  if kill -0 "$old" 2>/dev/null; then false; fi
  kill "$decoy"
}

@test "boot versus updater: boot waits for the lock and exactly one server results" {
  t3_fake_setup 0.0.42
  "$B/t3-start"; "$B/t3-stop"; : > "$(S)/enabled"
  pass >/dev/null
  pass >/dev/null &
  "$B/t3-start" --boot
  wait
  [ "$(pgrep -fc "$TMP/fake-server.py")" -eq 1 ]
  [ "$(t3_owner version)" = 0.0.50 ]
}

@test "component: selected only where enabled, and records a catalogued reason" {
  export AICODING_STATE_DIR="$TMP/state" AICODING_DATA_DIR="$TMP/data"
  export AICODING_RESULTS_FILE="$TMP/state/update-results.json"
  mkdir -p "$AICODING_STATE_DIR"
  t3_fake_setup 0.0.42
  run bash -c '. "$BLUEPRINT_ROOT/lib/update-results.sh"; . "$BLUEPRINT_ROOT/lib/update-components.sh"; aicoding_installed_components'
  [[ "$output" != *t3* ]]
  "$B/t3-start"
  run bash -c '. "$BLUEPRINT_ROOT/lib/update-results.sh"; . "$BLUEPRINT_ROOT/lib/update-components.sh"; aicoding_installed_components'
  [[ "$output" == *t3* ]]
  run bash -c '. "$BLUEPRINT_ROOT/lib/update-results.sh"; . "$BLUEPRINT_ROOT/lib/update-components.sh"; aicoding_update_t3'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.components.t3.state' "$AICODING_RESULTS_FILE")" = updated ]
  [ "$(jq -r '.components.t3.reason' "$AICODING_RESULTS_FILE")" = t3_switched ]
  jq -e '.reasons.t3_switched' "$BLUEPRINT_ROOT/lib/status-reasons.json" >/dev/null
}
