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
  # Never through a test's stubs.
  PATH=/usr/bin:/bin
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

@test "a release set aside by an in-place rebuild survives and gets no stamp" {
  mkdir -p "$D/versions/claude/1.0.0.replaced.4242/bin"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0.replaced.4242/bin" ]
  [ ! -e "$AICODING_STATE_DIR/retention/claude/1.0.0.replaced.4242" ]
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
  # Field 22 is the start time; FAKE_START sets it.
  printf '%s (%s) S %s 0 0 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 %s 0 0\n' \
    "${dir##*/}" "$comm" "${FAKE_PPID:-1}" "${FAKE_START:-1000}" > "$dir/stat"
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

@test "a symlinked component stamp directory is never followed" {
  mkdir -p "$TEST_ROOT/docs" "$AICODING_STATE_DIR/retention"
  printf 'keep\n' > "$TEST_ROOT/docs/sentinel"
  printf 'keep\n' > "$TEST_ROOT/docs/0.0.9"
  ln -s "$TEST_ROOT/docs" "$AICODING_STATE_DIR/retention/claude"
  mkver codex 1.0.0; mkver codex 2.0.0
  point current codex ../versions/codex/2.0.0
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [ "$(cat "$TEST_ROOT/docs/sentinel")" = keep ]
  [ "$(cat "$TEST_ROOT/docs/0.0.9")" = keep ]
  [ "$(find "$TEST_ROOT/docs" -mindepth 1 | wc -l)" -eq 2 ]
  [[ "$output" == *"WARN"*"claude"* ]]
  # Other components still prune.
  [ ! -e "$D/versions/codex/1.0.0" ]
  # A stamp write must not land there either.
  export AICODING_RETENTION_GRACE=3600
  run aicoding_version_retention
  [ "$(find "$TEST_ROOT/docs" -mindepth 1 | wc -l)" -eq 2 ]
  [ -d "$D/versions/claude/1.0.0" ]
}

@test "a symlinked retention root keeps every component" {
  mkdir -p "$TEST_ROOT/docs/claude" "$AICODING_STATE_DIR"
  printf 'keep\n' > "$TEST_ROOT/docs/sentinel"
  printf 'keep\n' > "$TEST_ROOT/docs/claude/0.0.9"
  ln -s "$TEST_ROOT/docs" "$AICODING_STATE_DIR/retention"
  mkver codex 1.0.0; mkver codex 2.0.0
  point current codex ../versions/codex/2.0.0
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [ -d "$D/versions/codex/1.0.0" ]
  [ "$(cat "$TEST_ROOT/docs/sentinel")" = keep ]
  [ "$(cat "$TEST_ROOT/docs/claude/0.0.9")" = keep ]
  [ "$(find "$TEST_ROOT/docs" -mindepth 1 | wc -l)" -eq 3 ]
  [[ "$output" == *"WARN"* ]]
}

@test "stamp cleanup deletes only regular files named like a version" {
  mkdir -p "$AICODING_STATE_DIR/retention/claude/sub" "$TEST_ROOT/outside"
  : > "$TEST_ROOT/outside/0.0.8"
  ln -s "$TEST_ROOT/outside/0.0.8" "$AICODING_STATE_DIR/retention/claude/0.0.8"
  : > "$AICODING_STATE_DIR/retention/claude/.hidden"
  : > "$AICODING_STATE_DIR/retention/claude/0.0.9"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ ! -e "$AICODING_STATE_DIR/retention/claude/0.0.9" ]
  [ -L "$AICODING_STATE_DIR/retention/claude/0.0.8" ]
  [ -f "$TEST_ROOT/outside/0.0.8" ]
  [ -d "$AICODING_STATE_DIR/retention/claude/sub" ]
  [ -f "$AICODING_STATE_DIR/retention/claude/.hidden" ]
}

@test "the stamp directories are private" {
  export AICODING_RETENTION_GRACE=3600
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -f "$AICODING_STATE_DIR/retention/claude/1.0.0" ]
  [ "$(stat -c %a "$AICODING_STATE_DIR/retention")" = 700 ]
  [ "$(stat -c %a "$AICODING_STATE_DIR/retention/claude")" = 700 ]
}

@test "a pointer that resolves through another release keeps the component" {
  mkver tool 1; mkver tool 2; mkver tool 3
  ln -s ../2 "$D/versions/tool/1/forward"
  point current tool ../versions/tool/1/forward
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/tool/1" ]
  [ -d "$D/versions/tool/2" ]
  [ -d "$D/versions/tool/3" ]
  # The same shape under previous/.
  point current tool ../versions/tool/3
  point previous tool "$D/versions/tool/1/forward"
  run aicoding_version_retention
  [ -d "$D/versions/tool/1" ]
  [ -d "$D/versions/tool/2" ]
  # A plain pointer still allows pruning.
  point previous tool ../versions/tool/2
  rm "$D/versions/tool/1/forward"
  run aicoding_version_retention
  [ ! -e "$D/versions/tool/1" ]
  [ -d "$D/versions/tool/2" ]
}

@test "a link elsewhere that resolves through a release keeps every release on the way" {
  mkver tool 0; mkver tool 1; mkver tool 2; mkver tool 3
  point current tool ../versions/tool/3
  ln -s ../2 "$D/versions/tool/1/forward"
  mkdir -p "$D/sources/x"
  ln -s "$D/versions/tool/1/forward/bin" "$D/sources/x/abs"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/tool/1" ]
  [ -d "$D/versions/tool/2" ]
  [ ! -e "$D/versions/tool/0" ]
  # A relative chain: from release 3 through 1 into 2.
  mkver tool 4; mkver tool 5
  rm "$D/sources/x/abs"
  ln -s ../2 "$D/versions/tool/4/forward"
  ln -s ../4/forward/bin "$D/versions/tool/3/chain"
  run aicoding_version_retention
  [ -d "$D/versions/tool/4" ]
  [ -d "$D/versions/tool/2" ]
  [ ! -e "$D/versions/tool/5" ]
}

@test "a release named on any command line is kept even when the process holds another" {
  mkver pi 0.9.0; mkver pi 1.0.0; mkver pi 1.1.0; mkver pi 1.2.0
  point current pi ../versions/pi/1.2.0
  fakeproc 4801 "$UID" node node "$D/versions/pi/1.0.0/dist/cli.js"
  inspectable 4801 "$D/versions/pi/1.1.0"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/pi/1.0.0" ]
  [ -d "$D/versions/pi/1.1.0" ]
  [ ! -e "$D/versions/pi/0.9.0" ]
}

@test "deleting a retired tree never changes a hard-linked file outside it" {
  : > "$TEST_ROOT/outside-file"
  chmod 0444 "$TEST_ROOT/outside-file"
  mkdir -p "$D/versions/claude/1.0.0/ro"
  ln "$TEST_ROOT/outside-file" "$D/versions/claude/1.0.0/ro/link"
  chmod 0555 "$D/versions/claude/1.0.0/ro"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ ! -e "$D/versions/claude/1.0.0" ]
  [ "$(stat -c %a "$TEST_ROOT/outside-file")" = 444 ]
}

