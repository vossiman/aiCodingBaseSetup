#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load t3-helpers

setup() {
  t3_test_setup
  t3_make_db
  export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
  git config --global user.name t && git config --global user.email t@t
  git config --global init.defaultBranch main
}
teardown() { t3_test_teardown; }

S() { printf '%s\n' "$T3_ENVS_ROOT/demo/aicoding"; }

remote_repo() {
  git init -q --bare "$TMP/remotes/$1.git"
  git clone -q "$TMP/remotes/$1.git" "$TMP/seed-$1" 2>/dev/null
  git -C "$TMP/seed-$1" commit -q --allow-empty -m init
  git -C "$TMP/seed-$1" push -q origin HEAD 2>/dev/null
  rm -rf "$TMP/seed-$1"
}

project() {
  t3_sql "INSERT INTO projection_projects VALUES ('$1', '$1', '$2', '[]', 'x', 'x', ${3:-NULL});"
}

projects() { bash -c '. "$BLUEPRINT_ROOT/lib/t3.sh"; t3_env 2>/dev/null; t3_projects_restore' ; }

@test "projects: records each live project's origin, then clones a missing one back" {
  remote_repo app
  git clone -q "$TMP/remotes/app.git" "$TMP/co/app"
  project p1 "$TMP/co/app"
  run projects
  [ "$status" -eq 0 ]
  [ "$(cat "$(S)/projects.tsv")" = "$TMP/co/app"$'\t'"$TMP/remotes/app.git" ]
  rm -rf "$TMP/co"
  run projects
  [ "$status" -eq 0 ]
  [[ "$output" == *"project restored: $TMP/co/app"* ]]
  [ "$(git -C "$TMP/co/app" remote get-url origin)" = "$TMP/remotes/app.git" ]
  [ "$(cat "$(S)/projects.tsv")" = "$TMP/co/app"$'\t'"$TMP/remotes/app.git" ]
}

@test "projects: a missing folder without a recorded remote is reported, not fatal" {
  project p1 "$TMP/co/gone"
  run projects
  [ "$status" -eq 0 ]
  [[ "$output" == *"no remote recorded: $TMP/co/gone"* ]]
  [ ! -e "$TMP/co/gone" ]
}

@test "projects: a failed clone is reported and keeps the recorded remote" {
  project p1 "$TMP/co/app"
  mkdir -p "$(S)"
  printf '%s\t%s\n' "$TMP/co/app" "$TMP/remotes/nope.git" > "$(S)/projects.tsv"
  run projects
  [ "$status" -eq 0 ]
  [[ "$output" == *"clone of $TMP/remotes/nope.git failed"* ]]
  [ "$(cat "$(S)/projects.tsv")" = "$TMP/co/app"$'\t'"$TMP/remotes/nope.git" ]
}

@test "projects: deleted projects are skipped and dropped from the record" {
  remote_repo app
  git clone -q "$TMP/remotes/app.git" "$TMP/co/app"
  project p1 "$TMP/co/app"
  projects
  t3_sql "UPDATE projection_projects SET deleted_at = 'x';"
  rm -rf "$TMP/co"
  run projects
  [ "$status" -eq 0 ]
  [ ! -e "$TMP/co/app" ]
  [ ! -s "$(S)/projects.tsv" ]
}

@test "projects: a folder inside a bigger repo never records that repo's remote" {
  remote_repo app
  git clone -q "$TMP/remotes/app.git" "$TMP/co/app"
  mkdir -p "$TMP/co/app/sub"
  project p1 "$TMP/co/app/sub"
  run projects
  [ "$status" -eq 0 ]
  [ ! -s "$(S)/projects.tsv" ]
}

@test "projects: no database or a broken one is a quiet no-op that keeps the record" {
  mkdir -p "$(S)"
  printf '%s\t%s\n' "$TMP/co/app" "$TMP/remotes/app.git" > "$(S)/projects.tsv"
  rm -f "$(t3_db)"
  run projects
  [ "$status" -eq 0 ]
  echo junk > "$(t3_db)"
  run projects
  [ "$status" -eq 0 ]
  [ "$(cat "$(S)/projects.tsv")" = "$TMP/co/app"$'\t'"$TMP/remotes/app.git" ]
  [ ! -e "$TMP/co/app" ]
}

@test "projects: t3-start clones a missing project back before starting" {
  t3_fake_setup
  remote_repo app
  project p1 "$TMP/co/app"
  printf '%s\t%s\n' "$TMP/co/app" "$TMP/remotes/app.git" > "$(S)/projects.tsv"
  run "$B/t3-start"
  [ "$status" -eq 0 ]
  [[ "$output" == *"project restored: $TMP/co/app"* ]]
  [ -d "$TMP/co/app/.git" ]
}

@test "projects: t3-projects restores and prints the record" {
  remote_repo app
  project p1 "$TMP/co/app"
  mkdir -p "$(S)"
  printf '%s\t%s\n' "$TMP/co/app" "$TMP/remotes/app.git" > "$(S)/projects.tsv"
  run "$B/t3-projects"
  [ "$status" -eq 0 ]
  [ -d "$TMP/co/app/.git" ]
  [[ "$output" == *"$TMP/co/app"$'\t'"$TMP/remotes/app.git"* ]]
}
