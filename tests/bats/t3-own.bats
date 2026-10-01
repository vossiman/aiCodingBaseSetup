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

@test "stop run by a real descendant of the server detaches and still completes" {
  t3_fake_setup
  t3_bin_as agentsh bash
  T3_TEST_CHILDREN="agentsh=until mv $TMP/go $TMP/go.taken 2>/dev/null; do sleep 0.1; done; $B/t3-stop > $TMP/child.out 2>&1" "$B/t3-start"
  : > "$TMP/go"
  # enabled is removed before t3_record and the final completion message.
  # Wait for the completed detached worker, not its earlier flag removal.
  for i in $(seq 1 100); do
    if grep -q "stopped; it will not start at boot" "$(S)/detached.log" 2>/dev/null; then break; fi
    sleep 0.2
  done
  [ ! -f "$(S)/enabled" ]
  grep -q "continuing in the background" "$TMP/child.out"
  grep -q "stopped; it will not start at boot" "$(S)/detached.log"
  run bash -c '. "$BLUEPRINT_ROOT/lib/t3.sh"; t3_env 2>/dev/null; t3_running'
  [ "$status" -ne 0 ]
}

@test "setup: logs in, links, publishes, then records the newest version and setup-done last" {
  run "$B/t3-setup"
  [ "$status" -eq 0 ]
  [ "$(jq -r .version "$(S)/version.json")" = 0.0.50 ]
  [ "$(jq -r .mode "$(S)/version.json")" = latest ]
  [ -f "$(S)/auto" ]
  [ "$(cat "$(S)/setup-done")" = env-test-1 ]
  grep -q 'connect login --headless' "$T3_STUB_LOG"
  grep -q 'connect link' "$T3_STUB_LOG"
  grep -q 'connect publish' "$T3_STUB_LOG"
}

@test "setup: a red connect status writes neither version.json nor setup-done" {
  export T3_TEST_CONNECT_RED=1
  run "$B/t3-setup"
  [ "$status" -eq 1 ]
  [ ! -f "$(S)/setup-done" ]
  [ ! -f "$(S)/version.json" ]
}

@test "setup: refuses while a server runs" {
  t3_fake_setup
  "$B/t3-start"
  run "$B/t3-setup"
  [ "$status" -eq 1 ]
  [[ "$output" == *"t3-stop first"* ]]
}

@test "adopt: uses the named version, never npm's newest" {
  mkdir -p "$T3_ENVS_ROOT/demo/userdata/secrets"
  echo env-legacy > "$T3_ENVS_ROOT/demo/userdata/environment-id"
  : > "$T3_ENVS_ROOT/demo/userdata/secrets/cloud-cli-oauth-token.bin"
  run "$B/t3-adopt" --version 0.0.40
  [ "$status" -eq 0 ]
  [ "$(jq -r .version "$(S)/version.json")" = 0.0.40 ]
  [ "$(cat "$(S)/setup-done")" = env-legacy ]
  if grep -q '^npm view' "$T3_STUB_LOG"; then false; fi
}

@test "adopt: falls back to the export manifest, refuses without either" {
  mkdir -p "$T3_ENVS_ROOT/demo/userdata/secrets" "$T3_MIGRATE_DIR"
  echo env-legacy > "$T3_ENVS_ROOT/demo/userdata/environment-id"
  : > "$T3_ENVS_ROOT/demo/userdata/secrets/cloud-cli-oauth-token.bin"
  run "$B/t3-adopt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--version"* ]]
  echo '{"version":"0.0.39"}' > "$T3_MIGRATE_DIR/demo.json"
  run "$B/t3-adopt"
  [ "$status" -eq 0 ]
  [ "$(jq -r .version "$(S)/version.json")" = 0.0.39 ]
}

@test "adopt: refuses missing identity or login" {
  run "$B/t3-adopt" --version 0.0.40
  [ "$status" -eq 1 ]
  [[ "$output" == *"environment-id"* ]]
  mkdir -p "$T3_ENVS_ROOT/demo/userdata"
  echo env-legacy > "$T3_ENVS_ROOT/demo/userdata/environment-id"
  run "$B/t3-adopt" --version 0.0.40
  [ "$status" -eq 1 ]
  [[ "$output" == *"stored login"* ]]
  [ ! -f "$(S)/setup-done" ]
}

@test "start: a lock descriptor held by the caller never survives into the server" {
  t3_fake_setup
  # the same form bin/aicoding-sync uses for sync.lock
  ( exec {lk}>"$TMP/caller.lock"; flock -n "$lk" || exit 9; "$B/t3-start" ) >/dev/null 2>&1
  [ "$?" -eq 0 ]
  run flock -n "$TMP/caller.lock" true
  [ "$status" -eq 0 ]
}

@test "start: an owner.json from a previous container life never blocks start" {
  t3_fake_setup
  t3_bin_as stale sleep
  setsid "$TMP/bin/stale" 60 &
  stale=$!
  sleep 0.3
  printf '{"pid":%s,"start":"1","sid":"%s","token":"old","init":"0"}\n' "$stale" "$stale" > "$(S)/owner.json"
  run "$B/t3-start"
  kill "$stale" 2>/dev/null
  [ "$status" -eq 0 ]
}

@test "setup and adopt keep an existing version choice" {
  t3_fake_setup 0.0.42
  printf '{"mode":"held","version":"0.0.42"}\n' > "$(S)/version.json"
  rm -f "$(S)/auto"
  run "$B/t3-setup"
  [ "$status" -eq 0 ]
  [ "$(jq -r .mode "$(S)/version.json")" = held ]
  [ ! -f "$(S)/auto" ]
  run "$B/t3-adopt" --version 0.0.40
  [ "$status" -eq 1 ]
  [ "$(jq -r .version "$(S)/version.json")" = 0.0.42 ]
}
