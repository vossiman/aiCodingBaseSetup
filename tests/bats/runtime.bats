#!/usr/bin/env bats

setup() {
  : "${BLUEPRINT_ROOT:?run via tests/bats/run.sh}"
  TEST_ROOT=$(mktemp -d)
  export HOME="$TEST_ROOT/home"
  export AICODING_DATA_DIR="$TEST_ROOT/data"
  export AICODING_STATE_DIR="$TEST_ROOT/state"
  mkdir -p "$HOME/.local/bin" "$TEST_ROOT/sources"
  # shellcheck source=../../lib/runtime.sh
  . "$BLUEPRINT_ROOT/lib/runtime.sh"
}

teardown() { rm -rf "$TEST_ROOT"; }

make_release() {
  local root=$1 version=$2 word=$3
  mkdir -p "$root/bin" "$root/lib"
  printf '%s\n' "$version" > "$root/.aicoding-version"
  cat > "$root/bin/tool" <<EOF
#!/usr/bin/env bash
sleep "\${AICODING_TEST_SLEEP:-0}"
. "\$(dirname "\$0")/../lib/value.sh"
printf '%s\\n' "\$VALUE"
EOF
  printf "VALUE='%s'\n" "$word" > "$root/lib/value.sh"
  chmod +x "$root/bin/tool"
}

@test "staging publishes an immutable copy and validates a reused release" {
  local version=0123456789abcdef0123456789abcdef01234567
  make_release "$TEST_ROOT/sources/one" "$version" one

  run aicoding_stage_source demo "$TEST_ROOT/sources/one" "$version"
  [ "$status" -eq 0 ]
  [ -x "$AICODING_DATA_DIR/versions/demo/$version/bin/tool" ]

  printf "VALUE='changed-source'\n" > "$TEST_ROOT/sources/one/lib/value.sh"
  run aicoding_stage_source demo "$TEST_ROOT/sources/one" "$version"
  [ "$status" -eq 0 ]
  grep -q "VALUE='one'" "$AICODING_DATA_DIR/versions/demo/$version/lib/value.sh"

  printf 'wrong\n' > "$AICODING_DATA_DIR/versions/demo/$version/.aicoding-version"
  run aicoding_stage_source demo "$TEST_ROOT/sources/one" "$version"
  [ "$status" -ne 0 ]
}

@test "staging rejects a reused release whose retained resources changed" {
  local version=0123456789abcdef0123456789abcdef01234568
  make_release "$TEST_ROOT/sources/one" "$version" one
  aicoding_stage_source demo "$TEST_ROOT/sources/one" "$version"
  printf "VALUE='tampered'\n" > "$AICODING_DATA_DIR/versions/demo/$version/lib/value.sh"

  run aicoding_stage_source demo "$TEST_ROOT/sources/one" "$version"
  [ "$status" -ne 0 ]
}

@test "source staging rejects symlink resources" {
  local version=0123456789abcdef0123456789abcdef0123456a
  make_release "$TEST_ROOT/sources/one" "$version" one
  printf 'outside\n' > "$TEST_ROOT/outside"
  ln -s "$TEST_ROOT/outside" "$TEST_ROOT/sources/one/lib/external"

  run aicoding_stage_source demo "$TEST_ROOT/sources/one" "$version"
  [ "$status" -ne 0 ]
  [ ! -e "$AICODING_DATA_DIR/versions/demo/$version" ]
}

@test "source publication never nests a losing concurrent staging tree" {
  mkdir -p "$TEST_ROOT/stage" "$TEST_ROOT/final"
  printf 'candidate\n' > "$TEST_ROOT/stage/candidate"
  printf 'winner\n' > "$TEST_ROOT/final/winner"

  run _aicoding_runtime_publish_release "$TEST_ROOT/stage" "$TEST_ROOT/final"
  [ "$status" -ne 0 ]
  [ "$(cat "$TEST_ROOT/final/winner")" = winner ]
  [ ! -e "$TEST_ROOT/final/stage" ]
}