@test "the grace period is read as decimal" {
  mkdir -p "$AICODING_STATE_DIR/retention/claude"
  # 0100 is a hundred seconds, not octal 64.
  export AICODING_RETENTION_GRACE=0100
  touch -d @"$(( $(date +%s) - 80 ))" "$AICODING_STATE_DIR/retention/claude/1.0.0"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  touch -d @"$(( $(date +%s) - 130 ))" "$AICODING_STATE_DIR/retention/claude/1.0.0"
  run aicoding_version_retention
  [ ! -e "$D/versions/claude/1.0.0" ]
  # 080 is eighty seconds, not an octal error.
  mkver claude 0.9.0
  export AICODING_RETENTION_GRACE=080
  mkdir -p "$AICODING_STATE_DIR/retention/claude"
  touch -d @"$(( $(date +%s) - 60 ))" "$AICODING_STATE_DIR/retention/claude/0.9.0"
  run aicoding_version_retention
  [ -d "$D/versions/claude/0.9.0" ]
  touch -d @"$(( $(date +%s) - 110 ))" "$AICODING_STATE_DIR/retention/claude/0.9.0"
  run aicoding_version_retention
  [ ! -e "$D/versions/claude/0.9.0" ]
}

@test "a grace period that is too large or not a number removes nothing" {
  local g
  for g in 9223372036854775807 315360001 -5 '10 ' 1e3; do
    export AICODING_RETENTION_GRACE=$g
    run aicoding_version_retention
    [ "$status" -eq 0 ]
    [ -d "$D/versions/claude/1.0.0" ]
    [[ "$output" == *"WARN"*"AICODING_RETENTION_GRACE"* ]]
    [ ! -e "$AICODING_STATE_DIR/retention/claude/1.0.0" ]
  done
}

@test "an uninspectable process with a looping parent chain removes nothing" {
  FAKE_PPID=4902 fakeproc 4901 "$UID" helper /usr/bin/helper
  FAKE_PPID=4901 fakeproc 4902 "$UID" other /usr/bin/other
  inspectable 4902
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [[ "$output" == *"process 4901 (helper) cannot be inspected"* ]]
}

# Wait until FILE exists; 1 after 5 s. A lock probe could collide with the
# launcher's own non-blocking attempt, so tools announce themselves instead.
_wait_file() {
  local i
  for ((i = 0; i < 50; i++)); do
    [ ! -e "$1" ] || return 0
    sleep 0.1
  done
  return 1
}

@test "a launcher's shared lock keeps its release even when the /proc scan cannot see the process" {
  export AICODING_RETENTION_GRACE=3600
  mkver tool 1.0.0; mkver tool 1.1.0
  mkfifo "$TEST_ROOT/gate"
  printf '#!/bin/sh\n: > "$1.ready"\nread -r line < "$1"\n' > "$D/versions/tool/1.0.0/bin/run"
  chmod +x "$D/versions/tool/1.0.0/bin/run"
  point current tool ../versions/tool/1.0.0
  launcher aicodingtesttool tool bin/run
  "$HOME/.local/bin/aicodingtesttool" "$TEST_ROOT/gate" "$HELPER_SLEEP" &
  HELPERS+=("$!")
  local pid=$!
  _wait_file "$TEST_ROOT/gate.ready"
  if flock -x -n "$D/versions/tool/1.0.0" true; then false; fi
  point current tool ../versions/tool/1.1.0
  mkdir -p "$AICODING_STATE_DIR/retention/tool"
  touch -d @"$(( $(date +%s) - 3700 ))" "$AICODING_STATE_DIR/retention/tool/1.0.0"
  # A fake proc root with one idle process: the scan sees nothing of the tool.
  fakeproc 4991 "$UID" idle /usr/bin/idle
  inspectable 4991
  export AICODING_RETENTION=preview
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [[ "$output" == *"tool/1.0.0 is held by a running process; kept"* ]]
  [[ "$output" != *"would remove tool/1.0.0"* ]]
  unset AICODING_RETENTION
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/tool/1.0.0" ]
  [ ! -e "$AICODING_STATE_DIR/retention/tool/1.0.0" ]
  [[ "$output" == *"tool/1.0.0 is held by a running process; kept"* ]]
  # Once the tool ends, the lease is gone and the release can go.
  printf 'go\n' > "$TEST_ROOT/gate"
  wait "$pid"
  export AICODING_RETENTION_GRACE=0 AICODING_RETENTION=preview
  run aicoding_version_retention
  [[ "$output" == *"would remove tool/1.0.0 now"* ]]
  # Preview leaves no lock behind.
  flock -x -n "$D/versions/tool/1.0.0" true
  unset AICODING_RETENTION
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ ! -e "$D/versions/tool/1.0.0" ]
  [ -d "$D/versions/tool/1.1.0" ]
}

@test "a launcher takes the lease lock and still runs when flock is missing or fails" {
  mkver tool 1.0.0
  printf '#!/bin/sh\necho ran "$@"\n' > "$D/versions/tool/1.0.0/bin/run"
  chmod +x "$D/versions/tool/1.0.0/bin/run"
  point current tool ../versions/tool/1.0.0
  launcher aicodingtesttool tool bin/run
  grep -qF 'flock -s -n "$aicoding_lease"' "$HOME/.local/bin/aicodingtesttool"
  [ "$(tail -n 1 "$HOME/.local/bin/aicodingtesttool")" = 'exec "$release/$relative" "$@"' ]
  mkdir "$TEST_ROOT/noflock"
  ln -s "$(command -v bash)" "$TEST_ROOT/noflock/bash"
  ln -s "$(command -v readlink)" "$TEST_ROOT/noflock/readlink"
  run env PATH="$TEST_ROOT/noflock" "$HOME/.local/bin/aicodingtesttool" a b
  [ "$status" -eq 0 ]
  [ "$output" = "ran a b" ]
  printf '#!/bin/sh\necho flock-failed >&2\nexit 1\n' > "$TEST_ROOT/noflock/flock"
  chmod +x "$TEST_ROOT/noflock/flock"
  run env PATH="$TEST_ROOT/noflock" "$HOME/.local/bin/aicodingtesttool" c
  [ "$status" -eq 0 ]
  [ "$output" = "ran c" ]
}

@test "retention removes nothing when flock is not installed" {
  local f
  mkdir "$TEST_ROOT/farm"
  for f in /usr/bin/* /bin/*; do
    [ "${f##*/}" != flock ] || continue
    [ -e "$TEST_ROOT/farm/${f##*/}" ] || [ -L "$TEST_ROOT/farm/${f##*/}" ] || ln -s "$f" "$TEST_ROOT/farm/${f##*/}"
  done
  if PATH="$TEST_ROOT/stubs:$TEST_ROOT/farm" command -v flock >/dev/null; then false; fi
  PATH="$TEST_ROOT/stubs:$TEST_ROOT/farm" run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [ "$(grep -c 'flock is not installed' <<< "$output")" -eq 1 ]
  [ ! -e "$AICODING_STATE_DIR/retention" ]
}

# Run HOOK once, in the middle of the process scan, after the first command line is read.
_hook_scan() {
  declare -F _test_orig_belongs >/dev/null \
    || eval "$(declare -f _aicoding_retention_belongs | sed '1s/_aicoding_retention_belongs/_test_orig_belongs/')"
  _TEST_SCAN_HOOK=$1
  _aicoding_retention_belongs() {
    _test_orig_belongs "$@"
    [ -e "$TEST_ROOT/hook-ran" ] && return 0
    : > "$TEST_ROOT/hook-ran"
    eval "$_TEST_SCAN_HOOK"
  }
}

