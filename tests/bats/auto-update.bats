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
  # A removed fixture must never fall through to live agent/update launchers.
  export PATH="$TEST_ROOT/bin:/usr/bin:/bin"
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
flock -n "$sync_fd" || { echo 'aicoding-sync: update already running' >&2; exit 0; }
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

# Enrollment and fallback workers are separate detached process groups; the
# current worker.pid cannot enumerate enrollment still waiting to create one.
# Freeze every exact fixture process and its descendants before termination so
# competing enrollment cannot create a replacement behind teardown's snapshot.
_stop_fixture_processes() {
  python3 - "$TEST_ROOT" <<'PY_CLEANUP'
import os
from pathlib import Path
import signal
import sys
import time

root = os.fsencode(sys.argv[1])
excluded = {os.getpid(), os.getppid()}
known = {}

def snapshot():
    rows = {}
    starts = {}
    for entry in Path('/proc').iterdir():
        if not entry.name.isdigit():
            continue
        pid = int(entry.name)
        if pid in excluded:
            continue
        try:
            args = (entry / 'cmdline').read_bytes().split(b'\0')
            stat = (entry / 'stat').read_text().rsplit(')', 1)[1].split()
            if stat[0] == 'Z':
                continue
            starts[pid] = stat[19]
            rows[pid] = (int(stat[1]), int(stat[2]), any(
                arg == root or arg.startswith(root + b'/') for arg in args))
        except (OSError, IndexError, ValueError):
            continue
    selected = {pid for pid, (_, _, match) in rows.items()
                if match or known.get(pid) == starts[pid]}
    groups = {group for pid, (_, group, _) in rows.items() if pid in selected and group == pid}
    while True:
        children = {pid for pid, (parent, group, _) in rows.items()
                    if parent in selected or group in groups}
        if children <= selected:
            # Retain descendants by process identity even after their parent
            # exits and the kernel reparents them outside the fixture tree.
            known.update({pid: starts[pid] for pid in selected})
            return selected
        selected |= children

def send(pids, sig):
    for pid in pids:
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            pass

quiet = 0
for attempt in range(30):
    pids = snapshot()
    if not pids:
        quiet += 1
        if quiet == 2:
            break
        time.sleep(.05)
        continue
    quiet = 0
    send(pids, signal.SIGSTOP)
    # Catch children forked immediately before the original parents froze.
    pids |= snapshot()
    send(pids, signal.SIGSTOP)
    send(pids, signal.SIGTERM)
    send(pids, signal.SIGCONT)
    time.sleep(.1)
    # Reidentify survivors before escalation; never signal a recycled PID
    # merely because it appeared in the preceding snapshot.
    send(snapshot(), signal.SIGKILL)
    time.sleep(.02)
else:
    raise SystemExit('fixture process cleanup did not converge; preserving runtime')
PY_CLEANUP
}

