#!/usr/bin/env bats
# Host-only pruning of unused staged releases (lib/version-retention.sh).
# Every run uses a temporary HOME and data directory; nothing here may ever
# point at the real ~/.local/share/aicoding.

# A per-run sleep length marks this file's helpers for the leak check.
setup_file() { export HELPER_SLEEP="30.${BASHPID}${RANDOM}"; }

setup() {
  : "${BLUEPRINT_ROOT:?run via tests/bats/run.sh}"
  TEST_ROOT=$(mktemp -d)
  export HOME="$TEST_ROOT/home"
  export AICODING_STATE_DIR="$TEST_ROOT/state"
  export AICODING_DATA_DIR="$TEST_ROOT/data"
  export AICODING_PROFILE=host AICODING_CONTAINER_RUNTIME=0 AICODING_RETENTION_GRACE=0
  unset AICODING_RETENTION
  mkdir -p "$HOME/.local/bin" "$AICODING_STATE_DIR" "$TEST_ROOT/stubs"
  export PATH="$TEST_ROOT/stubs:/usr/bin:/bin"
  D=$AICODING_DATA_DIR
  HELPERS=()
  . "$BLUEPRINT_ROOT/lib/version-retention.sh"
  # claude: 1.0.2 current, 1.0.1 previous, 1.0.0 unused.
  mkver claude 1.0.0; mkver claude 1.0.1; mkver claude 1.0.2
  point current claude ../versions/claude/1.0.2
  point previous claude ../versions/claude/1.0.1
}

teardown() {
  local pid
  for pid in "${HELPERS[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  chmod -R u+w "$TEST_ROOT" 2>/dev/null || true
  rm -rf "$TEST_ROOT"
}

teardown_file() {
  if pgrep -f -- "$HELPER_SLEEP" >/dev/null 2>&1; then
    echo "helper process outlived the test file" >&2
    false
  fi
}

mkver() {
  mkdir -p "$D/versions/$1/$2/bin"
  printf '#!/bin/sh\necho %s\n' "$2" > "$D/versions/$1/$2/bin/tool"
  chmod +x "$D/versions/$1/$2/bin/tool"
  printf '%s\n' "$2" > "$D/versions/$1/$2/.aicoding-version"
  head -c 4096 /dev/zero > "$D/versions/$1/$2/payload"
}

point() {
  mkdir -p "$D/$1"
  ln -sfn "$3" "$D/$1/$2"
}

@test "container profile removes nothing" {
  export AICODING_PROFILE=container
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [ -z "$output" ]
  # A host profile inside a container runtime is still a container.
  export AICODING_PROFILE=host AICODING_CONTAINER_RUNTIME=1
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
}

@test "unknown profile defaults to container and removes nothing" {
  unset AICODING_PROFILE
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
}

@test "current target survives" {
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.2" ]
  [ ! -e "$D/versions/claude/1.0.0" ]
}

@test "previous target survives" {
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.1" ]
  [ ! -e "$D/versions/claude/1.0.0" ]
}

@test "absolute-path pointers and cross-component pointers keep their targets" {
  mkver dvw aaa; mkver dvw bbb; mkver dvw ccc
  point current dvw "$D/versions/dvw/aaa"
  point previous dvw "$D/versions/dvw/bbb"
  mkver shared 2.0.0; mkver shared 1.0.0
  point current shared ../versions/shared/2.0.0
  point current helper ../versions/shared/1.0.0
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/dvw/aaa" ]
  [ -d "$D/versions/dvw/bbb" ]
  [ ! -e "$D/versions/dvw/ccc" ]
  [ -d "$D/versions/shared/1.0.0" ]
}

@test "dangling or missing current keeps the whole component" {
  point current claude ../versions/claude/9.9.9
  mkver pi 1.0.0; mkver pi 1.1.0
  mkver codex 1.0.0; mkver codex 2.0.0
  point current codex ../versions/codex/2.0.0
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [ -d "$D/versions/pi/1.0.0" ]
  [ -d "$D/versions/pi/1.1.0" ]
  [ ! -e "$D/versions/codex/1.0.0" ]
}

@test "dangling previous keeps the whole component" {
  point previous claude ../versions/claude/0.0.1
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
}

@test "dot-prefixed staging and transaction directories survive" {
  mkdir -p "$D/versions/claude/.staging.1.0.3.123/bin" "$D/versions/claude/1.0.4.staging.77"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/.staging.1.0.3.123/bin" ]
  [ -d "$D/versions/claude/1.0.4.staging.77" ]
  [ ! -e "$D/versions/claude/1.0.0" ]
}