@test "a managed process that exits or forks during the scan makes the run remove nothing" {
  export AICODING_RETENTION_GRACE=3600
  mkver claude 0.9.0
  mkdir -p "$AICODING_STATE_DIR/retention/claude"
  touch -d @1000000000 "$AICODING_STATE_DIR/retention/claude/1.0.0"
  fakeproc 4701 "$UID" claude /opt/claude
  inspectable 4701 "$D/versions/claude/1.0.2/bin/tool"
  _hook_scan 'rm -rf "$TEST_ROOT/proc/4701"'
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [[ "$output" == *"cannot prove"* ]]
  [ "$(stat -c %Y "$AICODING_STATE_DIR/retention/claude/1.0.0")" = 1000000000 ]
  [ ! -e "$AICODING_STATE_DIR/retention/claude/0.9.0" ]
  # A new child of a managed process appearing during the scan.
  rm -f "$TEST_ROOT/hook-ran"
  fakeproc 4701 "$UID" claude /opt/claude
  inspectable 4701 "$D/versions/claude/1.0.2/bin/tool"
  _hook_scan 'FAKE_PPID=4701 fakeproc 4702 "$UID" helper /usr/bin/helper; inspectable 4702'
  run aicoding_version_retention
  [ -d "$D/versions/claude/1.0.0" ]
  [[ "$output" == *"cannot prove"* ]]
  [ "$(stat -c %Y "$AICODING_STATE_DIR/retention/claude/1.0.0")" = 1000000000 ]
  [ ! -e "$AICODING_STATE_DIR/retention/claude/0.9.0" ]
  # Without changes during the scan, the same tree prunes.
  . "$BLUEPRINT_ROOT/lib/version-retention.sh"
  run aicoding_version_retention
  [ ! -e "$D/versions/claude/1.0.0" ]
}

@test "launcher refresh adds the lease lock to a launcher that has only the lease" {
  mkver tool 1.0.0
  point current tool ../versions/tool/1.0.0
  launcher aicodingtesttool tool bin/tool
  cp "$HOME/.local/bin/aicodingtesttool" "$TEST_ROOT/expected"
  grep -v -e 'flock' -e '^# A shared lock' "$TEST_ROOT/expected" > "$HOME/.local/bin/aicodingtesttool"
  grep -q 'aicoding_lease' "$HOME/.local/bin/aicodingtesttool"
  if cmp -s "$TEST_ROOT/expected" "$HOME/.local/bin/aicodingtesttool"; then false; fi
  run bash -c '. "$1/lib/runtime.sh" && aicoding_runtime_refresh_launchers' _ "$BLUEPRINT_ROOT"
  [ "$status" -eq 0 ]
  cmp "$TEST_ROOT/expected" "$HOME/.local/bin/aicodingtesttool"
}

@test "a ~/.local/bin link that walks through a release keeps every release on the way" {
  mkver tool 0.9; mkver tool 1.0; mkver tool 2.0; mkver tool 3.0
  point current tool ../versions/tool/3.0
  ln -s ../2.0 "$D/versions/tool/1.0/forward"
  ln -s "$D/versions/tool/1.0" "$HOME/old-alias"
  ln -s "$HOME/old-alias/forward/bin/tool" "$HOME/.local/bin/tool"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/tool/1.0" ]
  [ -d "$D/versions/tool/2.0" ]
  [ ! -e "$D/versions/tool/0.9" ]
  # A chain from ~/.local/bin that ends in a missing path keeps the component.
  mkver tool 0.8
  ln -s "$HOME/old-alias/forward/bin/missing" "$HOME/.local/bin/broken"
  run aicoding_version_retention
  [ -d "$D/versions/tool/0.8" ]
}

@test "every release and component named in one argument counts, in any order" {
  mkver pi 0.6.0; mkver pi 0.7.0; mkver pi 0.8.0; mkver pi 1.0.0; mkver pi 1.1.0
  point current pi ../versions/pi/1.1.0
  fakeproc 4811 "$UID" node node "--paths=$D/versions/pi/1.0.0/bin:$D/current/pi/bin"
  inspectable 4811 "$D/versions/pi/1.1.0"
  fakeproc 4812 "$UID" node node "--list=$D/versions/pi/0.8.0,$D/versions/pi/0.7.0 x"
  inspectable 4812 "$D/versions/pi/1.1.0"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/pi/1.0.0" ]
  [ -d "$D/versions/pi/0.8.0" ]
  [ -d "$D/versions/pi/0.7.0" ]
  [ ! -e "$D/versions/pi/0.6.0" ]
  # A component named only after another path still belongs: holding none of it keeps it.
  mkver codex 1.0.0; mkver codex 2.0.0
  point current codex ../versions/codex/2.0.0
  fakeproc 4813 "$UID" node node "--paths=$D/versions/pi/1.1.0/bin:$D/current/codex/bin"
  inspectable 4813 "$D/versions/pi/1.1.0"
  run aicoding_version_retention
  [ -d "$D/versions/codex/1.0.0" ]
  [[ "$output" == *"process 4813 (node) runs codex from a release it does not hold open"* ]]
}

@test "an unexpected stamp entry is left in place and keeps its release" {
  mkver claude 0.9.0; mkver claude 0.8.0; mkver claude 0.7.0
  local s="$AICODING_STATE_DIR/retention/claude"
  mkdir -p "$s" "$TEST_ROOT/outside"
  printf 'keep\n' > "$TEST_ROOT/outside/target"
  ln -s "$TEST_ROOT/outside/target" "$s/1.0.0"
  mkfifo "$s/0.9.0"
  mkdir "$s/0.8.0"
  # A kept version (previous) with a symlinked stamp.
  ln -s "$TEST_ROOT/outside/target" "$s/1.0.1"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [ -d "$D/versions/claude/0.9.0" ]
  [ -d "$D/versions/claude/0.8.0" ]
  [ -L "$s/1.0.0" ]
  [ -p "$s/0.9.0" ]
  [ -d "$s/0.8.0" ]
  [ -L "$s/1.0.1" ]
  [ "$(cat "$TEST_ROOT/outside/target")" = keep ]
  [ "$(grep -c "WARN: $s/1.0.0 is not a regular file" <<< "$output")" -eq 1 ]
  [ "$(grep -c "WARN: $s/1.0.1 is not a regular file" <<< "$output")" -eq 1 ]
  # The happy path still removes an old unused version.
  [ ! -e "$D/versions/claude/0.7.0" ]
}

@test "a dangling chain into a release keeps its component; harmless dangling links do not" {
  mkver tool 0.9; mkver tool 1.0; mkver tool 2.0
  point current tool ../versions/tool/2.0
  mkdir -p "$D/sources/x" "$D/versions/tool/1.0/node_modules/.bin"
  # Dangling links that never touch versions/.
  ln -s "$D/nowhere/at/all" "$D/sources/x/gone"
  ln -s "$TEST_ROOT/nowhere" "$HOME/.local/bin/gone"
  # A link inside a release to a missing file of that same release.
  ln -s ../missing/cli.js "$D/versions/tool/1.0/node_modules/.bin/cli"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ ! -e "$D/versions/tool/0.9" ]
  [ ! -e "$D/versions/tool/1.0" ]
  [ -d "$D/versions/tool/2.0" ]
  # A link elsewhere to a missing path inside a release keeps the component.
  mkver tool 0.8; mkver tool 0.7
  ln -s "$D/versions/tool/0.8/bin/missing" "$D/sources/x/into"
  run aicoding_version_retention
  [ -d "$D/versions/tool/0.8" ]
  [ -d "$D/versions/tool/0.7" ]
}

@test "the short-name key is the first 15 bytes of a launcher name, as the kernel cuts it" {
  locale -a 2>/dev/null | grep -qix 'c.utf-\?8' || skip "no C.UTF-8 locale"
  export LC_ALL=C.UTF-8
  local name='ääääääääääää-tool' comm
  launcher "$name" claude bin/tool
  comm=$(printf '%s' "$name" | head -c 15)
  fakeproc 4302 "$UID" "$comm" /usr/bin/whatever
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [[ "$output" == *"process 4302 ("*") cannot be inspected and runs a managed launcher"* ]]
}

