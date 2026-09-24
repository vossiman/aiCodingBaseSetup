#!/usr/bin/env bats
# Staging a newly selected blueprint sources its lib/blueprint-deploy.sh, and
# that removes Python bytecode written into an immutable release after it was
# staged. Old releases execute new code only through that staging step, so it
# is how a container stuck on a corrupt current release heals itself. A
# bounded background healer keeps the release clean until activation.

setup() {
  : "${BLUEPRINT_ROOT:?run via run.sh}"
  TEST_ROOT=$(mktemp -d)
  export HOME="$TEST_ROOT/home"
  export AICODING_DATA_DIR="$TEST_ROOT/data"
  export AICODING_STATE_DIR="$TEST_ROOT/state"
  export AICODING_MANIFEST="$TEST_ROOT/manifest.json"
  export AICODING_RELEASE_HEALER_SECONDS=4
  export AICODING_RELEASE_HEALER_INTERVAL=0.1
  mkdir -p "$HOME"
  SHA=0123456789abcdef0123456789abcdef01234567
  NEW_SHA=89abcdef0123456789abcdef0123456789abcdef
  RELEASE="$AICODING_DATA_DIR/versions/aicoding/$SHA"
  LOCK="$AICODING_STATE_DIR/release-bytecode-healer.lock"
}

teardown() {
  _wait_healer_idle 10 || true
  rm -rf "$TEST_ROOT"
}

# Stage a release with the real runtime staging function. The source carries
# a tracked __pycache__ (the repo tracks tools/render-debug/__pycache__), so
# the release digest legitimately covers that bytecode. Source mtimes are set
# in the past so bytecode written later is recognisably newer than staging.
_stage_release() {
  local source="$TEST_ROOT/source"
  mkdir -p "$source/lib/kanban_work" "$source/tools/render-debug/__pycache__"
  printf 'print(1)\n' > "$source/lib/kanban_work/store.py"
  printf 'tracked\n' > "$source/tools/render-debug/__pycache__/harness.pyc"
  printf '%s\n' "$SHA" > "$source/.aicoding-version"
  find "$source" -exec touch -h -d '2000-01-01 00:00:00' {} +
  (
    . "$BLUEPRINT_ROOT/lib/runtime.sh"
    aicoding_stage_source aicoding "$source" "$SHA"
  )
  rm -rf "$source"
  mkdir -p "$AICODING_DATA_DIR/current"
  ln -sfn "../versions/aicoding/$SHA" "$AICODING_DATA_DIR/current/aicoding"
}

_validate_release() {
  ( . "$BLUEPRINT_ROOT/lib/runtime.sh"; _aicoding_runtime_validate_release aicoding "$SHA" )
}

_corrupt_release() {
  mkdir -p "$RELEASE/lib/kanban_work/__pycache__"
  printf 'bytecode\n' > "$RELEASE/lib/kanban_work/__pycache__/store.cpython-314.pyc"
}