@test "activation accepts a package-local executable link but rejects an external one" {
  local version=0123456789abcdef0123456789abcdef0123456b
  local release="$AICODING_DATA_DIR/versions/vendor/$version"
  make_release "$release" "$version" vendor
  ln -s tool "$release/bin/package-bin"

  run aicoding_activate_version vendor "$version" vendor-tool bin/package-bin
  [ "$status" -eq 0 ]
  run "$HOME/.local/bin/vendor-tool"
  [ "$status" -eq 0 ]
  [ "$output" = vendor ]

  rm "$release/bin/package-bin"
  ln -s "$TEST_ROOT/outside-tool" "$release/bin/package-bin"
  printf '#!/bin/sh\nexit 0\n' > "$TEST_ROOT/outside-tool"
  chmod +x "$TEST_ROOT/outside-tool"
  run aicoding_activate_version vendor "$version" vendor-tool bin/package-bin
  [ "$status" -ne 0 ]
}

@test "interrupted source staging removes its unpublished temporary tree" {
  local version=0123456789abcdef0123456789abcdef01234569
  make_release "$TEST_ROOT/sources/one" "$version" one
  _aicoding_runtime_copy_source() {
    command cp -a "$1/." "$2/"
    kill -TERM "$BASHPID"
  }

  run aicoding_stage_source demo "$TEST_ROOT/sources/one" "$version"
  [ "$status" -eq 143 ]
  [[ "$output" == *"staging interrupted by TERM"* ]]
  [ ! -e "$AICODING_DATA_DIR/versions/demo/$version" ]
  ! find "$AICODING_DATA_DIR/versions/demo" -maxdepth 1 -name '.staging.*' -print -quit | grep -q .
}

@test "a running physical script keeps old resources while a fresh launcher uses new" {
  local old=1111111111111111111111111111111111111111
  local new=2222222222222222222222222222222222222222
  make_release "$TEST_ROOT/sources/old" "$old" old
  make_release "$TEST_ROOT/sources/new" "$new" new
  aicoding_stage_source demo "$TEST_ROOT/sources/old" "$old"
  aicoding_activate_version demo "$old" demo-tool bin/tool

  AICODING_TEST_SLEEP=1 "$HOME/.local/bin/demo-tool" > "$TEST_ROOT/running.out" &
  local pid=$!
  sleep 0.2
  aicoding_stage_source demo "$TEST_ROOT/sources/new" "$new"
  aicoding_activate_version demo "$new" demo-tool bin/tool
  wait "$pid"

  [ "$(cat "$TEST_ROOT/running.out")" = old ]
  run "$HOME/.local/bin/demo-tool"
  [ "$status" -eq 0 ]
  [ "$output" = new ]
  [ "$(readlink "$AICODING_DATA_DIR/previous/demo")" = "../versions/demo/$old" ]
}

@test "managed wrappers safely handle data paths containing shell metacharacters" {
  export AICODING_DATA_DIR="$TEST_ROOT/data with spaces and \$(touch SHOULD_NOT_EXIST)"
  local version=3333333333333333333333333333333333333333
  make_release "$TEST_ROOT/sources/quoted" "$version" quoted
  aicoding_stage_source demo "$TEST_ROOT/sources/quoted" "$version"
  aicoding_activate_version demo "$version" demo-tool bin/tool

  run "$HOME/.local/bin/demo-tool"
  [ "$status" -eq 0 ]
  [ "$output" = quoted ]
  [ ! -e "$PWD/SHOULD_NOT_EXIST" ]
}

@test "activation rejects a reused release whose launcher disappeared before switching" {
  local old=4444444444444444444444444444444444444444
  local new=5555555555555555555555555555555555555555
  make_release "$TEST_ROOT/sources/old" "$old" old
  make_release "$TEST_ROOT/sources/new" "$new" new
  aicoding_stage_source demo "$TEST_ROOT/sources/old" "$old"
  aicoding_activate_version demo "$old" demo-tool bin/tool
  aicoding_stage_source demo "$TEST_ROOT/sources/new" "$new"
  rm "$AICODING_DATA_DIR/versions/demo/$new/bin/tool"

  run aicoding_activate_version demo "$new" demo-tool bin/tool
  [ "$status" -ne 0 ]
  run "$HOME/.local/bin/demo-tool"
  [ "$output" = old ]
  [ "$(readlink "$AICODING_DATA_DIR/current/demo")" = "../versions/demo/$old" ]
}

