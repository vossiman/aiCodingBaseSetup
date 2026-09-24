#!/usr/bin/env bats
# Sourcing lib/blueprint-deploy.sh removes Python bytecode that was written
# into an immutable release after it was staged. Old releases execute new code
# only by sourcing this file while staging a newly selected release, so that
# is how a container stuck on a corrupt current release heals itself.

setup() {
  : "${BLUEPRINT_ROOT:?run via run.sh}"
  TEST_ROOT=$(mktemp -d)
  export HOME="$TEST_ROOT/home"
  export AICODING_DATA_DIR="$TEST_ROOT/data"
  export AICODING_STATE_DIR="$TEST_ROOT/state"
  export AICODING_MANIFEST="$TEST_ROOT/manifest.json"
  mkdir -p "$HOME"
  SHA=0123456789abcdef0123456789abcdef01234567
  RELEASE="$AICODING_DATA_DIR/versions/aicoding/$SHA"
}

teardown() { rm -rf "$TEST_ROOT"; }

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
}

_validate_release() {
  ( . "$BLUEPRINT_ROOT/lib/runtime.sh"; _aicoding_runtime_validate_release aicoding "$SHA" )
}

_corrupt_release() {
  mkdir -p "$RELEASE/lib/kanban_work/__pycache__"
  printf 'bytecode\n' > "$RELEASE/lib/kanban_work/__pycache__/store.cpython-314.pyc"
}

@test "sourcing removes bytecode written into a staged release and restores validity" {
  _stage_release
  _corrupt_release
  run _validate_release
  [ "$status" -ne 0 ]

  run bash -c 'set -euo pipefail; . "$1/lib/blueprint-deploy.sh"' _ "$BLUEPRINT_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  [ ! -e "$RELEASE/lib/kanban_work/__pycache__" ]
  [ "$(cat "$RELEASE/lib/kanban_work/store.py")" = 'print(1)' ]
  [ "$(cat "$RELEASE/tools/render-debug/__pycache__/harness.pyc")" = tracked ]
  run _validate_release
  [ "$status" -eq 0 ]
}

@test "sourcing keeps bytecode that the release digest covers" {
  _stage_release
  touch "$RELEASE/tools/render-debug/__pycache__"
  run bash -c '. "$1/lib/blueprint-deploy.sh"' _ "$BLUEPRINT_ROOT"
  [ "$status" -eq 0 ]
  [ -f "$RELEASE/tools/render-debug/__pycache__/harness.pyc" ]
  run _validate_release
  [ "$status" -eq 0 ]
}

@test "sourcing leaves a release alone when removing bytecode would not restore its digest" {
  _stage_release
  _corrupt_release
  printf 'tampered\n' >> "$RELEASE/lib/kanban_work/store.py"
  run bash -c '. "$1/lib/blueprint-deploy.sh"' _ "$BLUEPRINT_ROOT"
  [ "$status" -eq 0 ]
  [ -f "$RELEASE/lib/kanban_work/__pycache__/store.cpython-314.pyc" ]
}

@test "sourcing never follows symlinks out of the versions tree" {
  local outside="$TEST_ROOT/outside"
  mkdir -p "$outside/rel/__pycache__" "$outside/inner/__pycache__"
  printf 'x\n' > "$outside/rel/__pycache__/a.pyc"
  printf 'x\n' > "$outside/inner/__pycache__/b.pyc"
  printf '%s\n' "$(printf '0%.0s' {1..64})" > "$outside/rel/.aicoding-tree.sha256"
  touch -d '2000-01-01 00:00:00' "$outside/rel/.aicoding-tree.sha256"
  mkdir -p "$AICODING_DATA_DIR/versions/aicoding"
  # A release entry that is itself a symlink out of the tree.
  ln -s "$outside/rel" "$AICODING_DATA_DIR/versions/aicoding/linked"
  # A real release containing a symlink out of the tree.
  _stage_release
  ln -s "$outside/inner" "$RELEASE/lib/escape"
  _corrupt_release

  run bash -c '. "$1/lib/blueprint-deploy.sh"' _ "$BLUEPRINT_ROOT"
  [ "$status" -eq 0 ]
  [ -f "$outside/rel/__pycache__/a.pyc" ]
  [ -f "$outside/inner/__pycache__/b.pyc" ]
}

@test "sourcing never follows a symlinked versions directory" {
  local outside="$TEST_ROOT/outside-versions"
  mkdir -p "$outside/aicoding/$SHA/__pycache__" "$AICODING_DATA_DIR"
  printf 'x\n' > "$outside/aicoding/$SHA/__pycache__/a.pyc"
  printf '%s\n' "$(printf '0%.0s' {1..64})" > "$outside/aicoding/$SHA/.aicoding-tree.sha256"
  touch -d '2000-01-01 00:00:00' "$outside/aicoding/$SHA/.aicoding-tree.sha256"
  ln -s "$outside" "$AICODING_DATA_DIR/versions"
  run bash -c '. "$1/lib/blueprint-deploy.sh"' _ "$BLUEPRINT_ROOT"
  [ "$status" -eq 0 ]
  [ -f "$outside/aicoding/$SHA/__pycache__/a.pyc" ]
}

@test "sourcing without a versions directory or data dir variable succeeds under set -u" {
  run bash -c 'set -euo pipefail; . "$1/lib/blueprint-deploy.sh"; echo sourced' _ "$BLUEPRINT_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = sourced ]
  run env -u AICODING_DATA_DIR bash -c 'set -euo pipefail; shopt -s failglob; . "$1/lib/blueprint-deploy.sh"; echo sourced' _ "$BLUEPRINT_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = sourced ]
}

@test "the default data dir under HOME is healed when AICODING_DATA_DIR is unset" {
  _stage_release
  _corrupt_release
  mkdir -p "$HOME/.local/share"
  mv "$AICODING_DATA_DIR" "$HOME/.local/share/aicoding"
  run env -u AICODING_DATA_DIR bash -c 'set -euo pipefail; . "$1/lib/blueprint-deploy.sh"' _ "$BLUEPRINT_ROOT"
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.local/share/aicoding/versions/aicoding/$SHA/lib/kanban_work/__pycache__" ]
}

@test "the heal runs once per process" {
  _stage_release
  run bash -c '. "$1/lib/blueprint-deploy.sh"
    mkdir -p "$2/lib/kanban_work/__pycache__"
    printf x > "$2/lib/kanban_work/__pycache__/late.pyc"
    . "$1/lib/blueprint-deploy.sh"
    [ -f "$2/lib/kanban_work/__pycache__/late.pyc" ]' _ "$BLUEPRINT_ROOT" "$RELEASE"
  [ "$status" -eq 0 ]
}

@test "staging a new blueprint heals a corrupt current release before activation" {
  _stage_release
  _corrupt_release
  # The old code path: _sync_capture_generated_provenance sources the NEW
  # stage's lib/blueprint-deploy.sh before activation validates current.
  local stage="$TEST_ROOT/stage"
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