# A minimal staging clone at the path old and new sync code use:
# $AICODING_DATA_DIR/source-staging/aicoding.<sha>.<pid>, with a .git dir.
_make_stage() {
  local data=${1:-$AICODING_DATA_DIR}
  STAGE="$data/source-staging/aicoding.$NEW_SHA.$$"
  mkdir -p "$STAGE/lib" "$STAGE/.git"
  cp "$BLUEPRINT_ROOT"/lib/*.sh "$STAGE/lib/"
}

# Source the stage's library the way _sync_capture_generated_provenance does.
_source_stage() {
  AICODING_BLUEPRINT_CLONE="$STAGE" bash -c 'set -euo pipefail; . "$1/lib/blueprint-deploy.sh"' _ "$STAGE"
}

# True once no healer holds the single-instance lock.
_wait_healer_idle() {
  local tries=$(( ${1:-10} * 10 ))
  [ -e "$LOCK" ] || return 0
  while [ "$tries" -gt 0 ]; do
    flock -n "$LOCK" true 2>/dev/null && return 0
    sleep 0.1; tries=$((tries - 1))
  done
  return 1
}

@test "staging removes bytecode written into a release and restores validity" {
  _stage_release
  _corrupt_release
  run _validate_release
  [ "$status" -ne 0 ]
  _make_stage
  run _source_stage
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$RELEASE/lib/kanban_work/__pycache__" ]
  [ "$(cat "$RELEASE/lib/kanban_work/store.py")" = 'print(1)' ]
  [ "$(cat "$RELEASE/tools/render-debug/__pycache__/harness.pyc")" = tracked ]
  run _validate_release
  [ "$status" -eq 0 ]
}

@test "ordinary sourcing (reconcile, dry-run) never touches releases" {
  _stage_release
  _corrupt_release
  run env AICODING_BLUEPRINT_CLONE="$BLUEPRINT_ROOT" bash -c 'set -euo pipefail; . "$1/lib/blueprint-deploy.sh"' _ "$BLUEPRINT_ROOT"
  [ "$status" -eq 0 ]
  [ -f "$RELEASE/lib/kanban_work/__pycache__/store.cpython-314.pyc" ]
  [ ! -e "$LOCK" ]
}

@test "a staging-shaped tree sourced outside its staging context never touches releases" {
  _stage_release
  _corrupt_release
  _make_stage
  # Clone variable points elsewhere: not the provenance capture subshell.
  run env AICODING_BLUEPRINT_CLONE="$BLUEPRINT_ROOT" bash -c '. "$1/lib/blueprint-deploy.sh"' _ "$STAGE"
  [ "$status" -eq 0 ]
  [ -f "$RELEASE/lib/kanban_work/__pycache__/store.cpython-314.pyc" ]
  # No .git dir: not a fresh staging clone.
  rm -rf "$STAGE/.git"
  run _source_stage
  [ "$status" -eq 0 ]
  [ -f "$RELEASE/lib/kanban_work/__pycache__/store.cpython-314.pyc" ]
}

@test "aicoding-sync --dry-run leaves release bytecode alone" {
  _stage_release
  _corrupt_release
  run env AICODING_BLUEPRINT_CLONE="$BLUEPRINT_ROOT" AICODING_BLUEPRINT_LOCAL=1 \
    AICODINGSETUP_NONINTERACTIVE=1 bash "$BLUEPRINT_ROOT/bin/aicoding-sync" --dry-run
  [ -f "$RELEASE/lib/kanban_work/__pycache__/store.cpython-314.pyc" ]
}

@test "staging keeps bytecode that the release digest covers" {
  _stage_release
  touch "$RELEASE/tools/render-debug/__pycache__"
  _make_stage
  run _source_stage
  [ "$status" -eq 0 ]
  [ -f "$RELEASE/tools/render-debug/__pycache__/harness.pyc" ]
  run _validate_release
  [ "$status" -eq 0 ]
}

@test "staging leaves a release alone when removing bytecode would not restore its digest" {
  _stage_release
  _corrupt_release
  printf 'tampered\n' >> "$RELEASE/lib/kanban_work/store.py"
  _make_stage
  run _source_stage
  [ "$status" -eq 0 ]
  [ -f "$RELEASE/lib/kanban_work/__pycache__/store.cpython-314.pyc" ]
}

@test "staging never follows symlinks out of the versions tree" {
  local outside="$TEST_ROOT/outside"
  mkdir -p "$outside/rel/__pycache__" "$outside/inner/__pycache__"
  printf 'x\n' > "$outside/rel/__pycache__/a.pyc"
  printf 'x\n' > "$outside/inner/__pycache__/b.pyc"
  printf '%s\n' "$(printf '0%.0s' {1..64})" > "$outside/rel/.aicoding-tree.sha256"
  touch -d '2000-01-01 00:00:00' "$outside/rel/.aicoding-tree.sha256"
  mkdir -p "$AICODING_DATA_DIR/versions/aicoding"
  ln -s "$outside/rel" "$AICODING_DATA_DIR/versions/aicoding/linked"
  _stage_release
  ln -s "$outside/inner" "$RELEASE/lib/escape"
  _corrupt_release
  _make_stage
  run _source_stage
  [ "$status" -eq 0 ]
  [ -f "$outside/rel/__pycache__/a.pyc" ]
  [ -f "$outside/inner/__pycache__/b.pyc" ]
}

@test "staging never follows a symlinked versions directory" {
  local outside="$TEST_ROOT/outside-versions"
  mkdir -p "$outside/aicoding/$SHA/__pycache__" "$AICODING_DATA_DIR"
  printf 'x\n' > "$outside/aicoding/$SHA/__pycache__/a.pyc"
  printf '%s\n' "$(printf '0%.0s' {1..64})" > "$outside/aicoding/$SHA/.aicoding-tree.sha256"
  touch -d '2000-01-01 00:00:00' "$outside/aicoding/$SHA/.aicoding-tree.sha256"
  ln -s "$outside" "$AICODING_DATA_DIR/versions"
  _make_stage
  run _source_stage
  [ "$status" -eq 0 ]
  [ -f "$outside/aicoding/$SHA/__pycache__/a.pyc" ]
}

@test "sourcing without a versions directory or data dir variable succeeds under set -u" {
  run bash -c 'set -euo pipefail; . "$1/lib/blueprint-deploy.sh"; echo sourced' _ "$BLUEPRINT_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = sourced ]
  _make_stage
  run env -u AICODING_DATA_DIR AICODING_BLUEPRINT_CLONE="$STAGE" bash -c 'set -euo pipefail; shopt -s failglob; . "$1/lib/blueprint-deploy.sh"; echo sourced' _ "$STAGE"
  [ "$status" -eq 0 ]
  [ "$output" = sourced ]
}

@test "the default data dir under HOME is healed when AICODING_DATA_DIR is unset" {
  _stage_release
  _corrupt_release
  mkdir -p "$HOME/.local/share"
  mv "$AICODING_DATA_DIR" "$HOME/.local/share/aicoding"
  _make_stage "$HOME/.local/share/aicoding"
  run env -u AICODING_DATA_DIR AICODING_BLUEPRINT_CLONE="$STAGE" bash -c 'set -euo pipefail; . "$1/lib/blueprint-deploy.sh"' _ "$STAGE"
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.local/share/aicoding/versions/aicoding/$SHA/lib/kanban_work/__pycache__" ]
}

@test "the source-time heal runs once per process" {
  _stage_release
  _make_stage
  export AICODING_RELEASE_HEALER_SECONDS=0
  run env AICODING_BLUEPRINT_CLONE="$STAGE" bash -c '. "$1/lib/blueprint-deploy.sh"
    mkdir -p "$2/lib/kanban_work/__pycache__"
    printf x > "$2/lib/kanban_work/__pycache__/late.pyc"
    . "$1/lib/blueprint-deploy.sh"
    [ -f "$2/lib/kanban_work/__pycache__/late.pyc" ]' _ "$STAGE" "$RELEASE"
  [ "$status" -eq 0 ]
}

@test "background healer removes bytecode recreated before activation, keeps tracked bytecode, then exits" {
  _stage_release
  _corrupt_release
  _make_stage
  run _source_stage
  [ "$status" -eq 0 ]
  [ ! -e "$RELEASE/lib/kanban_work/__pycache__" ]
  # An old kanban-work hook recreates the bytecode after the first heal.
  sleep 0.3
  _corrupt_release
  local tries=30
  while [ -e "$RELEASE/lib/kanban_work/__pycache__" ] && [ "$tries" -gt 0 ]; do
    sleep 0.1; tries=$((tries - 1))
  done
  [ ! -e "$RELEASE/lib/kanban_work/__pycache__" ]
  [ -f "$RELEASE/tools/render-debug/__pycache__/harness.pyc" ]
  run _validate_release
  [ "$status" -eq 0 ]
  # Still running: activation has not happened yet.
  run flock -n "$LOCK" true
  [ "$status" -ne 0 ]
  # Activation of the staged release ends the healer well before its deadline.
  mkdir -p "$AICODING_DATA_DIR/versions/aicoding/$NEW_SHA"
  ln -sfn "../versions/aicoding/$NEW_SHA" "$AICODING_DATA_DIR/current/aicoding"
  _wait_healer_idle 2
}

@test "background healer stops at its deadline" {
  _stage_release
  _make_stage
  export AICODING_RELEASE_HEALER_SECONDS=1
  run _source_stage
  [ "$status" -eq 0 ]
  sleep 0.3
  run flock -n "$LOCK" true
  [ "$status" -ne 0 ]
  _wait_healer_idle 3
}

@test "only one background healer runs at a time" {
  _stage_release
  _make_stage
  mkdir -p "$AICODING_STATE_DIR"
  flock "$LOCK" sleep 3 3>&- &
  local holder=$!
  sleep 0.3
  _corrupt_release
  run _source_stage
  [ "$status" -eq 0 ]
  # The source-time heal still ran.
  [ ! -e "$RELEASE/lib/kanban_work/__pycache__" ]
  # No second healer: recreated bytecode stays while the lock is held.
  sleep 0.2
  _corrupt_release
  sleep 1
  [ -e "$RELEASE/lib/kanban_work/__pycache__" ]
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
}

@test "staging a new blueprint heals a corrupt current release before activation" {
  _stage_release
  _corrupt_release
  # The old code path: _sync_capture_generated_provenance sources the NEW
  # stage's lib/blueprint-deploy.sh before activation validates current.
  local stage="$AICODING_DATA_DIR/source-staging/aicoding.$NEW_SHA.$$"
  mkdir -p "$stage"
  tar -C "$BLUEPRINT_ROOT" --exclude=./.git --exclude=./.claude --exclude=./out \
    --exclude=__pycache__ -cf - . | tar -C "$stage" -xf -
  git -C "$stage" init --quiet
  git -C "$stage" -c user.name=t -c user.email=t@example.invalid add -A
  git -C "$stage" -c user.name=t -c user.email=t@example.invalid commit --quiet -m stage
  run _validate_release
  [ "$status" -ne 0 ]

  run bash -c '. "$1/lib/sync.sh"; _sync_capture_generated_provenance "$2"' _ "$BLUEPRINT_ROOT" "$stage"
  [ "$status" -eq 0 ]
  run _validate_release
  [ "$status" -eq 0 ]
}