@test "first managed activation retains an unknown legacy launcher byte for byte" {
  local version=6666666666666666666666666666666666666666
  make_release "$TEST_ROOT/sources/new" "$version" new
  printf '#!/bin/sh\nprintf legacy\\n\n' > "$HOME/.local/bin/demo-tool"
  chmod +x "$HOME/.local/bin/demo-tool"
  cp -a "$HOME/.local/bin/demo-tool" "$TEST_ROOT/expected"

  aicoding_stage_source demo "$TEST_ROOT/sources/new" "$version"
  aicoding_activate_version demo "$version" demo-tool bin/tool

  cmp "$TEST_ROOT/expected" "$HOME/.local/bin/demo-tool.pre-aicoding"
  run "$HOME/.local/bin/demo-tool"
  [ "$output" = new ]
}

@test "managed upgrade prepares wrappers and previous before current is published" {
  local old=7777777777777777777777777777777777777777
  local new=8888888888888888888888888888888888888888
  make_release "$TEST_ROOT/sources/old" "$old" old
  make_release "$TEST_ROOT/sources/new" "$new" new
  cp "$TEST_ROOT/sources/old/bin/tool" "$TEST_ROOT/sources/old/bin/tool-v2"
  cp "$TEST_ROOT/sources/new/bin/tool" "$TEST_ROOT/sources/new/bin/tool-v2"
  aicoding_stage_source demo "$TEST_ROOT/sources/old" "$old"
  aicoding_activate_version demo "$old" demo-tool bin/tool
  aicoding_stage_source demo "$TEST_ROOT/sources/new" "$new"

  _aicoding_runtime_commit_current() {
    [ "$(readlink "$AICODING_DATA_DIR/previous/demo")" = "../versions/demo/$old" ] || return 81
    "$HOME/.local/bin/demo-tool" > "$TEST_ROOT/before-current"
    local tmp="$1/.${2}.test"
    command ln -s "$3" "$tmp" && command mv -Tf "$tmp" "$1/$2"
  }
  run aicoding_activate_version demo "$new" demo-tool bin/tool-v2
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_ROOT/before-current")" = old ]
  [ "$(readlink "$AICODING_DATA_DIR/current/demo")" = "../versions/demo/$new" ]
  run "$HOME/.local/bin/demo-tool"
  [ "$output" = new ]
}

@test "byte-identical managed wrappers are not replaced" {
  local old=9999999999999999999999999999999999999999
  local new=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  make_release "$TEST_ROOT/sources/old" "$old" old
  make_release "$TEST_ROOT/sources/new" "$new" new
  aicoding_stage_source demo "$TEST_ROOT/sources/old" "$old"
  aicoding_activate_version demo "$old" demo-tool bin/tool
  local inode_before
  inode_before=$(stat -c %i "$HOME/.local/bin/demo-tool")
  aicoding_stage_source demo "$TEST_ROOT/sources/new" "$new"
  _aicoding_runtime_commit_wrapper() { return 91; }

  run aicoding_activate_version demo "$new" demo-tool bin/tool
  [ "$status" -eq 0 ]
  [ "$(stat -c %i "$HOME/.local/bin/demo-tool")" = "$inode_before" ]
  run "$HOME/.local/bin/demo-tool"
  [ "$output" = new ]
}

@test "managed wrapper failure leaves current and previous unchanged" {
  local old=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  local new=cccccccccccccccccccccccccccccccccccccccc
  make_release "$TEST_ROOT/sources/old" "$old" old
  make_release "$TEST_ROOT/sources/new" "$new" new
  cp "$TEST_ROOT/sources/old/bin/tool" "$TEST_ROOT/sources/old/bin/tool-v2"
  cp "$TEST_ROOT/sources/new/bin/tool" "$TEST_ROOT/sources/new/bin/tool-v2"
  aicoding_stage_source demo "$TEST_ROOT/sources/old" "$old"
  aicoding_activate_version demo "$old" demo-tool bin/tool
  aicoding_stage_source demo "$TEST_ROOT/sources/new" "$new"
  _aicoding_runtime_commit_wrapper() { return 1; }

  run aicoding_activate_version demo "$new" demo-tool bin/tool-v2
  [ "$status" -ne 0 ]
  [ "$(readlink "$AICODING_DATA_DIR/current/demo")" = "../versions/demo/$old" ]
  [ ! -e "$AICODING_DATA_DIR/previous/demo" ]
  run "$HOME/.local/bin/demo-tool"
  [ "$output" = old ]
}