@test "a version first seen unused starts its observation window and survives" {
  export AICODING_RETENTION_GRACE=3600
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [ -f "$AICODING_STATE_DIR/retention/claude/1.0.0" ]
  [[ "$output" == *"claude/1.0.0 unused since "*"; eligible for removal from "* ]]
  # Versions in use or referenced get no stamp.
  [ ! -e "$AICODING_STATE_DIR/retention/claude/1.0.1" ]
  [ ! -e "$AICODING_STATE_DIR/retention/claude/1.0.2" ]
}

@test "a version unused for the whole observation window is removed" {
  export AICODING_RETENTION_GRACE=3600
  mkdir -p "$AICODING_STATE_DIR/retention/claude"
  touch -d @"$(( $(date +%s) - 3700 ))" "$AICODING_STATE_DIR/retention/claude/1.0.0"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ ! -e "$D/versions/claude/1.0.0" ]
  [ ! -e "$AICODING_STATE_DIR/retention/claude/1.0.0" ]
  [[ "$output" == *"removed claude/1.0.0 ("* ]]
}

@test "the default observation window is seven days" {
  unset AICODING_RETENTION_GRACE
  mkdir -p "$AICODING_STATE_DIR/retention/claude"
  touch -d @"$(( $(date +%s) - 6 * 86400 ))" "$AICODING_STATE_DIR/retention/claude/1.0.0"
  run aicoding_version_retention
  [ -d "$D/versions/claude/1.0.0" ]
  touch -d @"$(( $(date +%s) - 7 * 86400 - 60 ))" "$AICODING_STATE_DIR/retention/claude/1.0.0"
  run aicoding_version_retention
  [ ! -e "$D/versions/claude/1.0.0" ]
}

@test "a run that sees a version in use deletes its stamp" {
  export AICODING_RETENTION_GRACE=3600
  mkdir -p "$AICODING_STATE_DIR/retention/claude"
  touch -d @"$(( $(date +%s) - 3700 ))" "$AICODING_STATE_DIR/retention/claude/1.0.0"
  sleep "$HELPER_SLEEP" 7<"$D/versions/claude/1.0.0/payload" &
  HELPERS+=("$!")
  sleep 0.2
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [ ! -e "$AICODING_STATE_DIR/retention/claude/1.0.0" ]
  # A component kept by a rule resets its stamps too.
  mkdir -p "$AICODING_STATE_DIR/retention/claude"
  touch -d @"$(( $(date +%s) - 3700 ))" "$AICODING_STATE_DIR/retention/claude/1.0.0"
  point current claude ../versions/claude/9.9.9
  run aicoding_version_retention
  [ ! -e "$AICODING_STATE_DIR/retention/claude/1.0.0" ]
}

@test "stamps of versions that no longer exist are cleaned up" {
  mkdir -p "$AICODING_STATE_DIR/retention/claude" "$AICODING_STATE_DIR/retention/gone"
  : > "$AICODING_STATE_DIR/retention/claude/0.0.9"
  : > "$AICODING_STATE_DIR/retention/gone/1.0.0"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ ! -e "$AICODING_STATE_DIR/retention/claude/0.0.9" ]
  [ ! -e "$AICODING_STATE_DIR/retention/gone" ]
}

@test "an incomplete scan neither creates nor advances stamps" {
  export AICODING_RETENTION_GRACE=3600
  mkver claude 0.9.0
  mkdir -p "$AICODING_STATE_DIR/retention/claude"
  touch -d @1000000000 "$AICODING_STATE_DIR/retention/claude/0.9.0"
  real=$(PATH=/usr/bin:/bin command -v find)
  printf '#!/bin/sh\ncase "$*" in */proc/*) %s "$@"; exit 137 ;; esac\nexec %s "$@"\n' "$real" "$real" \
    > "$TEST_ROOT/stubs/find"
  chmod +x "$TEST_ROOT/stubs/find"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/0.9.0" ]
  [ -d "$D/versions/claude/1.0.0" ]
  [ ! -e "$AICODING_STATE_DIR/retention/claude/1.0.0" ]
  [ "$(stat -c %Y "$AICODING_STATE_DIR/retention/claude/0.9.0")" = 1000000000 ]
}

@test "an invalid grace period removes nothing" {
  export AICODING_RETENTION_GRACE=soon
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [[ "$output" == *"WARN"* ]]
}