@test "a launcher that finds its release locked by retention resolves current once more" {
  mkver tool 1.0.0; mkver tool 1.1.0
  point current tool ../versions/tool/1.1.0
  launcher aicodingtesttool tool bin/tool
  local real fd
  real=$(command -v readlink)
  # The first resolution still sees the release retention is about to rename.
  printf '#!/bin/sh\nif mkdir "%s/readlink-once" 2>/dev/null; then echo "%s/versions/tool/1.0.0"; exit 0; fi\nexec %s "$@"\n' \
    "$TEST_ROOT" "$D" "$real" > "$TEST_ROOT/stubs/readlink"
  chmod +x "$TEST_ROOT/stubs/readlink"
  exec {fd}<"$D/versions/tool/1.0.0"
  flock -x -n "$fd"
  run "$HOME/.local/bin/aicodingtesttool"
  exec {fd}<&-
  [ "$status" -eq 0 ]
  [ "$output" = 1.1.0 ]
  # Without the exclusive lock the first resolution is used as before.
  rmdir "$TEST_ROOT/readlink-once"
  run "$HOME/.local/bin/aicodingtesttool"
  [ "$status" -eq 0 ]
  [ "$output" = 1.0.0 ]
}

@test "a ~/.local/bin reached through a release keeps that release" {
  mkver pi 1.0.0; mkver pi 1.2.0
  point current pi ../versions/pi/1.2.0
  mkdir -p "$D/launchers"
  rmdir "$HOME/.local/bin"
  ln -s "$D/versions/pi/1.0.0/../../../launchers" "$HOME/.local/bin"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/pi/1.0.0" ]
  [ ! -e "$D/versions/claude/1.0.0" ]
  # A parent of ~/.local/bin that passes through a release counts too.
  rm "$HOME/.local/bin"
  mkdir -p "$D/dotlocal/bin"
  rmdir "$HOME/.local"
  ln -s "$D/versions/pi/1.0.0/../../../dotlocal" "$HOME/.local"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/pi/1.0.0" ]
}

@test "a ~/.local/bin link to a script elsewhere has that script's contents scanned" {
  mkver pi 1.0.0; mkver pi 1.1.0
  point current pi ../versions/pi/1.1.0
  mkdir -p "$HOME/scripts"
  printf '#!/bin/sh\nexec %s/versions/pi/1.0.0/bin/tool "$@"\n' "$D" > "$HOME/scripts/pi-old"
  chmod +x "$HOME/scripts/pi-old"
  ln -s "$HOME/scripts/pi-old" "$HOME/.local/bin/pi-old"
  # A symlinked directory is not followed.
  ln -s "$HOME/scripts" "$HOME/.local/bin/scripts"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/pi/1.0.0" ]
  [ ! -e "$D/versions/claude/1.0.0" ]
  # An unreadable target makes the scan fail closed.
  [ "$(id -u)" -ne 0 ] || skip "root reads mode 000 files"
  mkver claude 0.9.0
  chmod 000 "$HOME/scripts/pi-old"
  run aicoding_version_retention
  chmod 0755 "$HOME/scripts/pi-old"
  [ -d "$D/versions/claude/0.9.0" ]
  [[ "$output" == *"cannot read every launcher in ~/.local/bin; nothing removed"* ]]
}

@test "a non-canonical release path on a command line keeps every version of the component" {
  mkver pi 1.0.0; mkver pi 1.1.0; mkver pi 1.2.0
  point current pi ../versions/pi/1.2.0
  fakeproc 4821 "$UID" node node "$D/versions/pi/1.1.0/../1.0.0/bin/cli.js"
  inspectable 4821 "$D/versions/pi/1.2.0"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/pi/1.0.0" ]
  [ -d "$D/versions/pi/1.1.0" ]
  [ ! -e "$D/versions/claude/1.0.0" ]
}

@test "a managed process that turns into a zombie or is replaced during the scan removes nothing" {
  export AICODING_RETENTION_GRACE=3600
  mkdir -p "$AICODING_STATE_DIR/retention/claude"
  touch -d @1000000000 "$AICODING_STATE_DIR/retention/claude/1.0.0"
  fakeproc 4711 "$UID" claude /opt/claude
  inspectable 4711 "$D/versions/claude/1.0.2/bin/tool"
  _hook_scan 'sed -i "s/) S /) Z /" "$TEST_ROOT/proc/4711/stat"'
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [[ "$output" == *"cannot prove"* ]]
  [ "$(stat -c %Y "$AICODING_STATE_DIR/retention/claude/1.0.0")" = 1000000000 ]
  # The same PID with a new start time is another process.
  rm -f "$TEST_ROOT/hook-ran"
  fakeproc 4711 "$UID" claude /opt/claude
  _hook_scan 'FAKE_START=2000 fakeproc 4711 "$UID" claude /opt/claude'
  run aicoding_version_retention
  [ -d "$D/versions/claude/1.0.0" ]
  [[ "$output" == *"cannot prove"* ]]
  [ "$(stat -c %Y "$AICODING_STATE_DIR/retention/claude/1.0.0")" = 1000000000 ]
  # Unchanged, the same tree prunes.
  . "$BLUEPRINT_ROOT/lib/version-retention.sh"
  run aicoding_version_retention
  [ ! -e "$D/versions/claude/1.0.0" ]
}

@test "a stamp directory that cannot be written keeps every version of its component" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores directory permissions"
  export AICODING_RETENTION_GRACE=3600
  mkver codex 1.0.0; mkver codex 2.0.0
  point current codex ../versions/codex/2.0.0
  mkdir -p "$AICODING_STATE_DIR/retention/claude" "$AICODING_STATE_DIR/retention/codex"
  touch -d @"$(( $(date +%s) - 3700 ))" "$AICODING_STATE_DIR/retention/claude/1.0.0" \
    "$AICODING_STATE_DIR/retention/codex/1.0.0"
  chmod 0555 "$AICODING_STATE_DIR/retention/claude"
  run aicoding_version_retention
  chmod 0755 "$AICODING_STATE_DIR/retention/claude"
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [[ "$output" == *"WARN"*"retention/claude"*"keeping every claude version"* ]]
  [ ! -e "$D/versions/codex/1.0.0" ]
}

@test "a stamp that cannot be reset keeps its component for the rest of the run" {
  export AICODING_RETENTION_GRACE=3600
  point previous claude ../versions/claude/1.0.0
  mkdir -p "$AICODING_STATE_DIR/retention/claude"
  : > "$AICODING_STATE_DIR/retention/claude/1.0.0"
  touch -d @"$(( $(date +%s) - 3700 ))" "$AICODING_STATE_DIR/retention/claude/1.0.1"
  local real
  real=$(command -v rm)
  printf '#!/bin/sh\ncase "$*" in */retention/claude/1.0.0) exit 1 ;; esac\nexec %s "$@"\n' "$real" > "$TEST_ROOT/stubs/rm"
  chmod +x "$TEST_ROOT/stubs/rm"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.1" ]
  [[ "$output" == *"WARN"*"retention/claude/1.0.0"* ]]
}

# Add a mount at PATH to the fake mount table right after its first read.
_mount_appears() {
  declare -F _test_orig_read_mounts >/dev/null \
    || eval "$(declare -f _aicoding_retention_read_mounts | sed '1s/_aicoding_retention_read_mounts/_test_orig_read_mounts/')"
  _TEST_LATE_MOUNT=$1
  _aicoding_retention_read_mounts() {
    _test_orig_read_mounts || return
    [ ! -e "$TEST_ROOT/mount-added" ] || return 0
    : > "$TEST_ROOT/mount-added"
    printf '905 1 0:99 / %s rw - tmpfs tmpfs rw\n' "$_TEST_LATE_MOUNT" >> "$TEST_ROOT/proc/self/mountinfo"
  }
}