@test "managed previous-pointer failure occurs before wrapper or current changes" {
  local old=dddddddddddddddddddddddddddddddddddddddd
  local new=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  make_release "$TEST_ROOT/sources/old" "$old" old
  make_release "$TEST_ROOT/sources/new" "$new" new
  aicoding_stage_source demo "$TEST_ROOT/sources/old" "$old"
  aicoding_activate_version demo "$old" demo-tool bin/tool
  aicoding_stage_source demo "$TEST_ROOT/sources/new" "$new"
  _aicoding_runtime_commit_previous() { return 1; }
  _aicoding_runtime_commit_wrapper() { : > "$TEST_ROOT/wrapper-touched"; return 1; }

  run aicoding_activate_version demo "$new" demo-tool bin/tool
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_ROOT/wrapper-touched" ]
  [ "$(readlink "$AICODING_DATA_DIR/current/demo")" = "../versions/demo/$old" ]
  [ ! -e "$AICODING_DATA_DIR/previous/demo" ]
}

@test "first enrollment keeps a legacy launcher until current points to the target" {
  local version=ffffffffffffffffffffffffffffffffffffffff
  make_release "$TEST_ROOT/sources/new" "$version" new
  printf '#!/bin/sh\nprintf "legacy\\n"\n' > "$HOME/.local/bin/demo-tool"
  chmod +x "$HOME/.local/bin/demo-tool"
  aicoding_stage_source demo "$TEST_ROOT/sources/new" "$version"
  _aicoding_runtime_commit_wrapper() {
    [ "$(readlink "$AICODING_DATA_DIR/current/demo")" = "../versions/demo/$version" ] || return 82
    "$2" > "$TEST_ROOT/during-enrollment"
    command mv -Tf "$1" "$2"
  }

  run aicoding_activate_version demo "$version" demo-tool bin/tool
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_ROOT/during-enrollment")" = legacy ]
  run "$HOME/.local/bin/demo-tool"
  [ "$output" = new ]
}

@test "failed fresh enrollment removes its prepared pointer and launcher" {
  local version=1010101010101010101010101010101010101010
  make_release "$TEST_ROOT/sources/new" "$version" new
  aicoding_stage_source demo "$TEST_ROOT/sources/new" "$version"
  _aicoding_runtime_commit_wrapper() { return 1; }

  run aicoding_activate_version demo "$version" demo-tool bin/tool
  [ "$status" -ne 0 ]
  [ ! -e "$AICODING_DATA_DIR/current/demo" ]
  [ ! -e "$HOME/.local/bin/demo-tool" ]
}

@test "current switch failure rolls back prepared wrapper and previous pointer" {
  local old=2020202020202020202020202020202020202020
  local new=3030303030303030303030303030303030303030
  make_release "$TEST_ROOT/sources/old" "$old" old
  make_release "$TEST_ROOT/sources/new" "$new" new
  cp "$TEST_ROOT/sources/old/bin/tool" "$TEST_ROOT/sources/old/bin/tool-v2"
  cp "$TEST_ROOT/sources/new/bin/tool" "$TEST_ROOT/sources/new/bin/tool-v2"
  aicoding_stage_source demo "$TEST_ROOT/sources/old" "$old"
  aicoding_activate_version demo "$old" demo-tool bin/tool
  aicoding_stage_source demo "$TEST_ROOT/sources/new" "$new"
  _aicoding_runtime_commit_current() { return 1; }

  run aicoding_activate_version demo "$new" demo-tool bin/tool-v2
  [ "$status" -ne 0 ]
  [ "$(readlink "$AICODING_DATA_DIR/current/demo")" = "../versions/demo/$old" ]
  [ ! -e "$AICODING_DATA_DIR/previous/demo" ]
  run "$HOME/.local/bin/demo-tool"
  [ "$output" = old ]
}

