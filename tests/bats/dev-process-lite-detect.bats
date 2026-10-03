#!/usr/bin/env bats
# skills/dev-process-lite/detect.sh: a repo with docs/DEV_PROCESS.md at its
# git top level has its own process; anything else uses the lite process.

bats_require_minimum_version 1.5.0

setup() {
  : "${BLUEPRINT_ROOT:?unset, run via tests/bats/run.sh}"
  TMPDIR=$(mktemp -d)
  DETECT="$BLUEPRINT_ROOT/skills/dev-process-lite/detect.sh"
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "detect: repo without docs/DEV_PROCESS.md prints lite" {
  git init -q "$TMPDIR/repo"
  cd "$TMPDIR/repo"
  run bash "$DETECT"
  [ "$status" -eq 0 ]
  [ "$output" = "lite" ]
}

@test "detect: repo with docs/DEV_PROCESS.md prints project and the path" {
  git init -q "$TMPDIR/repo"
  mkdir -p "$TMPDIR/repo/docs"
  echo "# process" > "$TMPDIR/repo/docs/DEV_PROCESS.md"
  cd "$TMPDIR/repo"
  run bash "$DETECT"
  [ "$status" -eq 0 ]
  [ "$output" = "project $(cd "$TMPDIR/repo" && pwd -P)/docs/DEV_PROCESS.md" ]
}

@test "detect: run from a subdirectory still finds the repo-root document" {
  git init -q "$TMPDIR/repo"
  mkdir -p "$TMPDIR/repo/docs" "$TMPDIR/repo/src/deep"
  echo "# process" > "$TMPDIR/repo/docs/DEV_PROCESS.md"
  cd "$TMPDIR/repo/src/deep"
  run bash "$DETECT"
  [ "$status" -eq 0 ]
  [[ "$output" == "project "*"/docs/DEV_PROCESS.md" ]]
}

@test "detect: a directory named DEV_PROCESS.md does not count" {
  git init -q "$TMPDIR/repo"
  mkdir -p "$TMPDIR/repo/docs/DEV_PROCESS.md"
  cd "$TMPDIR/repo"
  run bash "$DETECT"
  [ "$status" -eq 0 ]
  [ "$output" = "lite" ]
}

@test "detect: outside any git repo prints lite and exits 0" {
  mkdir -p "$TMPDIR/norepo"
  cd "$TMPDIR/norepo"
  run env GIT_CEILING_DIRECTORIES="$TMPDIR" bash "$DETECT"
  [ "$status" -eq 0 ]
  [ "$output" = "lite" ]
}
