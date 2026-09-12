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
printf '%s\n' "${AICODING_UPDATE_TTL:-unset}" >> "$AICODING_TEST_TTLS"
if [ "${AICODING_TEST_DEFERRED:-0}" = 1 ]; then
  echo 'aicoding-sync: completed with deferrals' >&2
  exit 0
fi
count=$(wc -l < "$AICODING_TEST_ATTEMPTS")
if [ "$count" -le "${AICODING_TEST_FAILS:-0}" ]; then exit 1; fi
EOF
  chmod +x "$TEST_ROOT/bin/aicoding-sync"
  export AICODING_TEST_ATTEMPTS="$TEST_ROOT/attempts"
  export AICODING_TEST_TTLS="$TEST_ROOT/ttls"
  : > "$AICODING_TEST_ATTEMPTS"
  : > "$AICODING_TEST_TTLS"
}

teardown() {
  if [ -f "$AICODING_STATE_DIR/auto-update/worker.pid" ]; then
    kill "$(cat "$AICODING_STATE_DIR/auto-update/worker.pid")" 2>/dev/null || true
  fi
  rm -rf "$TEST_ROOT"
}

wait_for_lines() {
  local wanted=$1 attempts=${2:-60} i
  for ((i=0; i<attempts; i++)); do
    [ "$(wc -l < "$AICODING_TEST_ATTEMPTS")" -ge "$wanted" ] && return 0
    sleep 0.1
  done
  local log pid
  for log in "$AICODING_STATE_DIR/auto-update/enroll.log" "$AICODING_STATE_DIR/auto-update/worker.log"; do
    if [ -f "$log" ]; then printf '%s\n' "$log"; cat "$log"; fi
  done
  if [ -f "$AICODING_STATE_DIR/auto-update/worker.pid" ]; then
    pid=$(cat "$AICODING_STATE_DIR/auto-update/worker.pid")
    ps -p "$pid" -o pid,ppid,stat,comm || true
    ls -l "/proc/$pid/fd" 2>/dev/null || true
  fi
  return 1
}

wait_for_replacement() {
  local old_worker=$1 pid i
  for ((i=0; i<150; i++)); do
    pid=$(cat "$AICODING_STATE_DIR/auto-update/worker.pid" 2>/dev/null || true)
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && [ "$pid" != "$old_worker" ] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
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
  [ "$(cat "$AICODING_TEST_TTLS")" = 0 ]
}

@test "once streams progress before sync finishes and captures its final deferral" {
  cat > "$TEST_ROOT/bin/aicoding-sync" <<'EOF'
#!/usr/bin/env bash
echo 'progress stdout'
echo 'progress stderr' >&2
touch "$TEST_ROOT/ready"
for ((i=0; i<100; i++)); do
  [ -f "$TEST_ROOT/release" ] && break
  sleep 0.05
done
echo 'aicoding-sync: completed with deferrals' >&2
EOF
  bash -c '
    . "$BLUEPRINT_ROOT/lib/auto-update.sh"
    aicoding_auto_update_once
    printf "flags:%s:%s\n" "$AICODING_AUTO_UPDATE_PERFORMED" "$AICODING_AUTO_UPDATE_DEFERRED"
  ' > "$TEST_ROOT/observed" 2>&1 3>&- &
  local updater=$! i visible=0 rc=0
  for ((i=0; i<60; i++)); do
    if [ -f "$TEST_ROOT/ready" ] && grep -q 'progress stderr' "$TEST_ROOT/observed"; then
      visible=1
      break
    fi
    sleep 0.05
  done
  touch "$TEST_ROOT/release"
  wait "$updater" || rc=$?
  [ "$visible" -eq 1 ]
  [ "$rc" -eq 0 ]
  [ "$(grep -c '^progress stdout$' "$TEST_ROOT/observed")" -eq 1 ]
  grep -q '^flags:1:1$' "$TEST_ROOT/observed"
  [ -z "$(find "$AICODING_STATE_DIR/auto-update" -name '.once.*' -print)" ]
}

@test "once preserves sync failure while streaming output" {
  printf '#!/usr/bin/env bash\necho sync-failed >&2\nexit 37\n' > "$TEST_ROOT/bin/aicoding-sync"
  run "$TEST_ROOT/aicoding-auto-update" --once
  [ "$status" -eq 37 ]
  [[ "$output" == *sync-failed* ]]
  [ -z "$(find "$AICODING_STATE_DIR/auto-update" -name '.once.*' -print)" ]
}