@test "versions referenced from ~/.local/bin survive" {
  mkver claude 0.9.0; mkver claude 0.8.0
  printf '#!/bin/sh\nexec %s/versions/claude/1.0.0/bin/tool "$@"\n' "$D" > "$HOME/.local/bin/legacy-claude"
  chmod +x "$HOME/.local/bin/legacy-claude"
  ln -s "$D/versions/claude/0.9.0/bin/tool" "$HOME/.local/bin/old-tool"
  # A chained link whose own text names no version is resolved too.
  mkver claude 0.7.0
  ln -s "$D/versions/claude/0.7.0" "$TEST_ROOT/alias"
  ln -s "$TEST_ROOT/alias/bin/tool" "$HOME/.local/bin/chained-tool"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [ -d "$D/versions/claude/0.9.0" ]
  [ -d "$D/versions/claude/0.7.0" ]
  [ ! -e "$D/versions/claude/0.8.0" ]
}

@test "a symlink elsewhere in the data directory keeps its target" {
  mkver claude 0.9.0
  mkdir -p "$D/sources/x"
  ln -s "$D/versions/claude/1.0.0/bin" "$D/sources/x/link"
  # A link inside a version pointing into itself does not keep that version.
  ln -s "$D/versions/claude/0.9.0/bin/tool" "$D/versions/claude/0.9.0/self"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [ ! -e "$D/versions/claude/0.9.0" ]
}

@test "a live process with its working directory inside a version keeps it" {
  mkver claude 0.5.0
  (cd "$D/versions/claude/1.0.0" && exec sleep "$HELPER_SLEEP") &
  HELPERS+=("$!")
  sleep 0.2
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [ ! -e "$D/versions/claude/0.5.0" ]
}

@test "a live process with an open file inside a version keeps it" {
  mkver claude 0.5.0
  sleep "$HELPER_SLEEP" 7<"$D/versions/claude/1.0.0/payload" &
  HELPERS+=("$!")
  sleep 0.2
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [ ! -e "$D/versions/claude/0.5.0" ]
}

@test "a live process mapping a file inside a version keeps it" {
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"
  mkver claude 0.5.0
  # Python's mmap module keeps a dup of the descriptor, so map through libc.
  python3 -c 'import ctypes, os, sys, time
libc = ctypes.CDLL(None)
libc.mmap.restype = ctypes.c_void_p
libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_long]
fd = os.open(sys.argv[1], os.O_RDONLY)
assert libc.mmap(None, 4096, 1, 2, fd, 0) not in (None, ctypes.c_void_p(-1).value)
os.close(fd)
time.sleep(float(sys.argv[2]))' "$D/versions/claude/1.0.0/payload" "$HELPER_SLEEP" &
  HELPERS+=("$!")
  sleep 0.5
  # The descriptor is closed, so only /proc/<pid>/maps can see the use.
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [ ! -e "$D/versions/claude/0.5.0" ]
}

@test "an incomplete /proc descriptor scan removes nothing" {
  real=$(PATH=/usr/bin:/bin command -v find)
  printf '#!/bin/sh\ncase "$*" in */proc/*) %s "$@"; exit 137 ;; esac\nexec %s "$@"\n' "$real" "$real" \
    > "$TEST_ROOT/stubs/find"
  chmod +x "$TEST_ROOT/stubs/find"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [[ "$output" == *"cannot prove"* ]]
}

@test "an incomplete /proc memory-map scan removes nothing" {
  real=$(PATH=/usr/bin:/bin command -v grep)
  printf '#!/bin/sh\ncase "$*" in */maps*) %s "$@"; exit 137 ;; esac\nexec %s "$@"\n' "$real" "$real" \
    > "$TEST_ROOT/stubs/grep"
  chmod +x "$TEST_ROOT/stubs/grep"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [[ "$output" == *"cannot prove"* ]]
}

# A fake proc entry with no exe, cwd, fd or maps: fakeproc PID UID COMM [ARG...].
# FAKE_PPID sets its parent. The fake root replaces the whole process scan.
fakeproc() {
  local dir="$TEST_ROOT/proc/$1" uid=$2 comm=$3
  shift 3
  mkdir -p "$dir" "$TEST_ROOT/proc/self"
  [ -e "$TEST_ROOT/proc/self/mountinfo" ] || cat /proc/self/mountinfo > "$TEST_ROOT/proc/self/mountinfo"
  printf 'Name:\t%s\nState:\tS (sleeping)\nPPid:\t%s\nUid:\t%s\t%s\t%s\t%s\n' \
    "$comm" "${FAKE_PPID:-1}" "$uid" "$uid" "$uid" "$uid" > "$dir/status"
  printf '%s\n' "$comm" > "$dir/comm"
  : > "$dir/cmdline"
  [ "$#" -eq 0 ] || printf '%s\0' "$@" > "$dir/cmdline"
  export _AICODING_RETENTION_PROC="$TEST_ROOT/proc"
}

