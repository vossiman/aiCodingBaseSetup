#!/usr/bin/env bats

setup() {
  : "${BLUEPRINT_ROOT:?run via tests/bats/run.sh}"
  export TEST_ROOT=$(mktemp -d)
  export HOME="$TEST_ROOT/home"
  export AICODING_STATE_DIR="$TEST_ROOT/state"
  export AICODING_DATA_DIR="$TEST_ROOT/data"
  export AICODING_AUTO_UPDATE_INTERVAL=1
  export AICODING_AUTO_UPDATE_MIN_BACKOFF=1
  export AICODING_AUTO_UPDATE_MAX_BACKOFF=2
  export PATH="$TEST_ROOT/bin:$PATH"
  mkdir -p "$HOME/.local/bin" "$TEST_ROOT/bin" "$AICODING_STATE_DIR"
  mkdir -p "$TEST_ROOT/runtime/bin" "$TEST_ROOT/runtime/lib" "$TEST_ROOT/runtime/configs/systemd"
  cp "$BLUEPRINT_ROOT/bin/aicoding-auto-update" "$TEST_ROOT/runtime/bin/"
  cp "$BLUEPRINT_ROOT/lib/auto-update.sh" "$TEST_ROOT/runtime/lib/"
  cp "$BLUEPRINT_ROOT/configs/systemd/"* "$TEST_ROOT/runtime/configs/systemd/"
  chmod +x "$TEST_ROOT/runtime/bin/aicoding-auto-update"
  ln -s "$TEST_ROOT/runtime/bin/aicoding-auto-update" "$TEST_ROOT/aicoding-auto-update"
  cat > "$TEST_ROOT/bin/aicoding-sync" <<'EOF'
#!/usr/bin/env bash
read -r unexpected && exit 91
mkdir -p "$AICODING_STATE_DIR"
if [ "${AICODING_TEST_BUSY:-0}" = 1 ]; then
  sleep 0.2
  echo 'aicoding-sync: update already running' >&2
  exit 0
fi
exec {sync_fd}>"$AICODING_STATE_DIR/sync.lock"
flock -n "$sync_fd" || exit 0
printf '%s %s\n' "$PWD" "$*" >> "$AICODING_TEST_ATTEMPTS"
if [ "${AICODING_TEST_DEFERRED:-0}" = 1 ]; then
  echo 'aicoding-sync: completed with deferrals' >&2
  exit 0
fi
count=$(wc -l < "$AICODING_TEST_ATTEMPTS")
if [ "$count" -le "${AICODING_TEST_FAILS:-0}" ]; then exit 1; fi
EOF
  chmod +x "$TEST_ROOT/bin/aicoding-sync"
  export AICODING_TEST_ATTEMPTS="$TEST_ROOT/attempts"
  : > "$AICODING_TEST_ATTEMPTS"
}

teardown() {
  if [ -f "$AICODING_STATE_DIR/auto-update/worker.pid" ]; then
    kill "$(cat "$AICODING_STATE_DIR/auto-update/worker.pid")" 2>/dev/null || true
  fi
  rm -rf "$TEST_ROOT"
}

wait_for_lines() {
  local wanted=$1 i
  for ((i=0; i<60; i++)); do
    [ "$(wc -l < "$AICODING_TEST_ATTEMPTS")" -ge "$wanted" ] && return 0
    sleep 0.1
  done
  return 1
}

false_systemd_shim() {
  cat > "$TEST_ROOT/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo 'System has not been booted with systemd as init system.'
exit 0
EOF
  cat > "$TEST_ROOT/bin/loginctl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$TEST_ROOT/bin/systemctl" "$TEST_ROOT/bin/loginctl"
}

@test "once runs one closed-stdin unattended sync from the state directory" {
  run "$TEST_ROOT/aicoding-auto-update" --once </dev/null
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$AICODING_TEST_ATTEMPTS")" -eq 1 ]
  [ "$(cat "$AICODING_TEST_ATTEMPTS")" = "$AICODING_STATE_DIR/auto-update --boot" ]
}