@test "once reports capture failure instead of successful sync" {
  cat > "$TEST_ROOT/bin/tee" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
exit 23
EOF
  chmod +x "$TEST_ROOT/bin/tee"
  run "$TEST_ROOT/aicoding-auto-update" --once
  [ "$status" -eq 23 ]
  [ -z "$(find "$AICODING_STATE_DIR/auto-update" -name '.once.*' -print)" ]
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

@test "detached fallback worker does not retain the caller workspace cwd" {
  false_systemd_shim
  local workspace="$TEST_ROOT/workspace" pid actual expected
  mkdir -p "$workspace"

  (cd "$workspace" && "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null)
  for _ in $(seq 60); do
    [ -s "$AICODING_STATE_DIR/auto-update/worker.pid" ] && break
    sleep 0.05
  done
  pid=$(cat "$AICODING_STATE_DIR/auto-update/worker.pid")
  kill -0 "$pid"
  actual=$(readlink -f "/proc/$pid/cwd")
  expected=$(readlink -f "$AICODING_STATE_DIR/auto-update")

  [ "$actual" = "$expected" ]
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

@test "detached scheduler never retains shared configuration writer locks" {
  false_systemd_shim
  export AICODING_AUTO_UPDATE_INTERVAL=3600
  mkdir -p "$HOME/.claude"
  exec {held_fd}>"$HOME/.claude/.aicoding-update.lock"
  flock "$held_fd"
  "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  run flock -n "$HOME/.claude/.aicoding-update.lock" true
  [ "$status" -ne 0 ]
  exec {held_fd}>&-
  wait_for_lines 1
  run flock -n "$HOME/.claude/.aicoding-update.lock" true
  [ "$status" -eq 0 ]
}

@test "ensure replaces a legacy worker retaining shared configuration locks" {
  false_systemd_shim
  export AICODING_AUTO_UPDATE_INTERVAL=3600
  mkdir -p "$HOME/.claude" "$TEST_ROOT/legacy"
  cat > "$TEST_ROOT/legacy/aicoding-auto-update" <<'LEGACY'
#!/usr/bin/env bash
# Exercise the real worker without the corrected executable's FD cleanup.
source "$TEST_ROOT/runtime/lib/auto-update.sh"
aicoding_auto_update_worker
LEGACY
  chmod +x "$TEST_ROOT/legacy/aicoding-auto-update"
  exec {held_fd}>"$HOME/.claude/.aicoding-update.lock"
  flock "$held_fd"
  "$TEST_ROOT/legacy/aicoding-auto-update" --worker </dev/null >/dev/null 2>&1 &
  local old_worker=$!
  exec {held_fd}>&-
  wait_for_lines 1
  "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  local i
  for ((i=0; i<60; i++)); do
    kill -0 "$old_worker" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$old_worker" 2>/dev/null; then false; fi
  run flock -n "$HOME/.claude/.aicoding-update.lock" true
  [ "$status" -eq 0 ]
}

@test "legacy lock recovery does not signal an unrelated process in a stale PID file" {
  source "$TEST_ROOT/runtime/lib/auto-update.sh"
  mkdir -p "$HOME/.claude" "$AICODING_STATE_DIR/auto-update"
  exec {held_fd}>"$HOME/.claude/.aicoding-update.lock"
  flock "$held_fd"
  printf '%s\n' "$BASHPID" > "$AICODING_STATE_DIR/auto-update/worker.pid"
  _aicoding_auto_recover_shared_lock_worker
  run flock -n "$HOME/.claude/.aicoding-update.lock" true
  [ "$status" -ne 0 ]
  exec {held_fd}>&-
}

@test "a still-finishing legacy worker does not make scheduler ensure fatal" {
  false_systemd_shim
  source "$TEST_ROOT/runtime/lib/auto-update.sh"
  export AICODING_AUTO_UPDATE_SELF="$TEST_ROOT/aicoding-auto-update"
  _aicoding_auto_recover_shared_lock_worker() { return 1; }
  run aicoding_auto_update_ensure
  [ "$status" -eq 0 ]
  [[ "$output" == *'recovery deferred'* ]]
  wait_for_lines 1
}

@test "busy legacy worker hands scheduling to its replacement after finishing" {
  false_systemd_shim
  export AICODING_AUTO_UPDATE_INTERVAL=3600
  mkdir -p "$HOME/.claude" "$TEST_ROOT/legacy"
  # Keep the real legacy worker inside its synchronous update long enough
  # to exceed the bounded TERM wait; the replacement must still start.
  printf '\nif [ "${AICODING_TEST_SLOW_LEGACY:-0}" = 1 ]; then sleep 4; fi\n' >> "$TEST_ROOT/bin/aicoding-sync"
  cat > "$TEST_ROOT/legacy/aicoding-auto-update" <<'LEGACY'
#!/usr/bin/env bash
source "$TEST_ROOT/runtime/lib/auto-update.sh"
aicoding_auto_update_worker
LEGACY
  chmod +x "$TEST_ROOT/legacy/aicoding-auto-update"
  exec {held_fd}>"$HOME/.claude/.aicoding-update.lock"
  flock "$held_fd"
  AICODING_TEST_SLOW_LEGACY=1 "$TEST_ROOT/legacy/aicoding-auto-update" --worker </dev/null >/dev/null 2>&1 &
  local old_worker=$!
  exec {held_fd}>&-
  wait_for_lines 1
  run "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  [ "$status" -eq 0 ]
  wait_for_replacement "$old_worker"
  run flock -n "$HOME/.claude/.aicoding-update.lock" true
  [ "$status" -eq 0 ]
}

@test "detached legacy recovery has a deadline and reports why enrollment deferred" {
  export AICODING_AUTO_UPDATE_RECOVERY_TIMEOUT=1
  run timeout 4 bash -c '
    source "$TEST_ROOT/runtime/lib/auto-update.sh"
    _aicoding_auto_recover_shared_lock_worker_locked() { return 3; }
    aicoding_auto_update_enroll
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *'waiting for legacy worker'* ]]
  [[ "$output" == *'recovery timed out'* ]]
}

@test "shared lock recovery distinguishes competing enrollment from worker deferral" {
  source "$TEST_ROOT/runtime/lib/auto-update.sh"
  mkdir -p "$AICODING_STATE_DIR/auto-update"
  exec {held_fd}>"$AICODING_STATE_DIR/auto-update/ensure.lock"
  flock "$held_fd"
  run _aicoding_auto_recover_shared_lock_worker
  [ "$status" -eq 4 ]
  exec {held_fd}>&-
}

@test "recovery deadline leaves an in-flight legacy scheduler alive" {
  false_systemd_shim
  export AICODING_AUTO_UPDATE_INTERVAL=3600 AICODING_AUTO_UPDATE_RECOVERY_TIMEOUT=1
  mkdir -p "$HOME/.claude" "$TEST_ROOT/legacy"
  printf '\nif [ "${AICODING_TEST_SLOW_LEGACY:-0}" = 1 ]; then sleep 8; touch "$TEST_ROOT/legacy-finished"; fi\n' >> "$TEST_ROOT/bin/aicoding-sync"
  cat > "$TEST_ROOT/legacy/aicoding-auto-update" <<'LEGACY'
#!/usr/bin/env bash
source "$TEST_ROOT/runtime/lib/auto-update.sh"
aicoding_auto_update_worker
LEGACY
  chmod +x "$TEST_ROOT/legacy/aicoding-auto-update"
  exec {held_fd}>"$HOME/.claude/.aicoding-update.lock"
  flock "$held_fd"
  AICODING_TEST_SLOW_LEGACY=1 "$TEST_ROOT/legacy/aicoding-auto-update" --worker </dev/null >/dev/null 2>&1 &
  local old_worker=$! i
  exec {held_fd}>&-
  wait_for_lines 1
  run "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  [ "$status" -eq 0 ]
  for ((i=0; i<150; i++)); do
    [ -f "$TEST_ROOT/legacy-finished" ] && break
    sleep 0.1
  done
  [ -f "$TEST_ROOT/legacy-finished" ]
  sleep 0.2
  kill -0 "$old_worker"
  [ "$(cat "$AICODING_STATE_DIR/auto-update/worker.pid")" = "$old_worker" ]
}

@test "ensure rejects invalid recovery timeout before queuing enrollment" {
  export AICODING_AUTO_UPDATE_RECOVERY_TIMEOUT=oops
  run "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  [ "$status" -eq 2 ]
  [ ! -f "$AICODING_STATE_DIR/auto-update/enroll.log" ]
}

@test "installer-owned update lock permits idle legacy recovery without releasing its lock" {
  false_systemd_shim
  export AICODING_AUTO_UPDATE_INTERVAL=3600
  mkdir -p "$HOME/.claude" "$TEST_ROOT/legacy"
  cat > "$TEST_ROOT/legacy/aicoding-auto-update" <<'LEGACY'
#!/usr/bin/env bash
source "$TEST_ROOT/runtime/lib/auto-update.sh"
aicoding_auto_update_worker
LEGACY
  chmod +x "$TEST_ROOT/legacy/aicoding-auto-update"
  exec {held_fd}>"$HOME/.claude/.aicoding-update.lock"
  flock "$held_fd"
  "$TEST_ROOT/legacy/aicoding-auto-update" --worker </dev/null >/dev/null 2>&1 &
  exec {held_fd}>&-
  wait_for_lines 1
  exec {AICODING_SYNC_LOCK_FD}>"$AICODING_STATE_DIR/sync.lock"
  flock -w 2 "$AICODING_SYNC_LOCK_FD"
  export AICODING_SYNC_LOCK_FD AICODING_SYNC_LOCK_PID=$$
  source "$TEST_ROOT/runtime/lib/auto-update.sh"
  _aicoding_auto_recover_shared_lock_worker
  run flock -n "$HOME/.claude/.aicoding-update.lock" true
  [ "$status" -eq 0 ]
  run flock -n "$AICODING_STATE_DIR/sync.lock" true
  [ "$status" -ne 0 ]
  exec {AICODING_SYNC_LOCK_FD}>&-
}

@test "worker replacement waits for process exit after PID file cleanup" {
  false_systemd_shim
  export AICODING_AUTO_UPDATE_INTERVAL=3600
  mkdir -p "$HOME/.claude" "$TEST_ROOT/legacy"
  cat > "$TEST_ROOT/legacy/aicoding-auto-update" <<'LEGACY'
#!/usr/bin/env bash
source "$TEST_ROOT/runtime/lib/auto-update.sh"
rm() {
  command rm "$@"
  case "$*" in *'/worker.pid') sleep 0.5 ;; esac
}
aicoding_auto_update_worker
LEGACY
  chmod +x "$TEST_ROOT/legacy/aicoding-auto-update"
  exec {held_fd}>"$HOME/.claude/.aicoding-update.lock"
  flock "$held_fd"
  "$TEST_ROOT/legacy/aicoding-auto-update" --worker </dev/null >/dev/null 2>&1 &
  local old_worker=$!
  exec {held_fd}>&-
  wait_for_lines 1
  run "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  [ "$status" -eq 0 ]
  wait_for_replacement "$old_worker"
  run flock -n "$HOME/.claude/.aicoding-update.lock" true
  [ "$status" -eq 0 ]
}