# Make a fake process fully readable: inspectable PID [HELD_PATH].
inspectable() {
  local dir="$TEST_ROOT/proc/$1"
  ln -sfn /usr/bin/env "$dir/exe"
  ln -sfn "$TEST_ROOT" "$dir/cwd"
  mkdir -p "$dir/fd"
  ln -sfn /dev/null "$dir/fd/0"
  : > "$dir/maps"
  [ "$#" -lt 2 ] || ln -sfn "$2" "$dir/fd/9"
}

@test "an uninspectable process naming the data directory removes nothing" {
  fakeproc 4101 "$UID" claude node "$D/versions/claude/1.0.0/bin/tool" --token=sekrit-value
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [[ "$output" == *"process 4101 (claude) cannot be inspected and runs from a managed path; nothing removed"* ]]
  [[ "$output" != *"sekrit"* ]]
  [[ "$output" != *"bin/tool"* ]]
  # Through a symlinked data directory: the given and the resolved path both count.
  ln -s "$D" "$TEST_ROOT/data-link"
  export AICODING_DATA_DIR="$TEST_ROOT/data-link"
  fakeproc 4101 "$UID" claude node "$TEST_ROOT/data-link/current/claude/bin/tool"
  run aicoding_version_retention
  [ -d "$D/versions/claude/1.0.0" ]
  [[ "$output" == *"process 4101 (claude)"* ]]
  fakeproc 4101 "$UID" claude "--root=$D"
  run aicoding_version_retention
  [ -d "$D/versions/claude/1.0.0" ]
  [[ "$output" == *"process 4101 (claude)"* ]]
}

@test "an uninspectable process naming a launcher in ~/.local/bin removes nothing" {
  fakeproc 4102 "$UID" codex /bin/sh "$HOME/.local/bin/codex" --api-key=sekrit-value
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [[ "$output" == *"process 4102 (codex) cannot be inspected and runs from a managed path"* ]]
  [[ "$output" != *"sekrit"* ]]
}

@test "an uninspectable process with an unreadable command line removes nothing" {
  [ "$(id -u)" -ne 0 ] || skip "root reads mode 000 files"
  fakeproc 4103 "$UID" helper /usr/bin/helper
  chmod 000 "$TEST_ROOT/proc/4103/cmdline"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [[ "$output" == *"process 4103 (helper) cannot be inspected and its command line cannot be read"* ]]
}

@test "uninspectable processes that name no managed path do not block pruning" {
  fakeproc 4104 "$UID" ssh-agent /usr/bin/ssh-agent -D
  fakeproc 4105 "$UID" zombie
  # Another user's process is out of scope even when it names the data directory.
  fakeproc 4106 "$((UID + 1))" claude node "$D/versions/claude/1.0.0/bin/tool"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ ! -e "$D/versions/claude/1.0.0" ]
  [[ "$output" != *"cannot be inspected"* ]]
}

@test "an inspectable process is judged by what it holds, not its command line" {
  fakeproc 4107 "$UID" claude node "$D/current/claude/bin/tool"
  inspectable 4107 "$D/versions/claude/1.0.2"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ ! -e "$D/versions/claude/1.0.0" ]
  [[ "$output" != *"cannot be inspected"* ]]
  [[ "$output" != *"does not hold open"* ]]
}

@test "an old unused version is removed and logged with its size" {
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ ! -e "$D/versions/claude/1.0.0" ]
  [[ "$output" == *"removed claude/1.0.0 ("*"KiB)"* ]]
  [[ "$output" == *"removed 1 unused version, freed "* ]]
  if compgen -G "$D/versions/claude/.*retired*" >/dev/null; then false; fi
}

@test "preview lists what it would remove and removes nothing" {
  export AICODING_RETENTION=preview
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [[ "$output" == *"would remove claude/1.0.0 now ("* ]]
  [[ "$output" != *"would remove claude/1.0.1"* ]]
  [ ! -e "$AICODING_STATE_DIR/retention" ]
}

