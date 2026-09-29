#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load t3-helpers

setup() { t3_test_setup; }
teardown() { t3_test_teardown; }

S() { printf '%s\n' "$T3_ENVS_ROOT/demo/aicoding"; }

@test "start: refuses when not set up" {
  run "$B/t3-start"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not set up"* ]]
}

@test "start: runs the selected version under a supervisor, ready, enabled" {
  t3_fake_setup 0.0.42
  run "$B/t3-start"
  [ "$status" -eq 0 ]
  [ -f "$(S)/enabled" ]
  sup=$(t3_owner pid)
  kill -0 "$sup"
  srv=$(jq -r .pid "$T3_ENVS_ROOT/demo/userdata/server-runtime.json")
  [ "$(awk '{print $4}' "/proc/$srv/stat")" = "$sup" ]
  [ "$(t3_owner version)" = 0.0.42 ]
  # the fake logs "t3<version> <args>"
  grep -q "0.0.42 serve $TMP/work" "$T3_STUB_LOG"
}

@test "start: --dir is remembered" {
  t3_fake_setup
  mkdir -p "$TMP/elsewhere"
  run "$B/t3-start" --dir "$TMP/elsewhere"
  [ "$status" -eq 0 ]
  [ "$(cat "$(S)/serve-dir")" = "$TMP/elsewhere" ]
  grep -q "serve $TMP/elsewhere" "$T3_STUB_LOG"
}

@test "start: a second start reports the running server and starts nothing" {
  t3_fake_setup
  "$B/t3-start"
  first=$(t3_owner pid)
  run "$B/t3-start"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already running"* ]]
  [ "$(t3_owner pid)" = "$first" ]
  [ "$(grep -c ' serve ' "$T3_STUB_LOG")" -eq 1 ]
}

@test "start: two simultaneous starts give exactly one server" {
  t3_fake_setup
  "$B/t3-start" & a=$!
  "$B/t3-start" & b=$!
  wait "$a" || true; wait "$b" || true
  [ "$(grep -c ' serve ' "$T3_STUB_LOG")" -eq 1 ]
}

@test "start: a second start from another mount namespace fails on the owner lock" {
  command -v unshare >/dev/null && unshare -rm true 2>/dev/null || skip "unprivileged user namespaces unavailable"
  t3_fake_setup
  "$B/t3-start"
  run unshare -rm bash -c 'exec 9>>"$0/owner.lock"; flock -n 9' "$(S)"
  [ "$status" -ne 0 ]
}

@test "start: no control or owner lock descriptor leaks into the server" {
  t3_fake_setup
  "$B/t3-start"
  run t3_lib t3_entry
  [ "$status" -eq 0 ]
  srv=$(jq -r .pid "$T3_ENVS_ROOT/demo/userdata/server-runtime.json")
  if ls -l "/proc/$srv/fd" | grep -qE 'control\.lock|owner\.lock'; then false; fi
}

@test "start: a version that never becomes ready leaves nothing running and enabled unchanged" {
  t3_fake_setup
  export T3_TEST_SERVE_FAIL=0.0.42
  run "$B/t3-start"
  [ "$status" -eq 1 ]
  [ ! -f "$(S)/enabled" ]
  run bash -c '. "$BLUEPRINT_ROOT/lib/t3.sh"; t3_env 2>/dev/null; t3_running'
  [ "$status" -eq 1 ]
}

@test "start: a red connect status is not ready" {
  t3_fake_setup
  export T3_TEST_CONNECT_RED=1
  run "$B/t3-start"
  [ "$status" -eq 1 ]
}

@test "start: a missing tunnel is not ready" {
  t3_fake_setup
  export T3_TEST_NO_TUNNEL=1
  run "$B/t3-start"
  [ "$status" -eq 1 ]
}

@test "start: reinstalls a wiped runtime" {
  t3_fake_setup
  rm -rf "$T3_RUNTIME_ROOT"
  run "$B/t3-start"
  [ "$status" -eq 0 ]
  [ -x "$T3_RUNTIME_ROOT/0.0.42/node_modules/.bin/t3" ]
}

@test "stop: stops the whole scope and clears enabled" {
  t3_fake_setup
  "$B/t3-start"
  sid=$(t3_owner sid)
  run "$B/t3-stop"
  [ "$status" -eq 0 ]
  [ ! -f "$(S)/enabled" ]
  if pgrep -s "$sid" >/dev/null; then false; fi
}

@test "stop: refuses to signal a supervisor whose identity does not match" {
  t3_fake_setup
  "$B/t3-start"
  jq '.start = "1"' "$(S)/owner.json" > "$TMP/o" && mv "$TMP/o" "$(S)/owner.json"
  run "$B/t3-stop"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not match"* ]]
  [ -f "$(S)/enabled" ]
}

@test "orphans: killing only the supervisor frees the owner lock and the server is a token orphan" {
  t3_fake_setup
  "$B/t3-start"
  kill -KILL "$(t3_owner pid)"
  sleep 0.5
  run bash -c '. "$BLUEPRINT_ROOT/lib/t3.sh"; t3_env 2>/dev/null; t3_running'
  [ "$status" -eq 1 ]
  run "$B/t3-start"
  [ "$status" -eq 1 ]
  [[ "$output" == *"left processes behind"* ]]
  run "$B/t3-stop" --orphans
  [ "$status" -eq 0 ]
  run "$B/t3-start"
  [ "$status" -eq 0 ]
}

@test "orphans: a session-only match is listed but never signalled" {
  t3_fake_setup
  "$B/t3-start"
  sid=$(t3_owner sid)
  kill -KILL "$(t3_owner pid)"; sleep 0.3
  pkill -KILL -s "$sid"; sleep 0.3
  # a process in the recorded session without the token
  setsid bash -c 'sleep 60' & decoy=$!
  sleep 0.3
  dsid=$(awk '{print $6}' "/proc/$decoy/stat")
  jq --arg s "$dsid" '.sid = $s' "$(S)/owner.json" > "$TMP/o" && mv "$TMP/o" "$(S)/owner.json"
  run "$B/t3-stop" --orphans
  kill -0 "$decoy"
  [[ "$output" == *"not signalled"* ]]
  kill "$decoy"
}

@test "boot: silent no-op when not enabled; starts when enabled; retries while the lock is held" {
  t3_fake_setup
  run "$B/t3-start" --boot
  [ "$status" -eq 0 ]
  [ ! -f "$(S)/owner.json" ]
  : > "$(S)/enabled"
  bash -c '. "$BLUEPRINT_ROOT/lib/t3.sh"; t3_entry 2>/dev/null; sleep 3' &
  sleep 0.5
  run "$B/t3-start" --boot
  wait
  [ "$status" -eq 0 ]
  run bash -c '. "$BLUEPRINT_ROOT/lib/t3.sh"; t3_env 2>/dev/null; t3_running'
  [ "$status" -eq 0 ]
}

@test "stop from inside the scope detaches and still completes" {
  t3_fake_setup
  "$B/t3-start"
  srv=$(jq -r .pid "$T3_ENVS_ROOT/demo/userdata/server-runtime.json")
  # run t3-stop as a child of the server's session by joining its environment token
  tok=$(t3_owner token)
  run env T3_AICODING_OWNER="$tok" "$B/t3-stop"
  [ "$status" -eq 0 ]
  [[ "$output" == *"continuing in the background"* ]]
  for i in $(seq 1 60); do [ -f "$(S)/enabled" ] || break; sleep 0.2; done
  [ ! -f "$(S)/enabled" ]
}