@test "current publication stays committed when only empty temp cleanup fails" {
  local old=3131313131313131313131313131313131313131
  local new=3232323232323232323232323232323232323232
  make_release "$TEST_ROOT/sources/old" "$old" old
  make_release "$TEST_ROOT/sources/new" "$new" new
  aicoding_stage_source demo "$TEST_ROOT/sources/old" "$old"
  aicoding_activate_version demo "$old" demo-tool bin/tool
  aicoding_stage_source demo "$TEST_ROOT/sources/new" "$new"
  rmdir() {
    local candidate=${!#}
    case "$candidate" in
      "$AICODING_DATA_DIR/current/.demo.link."*) return 1 ;;
      *) command rmdir "$@" ;;
    esac
  }

  run aicoding_activate_version demo "$new" demo-tool bin/tool
  [ "$status" -eq 0 ]
  [[ "$output" == *"pointer published; empty temporary directory retained at"* ]]
  [ "$(readlink "$AICODING_DATA_DIR/current/demo")" = "../versions/demo/$new" ]
  [ "$(readlink "$AICODING_DATA_DIR/previous/demo")" = "../versions/demo/$old" ]
  find "$AICODING_DATA_DIR/current" -maxdepth 1 -type d -name '.demo.link.*' -print -quit | grep -q .
  run "$HOME/.local/bin/demo-tool"
  [ "$status" -eq 0 ]
  [ "$output" = new ]
}

@test "incomplete rollback retains the recovery snapshot and reports its path" {
  local old=4040404040404040404040404040404040404040
  local new=5050505050505050505050505050505050505050
  make_release "$TEST_ROOT/sources/old" "$old" old
  make_release "$TEST_ROOT/sources/new" "$new" new
  aicoding_stage_source demo "$TEST_ROOT/sources/old" "$old"
  aicoding_activate_version demo "$old" demo-tool bin/tool
  aicoding_stage_source demo "$TEST_ROOT/sources/new" "$new"
  _aicoding_runtime_commit_current() {
    local tmp="$1/.${2}.test"
    command ln -s "$3" "$tmp" && command mv -Tf "$tmp" "$1/$2"
    return 1
  }
  _aicoding_runtime_restore_path() {
    if [ "$2" = "$AICODING_DATA_DIR/current/demo" ]; then return 1; fi
    command rm -f -- "$2" || return 1
    [ "$3" -eq 1 ] || return 0
    command cp -a --no-dereference -- "$1" "$2"
  }

  run aicoding_activate_version demo "$new" demo-tool bin/tool
  [ "$status" -ne 0 ]
  [[ "$output" == *"rollback incomplete; recovery retained at"* ]]
  local recovery
  recovery=$(find "$AICODING_STATE_DIR/activation-recovery" -mindepth 1 -maxdepth 1 -type d -print -quit)
  [ -n "$recovery" ]
  [ -L "$recovery/current" ]
  [ "$(readlink "$AICODING_DATA_DIR/current/demo")" = "../versions/demo/$new" ]
}

@test "TERM INT and HUP interruptions roll managed activation back" {
  local old=6060606060606060606060606060606060606060
  local new=7070707070707070707070707070707070707070 signal expected
  make_release "$TEST_ROOT/sources/old" "$old" old
  make_release "$TEST_ROOT/sources/new" "$new" new
  aicoding_stage_source demo "$TEST_ROOT/sources/old" "$old"
  aicoding_activate_version demo "$old" demo-tool bin/tool
  aicoding_stage_source demo "$TEST_ROOT/sources/new" "$new"
  for signal in TERM INT HUP; do
    case "$signal" in TERM) expected=143 ;; INT) expected=130 ;; HUP) expected=129 ;; esac
    # Bats parallel workers launch test bodies asynchronously, which makes
    # their children inherit SIGINT ignored. Reset the selected disposition
    # before Bash starts so the runtime's real signal trap is exercised.
    run env --default-signal="$signal" bash -c '
      . "$BLUEPRINT_ROOT/lib/runtime.sh"
      TEST_SIGNAL=$1
      _aicoding_runtime_commit_current() { kill "-$TEST_SIGNAL" "$BASHPID"; }
      aicoding_activate_version demo "$2" demo-tool bin/tool
    ' signal-test "$signal" "$new"
    [ "$status" -eq "$expected" ]
    [[ "$output" == *"activation interrupted by $signal"* ]]
    [ "$(readlink "$AICODING_DATA_DIR/current/demo")" = "../versions/demo/$old" ]
    [ ! -e "$AICODING_DATA_DIR/previous/demo" ]
    run "$HOME/.local/bin/demo-tool"
    [ "$status" -eq 0 ]
    [ "$output" = old ]
  done
}