@test "a success-exit systemctl shim falls back to one persistent worker" {
  false_systemd_shim
  "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  wait_for_lines 1
  local first_pid
  first_pid=$(cat "$AICODING_STATE_DIR/auto-update/worker.pid")
  kill -0 "$first_pid"

  "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  sleep 0.2
  [ "$(cat "$AICODING_STATE_DIR/auto-update/worker.pid")" = "$first_pid" ]
}

@test "two simultaneous ensure calls still leave one fallback worker" {
  false_systemd_shim
  "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null & local one=$!
  "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null & local two=$!
  wait "$one"; wait "$two"
  wait_for_lines 1
  local pid
  pid=$(cat "$AICODING_STATE_DIR/auto-update/worker.pid")
  kill -0 "$pid"
  "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  sleep 0.2
  [ "$(cat "$AICODING_STATE_DIR/auto-update/worker.pid")" = "$pid" ]
}

@test "fallback worker retries an offline failure then recovers without another shell" {
  false_systemd_shim
  export AICODING_TEST_FAILS=1
  "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  wait_for_lines 2
  [ "$(wc -l < "$AICODING_TEST_ATTEMPTS")" -ge 2 ]
  for _ in $(seq 40); do [ -s "$AICODING_STATE_DIR/auto-update/last-success" ] && break; sleep 0.05; done
  [ -s "$AICODING_STATE_DIR/auto-update/last-success" ]
}

@test "fallback worker schedules the normal interval for a completed pass with deferrals without stamping success" {
  false_systemd_shim
  export AICODING_TEST_DEFERRED=1 AICODING_AUTO_UPDATE_INTERVAL=30
  "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  wait_for_lines 1
  for _ in $(seq 40); do [ -s "$AICODING_STATE_DIR/auto-update/next-due" ] && break; sleep 0.05; done
  [ ! -e "$AICODING_STATE_DIR/auto-update/last-success" ]
  [ "$(cat "$AICODING_STATE_DIR/auto-update/next-due")" -gt "$(date +%s)" ]
  sleep 0.3
  [ "$(wc -l < "$AICODING_TEST_ATTEMPTS")" -eq 1 ]
}

@test "long-running fallback worker rotates and reopens its log between passes" {
  false_systemd_shim
  "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  wait_for_lines 1
  local log="$AICODING_STATE_DIR/auto-update/worker.log"
  dd if=/dev/zero bs=1048577 count=1 2>/dev/null >> "$log"
  wait_for_lines 2
  for _ in $(seq 40); do
    [ -f "$log.previous" ] && [ "$(wc -c < "$log")" -le 1048576 ] && break
    sleep 0.05
  done
  [ -f "$log.previous" ]
  [ "$(wc -c < "$log.previous")" -gt 1048576 ]
  [ "$(wc -c < "$log")" -le 1048576 ]
}

@test "worker restart catches up when persisted next-due is in the past" {
  false_systemd_shim
  mkdir -p "$AICODING_STATE_DIR/auto-update"
  printf '1\n' > "$AICODING_STATE_DIR/auto-update/next-due"
  "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  wait_for_lines 1
  [ -s "$AICODING_STATE_DIR/auto-update/last-attempt" ]
}

@test "monotonic timer keeps startup catch-up without an ineffective Persistent directive" {
  local timer="$TEST_ROOT/runtime/configs/systemd/aicoding-auto-update.timer"
  grep -q '^OnBootSec=' "$timer"
  grep -q '^OnUnitActiveSec=' "$timer"
  if grep -q '^Persistent=' "$timer"; then false; fi
}

@test "a verified user manager with linger installs and enables the persistent timer" {
  cat > "$TEST_ROOT/bin/systemctl" <<EOF
#!/usr/bin/env bash
case "\$*" in
  '--user is-system-running') echo running ;;
  '--user show --property=Version --value') echo 257 ;;
  '--user is-enabled aicoding-auto-update.timer') echo enabled ;;
  '--user is-active aicoding-auto-update.timer') echo active ;;
