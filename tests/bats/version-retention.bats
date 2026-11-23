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

@test "a version younger than the grace period survives" {
  export AICODING_RETENTION_GRACE=3600
  run aicoding_version_retention
  [ "$status" -eq 0 ]
  [ -d "$D/versions/claude/1.0.0" ]
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
  [[ "$output" == *"would remove claude/1.0.0 ("* ]]
  [[ "$output" != *"would remove claude/1.0.1"* ]]
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