teardown() {
  touch "$TEST_ROOT/release"
  if [ -f "$TEST_ROOT/once.pid" ]; then
    wait "$(cat "$TEST_ROOT/once.pid")" 2>/dev/null || true
    flock -w 2 "$AICODING_STATE_DIR/sync.lock" true || true
  fi
  if [ -f "$TEST_ROOT/detached.pid" ]; then
    kill "$(cat "$TEST_ROOT/detached.pid")" 2>/dev/null || true
  fi
  _stop_fixture_processes || return 1
  wait 2>/dev/null || true
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

@test "manual once records completed success and attempt without fallback success stamp" {
  run "$TEST_ROOT/aicoding-auto-update" --once
  [ "$status" -eq 0 ]
  [ -s "$AICODING_STATE_DIR/auto-update/last-attempt" ]
  jq -e '.outcome == "success" and .source == "manual" and .completed_at >= .started_at and .exit_code == 0' "$AICODING_STATE_DIR/auto-update/last-completed.json"
  [ ! -e "$AICODING_STATE_DIR/auto-update/run.json" ]
  [ ! -e "$AICODING_STATE_DIR/auto-update/last-success" ]
}

@test "systemd once records completed deferral then failure honestly" {
  local source_setting
  source_setting=$(sed -n 's/^Environment=//p' "$TEST_ROOT/runtime/configs/systemd/aicoding-auto-update.service")
  [ "$source_setting" = AICODING_AUTO_UPDATE_SOURCE=systemd ]
  export "$source_setting"
  export INVOCATION_ID=synthetic AICODING_TEST_DEFERRED=1
  run "$TEST_ROOT/aicoding-auto-update" --once
  [ "$status" -eq 0 ]
  jq -e '.outcome == "deferred" and .source == "systemd"' "$AICODING_STATE_DIR/auto-update/last-completed.json"
  export AICODING_TEST_DEFERRED=0 AICODING_TEST_FAILS=99
  run "$TEST_ROOT/aicoding-auto-update" --once
  [ "$status" -eq 1 ]
  jq -e '.outcome == "failed" and .exit_code == 1' "$AICODING_STATE_DIR/auto-update/last-completed.json"
}

@test "busy sync does not overwrite the last completed outcome" {
  "$TEST_ROOT/aicoding-auto-update" --once
  cp "$AICODING_STATE_DIR/auto-update/last-completed.json" "$TEST_ROOT/completed"
  export AICODING_TEST_BUSY=1
  run "$TEST_ROOT/aicoding-auto-update" --once
  [ "$status" -eq 0 ]
  cmp "$TEST_ROOT/completed" "$AICODING_STATE_DIR/auto-update/last-completed.json"
  [ ! -e "$AICODING_STATE_DIR/auto-update/run.json" ]
}

@test "ongoing once holds lifetime lock with process identity and concurrent request preserves it" {
  cat > "$TEST_ROOT/bin/date" <<'DATE'
#!/usr/bin/env bash
if [ "$*" = +%s ] && [ -n "${AICODING_TEST_NOW:-}" ]; then
  printf '%s\n' "$AICODING_TEST_NOW"
else
  exec /usr/bin/date "$@"
fi
DATE
  chmod +x "$TEST_ROOT/bin/date"
  export AICODING_TEST_NOW=1000
  printf '\nwhile [ ! -f "$TEST_ROOT/release" ]; do sleep 0.05; done\n' >> "$TEST_ROOT/bin/aicoding-sync"
  "$TEST_ROOT/aicoding-auto-update" --once > "$TEST_ROOT/once.log" 2>&1 &
  local runner=$!
  printf '%s\n' "$runner" > "$TEST_ROOT/once.pid"
  wait_for_lines 1
  jq -e --argjson pid "$runner" '.pid == $pid and .start_ticks > 0 and .started_at > 0' "$AICODING_STATE_DIR/auto-update/run.json"
  run flock -n "$AICODING_STATE_DIR/auto-update/run.lock" true
  [ "$status" -ne 0 ]
  export AICODING_TEST_NOW=2000
  run "$TEST_ROOT/aicoding-auto-update" --once
  [ "$status" -eq 0 ]
  [[ "$output" == *'update already running'* ]]
  [ "$(cat "$AICODING_STATE_DIR/auto-update/last-attempt")" = 1000 ]
  jq -e --argjson pid "$runner" '.pid == $pid' "$AICODING_STATE_DIR/auto-update/run.json"
  touch "$TEST_ROOT/release"
  wait "$runner"
  jq -e '.outcome == "success"' "$AICODING_STATE_DIR/auto-update/last-completed.json"
  run flock -n "$AICODING_STATE_DIR/auto-update/run.lock" true
  [ "$status" -eq 0 ]
}

@test "missing sync executable records a failed attempt" {
  source "$TEST_ROOT/runtime/lib/auto-update.sh"
  # Mask resolution without falling through to the host's installed sync.
  command() { if [ "$*" = '-v aicoding-sync' ]; then return 1; fi; builtin command "$@"; }
  AICODING_RUNTIME_ROOT="$TEST_ROOT/runtime"
  run aicoding_auto_update_once
  [ "$status" -eq 1 ]
  jq -e '.outcome == "failed" and .exit_code == 1' "$AICODING_STATE_DIR/auto-update/last-completed.json"
  [ ! -e "$AICODING_STATE_DIR/auto-update/run.json" ]
}

@test "failed fallback records failure while overdue retry is pending then recovers" {
  false_systemd_shim
  export AICODING_TEST_FAILS=1 AICODING_AUTO_UPDATE_MIN_BACKOFF=2 AICODING_AUTO_UPDATE_INTERVAL=3600
  "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  wait_for_lines 1
  for _ in $(seq 40); do [ -s "$AICODING_STATE_DIR/auto-update/next-due" ] && break; sleep 0.025; done
  jq -e '.outcome == "failed" and .source == "fallback"' "$AICODING_STATE_DIR/auto-update/last-completed.json"
  [ "$(cat "$AICODING_STATE_DIR/auto-update/next-due")" -le "$(date +%s)" ]
  [ ! -e "$AICODING_STATE_DIR/auto-update/last-success" ]
  wait_for_lines 2 100
  for _ in $(seq 40); do [ -s "$AICODING_STATE_DIR/auto-update/last-success" ] && break; sleep 0.025; done
  jq -e '.outcome == "success" and .source == "fallback"' "$AICODING_STATE_DIR/auto-update/last-completed.json"
}

@test "fallback deferral records completed outcome without superseding previous success timestamp" {
  false_systemd_shim
  export AICODING_TEST_DEFERRED=1 AICODING_AUTO_UPDATE_INTERVAL=3600
  mkdir -p "$AICODING_STATE_DIR/auto-update"
  printf '123\n' > "$AICODING_STATE_DIR/auto-update/last-success"
  "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  wait_for_lines 1
  for _ in $(seq 40); do [ -s "$AICODING_STATE_DIR/auto-update/next-due" ] && break; sleep 0.025; done
  jq -e '.outcome == "deferred" and .source == "fallback"' "$AICODING_STATE_DIR/auto-update/last-completed.json"
  [ "$(cat "$AICODING_STATE_DIR/auto-update/last-success")" = 123 ]
}

@test "sync cannot leak the reporting lock to detached children from older releases" {
  cat >> "$TEST_ROOT/bin/aicoding-sync" <<'CHILD'
sleep 30 </dev/null >/dev/null 2>&1 &
printf '%s\n' "$!" > "$TEST_ROOT/detached.pid"
CHILD
  "$TEST_ROOT/aicoding-auto-update" --once
  local child
  child=$(cat "$TEST_ROOT/detached.pid")
  kill -0 "$child"
  run flock -n "$AICODING_STATE_DIR/auto-update/run.lock" true
  kill "$child"
  [ "$status" -eq 0 ]
}

@test "interrupted once leaves identity evidence but does not overwrite completed outcome" {
  "$TEST_ROOT/aicoding-auto-update" --once
  cp "$AICODING_STATE_DIR/auto-update/last-completed.json" "$TEST_ROOT/completed"
  printf '\nwhile [ ! -f "$TEST_ROOT/release" ]; do sleep 0.05; done\n' >> "$TEST_ROOT/bin/aicoding-sync"
  "$TEST_ROOT/aicoding-auto-update" --once > "$TEST_ROOT/once.log" 2>&1 &
  local runner=$!
  printf '%s\n' "$runner" > "$TEST_ROOT/once.pid"
  wait_for_lines 2
  jq -e --argjson pid "$runner" '.pid == $pid' "$AICODING_STATE_DIR/auto-update/run.json"
  kill -KILL "$runner"
  wait "$runner" 2>/dev/null || true
  cmp "$TEST_ROOT/completed" "$AICODING_STATE_DIR/auto-update/last-completed.json"
  [ -s "$AICODING_STATE_DIR/auto-update/run.json" ]
  touch "$TEST_ROOT/release"
  for _ in $(seq 40); do
    if flock -n "$AICODING_STATE_DIR/sync.lock" true; then break; fi
    sleep 0.025
  done
  run "$TEST_ROOT/aicoding-auto-update" --once
  [ "$status" -eq 0 ]
  [ ! -e "$AICODING_STATE_DIR/auto-update/run.json" ]
  jq -e '.outcome == "success"' "$AICODING_STATE_DIR/auto-update/last-completed.json"
}

@test "ensure upgrades an idle worker without current reporting protocol and preserves its due time" {
  false_systemd_shim
  export AICODING_AUTO_UPDATE_INTERVAL=3600
  "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  wait_for_lines 1
  for _ in $(seq 40); do [ -s "$AICODING_STATE_DIR/auto-update/next-due" ] && break; sleep 0.025; done
  local old_worker due
  old_worker=$(cat "$AICODING_STATE_DIR/auto-update/worker.pid")
  due=$(cat "$AICODING_STATE_DIR/auto-update/next-due")
  rm -f "$AICODING_STATE_DIR/auto-update/worker.protocol"
  "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  wait_for_replacement "$old_worker"
  [ "$(cat "$AICODING_STATE_DIR/auto-update/next-due")" = "$due" ]
  [ -s "$AICODING_STATE_DIR/auto-update/worker.protocol" ]
}

@test "outdated-worker upgrade waits for its active sync to finish" {
  false_systemd_shim
  export AICODING_AUTO_UPDATE_INTERVAL=3600
  printf '\nif [ "${AICODING_TEST_SLOW_LEGACY:-0}" = 1 ]; then sleep 2; touch "$TEST_ROOT/legacy-finished"; fi\n' >> "$TEST_ROOT/bin/aicoding-sync"
  AICODING_TEST_SLOW_LEGACY=1 "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  wait_for_lines 1
  local old_worker
  old_worker=$(cat "$AICODING_STATE_DIR/auto-update/worker.pid")
  rm -f "$AICODING_STATE_DIR/auto-update/worker.protocol"
  "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  sleep 0.2
  kill -0 "$old_worker"
  [ "$(cat "$AICODING_STATE_DIR/auto-update/worker.pid")" = "$old_worker" ]
  wait_for_replacement "$old_worker"
  [ -f "$TEST_ROOT/legacy-finished" ]
}

@test "stale protocol receipt cannot authenticate a recycled worker PID" {
  false_systemd_shim
  export AICODING_AUTO_UPDATE_INTERVAL=3600
  "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  wait_for_lines 1
  local old_worker
  old_worker=$(cat "$AICODING_STATE_DIR/auto-update/worker.pid")
  printf '1 %s 1\n' "$old_worker" > "$AICODING_STATE_DIR/auto-update/worker.protocol"
  "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  wait_for_replacement "$old_worker"
}

_upgrading_sync_fixture() {
  cp "$BLUEPRINT_ROOT/bin/aicoding-sync" "$TEST_ROOT/runtime/bin/"
  cp "$BLUEPRINT_ROOT/lib/blueprint-source.sh" "$TEST_ROOT/runtime/lib/"
  cat > "$TEST_ROOT/runtime/lib/sync.sh" <<'SYNC'
aicoding_sync() {
  printf '%s\n' "$*" >> "$AICODING_TEST_ATTEMPTS"
  return "${AICODING_TEST_SYNC_RC:-0}"
}
SYNC
  rm "$TEST_ROOT/bin/aicoding-sync"
  ln -s "$TEST_ROOT/runtime/bin/aicoding-sync" "$TEST_ROOT/bin/aicoding-sync"
  mkdir -p "$TEST_ROOT/legacy" "$AICODING_STATE_DIR/auto-update"
  # An already loaded legacy worker has no protocol/run reporting, but invokes
  # the updated stable sync entrypoint on its next scheduled pass.
  cat > "$TEST_ROOT/legacy/aicoding-auto-update" <<'LEGACY'
#!/usr/bin/env bash
state="$AICODING_STATE_DIR/auto-update"
exec 9>"$state/worker.lock"
flock -n 9 || exit 0
printf '%s\n' "$$" > "$state/worker.pid"
sleep_pid=
trap 'test -z "$sleep_pid" || kill "$sleep_pid" 2>/dev/null; rm -f "$state/worker.pid"; exit 0' TERM INT
while :; do
  aicoding-sync --boot
  printf '%s\n' "$(date +%s)" > "$state/next-due"
  sleep 1 & sleep_pid=$!
  wait "$sleep_pid"
  sleep_pid=
done
LEGACY
  chmod +x "$TEST_ROOT/legacy/aicoding-auto-update"
}

@test "a legacy worker upgrades itself through the newly selected sync without another shell" {
  false_systemd_shim
  _upgrading_sync_fixture
  export AICODING_AUTO_UPDATE_INTERVAL=3600
  AICODINGSETUP_SKIP_NETWORK= "$TEST_ROOT/legacy/aicoding-auto-update" --worker > "$TEST_ROOT/legacy.log" 2>&1 &
  local old_worker=$!
  wait_for_lines 1
  wait_for_replacement "$old_worker"
  for _ in $(seq 80); do [ -s "$AICODING_STATE_DIR/auto-update/last-completed.json" ] && break; sleep .05; done
  jq -e '.outcome == "success" and .source == "fallback"' "$AICODING_STATE_DIR/auto-update/last-completed.json"
}

@test "scheduled migration hook preserves sync failure and respects the no-network guard" {
  false_systemd_shim
  _upgrading_sync_fixture
  export AICODING_TEST_SYNC_RC=7
  printf '99999999\n' > "$AICODING_STATE_DIR/auto-update/worker.pid"
  run "$TEST_ROOT/runtime/bin/aicoding-sync" --boot
  [ "$status" -eq 7 ]
  [ ! -f "$AICODING_STATE_DIR/auto-update/enroll.log" ]
  run env AICODINGSETUP_SKIP_NETWORK= "$TEST_ROOT/runtime/bin/aicoding-sync" --boot
  [ "$status" -eq 7 ]
  for _ in $(seq 80); do [ -s "$AICODING_STATE_DIR/auto-update/worker.protocol" ] && break; sleep .05; done
  [ -s "$AICODING_STATE_DIR/auto-update/worker.protocol" ]
}

@test "stale PID of another runtime worker is not signalled during protocol migration" {
  false_systemd_shim
  export AICODING_AUTO_UPDATE_INTERVAL=3600
  AICODING_STATE_DIR="$TEST_ROOT/other-state" "$TEST_ROOT/aicoding-auto-update" --worker > "$TEST_ROOT/other.log" 2>&1 &
  local other_worker=$!
  printf '%s\n' "$other_worker" > "$TEST_ROOT/detached.pid"
  wait_for_lines 1
  mkdir -p "$AICODING_STATE_DIR/auto-update"
  printf '%s\n' "$other_worker" > "$AICODING_STATE_DIR/auto-update/worker.pid"
  run bash -c '. "$1/lib/auto-update.sh"; _aicoding_auto_recover_shared_lock_worker' _ "$TEST_ROOT/runtime"
  [ "$status" -eq 0 ]
  kill -0 "$other_worker"
  [ ! -e "$AICODING_STATE_DIR/auto-update/worker.pid" ]
}

@test "fixture cleanup drains delayed enrollment before removing its runtime" {
  false_systemd_shim
  cat > "$TEST_ROOT/bin/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env bash
sleep 0.2
exit 1
SYSTEMCTL
  chmod +x "$TEST_ROOT/bin/systemctl"
  "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  _stop_fixture_processes
  sleep 0.3
  local observed
  observed=$(ps -eo args=)
  if [[ "$observed" == *"$TEST_ROOT/runtime/bin/aicoding-auto-update"* ]]; then false; fi
}

@test "manual once inside an unrelated systemd service stays manual" {
  export INVOCATION_ID=unrelated-ci-runner-service
  run "$TEST_ROOT/aicoding-auto-update" --once
  [ "$status" -eq 0 ]
  jq -e '.source == "manual"' "$AICODING_STATE_DIR/auto-update/last-completed.json"
}

@test "legacy service source detection is scoped to the updater unit cgroup" {
  source "$TEST_ROOT/runtime/lib/auto-update.sh"
  printf '0::/user.slice/user-1000.slice/user@1000.service/app.slice/aicoding-auto-update.service\n' > "$TEST_ROOT/cgroup"
  run _aicoding_auto_in_systemd_service "$TEST_ROOT/cgroup"
  [ "$status" -eq 0 ]
  printf '0::/system.slice/actions-runner.service\n' > "$TEST_ROOT/cgroup"
  run _aicoding_auto_in_systemd_service "$TEST_ROOT/cgroup"
  [ "$status" -eq 1 ]
}

@test "detached scheduler cleanup closes inherited unlinked scheduler lock descriptors" {
  mkdir -p "$AICODING_STATE_DIR/auto-update"
  exec {worker_fd}>"$AICODING_STATE_DIR/auto-update/worker.lock"
  exec {run_fd}>"$AICODING_STATE_DIR/auto-update/run.lock"
  flock "$worker_fd"
  flock "$run_fd"
  rm "$AICODING_STATE_DIR/auto-update/worker.lock" "$AICODING_STATE_DIR/auto-update/run.lock"
  # The replacement inode is independent: the deleted lock does not block it.
  # It must nevertheless not leak into a newly detached scheduler's lifetime.
  run flock -n "$AICODING_STATE_DIR/auto-update/worker.lock" true
  [ "$status" -eq 0 ]
  run bash -c '
    source "$TEST_ROOT/runtime/lib/auto-update.sh"
    _aicoding_auto_close_scheduler_lock_fds
    [ ! -e "/proc/$BASHPID/fd/$1" ] && [ ! -e "/proc/$BASHPID/fd/$2" ]
  ' _ "$worker_fd" "$run_fd"
  exec {worker_fd}>&-
  exec {run_fd}>&-
  [ "$status" -eq 0 ]
}

@test "deleted worker lock stops only a worker with matching protocol identity" {
  false_systemd_shim
  export AICODING_AUTO_UPDATE_INTERVAL=3600
  "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  wait_for_lines 1
  local worker
  worker=$(cat "$AICODING_STATE_DIR/auto-update/worker.pid")
  rm "$AICODING_STATE_DIR/auto-update/worker.lock"
  run bash -c '. "$1/lib/auto-update.sh"; _aicoding_auto_stop_worker' _ "$TEST_ROOT/runtime"
  [ "$status" -eq 0 ]
  if kill -0 "$worker" 2>/dev/null; then false; fi
}

@test "deleted worker lock without protocol proof preserves worker and defers transition" {
  false_systemd_shim
  export AICODING_AUTO_UPDATE_INTERVAL=3600
  "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  wait_for_lines 1
  local worker
  worker=$(cat "$AICODING_STATE_DIR/auto-update/worker.pid")
  rm "$AICODING_STATE_DIR/auto-update/worker.lock" "$AICODING_STATE_DIR/auto-update/worker.protocol"
  run bash -c '. "$1/lib/auto-update.sh"; _aicoding_auto_stop_worker' _ "$TEST_ROOT/runtime"
  [ "$status" -eq 1 ]
  kill -0 "$worker"
  [ "$(cat "$AICODING_STATE_DIR/auto-update/worker.pid")" = "$worker" ]
}

@test "deleted worker descriptor cannot stand in for a held replacement lock inode" {
  false_systemd_shim
  export AICODING_AUTO_UPDATE_INTERVAL=3600
  "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  wait_for_lines 1
  local worker
  worker=$(cat "$AICODING_STATE_DIR/auto-update/worker.pid")
  rm "$AICODING_STATE_DIR/auto-update/worker.lock"
  exec {replacement_fd}>"$AICODING_STATE_DIR/auto-update/worker.lock"
  flock "$replacement_fd"
  run bash -c '. "$1/lib/auto-update.sh"; _aicoding_auto_stop_worker' _ "$TEST_ROOT/runtime"
  exec {replacement_fd}>&-
  [ "$status" -eq 3 ]
  kill -0 "$worker"
  [ "$(cat "$AICODING_STATE_DIR/auto-update/worker.pid")" = "$worker" ]
}

@test "post-sync migration skips enrollment inside the updater systemd service" {
  false_systemd_shim
  _upgrading_sync_fixture
  printf '99999999\n' > "$AICODING_STATE_DIR/auto-update/worker.pid"
  run env AICODINGSETUP_SKIP_NETWORK= AICODING_AUTO_UPDATE_SOURCE=systemd "$TEST_ROOT/runtime/bin/aicoding-sync" --boot
  [ "$status" -eq 0 ]
  sleep .1
  [ ! -f "$AICODING_STATE_DIR/auto-update/enroll.log" ]
  source "$TEST_ROOT/runtime/lib/auto-update.sh"
  _aicoding_auto_in_systemd_service() { return 0; }
  AICODINGSETUP_SKIP_NETWORK= aicoding_auto_upgrade_worker_after_sync "$TEST_ROOT/runtime"
  [ ! -f "$AICODING_STATE_DIR/auto-update/enroll.log" ]
}

@test "ensure repairs a deleted lifetime lock before starting a fallback successor" {
  false_systemd_shim
  export AICODING_AUTO_UPDATE_INTERVAL=3600
  "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  wait_for_lines 1
  local old_worker
  old_worker=$(cat "$AICODING_STATE_DIR/auto-update/worker.pid")
  rm "$AICODING_STATE_DIR/auto-update/worker.lock"
  "$TEST_ROOT/aicoding-auto-update" --ensure </dev/null
  wait_for_replacement "$old_worker"
  if kill -0 "$old_worker" 2>/dev/null; then false; fi
}

@test "failed attempt timestamp persistence releases the controller lock" {
  source "$TEST_ROOT/runtime/lib/auto-update.sh"
  _aicoding_auto_atomic_number() { return 1; }
  local rc=0
  aicoding_auto_update_once || rc=$?
  [ "$rc" -eq 1 ]
  run flock -n "$AICODING_STATE_DIR/auto-update/run.lock" true
  [ "$status" -eq 0 ]
  [ ! -s "$AICODING_TEST_ATTEMPTS" ]
}