esac
exit 0
EOF
  cat > "$TEST_ROOT/bin/loginctl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *'show-user'* ]]; then echo yes; fi
exit 0
EOF
  chmod +x "$TEST_ROOT/bin/systemctl" "$TEST_ROOT/bin/loginctl"

  run "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  [ "$status" -eq 0 ]
  for _ in $(seq 40); do [ -f "$HOME/.config/systemd/user/aicoding-auto-update.timer" ] && break; sleep 0.05; done
  [ -f "$HOME/.config/systemd/user/aicoding-auto-update.service" ]
  [ -f "$HOME/.config/systemd/user/aicoding-auto-update.timer" ] || { cat "$AICODING_STATE_DIR/auto-update/enroll.log"; false; }
  [ ! -s "$AICODING_TEST_ATTEMPTS" ]
}

@test "ensure returns before a stalled manager probe finishes" {
  cat > "$TEST_ROOT/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
sleep 5
exit 1
EOF
  chmod +x "$TEST_ROOT/bin/systemctl"
  run timeout 1 "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  [ "$status" -eq 0 ]
}

@test "detached enrollment closes an inherited whole-run lock before its worker syncs" {
  false_systemd_shim
  mkdir -p "$AICODING_STATE_DIR"
  exec {held_fd}>"$AICODING_STATE_DIR/sync.lock"
  flock "$held_fd"
  export AICODING_SYNC_LOCK_FD=$held_fd AICODING_SYNC_LOCK_PID=$$
  "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  exec {held_fd}>&-
  unset AICODING_SYNC_LOCK_FD AICODING_SYNC_LOCK_PID
  wait_for_lines 1
}

@test "healthy user manager transition stops fallback worker before enabling timer" {
  false_systemd_shim
  export AICODING_AUTO_UPDATE_INTERVAL=3600
  "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  wait_for_lines 1
  local worker
  worker=$(cat "$AICODING_STATE_DIR/auto-update/worker.pid")
  kill -0 "$worker"

  cat > "$TEST_ROOT/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/systemctl.calls"
case "$*" in
  '--user is-system-running') echo running ;;
  '--user show --property=Version --value') echo 257 ;;
  '--user is-enabled aicoding-auto-update.timer') echo enabled ;;
  '--user is-active aicoding-auto-update.timer') echo active ;;
esac
exit 0
EOF
  cat > "$TEST_ROOT/bin/loginctl" <<'EOF'
#!/usr/bin/env bash
echo yes
EOF
  chmod +x "$TEST_ROOT/bin/systemctl" "$TEST_ROOT/bin/loginctl"
  "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  for _ in $(seq 60); do
    [ -f "$HOME/.config/systemd/user/aicoding-auto-update.timer" ] \
      && [ ! -e "$AICODING_STATE_DIR/auto-update/worker.pid" ] && break
    sleep 0.05
  done
  [ -f "$HOME/.config/systemd/user/aicoding-auto-update.timer" ] || { cat "$AICODING_STATE_DIR/auto-update/enroll.log"; cat "$TEST_ROOT/systemctl.calls"; find "$HOME/.config" -type f -print 2>/dev/null; false; }
  [ ! -e "$AICODING_STATE_DIR/auto-update/worker.pid" ]
  if kill -0 "$worker" 2>/dev/null; then false; fi
}

@test "healthy user manager transition removes a proven stale worker pid" {
  mkdir -p "$AICODING_STATE_DIR/auto-update"
  printf '999999999\n' > "$AICODING_STATE_DIR/auto-update/worker.pid"
  cat > "$TEST_ROOT/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  '--user is-system-running') echo running ;;
  '--user show --property=Version --value') echo 257 ;;
  '--user is-enabled aicoding-auto-update.timer') echo enabled ;;
  '--user is-active aicoding-auto-update.timer') echo active ;;
esac
exit 0
EOF
  cat > "$TEST_ROOT/bin/loginctl" <<'EOF'