@test "recovery arriving after PID cleanup still waits for the worker lock" {
  false_systemd_shim
  export AICODING_AUTO_UPDATE_INTERVAL=3600
  mkdir -p "$HOME/.claude" "$TEST_ROOT/legacy"
  cat > "$TEST_ROOT/legacy/aicoding-auto-update" <<'LEGACY'
#!/usr/bin/env bash
source "$TEST_ROOT/runtime/lib/auto-update.sh"
rm() {
  command rm "$@"
  case "$*" in *'/worker.pid') sleep 2 ;; esac
}
aicoding_auto_update_worker
LEGACY
  chmod +x "$TEST_ROOT/legacy/aicoding-auto-update"
  exec {held_fd}>"$HOME/.claude/.aicoding-update.lock"
  flock "$held_fd"
  "$TEST_ROOT/legacy/aicoding-auto-update" --worker </dev/null >/dev/null 2>&1 &
  local old_worker=$! i
  exec {held_fd}>&-
  wait_for_lines 1
  kill "$old_worker"
  for ((i=0; i<100; i++)); do
    [ ! -e "$AICODING_STATE_DIR/auto-update/worker.pid" ] && break
    sleep 0.02
  done
  [ ! -e "$AICODING_STATE_DIR/auto-update/worker.pid" ]
  kill -0 "$old_worker"
  run "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  [ "$status" -eq 0 ]
  wait_for_replacement "$old_worker"
  run flock -n "$HOME/.claude/.aicoding-update.lock" true
  [ "$status" -eq 0 ]
}