@test "a mount that appears after the first mount table read is never deleted through" {
  fakeproc 4611 "$UID" idle /usr/bin/idle
  inspectable 4611
  local tomb="$D/versions/claude/.aicoding-retired.0.1.0.abcdef"
  mkdir -p "$tomb/item/mnt"
  : > "$tomb/item/mnt/file"
  _mount_appears "$tomb/item/mnt"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -f "$tomb/item/mnt/file" ]
  [[ "$output" == *"leftover $tomb contains a mount point; kept"* ]]
  # The same for a release, checked again right before its rename.
  rm -f "$TEST_ROOT/mount-added"
  mkver claude 0.9.0
  mkdir -p "$D/versions/claude/0.9.0/mnt"
  _mount_appears "$D/versions/claude/0.9.0/mnt"
  run aicoding_version_retention
  [ -d "$D/versions/claude/0.9.0/mnt" ]
  [[ "$output" == *"claude/0.9.0 contains a mount point; kept"* ]]
}

@test "a mount that appears inside a tombstone right after the rename is not deleted through" {
  fakeproc 4612 "$UID" idle /usr/bin/idle
  inspectable 4612
  mkdir -p "$D/versions/claude/1.0.0/mnt"
  : > "$D/versions/claude/1.0.0/mnt/file"
  local real
  real=$(command -v mv)
  printf '#!/bin/sh\n%s "$@" || exit\nfor a; do dst=$a; done\nprintf "906 1 0:99 / %%s/mnt rw - tmpfs tmpfs rw\\n" "$dst" >> "%s"\n' \
    "$real" "$TEST_ROOT/proc/self/mountinfo" > "$TEST_ROOT/stubs/mv"
  chmod +x "$TEST_ROOT/stubs/mv"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ ! -e "$D/versions/claude/1.0.0" ]
  compgen -G "$D/versions/claude/.aicoding-retired.1.0.0.*/item/mnt/file" >/dev/null
  [[ "$output" == *"removed claude/1.0.0 from use, but could not delete all of"* ]]
}

@test "a dangling link through a missing directory does not pin the release its text names" {
  mkver pi 1.0.0; mkver pi 1.1.0
  point current pi ../versions/pi/1.1.0
  mkdir -p "$D/sources/x"
  ln -s "$D/nowhere/../versions/pi/1.0.0/bin/tool" "$D/sources/x/through-missing"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ ! -e "$D/versions/pi/1.0.0" ]
  [ -d "$D/versions/pi/1.1.0" ]
}

@test "an empty grace period removes nothing" {
  export AICODING_RETENTION_GRACE=
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [[ "$output" == *"WARN"*"AICODING_RETENTION_GRACE"* ]]
  [ ! -e "$AICODING_STATE_DIR/retention/claude/1.0.0" ]
}

# Point a fake process's exe link at PATH: fake_exe PID PATH.
fake_exe() { ln -sfn "$2" "$TEST_ROOT/proc/$1/exe"; }

@test "another program that only shares a launcher's name does not keep the component" {
  mkver cursor 1.0; mkver cursor 1.1
  point current cursor ../versions/cursor/1.1
  launcher agent cursor bin/tool
  fakeproc 5101 "$UID" agent /usr/libexec/geoclue-2.0/demos/agent
  inspectable 5101
  fake_exe 5101 /usr/libexec/geoclue-2.0/demos/agent
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ ! -e "$D/versions/cursor/1.0" ]
  [ -d "$D/versions/cursor/1.1" ]
  [[ "$output" != *"runs cursor from a release"* ]]
  # A deleted executable of the same name is still another program.
  mkver cursor 1.0
  fake_exe 5101 "/usr/libexec/geoclue-2.0/demos/agent (deleted)"
  run aicoding_version_retention
  [ ! -e "$D/versions/cursor/1.0" ]
}

@test "a launcher name still counts when the executable is an interpreter, managed or unreadable" {
  mkver cursor 1.0; mkver cursor 1.1
  point current cursor ../versions/cursor/1.1
  launcher agent cursor bin/tool
  # A node tool that renamed itself.
  fakeproc 5102 "$UID" agent agent --serve
  inspectable 5102
  fake_exe 5102 /usr/bin/node
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/cursor/1.0" ]
  [[ "$output" == *"process 5102 (agent) runs cursor from a release it does not hold open"* ]]
  # An executable of that name inside ~/.local/bin is the launcher itself.
  fake_exe 5102 "$HOME/.local/bin/agent"
  run aicoding_version_retention
  [ -d "$D/versions/cursor/1.0" ]
  [[ "$output" == *"process 5102 (agent) runs cursor from a release it does not hold open"* ]]
  # An unreadable executable leaves the uninspectable rules in charge.
  rm -rf "$TEST_ROOT/proc/5102"
  fakeproc 5103 "$UID" agent /usr/libexec/geoclue-2.0/demos/agent
  run aicoding_version_retention
  [ -d "$D/versions/cursor/1.0" ]
  [[ "$output" == *"process 5103 (agent) cannot be inspected and runs a managed launcher"* ]]
}

@test "a truncated short name is compared with the executable name as the kernel cuts it" {
  mkver tool 1.0; mkver tool 1.1
  point current tool ../versions/tool/1.1
  launcher aicodingtesttool tool bin/tool
  # comm is the first 15 bytes of the executable name, whichever is longer.
  fakeproc 5111 "$UID" aicodingtesttoo /opt/x/aicodingtesttool-helper
  inspectable 5111
  fake_exe 5111 /opt/x/aicodingtesttool-helper
  fakeproc 5112 "$UID" aicodingtesttoo /opt/x/aicodingtesttoo
  inspectable 5112
  fake_exe 5112 /opt/x/aicodingtesttoo
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ ! -e "$D/versions/tool/1.0" ]
  [[ "$output" != *"runs tool from a release"* ]]
  # The same short name on an interpreter still keeps the component.
  mkver tool 1.0
  fakeproc 5113 "$UID" aicodingtesttoo /usr/bin/node /opt/x/tool.js
  inspectable 5113
  fake_exe 5113 /usr/bin/node
  run aicoding_version_retention
  [ -d "$D/versions/tool/1.0" ]
  [[ "$output" == *"process 5113 (aicodingtesttoo) runs tool from a release it does not hold open"* ]]
}

@test "a process that names its physical release keeps only that release" {
  mkver aicoding aaa; mkver aicoding bbb; mkver aicoding ccc
  point current aicoding ../versions/aicoding/ccc
  fakeproc 5201 "$UID" python3 python3 "$D/versions/aicoding/aaa/bin/kanban-work" --hook
  inspectable 5201
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/aicoding/aaa" ]
  [ ! -e "$D/versions/aicoding/bbb" ]
  [ -d "$D/versions/aicoding/ccc" ]
  [[ "$output" != *"runs aicoding from a release"* ]]
}

@test "a named physical release next to current, or through a dot segment, still keeps the component" {
  mkver aicoding aaa; mkver aicoding bbb; mkver aicoding ccc
  point current aicoding ../versions/aicoding/ccc
  fakeproc 5202 "$UID" python3 python3 "$D/versions/aicoding/aaa/bin/kanban-work" "--lib=$D/current/aicoding/lib"
  inspectable 5202
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/aicoding/bbb" ]
  [[ "$output" == *"process 5202 (python3) runs aicoding from a release it does not hold open"* ]]
  rm -rf "$TEST_ROOT/proc/5202"
  fakeproc 5203 "$UID" python3 python3 "$D/versions/aicoding/aaa/../aaa/bin/kanban-work"
  inspectable 5203
  run aicoding_version_retention
  [ -d "$D/versions/aicoding/bbb" ]
  [ -d "$D/versions/aicoding/aaa" ]
}

