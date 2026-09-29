#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load t3-helpers

setup() { t3_test_setup; t3_make_db; }
teardown() { t3_test_teardown; }

db() { bash -c '. "$BLUEPRINT_ROOT/lib/t3.sh"; t3_env 2>/dev/null; t3_idle_db "$1"; r=$?; [ "$r" -eq 1 ] && echo "$T3_BUSY"; exit "$r"' _ "$1"; }
procs() { bash -c '. "$BLUEPRINT_ROOT/lib/t3.sh"; t3_env 2>/dev/null; t3_idle_procs; r=$?; [ "$r" -eq 1 ] && echo "$T3_BUSY"; exit "$r"'; }
full() { bash -c '. "$BLUEPRINT_ROOT/lib/t3.sh"; t3_env 2>/dev/null; t3_idle_full; r=$?; [ "$r" -eq 1 ] && echo "$T3_BUSY"; exit "$r"'; }
old() { t3_iso '-2 hours'; }

@test "db: an empty database is idle" {
  run db 12
  [ "$status" -eq 0 ]
}

@test "db: each busy session status and an active turn block" {
  for st in starting running; do
    t3_sql "DELETE FROM projection_thread_sessions; INSERT INTO projection_thread_sessions VALUES('t','$st',NULL,NULL,NULL,NULL,NULL,'$(old)');"
    run db 1
    [ "$status" -eq 1 ]
  done
  t3_sql "DELETE FROM projection_thread_sessions; INSERT INTO projection_thread_sessions VALUES('t','ready',NULL,NULL,NULL,'turn-1',NULL,'$(old)');"
  run db 1
  [ "$status" -eq 1 ]
  [[ "$output" == *active_turn* ]]
}

@test "db: an unknown session status blocks, the five settled ones do not" {
  for st in idle ready interrupted stopped error; do
    t3_sql "DELETE FROM projection_thread_sessions; INSERT INTO projection_thread_sessions VALUES('t','$st',NULL,NULL,NULL,NULL,NULL,'$(old)');"
    run db 1
    [ "$status" -eq 0 ]
  done
  t3_sql "DELETE FROM projection_thread_sessions; INSERT INTO projection_thread_sessions VALUES('t','paused',NULL,NULL,NULL,NULL,NULL,'$(old)');"
  run db 1
  [ "$status" -eq 1 ]
  [[ "$output" == *session_unknown* ]]
}

@test "db: pending, running and unknown turn states block" {
  for st in pending running mystery; do
    t3_sql "DELETE FROM projection_turns; INSERT INTO projection_turns(thread_id,turn_id,state,requested_at,checkpoint_files_json) VALUES('t','x','$st','$(old)','[]');"
    run db 1
    [ "$status" -eq 1 ]
  done
  t3_sql "DELETE FROM projection_turns; INSERT INTO projection_turns(thread_id,turn_id,state,requested_at,checkpoint_files_json) VALUES('t','x','completed','$(old)','[]');"
  run db 1
  [ "$status" -eq 0 ]
}

@test "db: a pending approval blocks, a resolved one does not, an unknown status blocks" {
  t3_sql "INSERT INTO projection_pending_approvals VALUES('r1','t',NULL,'resolved','accept','$(old)','$(old)');"
  run db 1
  [ "$status" -eq 0 ]
  t3_sql "INSERT INTO projection_pending_approvals VALUES('r2','t',NULL,'pending',NULL,'$(old)',NULL);"
  run db 1
  [ "$status" -eq 1 ]
  [[ "$output" == *approval_pending* ]]
  t3_sql "DELETE FROM projection_pending_approvals; INSERT INTO projection_pending_approvals VALUES('r3','t',NULL,'weird',NULL,'$(old)',NULL);"
  run db 1
  [ "$status" -eq 1 ]
}

@test "db: activity 59 minutes ago in each listed column blocks; 61 minutes does not" {
  recent=$(t3_iso '-59 minutes'); quiet=$(t3_iso '-61 minutes')
  for ts in "$recent" "$quiet"; do
    t3_sql "DELETE FROM projection_thread_messages; INSERT INTO projection_thread_messages VALUES('m','t',NULL,'user','hi',0,'$ts','$ts');"
    run db 12
    if [ "$ts" = "$recent" ]; then [ "$status" -eq 1 ]; [[ "$output" == *recent_activity* ]]; else [ "$status" -eq 0 ]; fi
  done
  t3_sql "DELETE FROM projection_thread_messages;"
  t3_sql "INSERT INTO projection_thread_activities VALUES('a','t',NULL,'info','tool','s','{}','$recent');"
  run db 12; [ "$status" -eq 1 ]
  t3_sql "DELETE FROM projection_thread_activities; INSERT INTO projection_turns(thread_id,turn_id,state,requested_at,started_at,completed_at,checkpoint_files_json) VALUES('t','x','completed','$quiet','$quiet','$recent','[]');"
  run db 12; [ "$status" -eq 1 ]
  t3_sql "DELETE FROM projection_turns; INSERT INTO projection_pending_approvals VALUES('r','t',NULL,'resolved','accept','$quiet','$recent');"
  run db 12; [ "$status" -eq 1 ]
  t3_sql "DELETE FROM projection_pending_approvals; INSERT INTO projection_thread_sessions VALUES('t','ready',NULL,NULL,NULL,NULL,NULL,'$recent');"
  run db 12; [ "$status" -eq 1 ]
}