#!/usr/bin/env bash
echo yes
EOF
  chmod +x "$TEST_ROOT/bin/systemctl" "$TEST_ROOT/bin/loginctl"

  "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  for _ in $(seq 40); do
    [ -f "$HOME/.config/systemd/user/aicoding-auto-update.timer" ] \
      && [ ! -e "$AICODING_STATE_DIR/auto-update/worker.pid" ] && break
    sleep 0.05
  done
  [ -f "$HOME/.config/systemd/user/aicoding-auto-update.timer" ]
  [ ! -e "$AICODING_STATE_DIR/auto-update/worker.pid" ]
}

@test "worker cleanup never signals an unrelated live process named by a stale pid file" {
  sleep 30 & local unrelated=$!
  mkdir -p "$AICODING_STATE_DIR/auto-update"
  printf '%s\n' "$unrelated" > "$AICODING_STATE_DIR/auto-update/worker.pid"

  run bash -c '. "$1/lib/auto-update.sh"; _aicoding_auto_stop_worker' _ "$TEST_ROOT/runtime"
  [ "$status" -eq 0 ]
  kill -0 "$unrelated"
  [ ! -e "$AICODING_STATE_DIR/auto-update/worker.pid" ]
  kill "$unrelated"
  wait "$unrelated" 2>/dev/null || true
}

@test "a delayed busy result is not recorded as a successful update" {
  false_systemd_shim
  export AICODING_TEST_BUSY=1
  "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  for _ in $(seq 60); do
    [ -s "$AICODING_STATE_DIR/auto-update/last-attempt" ] && break
    sleep 0.05
  done
  sleep 0.3
  [ -s "$AICODING_STATE_DIR/auto-update/last-attempt" ]
  [ ! -e "$AICODING_STATE_DIR/auto-update/last-success" ]
}

@test "fallback is deferred when a partially enabled timer cannot be disabled" {
  cat > "$TEST_ROOT/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/systemctl.calls"
case "$*" in
  '--user is-system-running') echo running ;;
  '--user show --property=Version --value') echo 257 ;;
  '--user enable --now aicoding-auto-update.timer') exit 1 ;;
  '--user disable --now aicoding-auto-update.timer') exit 1 ;;
  '--user is-enabled aicoding-auto-update.timer') echo enabled ;;
  '--user is-active aicoding-auto-update.timer') echo active ;;
esac
EOF
  cat > "$TEST_ROOT/bin/loginctl" <<'EOF'
#!/usr/bin/env bash
echo yes
EOF
  chmod +x "$TEST_ROOT/bin/systemctl" "$TEST_ROOT/bin/loginctl"

  "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  for _ in $(seq 60); do
    grep -q 'disable --now' "$TEST_ROOT/systemctl.calls" 2>/dev/null && break
    sleep 0.05
  done
  grep -q 'disable --now' "$TEST_ROOT/systemctl.calls"
  [ ! -e "$AICODING_STATE_DIR/auto-update/worker.pid" ]
  [ ! -s "$AICODING_TEST_ATTEMPTS" ]
  for _ in $(seq 40); do
    grep -q 'fallback deferred' "$AICODING_STATE_DIR/auto-update/enroll.log" 2>/dev/null && break
    sleep 0.05
  done
  grep -q 'fallback deferred' "$AICODING_STATE_DIR/auto-update/enroll.log"
}

@test "fallback is deferred when an enabled timer survives an unavailable manager" {
  false_systemd_shim
  mkdir -p "$HOME/.config/systemd/user/timers.target.wants"
  ln -s ../../aicoding-auto-update.timer \
    "$HOME/.config/systemd/user/timers.target.wants/aicoding-auto-update.timer"

  "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  for _ in $(seq 40); do
    grep -q 'enabled timer state cannot be verified' \
      "$AICODING_STATE_DIR/auto-update/enroll.log" 2>/dev/null && break
    sleep 0.05
  done
  [ ! -e "$AICODING_STATE_DIR/auto-update/worker.pid" ]
  [ ! -s "$AICODING_TEST_ATTEMPTS" ]
  grep -q 'enabled timer state cannot be verified' "$AICODING_STATE_DIR/auto-update/enroll.log"
}