# A Playwright browser cache as provisioning leaves it: mkcache VERSION [LINKED_PACKAGE].
mkcache() {
  local c="$D/browser-cache/mcp-playwright/$1"
  mkdir -p "$c/chromium-1/chrome-linux64" "$c/.links"
  printf '#!/bin/sh\n' > "$c/chromium-1/chrome-linux64/chrome"
  chmod +x "$c/chromium-1/chrome-linux64/chrome"
  head -c 4096 /dev/zero > "$c/chromium-1/payload"
  printf '%s' "${2:-$D/versions/mcp-playwright/$1/node_modules/playwright-core}" > "$c/.links/hash$1"
  printf '%s\n' "$c/chromium-1/chrome-linux64/chrome" > "$c/.browser-bin"
}

# mcp-playwright: 0.3 current, 0.2 previous.
mkplaywright() {
  mkver mcp-playwright 0.2; mkver mcp-playwright 0.3
  mkdir -p "$D/versions/mcp-playwright/0.2/node_modules/playwright-core" \
    "$D/versions/mcp-playwright/0.3/node_modules/playwright-core"
  point current mcp-playwright ../versions/mcp-playwright/0.3
  point previous mcp-playwright ../versions/mcp-playwright/0.2
}

@test "a browser cache follows its release" {
  mkplaywright
  mkcache 0.1; mkcache 0.2; mkcache 0.3
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ ! -e "$D/browser-cache/mcp-playwright/0.1" ]
  [ -d "$D/browser-cache/mcp-playwright/0.2" ]
  [ -d "$D/browser-cache/mcp-playwright/0.3" ]
  [[ "$output" == *"removed auxiliary tree browser-cache/mcp-playwright/0.1 ("*"KiB)"* ]]
  [[ "$output" == *"removed 1 auxiliary tree, freed "* ]]
  if compgen -G "$D/browser-cache/mcp-playwright/.*retired*" >/dev/null; then false; fi
  # A cache whose release was removed in this run starts its window on the next run.
  export AICODING_RETENTION_GRACE=3600
  mkver mcp-playwright 0.0.9; mkcache 0.0.9
  mkdir -p "$AICODING_STATE_DIR/retention/mcp-playwright"
  touch -d @"$(( $(date +%s) - 3700 ))" "$AICODING_STATE_DIR/retention/mcp-playwright/0.0.9"
  run aicoding_version_retention
  [ ! -e "$D/versions/mcp-playwright/0.0.9" ]
  [ -d "$D/browser-cache/mcp-playwright/0.0.9" ]
  [[ "$output" != *"auxiliary tree browser-cache/mcp-playwright/0.0.9"* ]]
  run aicoding_version_retention
  [ -d "$D/browser-cache/mcp-playwright/0.0.9" ]
  [[ "$output" == *"auxiliary tree browser-cache/mcp-playwright/0.0.9 unused since "*"; eligible for removal from "* ]]
}

@test "a browser cache another release or cache refers to is kept" {
  mkplaywright
  # Linked by a release that still exists.
  mkcache 0.0.7 "$D/versions/mcp-playwright/0.3/node_modules/playwright-core"
  # Linked by a package outside the data directory that still exists.
  mkdir -p "$TEST_ROOT/global/playwright-core"
  mkcache 0.0.6 "$TEST_ROOT/global/playwright-core"
  # A symlink in another cache resolves into it.
  mkcache 0.0.5
  mkcache 0.3
  ln -s ../0.0.5/chromium-1/chrome-linux64 "$D/browser-cache/mcp-playwright/0.3/old-chrome"
  # Another cache's marker names it.
  mkcache 0.0.4
  printf '%s\n' "$D/browser-cache/mcp-playwright/0.0.4/chromium-1/chrome-linux64/chrome" \
    > "$D/browser-cache/mcp-playwright/0.3/.browser-bin"
  # A link back into itself, and a link file that names a vanished package, keep nothing.
  mkcache 0.0.3
  ln -s chromium-1/chrome-linux64/chrome "$D/browser-cache/mcp-playwright/0.0.3/self"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/browser-cache/mcp-playwright/0.0.7" ]
  [ -d "$D/browser-cache/mcp-playwright/0.0.6" ]
  [ -d "$D/browser-cache/mcp-playwright/0.0.5" ]
  [ -d "$D/browser-cache/mcp-playwright/0.0.4" ]
  [ ! -e "$D/browser-cache/mcp-playwright/0.0.3" ]
  # A link file that cannot be read keeps its cache.
  [ "$(id -u)" -ne 0 ] || skip "root reads mode 000 files"
  mkcache 0.0.2
  chmod 000 "$D/browser-cache/mcp-playwright/0.0.2/.links/hash0.0.2"
  run aicoding_version_retention
  chmod 644 "$D/browser-cache/mcp-playwright/0.0.2/.links/hash0.0.2"
  [ -d "$D/browser-cache/mcp-playwright/0.0.2" ]
}

@test "a browser cache a process uses is kept" {
  mkplaywright
  mkcache 0.0.8; mkcache 0.0.7; mkcache 0.0.6; mkcache 0.0.5; mkcache 0.0.1
  fakeproc 5301 "$UID" chrome /opt/chrome --type=renderer
  inspectable 5301
  fake_exe 5301 "$D/browser-cache/mcp-playwright/0.0.8/chromium-1/chrome-linux64/chrome"
  fakeproc 5302 "$UID" helper /usr/bin/helper
  inspectable 5302
  printf '7f0000000000-7f0000001000 r--p 00000000 08:01 1234                       %s\n' \
    "$D/browser-cache/mcp-playwright/0.0.7/chromium-1/payload" > "$TEST_ROOT/proc/5302/maps"
  fakeproc 5303 "$UID" helper /usr/bin/helper
  inspectable 5303 "$D/browser-cache/mcp-playwright/0.0.6/chromium-1/payload"
  fakeproc 5304 "$UID" helper /usr/bin/helper "--browsers=$D/browser-cache/mcp-playwright/0.0.5"
  inspectable 5304
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/browser-cache/mcp-playwright/0.0.8" ]
  [ -d "$D/browser-cache/mcp-playwright/0.0.7" ]
  [ -d "$D/browser-cache/mcp-playwright/0.0.6" ]
  [ -d "$D/browser-cache/mcp-playwright/0.0.5" ]
  [ ! -e "$D/browser-cache/mcp-playwright/0.0.1" ]
}

@test "preview lists auxiliary candidates and removes none" {
  mkplaywright
  mkcache 0.1; mkcache 0.0.1
  export AICODING_RETENTION=preview
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/browser-cache/mcp-playwright/0.1" ]
  [ -d "$D/browser-cache/mcp-playwright/0.0.1" ]
  [[ "$output" == *"would remove auxiliary tree browser-cache/mcp-playwright/0.1 now ("* ]]
  [[ "$output" == *"would remove 2 auxiliary trees now, freeing "* ]]
  [ ! -e "$AICODING_STATE_DIR/retention" ]
}

@test "a component kept as a whole keeps its auxiliary trees" {
  mkplaywright
  mkcache 0.1
  mkdir -p "$AICODING_STATE_DIR/locks"
  exec {fd}>"$AICODING_STATE_DIR/locks/mcp-playwright.lock"
  flock -n "$fd"
  run aicoding_version_retention
  exec {fd}>&-
  [ "$status" -eq 0 ]
  [ -d "$D/browser-cache/mcp-playwright/0.1" ]
  # A process of mcp-playwright that holds none of its releases.
  fakeproc 5401 "$UID" node node "$D/current/mcp-playwright/cli.js"
  inspectable 5401
  run aicoding_version_retention
  [ -d "$D/browser-cache/mcp-playwright/0.1" ]
  rm -rf "$TEST_ROOT/proc/5401"
  fakeproc 5402 "$UID" idle /usr/bin/idle
  inspectable 5402
  run aicoding_version_retention
  [ ! -e "$D/browser-cache/mcp-playwright/0.1" ]
  # A missing release named by previous/ keeps every tree of the component.
  mkcache 0.0.5
  point previous mcp-playwright ../versions/mcp-playwright/0.0.5
  run aicoding_version_retention
  [ -d "$D/browser-cache/mcp-playwright/0.0.5" ]
}