@test "db: one bad or future timestamp among many valid ones blocks" {
  for i in $(seq 1 50); do t3_sql "INSERT INTO projection_thread_messages VALUES('m$i','t',NULL,'user','x',0,'$(old)','$(old)');"; done
  t3_sql "INSERT INTO projection_thread_messages VALUES('bad','t',NULL,'user','x',0,'not-a-date','$(old)');"
  run db 12
  [ "$status" -eq 1 ]
  [[ "$output" == *bad_timestamp* ]]
  t3_sql "DELETE FROM projection_thread_messages WHERE message_id='bad'; INSERT INTO projection_thread_messages VALUES('fut','t',NULL,'user','x',0,'$(t3_iso '+10 minutes')','$(old)');"
  run db 12
  [ "$status" -eq 1 ]
  [[ "$output" == *future_timestamp* ]]
}

@test "db: a missing table, a missing column and an unreadable database block" {
  t3_sql "DROP TABLE projection_turns;"
  run db 1
  [ "$status" -eq 1 ]
  [[ "$output" == *db_error* ]]
  rm -f "$(t3_db)"; t3_make_db
  t3_sql "ALTER TABLE projection_thread_sessions RENAME COLUMN active_turn_id TO renamed;"
  run db 1
  [ "$status" -eq 1 ]
  rm -f "$(t3_db)"
  run db 1
  [ "$status" -eq 1 ]
}

@test "procs: server, cloudflared and an idle provider are allowed" {
  t3_bin_as claude sleep
  t3_fake_setup
  T3_TEST_CHILDREN=claude "$B/t3-start"
  run procs
  [ "$status" -eq 0 ]
}

@test "procs: a provider chain (launcher with native child) is allowed; a tool under it is not" {
  t3_bin_as claude bash; t3_bin_as codex sleep; t3_bin_as make sleep
  t3_fake_setup
  T3_TEST_CHILDREN="claude=$TMP/bin/codex 3600" "$B/t3-start"
  run procs
  [ "$status" -eq 0 ]
  "$B/t3-stop"
  T3_TEST_CHILDREN="claude=$TMP/bin/make 3600" "$B/t3-start"
  run procs
  [ "$status" -eq 1 ]
  [[ "$output" == *process_make* ]]
}

@test "procs: a non-allowed process in scope blocks" {
  t3_bin_as make sleep
  t3_fake_setup
  T3_TEST_CHILDREN=make "$B/t3-start"
  run procs
  [ "$status" -eq 1 ]
  [[ "$output" == *process_make* ]]
}

@test "procs: a reparented process carrying the owner token blocks" {
  t3_fake_setup
  "$B/t3-start"
  tok=$(t3_owner token)
  t3_bin_as stray sleep
  env T3_AICODING_OWNER="$tok" setsid "$TMP/bin/stray" 60 &
  stray=$!
  sleep 0.3
  run procs
  kill "$stray" 2>/dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"busy:process_stray"* ]]
}

@test "procs: a terminal shell is allowed only when its tty is an hour quiet" {
  t3_bin_as bash bash
  t3_fake_setup
  T3_TEST_PTY_SHELL=1 "$B/t3-start"
  sleep 1
  srv=$(jq -r .pid "$T3_ENVS_ROOT/demo/userdata/server-runtime.json")
  sh=$(pgrep -P "$srv" -x bash | head -1)
  [ -n "$sh" ]
  tty=$(readlink "/proc/$sh/fd/0")
  touch -d '-2 hours' "$tty" 2>/dev/null || skip "cannot set times on $tty here"
  run procs
  [ "$status" -eq 0 ]
  touch -d '-59 minutes' "$tty"
  run procs
  [ "$status" -eq 1 ]
}

@test "window: CPU use in scope blocks; a quiet scope passes the whole sequence" {
  t3_bin_as claude bash
  t3_fake_setup
  "$B/t3-start"
  run full
  [ "$status" -eq 0 ]
  "$B/t3-stop"
  T3_TEST_CHILDREN='claude=while :; do :; done' "$B/t3-start"
  run full
  [ "$status" -eq 1 ]
  [[ "$output" == *cpu* ]]
}

@test "window: a process that lives across a sample inside the window blocks" {
  t3_bin_as make sleep
  t3_fake_setup
  "$B/t3-start"
  srv=$(jq -r .pid "$T3_ENVS_ROOT/demo/userdata/server-runtime.json")
  ( sleep 0.5; tok=$(t3_owner token); env T3_AICODING_OWNER="$tok" "$TMP/bin/make" 1.5 ) &
  run full
  wait
  [ "$status" -eq 1 ]
  [[ "$output" == *process_make* ]]
}

@test "workloads: lists every finding, not just the first" {
  t3_bin_as make sleep; t3_bin_as gcc sleep
  t3_fake_setup
  T3_TEST_CHILDREN="make|gcc" "$B/t3-start"
  t3_sql "INSERT INTO projection_thread_sessions VALUES('t','running',NULL,NULL,NULL,'x',NULL,'$(old)');"
  run bash -c '. "$BLUEPRINT_ROOT/lib/t3.sh"; t3_env 2>/dev/null; t3_workloads; printf "%s\n" "${T3_BUSY_LIST[@]}"'
  [[ "$output" == *process_make* ]]
  [[ "$output" == *process_gcc* ]]
  [[ "$output" == *session* ]]
}