@test "preview tells when each candidate becomes eligible and writes no stamp" {
  export AICODING_RETENTION=preview AICODING_RETENTION_GRACE=3600
  mkver claude 0.9.0
  mkdir -p "$AICODING_STATE_DIR/retention/claude"
  touch -d @"$(( $(date +%s) - 3700 ))" "$AICODING_STATE_DIR/retention/claude/0.9.0"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [[ "$output" == *"would remove claude/0.9.0 now ("* ]]
  [[ "$output" == *"claude/1.0.0 unused since "*"; eligible for removal from "* ]]
  [ ! -e "$AICODING_STATE_DIR/retention/claude/1.0.0" ]
  [ -d "$D/versions/claude/0.9.0" ]
}

@test "preview lists leftover retired trees a real run would delete" {
  export AICODING_RETENTION=preview
  mkdir -p "$D/versions/claude/.aicoding-retired.0.1.0.abcdef/item"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/.aicoding-retired.0.1.0.abcdef/item" ]
  [[ "$output" == *"would delete leftover $D/versions/claude/.aicoding-retired.0.1.0.abcdef"* ]]
}

@test "off does nothing" {
  export AICODING_RETENTION=off
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [ -z "$output" ]
}

@test "an unknown mode removes nothing" {
  export AICODING_RETENTION=yes-please
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [[ "$output" == *"WARN"* ]]
}

@test "a removal failure warns and still returns 0" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores directory permissions"
  chmod 0555 "$D/versions/claude"
  run aicoding_version_retention
  chmod 0755 "$D/versions/claude"
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [[ "$output" == *"WARN"*"claude/1.0.0"* ]]
}

@test "read-only trees inside a removed version are still removed" {
  mkdir -p "$D/versions/claude/1.0.0/modcache/pkg"
  : > "$D/versions/claude/1.0.0/modcache/pkg/file"
  chmod 0555 "$D/versions/claude/1.0.0/modcache/pkg"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ ! -e "$D/versions/claude/1.0.0" ]
}

@test "a symlink inside versions/<component> pointing outside is never followed or removed" {
  mkdir -p "$TEST_ROOT/outside/keep"
  : > "$TEST_ROOT/outside/keep/file"
  ln -s "$TEST_ROOT/outside" "$D/versions/claude/9.9.9"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -L "$D/versions/claude/9.9.9" ]
  [ -f "$TEST_ROOT/outside/keep/file" ]
  [[ "$output" != *"claude/9.9.9"* ]]
}

@test "a busy update lock skips the run" {
  exec {fd}>"$AICODING_STATE_DIR/sync.lock"
  flock -n "$fd"
  run aicoding_version_retention
  exec {fd}>&-
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
}

@test "a busy component activation lock keeps that component" {
  mkver codex 1.0.0; mkver codex 2.0.0
  point current codex ../versions/codex/2.0.0
  mkdir -p "$AICODING_STATE_DIR/locks"
  exec {fd}>"$AICODING_STATE_DIR/locks/claude.lock"
  flock -n "$fd"
  run aicoding_version_retention
  exec {fd}>&-
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [ ! -e "$D/versions/codex/1.0.0" ]
}

@test "a leftover retired tree from an interrupted removal is cleaned up" {
  mkdir -p "$D/versions/claude/.aicoding-retired.0.1.0.abcdef/item/bin"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ ! -e "$D/versions/claude/.aicoding-retired.0.1.0.abcdef" ]
}

# The scheduled pass prunes only after a successful sync, under run.lock.
_once_with_sync_exit() {
  printf '#!/bin/sh\nread -r unexpected && exit 91\nexit %s\n' "$1" > "$TEST_ROOT/stubs/aicoding-sync"
  chmod +x "$TEST_ROOT/stubs/aicoding-sync"
  (
    unset AICODINGSETUP_SKIP_NETWORK
    # The same shell options as bin/aicoding-auto-update.
    set -uo pipefail
    . "$BLUEPRINT_ROOT/lib/auto-update.sh"
    aicoding_auto_update_once
  )
}

@test "a successful scheduled pass prunes on a host and keeps its recorded result" {
  run _once_with_sync_exit 0
  [ "$status" -eq 0 ]
  [ ! -e "$D/versions/claude/1.0.0" ]
  [ "$(jq -r .outcome "$AICODING_STATE_DIR/auto-update/last-completed.json")" = success ]
}