@test "source snapshots are never pruned, renamed or stamped" {
  mkver dvw sha2
  point current dvw ../versions/dvw/sha2
  mkdir -p "$D/sources/dvw/sha1/bin" "$D/sources/dvw/local-checkout/.git" \
    "$D/sources/dvw/.aicoding-retired.sha0.abcdef"
  printf 'work\n' > "$D/sources/dvw/local-checkout/uncommitted"
  export AICODING_RETENTION=preview
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [[ "$output" != *"sources/"* ]]
  unset AICODING_RETENTION
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/sources/dvw/sha1/bin" ]
  [ -f "$D/sources/dvw/local-checkout/uncommitted" ]
  [ -d "$D/sources/dvw/.aicoding-retired.sha0.abcdef" ]
  [[ "$output" != *"sources/"* ]]
  export AICODING_RETENTION_GRACE=3600
  run aicoding_version_retention
  [ -d "$D/sources/dvw/sha1" ]
  if compgen -G "$AICODING_STATE_DIR/retention/.aux.sources*" >/dev/null; then false; fi
}

@test "a symlinked auxiliary root is never followed" {
  mkplaywright
  mkcache 0.1
  mv "$D/browser-cache" "$TEST_ROOT/elsewhere"
  ln -s "$TEST_ROOT/elsewhere" "$D/browser-cache"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$TEST_ROOT/elsewhere/mcp-playwright/0.1" ]
  rm "$D/browser-cache"
  mkdir -p "$D/browser-cache"
  ln -s "$TEST_ROOT/elsewhere/mcp-playwright" "$D/browser-cache/mcp-playwright"
  run aicoding_version_retention
  [ -d "$TEST_ROOT/elsewhere/mcp-playwright/0.1" ]
}

@test "a browser cache with a mount point inside is kept" {
  mkplaywright
  mkcache 0.0.1
  fakeproc 5501 "$UID" idle /usr/bin/idle
  inspectable 5501
  mkdir -p "$D/browser-cache/mcp-playwright/0.0.1/mnt"
  printf '907 1 0:99 / %s rw - tmpfs tmpfs rw\n' "$D/browser-cache/mcp-playwright/0.0.1/mnt" \
    >> "$TEST_ROOT/proc/self/mountinfo"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/browser-cache/mcp-playwright/0.0.1" ]
  [[ "$output" == *"auxiliary tree browser-cache/mcp-playwright/0.0.1 contains a mount point; kept"* ]]
}

@test "a browser cache without provisioning's markers is never touched or stamped" {
  export AICODING_RETENTION_GRACE=3600
  mkplaywright
  mkcache 0.0.1; mkcache 0.0.2; mkcache 0.0.3
  rm -rf "$D/browser-cache/mcp-playwright/0.0.1/.links"
  rm -f "$D/browser-cache/mcp-playwright/0.0.2/.browser-bin"
  mkdir -p "$D/browser-cache/mcp-playwright/handmade"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  local s="$AICODING_STATE_DIR/retention/.aux.browser-cache.mcp-playwright"
  [ -f "$s/0.0.3" ]
  [ ! -e "$s/0.0.1" ]
  [ ! -e "$s/0.0.2" ]
  [ ! -e "$s/handmade" ]
  export AICODING_RETENTION_GRACE=0
  run aicoding_version_retention
  [ ! -e "$D/browser-cache/mcp-playwright/0.0.3" ]
  [ -d "$D/browser-cache/mcp-playwright/0.0.1" ]
  [ -d "$D/browser-cache/mcp-playwright/0.0.2" ]
  [ -d "$D/browser-cache/mcp-playwright/handmade" ]
}

@test "only the program itself can name the release a process runs" {
  mkver cursor 1.0; mkver cursor 1.1; mkver cursor 1.2
  point current cursor ../versions/cursor/1.2
  launcher agent cursor bin/tool
  # A renamed node tool whose option names a release proves only that 1.1 is referenced.
  fakeproc 5601 "$UID" agent agent "--log=$D/versions/cursor/1.1/log"
  inspectable 5601
  fake_exe 5601 /usr/bin/node
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/cursor/1.0" ]
  [ -d "$D/versions/cursor/1.1" ]
  [[ "$output" == *"process 5601 (agent) runs cursor from a release it does not hold open"* ]]
  # An interpreter whose script lies elsewhere, with a release path further on.
  rm -rf "$TEST_ROOT/proc/5601"
  fakeproc 5602 "$UID" python3 /usr/bin/python3 /opt/x/run.py "$D/versions/cursor/1.1/bin/tool"
  inspectable 5602
  run aicoding_version_retention
  [ -d "$D/versions/cursor/1.0" ]
  [[ "$output" == *"process 5602 (python3) runs cursor from a release it does not hold open"* ]]
  # argv[0] inside the release, or the script an interpreter runs, names it.
  rm -rf "$TEST_ROOT/proc/5602"
  fakeproc 5603 "$UID" tool "$D/versions/cursor/1.1/bin/tool" --serve
  inspectable 5603
  fakeproc 5604 "$UID" python3.12 python3.12 -u "$D/versions/cursor/1.1/bin/tool"
  inspectable 5604
  run aicoding_version_retention
  [ ! -e "$D/versions/cursor/1.0" ]
  [ -d "$D/versions/cursor/1.1" ]
}

# The retention step of an older worker whose own release has a stub library.
_worker_retention() {
  (
    unset AICODINGSETUP_SKIP_NETWORK
    . "$TEST_ROOT/oldrel/lib/auto-update.sh"
    _aicoding_auto_version_retention
  )
}

@test "the fallback worker runs the retention library of the active aicoding release" {
  mkdir -p "$TEST_ROOT/oldrel/lib"
  cp "$BLUEPRINT_ROOT/lib/auto-update.sh" "$TEST_ROOT/oldrel/lib/"
  printf 'aicoding_version_retention() { echo old-retention; }\n' > "$TEST_ROOT/oldrel/lib/version-retention.sh"
  mkver aicoding sha1
  local lib="$D/versions/aicoding/sha1/lib/version-retention.sh"
  mkdir -p "${lib%/*}"
  printf 'aicoding_version_retention() { echo new-retention; }\n' > "$lib"
  point current aicoding ../versions/aicoding/sha1
  run _worker_retention
  [ "$status" -eq 0 ]
  [ "$output" = new-retention ]
  point current aicoding "$D/versions/aicoding/sha1"
  run _worker_retention
  [ "$output" = new-retention ]
  # Without a valid pointer or a regular library, the worker's own copy runs.
  point current aicoding ../versions/aicoding/missing
  run _worker_retention
  [ "$output" = old-retention ]
  point current aicoding ../versions/aicoding/sha1
  mv "$lib" "$lib.real"
  ln -s "$lib.real" "$lib"
  run _worker_retention
  [ "$output" = old-retention ]
  rm -f "$D/current/aicoding"
  run _worker_retention
  [ "$output" = old-retention ]
}

@test "a cache record that climbs out of its cache keeps every cache it reaches" {
  mkplaywright
  mkcache 0.3; mkcache 0.0.2; mkcache 0.0.1; mkcache 0.0.0
  printf '%s\n' "$D/browser-cache/mcp-playwright/0.3/../0.0.2/chromium-1/chrome-linux64/chrome" \
    > "$D/browser-cache/mcp-playwright/0.3/.browser-bin"
  printf '%s' "$D/browser-cache//mcp-playwright/./0.3/../../mcp-playwright/0.0.1/x" \
    > "$D/browser-cache/mcp-playwright/0.3/.links/other"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/browser-cache/mcp-playwright/0.0.2" ]
  [ -d "$D/browser-cache/mcp-playwright/0.0.1" ]
  [ ! -e "$D/browser-cache/mcp-playwright/0.0.0" ]
  # A relative record could name any cache.
  mkcache 0.0.0
  printf 'chromium-1/chrome-linux64/chrome\n' > "$D/browser-cache/mcp-playwright/0.3/.browser-bin"
  run aicoding_version_retention
  [ -d "$D/browser-cache/mcp-playwright/0.0.0" ]
  # So could a record that cannot be read.
  [ "$(id -u)" -ne 0 ] || skip "root reads mode 000 files"
  printf '%s\n' "$D/browser-cache/mcp-playwright/0.3/chromium-1/chrome-linux64/chrome" \
    > "$D/browser-cache/mcp-playwright/0.3/.browser-bin"
  chmod 000 "$D/browser-cache/mcp-playwright/0.3/.browser-bin"
  run aicoding_version_retention
  chmod 644 "$D/browser-cache/mcp-playwright/0.3/.browser-bin"
  [ -d "$D/browser-cache/mcp-playwright/0.0.0" ]
  run aicoding_version_retention
  [ ! -e "$D/browser-cache/mcp-playwright/0.0.0" ]
}

@test "repeated slashes on a command line still name a release or a cache" {
  mkver pi 1.0.0; mkver pi 1.1.0; mkver pi 1.2.0
  point current pi ../versions/pi/1.2.0
  mkplaywright
  mkcache 0.0.5; mkcache 0.0.4
  fakeproc 5701 "$UID" node node "$D//versions/pi//1.0.0/cli.js" \
    "--browsers=$D//browser-cache/mcp-playwright//0.0.5"
  inspectable 5701 "$D/versions/pi/1.2.0"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/pi/1.0.0" ]
  [ ! -e "$D/versions/pi/1.1.0" ]
  [ -d "$D/browser-cache/mcp-playwright/0.0.5" ]
  [ ! -e "$D/browser-cache/mcp-playwright/0.0.4" ]
}

@test "a process working on a cache root keeps every cache" {
  mkplaywright
  mkcache 0.0.1
  fakeproc 5801 "$UID" helper /usr/bin/helper
  inspectable 5801
  ln -sfn "$D/browser-cache" "$TEST_ROOT/proc/5801/cwd"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/browser-cache/mcp-playwright/0.0.1" ]
  # An open descriptor on either root counts the same.
  inspectable 5801 "$D/browser-cache"
  run aicoding_version_retention
  [ -d "$D/browser-cache/mcp-playwright/0.0.1" ]
  inspectable 5801 "$D/browser-cache/mcp-playwright"
  run aicoding_version_retention
  [ -d "$D/browser-cache/mcp-playwright/0.0.1" ]
  inspectable 5801 /dev/null
  run aicoding_version_retention
  [ ! -e "$D/browser-cache/mcp-playwright/0.0.1" ]
}

@test "a dangling link confined to its own cache or release keeps nothing" {
  mkplaywright
  mkcache 0.0.1; mkcache 0.0.2
  ln -s "$D/browser-cache/mcp-playwright/0.0.1/missing" "$D/browser-cache/mcp-playwright/0.0.1/self"
  mkver tool 1.0; mkver tool 2.0
  point current tool ../versions/tool/2.0
  ln -s "$D/versions/tool/1.0/missing" "$D/versions/tool/1.0/self"
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ ! -e "$D/browser-cache/mcp-playwright/0.0.1" ]
  [ ! -e "$D/browser-cache/mcp-playwright/0.0.2" ]
  [ ! -e "$D/versions/tool/1.0" ]
  # A dangling link into another cache keeps every cache.
  mkcache 0.0.1; mkcache 0.0.2; mkcache 0.0.3
  ln -s "$D/browser-cache/mcp-playwright/0.0.2/missing" "$D/browser-cache/mcp-playwright/0.0.1/other"
  run aicoding_version_retention
  [ -d "$D/browser-cache/mcp-playwright/0.0.1" ]
  [ -d "$D/browser-cache/mcp-playwright/0.0.2" ]
  [ -d "$D/browser-cache/mcp-playwright/0.0.3" ]
}

@test "a stamp that cannot be created keeps its candidate even with no window" {
  [ "$(id -u)" -ne 0 ] || skip "root writes read-only directories"
  mkplaywright
  mkcache 0.0.1
  mkdir -p "$AICODING_STATE_DIR/retention"
  chmod 0500 "$AICODING_STATE_DIR/retention"
  run aicoding_version_retention
  chmod 0700 "$AICODING_STATE_DIR/retention"
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
  [ -d "$D/browser-cache/mcp-playwright/0.0.1" ]
  [[ "$output" == *"cannot record when claude/1.0.0 was first seen unused"* ]]
}

@test "a release and its cache are never removed on the same run, and preview agrees" {
  mkplaywright
  mkver mcp-playwright 0.1; mkcache 0.1
  export AICODING_RETENTION=preview
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [[ "$output" == *"would remove mcp-playwright/0.1 now"* ]]
  [[ "$output" != *"auxiliary tree browser-cache/mcp-playwright/0.1"* ]]
  unset AICODING_RETENTION
  run aicoding_version_retention
  [ ! -e "$D/versions/mcp-playwright/0.1" ]
  [ -d "$D/browser-cache/mcp-playwright/0.1" ]
  [[ "$output" != *"auxiliary tree browser-cache/mcp-playwright/0.1"* ]]
  export AICODING_RETENTION=preview
  run aicoding_version_retention
  [[ "$output" == *"would remove auxiliary tree browser-cache/mcp-playwright/0.1 now"* ]]
  unset AICODING_RETENTION
  run aicoding_version_retention
  [ ! -e "$D/browser-cache/mcp-playwright/0.1" ]
}

@test "stamps of releases and of auxiliary trees never stand in for each other" {
  export AICODING_RETENTION_GRACE=3600
  mkplaywright
  local old=$(( $(date +%s) - 3700 )) r="$AICODING_STATE_DIR/retention"
  # An old release stamp for a version whose release is gone but whose cache remains.
  mkcache 0.0.9
  mkdir -p "$r/mcp-playwright"
  touch -d @"$old" "$r/mcp-playwright/0.0.9"
  # An old cache stamp for a release that is now unused for the first time.
  mkver mcp-playwright 0.1
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/browser-cache/mcp-playwright/0.0.9" ]
  [ -d "$D/versions/mcp-playwright/0.1" ]
  [ -f "$r/mcp-playwright/0.1" ]
  local aux=("$r"/.aux.*)
  [ "${#aux[@]}" -eq 1 ]
  [ -f "${aux[0]}/0.0.9" ]
  [ "$(stat -c %a "${aux[0]}")" = 700 ]
  [ ! -e "$r/mcp-playwright/0.0.9" ]
  # Once the cache's own stamp is old enough, it goes.
  touch -d @"$old" "${aux[0]}/0.0.9"
  run aicoding_version_retention
  [ ! -e "$D/browser-cache/mcp-playwright/0.0.9" ]
  [ ! -e "${aux[0]}/0.0.9" ]
  # An old aux stamp does not let the release go early.
  mkdir -p "${aux[0]}"
  touch -d @"$old" "${aux[0]}/0.1"
  rm -f "$r/mcp-playwright/0.1"
  run aicoding_version_retention
  [ -d "$D/versions/mcp-playwright/0.1" ]
}