@test "a failed scheduled pass prunes nothing" {
  run _once_with_sync_exit 1
  [ "$status" -eq 1 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [ "$(jq -r .outcome "$AICODING_STATE_DIR/auto-update/last-completed.json")" = failed ]
}

@test "aicoding-auto-update --retention-preview lists and removes nothing" {
  run "$BLUEPRINT_ROOT/bin/aicoding-auto-update" --retention-preview
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [[ "$output" == *"would remove claude/1.0.0"* ]]
}

# A managed launcher for COMPONENT named NAME running RELATIVE: launcher NAME COMPONENT RELATIVE.
launcher() {
  ( . "$BLUEPRINT_ROOT/lib/runtime.sh" && _aicoding_runtime_write_wrapper "$HOME/.local/bin/$1" "$D/current/$2" "$3" )
}

@test "the launcher lease keeps a release open for an interpreter-run tool" {
  mkver tool 1.0.0; mkver tool 1.1.0
  printf '#!/bin/sh\nexec sleep "$1"\n' > "$D/versions/tool/1.0.0/bin/run"
  chmod +x "$D/versions/tool/1.0.0/bin/run"
  point current tool ../versions/tool/1.0.0
  launcher aicodingtesttool tool bin/run
  "$HOME/.local/bin/aicodingtesttool" "$HELPER_SLEEP" &
  HELPERS+=("$!")
  local pid=$! fd held=
  sleep 0.3
  # The tool runs as plain sleep: no exe, cwd, file or mapping inside its release.
  for fd in /proc/"$pid"/fd/*; do
    [ "$(readlink "$fd")" != "$D/versions/tool/1.0.0" ] || held=1
  done
  [ "$held" = 1 ]
  # An upgrade moves current away; the lease alone must keep 1.0.0.
  point current tool ../versions/tool/1.1.0
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/tool/1.0.0" ]
}

@test "a launcher still runs when its release directory cannot be opened" {
  [ "$(id -u)" -ne 0 ] || skip "root opens any directory"
  mkver tool 1.0.0
  printf '#!/bin/sh\necho ran "$@"\n' > "$D/versions/tool/1.0.0/bin/run"
  chmod +x "$D/versions/tool/1.0.0/bin/run"
  point current tool ../versions/tool/1.0.0
  launcher aicodingtesttool tool bin/run
  chmod 0111 "$D/versions/tool/1.0.0"
  run "$HOME/.local/bin/aicodingtesttool" a b
  chmod 0755 "$D/versions/tool/1.0.0"
  [ "$status" -eq 0 ]
  [ "$output" = "ran a b" ]
  # Also under POSIX mode, where a failed exec redirection ends the shell.
  chmod 0111 "$D/versions/tool/1.0.0"
  run env POSIXLY_CORRECT=1 "$HOME/.local/bin/aicodingtesttool" c
  chmod 0755 "$D/versions/tool/1.0.0"
  [ "$status" -eq 0 ]
  [ "$output" = "ran c" ]
}

@test "launcher refresh rewrites outdated managed launchers once and leaves current ones alone" {
  mkver tool 1.0.0
  point current tool ../versions/tool/1.0.0
  launcher aicodingtesttool tool bin/tool
  launcher other tool bin/tool
  cp "$HOME/.local/bin/aicodingtesttool" "$TEST_ROOT/expected"
  # What an older release wrote: the same launcher without the lease.
  grep -v -e 'aicoding_lease' -e '^# Lease' "$TEST_ROOT/expected" > "$HOME/.local/bin/aicodingtesttool"
  if cmp -s "$TEST_ROOT/expected" "$HOME/.local/bin/aicodingtesttool"; then false; fi
  local before
  before=$(stat -c %i "$HOME/.local/bin/other")
  run bash -c '. "$1/lib/runtime.sh" && aicoding_runtime_refresh_launchers' _ "$BLUEPRINT_ROOT"
  [ "$status" -eq 0 ]
  cmp "$TEST_ROOT/expected" "$HOME/.local/bin/aicodingtesttool"
  [ "$(stat -c %i "$HOME/.local/bin/other")" = "$before" ]
  [ "$(readlink "$D/current/tool")" = ../versions/tool/1.0.0 ]
  before=$(stat -c %i "$HOME/.local/bin/aicodingtesttool")
  run bash -c '. "$1/lib/runtime.sh" && aicoding_runtime_refresh_launchers' _ "$BLUEPRINT_ROOT"
  [ "$status" -eq 0 ]
  [ "$(stat -c %i "$HOME/.local/bin/aicodingtesttool")" = "$before" ]
}

@test "launcher refresh handles an absolute current pointer without moving any pointer" {
  mkver tool 0.9.0; mkver tool 1.0.0
  point current tool "$D/versions/tool/1.0.0"
  point previous tool "$D/versions/tool/0.9.0"
  launcher aicodingtesttool tool bin/tool
  cp "$HOME/.local/bin/aicodingtesttool" "$TEST_ROOT/expected"
  grep -v -e 'aicoding_lease' -e '^# Lease' "$TEST_ROOT/expected" > "$HOME/.local/bin/aicodingtesttool"
  local cur prev cur_ino prev_ino
  cur=$(readlink "$D/current/tool"); prev=$(readlink "$D/previous/tool")
  cur_ino=$(stat -c %i "$D/current/tool"); prev_ino=$(stat -c %i "$D/previous/tool")
  run bash -c '. "$1/lib/runtime.sh" && aicoding_runtime_refresh_launchers' _ "$BLUEPRINT_ROOT"
  [ "$status" -eq 0 ]
  cmp "$TEST_ROOT/expected" "$HOME/.local/bin/aicodingtesttool"
  [ "$(readlink "$D/current/tool")" = "$cur" ]
  [ "$(readlink "$D/previous/tool")" = "$prev" ]
  [ "$(stat -c %i "$D/current/tool")" = "$cur_ino" ]
  [ "$(stat -c %i "$D/previous/tool")" = "$prev_ino" ]
}

@test "sync refreshes managed launchers after updating components" {
  grep -q 'aicoding_runtime_refresh_launchers' "$BLUEPRINT_ROOT/lib/sync.sh"
}

@test "a process run through a launcher name that holds no release keeps the component" {
  mkver tool 1.0.0; mkver tool 1.1.0
  point current tool ../versions/tool/1.1.0
  launcher aicodingtesttool tool bin/tool
  # argv[0] is the launcher name, as after a process.title rewrite.
  bash -c 'exec -a aicodingtesttool sleep "$1"' _ "$HELPER_SLEEP" &
  HELPERS+=("$!")
  local pid=$!
  sleep 0.2
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/tool/1.0.0" ]
  [[ "$output" == *"process $pid (sleep) runs tool from a release it does not hold open; keeping every tool version"* ]]
  # Other components still prune.
  [ ! -e "$D/versions/claude/1.0.0" ]
}

@test "a process whose command line names a component but holds none of it keeps the component" {
  mkver pi 1.0.0; mkver pi 1.1.0
  point current pi ../versions/pi/1.1.0
  fakeproc 4201 "$UID" node node "$D/current/pi/node_modules/.bin/pi" --sekrit-flag
  inspectable 4201
  fakeproc 4202 "$UID" node node "$D/versions/pi/1.0.0/dist/cli.js"
  inspectable 4202
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/pi/1.0.0" ]
  [[ "$output" == *"process 4201 (node) runs pi from a release"* ]]
  [[ "$output" != *"sekrit"* ]]
  [ ! -e "$D/versions/claude/1.0.0" ]
  # Once it holds its release, the rule is satisfied.
  rm -rf "$TEST_ROOT/proc/4202"
  inspectable 4201 "$D/versions/pi/1.1.0"
  run aicoding_version_retention
  [ ! -e "$D/versions/pi/1.0.0" ]
}

@test "an uninspectable process running a managed launcher name removes nothing" {
  launcher aicodingtesttool claude bin/tool
  fakeproc 4301 "$UID" node aicodingtesttool --flag
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [[ "$output" == *"process 4301 (node) cannot be inspected and runs a managed launcher"* ]]
  # comm alone (first 15 bytes of the launcher name) is enough.
  fakeproc 4301 "$UID" aicodingtesttoo /usr/bin/whatever
  run aicoding_version_retention
  [ -d "$D/versions/claude/1.0.0" ]
  [[ "$output" == *"process 4301 (aicodingtesttoo) cannot be inspected and runs a managed launcher"* ]]
}

@test "an uninspectable child of a process that uses a release removes nothing" {
  fakeproc 4401 "$UID" claude /opt/claude
  inspectable 4401 "$D/versions/claude/1.0.2/bin/tool"
  FAKE_PPID=4401 fakeproc 4402 "$UID" helper /usr/bin/helper
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [[ "$output" == *"process 4402 (helper) cannot be inspected and descends from a process that uses a managed release"* ]]
}

@test "a process is inspected only when exe, cwd, descriptors and maps are all readable" {
  # exe and cwd readable, but no descriptor directory: still unknown.
  fakeproc 4501 "$UID" claude node "$D/versions/claude/1.0.0/bin/tool"
  ln -s /usr/bin/env "$TEST_ROOT/proc/4501/exe"
  ln -s "$TEST_ROOT" "$TEST_ROOT/proc/4501/cwd"
  : > "$TEST_ROOT/proc/4501/maps"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [[ "$output" == *"process 4501 (claude) cannot be inspected and runs from a managed path"* ]]
  # Readable descriptors but no maps file.
  mkdir "$TEST_ROOT/proc/4501/fd"
  rm "$TEST_ROOT/proc/4501/maps"
  run aicoding_version_retention
  [ -d "$D/versions/claude/1.0.0" ]
  [[ "$output" == *"process 4501 (claude) cannot be inspected"* ]]
}

@test "a release containing a mount point is kept with a warning" {
  fakeproc 4601 "$UID" idle /usr/bin/idle
  inspectable 4601
  mkdir -p "$D/versions/claude/1.0.0/mnt" "$D/versions/claude/.aicoding-retired.0.1.0.abcdef/item/mnt"
  printf '901 1 0:99 / %s rw - tmpfs tmpfs rw\n' \
    "$D/versions/claude/1.0.0/mnt" "$D/versions/claude/.aicoding-retired.0.1.0.abcdef/item/mnt" \
    >> "$TEST_ROOT/proc/self/mountinfo"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0/mnt" ]
  [ -d "$D/versions/claude/.aicoding-retired.0.1.0.abcdef/item/mnt" ]
  [[ "$output" == *"claude/1.0.0 contains a mount point; kept"* ]]
  [[ "$output" == *"leftover $D/versions/claude/.aicoding-retired.0.1.0.abcdef contains a mount point; kept"* ]]
}

@test "a mount point on the release itself, with escaped spaces, is found" {
  mkver claude "0.9.0"
  fakeproc 4602 "$UID" idle /usr/bin/idle
  inspectable 4602
  mkdir -p "$D/versions/claude/0.9.0/a b"
  printf '902 1 0:99 / %s rw - tmpfs tmpfs rw\n' "$D/versions/claude/0.9.0" >> "$TEST_ROOT/proc/self/mountinfo"
  printf '903 1 0:99 / %s rw - tmpfs tmpfs rw\n' "$D/versions/claude/1.0.0/a\\040b" >> "$TEST_ROOT/proc/self/mountinfo"
  mkdir -p "$D/versions/claude/1.0.0/a b"
  run aicoding_version_retention
  [ -d "$D/versions/claude/0.9.0" ]
  [ -d "$D/versions/claude/1.0.0" ]
}

@test "an unreadable mount table removes nothing" {
  fakeproc 4603 "$UID" idle /usr/bin/idle
  inspectable 4603
  rm "$TEST_ROOT/proc/self/mountinfo"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [[ "$output" == *"cannot read the mount table; nothing removed"* ]]
}

@test "a symlinked ~/.local/bin pointing into a release keeps that release" {
  rmdir "$HOME/.local/bin"
  ln -s "$D/versions/claude/1.0.0/bin" "$HOME/.local/bin"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
}

@test "current must point at exactly one release of its own component" {
  mkdir -p "$D/versions/claude/.staging.1.0.3.1/bin"
  point current claude ../versions/claude/.staging.1.0.3.1
  run aicoding_version_retention
  [ -d "$D/versions/claude/1.0.0" ]
  point current claude ../versions/claude/1.0.2/bin
  run aicoding_version_retention
  [ -d "$D/versions/claude/1.0.0" ]
  mkdir -p "$D/versions/claude/1.0.4.staging.77"
  point current claude ../versions/claude/1.0.4.staging.77
  run aicoding_version_retention
  [ -d "$D/versions/claude/1.0.0" ]
  mkver codex 2.0.0
  point current codex ../versions/codex/2.0.0
  point current claude ../versions/codex/2.0.0
  run aicoding_version_retention
  [ -d "$D/versions/claude/1.0.0" ]
  # Back to a plain release: pruning resumes.
  point current claude ../versions/claude/1.0.2
  run aicoding_version_retention
  [ ! -e "$D/versions/claude/1.0.0" ]
}

@test "a scheduled pass that completed with deferrals prunes nothing" {
  printf '#!/bin/sh\nread -r unexpected && exit 91\necho "aicoding-sync: completed with deferrals"\nexit 0\n' \
    > "$TEST_ROOT/stubs/aicoding-sync"
  chmod +x "$TEST_ROOT/stubs/aicoding-sync"
  run bash -c 'unset AICODINGSETUP_SKIP_NETWORK; set -uo pipefail; . "$1/lib/auto-update.sh"; aicoding_auto_update_once' _ "$BLUEPRINT_ROOT"
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [ "$(jq -r .outcome "$AICODING_STATE_DIR/auto-update/last-completed.json")" = deferred ]
}
