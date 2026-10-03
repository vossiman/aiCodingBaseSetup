#!/usr/bin/env bats
# skills/dev-process-lite/routes.sh: routes lookup, entry detection and model
# resolution. No real agent CLI is ever called: model lists come from fixtures.

bats_require_minimum_version 1.5.0

setup() {
  : "${BLUEPRINT_ROOT:?unset, run via tests/bats/run.sh}"
  TMPDIR=$(mktemp -d)
  unset CLAUDECODE CODEX_THREAD_ID
  FIX="$BLUEPRINT_ROOT/tests/bats/fixtures/dev-process-lite"
  export DEV_PROCESS_LITE_CODEX_MODELS="$FIX/codex-models.json"
  export DEV_PROCESS_LITE_CURSOR_MODELS="$FIX/cursor-models.txt"
  export GIT_CEILING_DIRECTORIES="$TMPDIR"
  R="$BLUEPRINT_ROOT/skills/dev-process-lite/routes.sh"
  DEFAULT="$BLUEPRINT_ROOT/skills/dev-process-lite/routes.default.json"
  mkdir -p "$TMPDIR/norepo"
  cd "$TMPDIR/norepo"
}

teardown() {
  rm -rf "$TMPDIR"
}

# Creates a repo at $1 whose .dev-process/routes.json holds $2.
project_repo() {
  git init -q "$1"
  mkdir -p "$1/.dev-process"
  printf '%s\n' "$2" > "$1/.dev-process/routes.json"
}

@test "resolver: explicit entry without role prints the default table" {
  run --separate-stderr bash "$R" claude
  [ "$status" -eq 0 ]
  [ "$(jq -r .entry <<<"$output")" = "claude" ]
  [ "$(jq -r .routes.implementer.family <<<"$output")" = "sonnet" ]
  [ "$(jq -r .source <<<"$output")" = "$DEFAULT" ]
  [ "$(jq -r 'has("note")' <<<"$output")" = "false" ]
}

@test "resolver: CLAUDECODE selects claude when no entry is given" {
  run --separate-stderr env CLAUDECODE=1 bash "$R"
  [ "$status" -eq 0 ]
  [ "$(jq -r .entry <<<"$output")" = "claude" ]
}

@test "resolver: CODEX_THREAD_ID wins over an inherited CLAUDECODE" {
  run --separate-stderr env CLAUDECODE=1 CODEX_THREAD_ID=t-1 bash "$R"
  [ "$status" -eq 0 ]
  [ "$(jq -r .entry <<<"$output")" = "codex" ]
}

@test "resolver: no entry and no marker blocks" {
  run --separate-stderr bash "$R"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == "blocked: "*"claude, codex or cursor"* ]]
}

@test "resolver: opencode and unknown entries block with the start-runs message" {
  run --separate-stderr bash "$R" opencode implementer
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"start runs from Claude, Codex or Cursor"* ]]
  run --separate-stderr bash "$R" vim
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"start runs from Claude, Codex or Cursor"* ]]
}

@test "resolver: claude family passes the alias through" {
  run --separate-stderr bash "$R" claude overseer
  [ "$status" -eq 0 ]
  [ "$(jq -r .model <<<"$output")" = "opus" ]
  [ "$(jq -r .resolved <<<"$output")" = "alias" ]
  [ "$(jq -r .effort <<<"$output")" = "high" ]
  [ "$(jq -r .harness <<<"$output")" = "claude" ]
}

@test "resolver: unknown role blocks" {
  run --separate-stderr bash "$R" claude janitor
  [ "$status" -eq 2 ]
  [[ "$stderr" == "blocked: "*"janitor"* ]]
}

@test "resolver: project routes file is used, found from a subdirectory" {
  project_repo "$TMPDIR/repo" '{"version":1,"routes":{"claude":{"implementer":{"harness":"claude","model":"claude-sonnet-5-5","effort":"low"}}}}'
  mkdir -p "$TMPDIR/repo/src/deep"
  cd "$TMPDIR/repo/src/deep"
  run --separate-stderr bash "$R" claude implementer
  [ "$status" -eq 0 ]
  [ "$(jq -r .model <<<"$output")" = "claude-sonnet-5-5" ]
  [ "$(jq -r .resolved <<<"$output")" = "pinned" ]
  [ "$(jq -r .effort <<<"$output")" = "low" ]
  [[ "$(jq -r .source <<<"$output")" == *"/repo/.dev-process/routes.json" ]]
}

@test "resolver: exact model wins over family and family is reported null" {
  project_repo "$TMPDIR/repo" '{"version":1,"routes":{"claude":{"overseer":{"harness":"claude","model":"claude-opus-5-5[1m]","family":"sonnet","effort":"high"}}}}'
  cd "$TMPDIR/repo"
  run --separate-stderr bash "$R" claude overseer
  [ "$status" -eq 0 ]
  [ "$(jq -r .model <<<"$output")" = "claude-opus-5-5[1m]" ]
  [ "$(jq -r .family <<<"$output")" = "null" ]
}

@test "resolver: a claude pin with the wrong shape blocks" {
  project_repo "$TMPDIR/repo" '{"version":1,"routes":{"claude":{"overseer":{"harness":"claude","model":"opus-latest","effort":"high"}}}}'
  cd "$TMPDIR/repo"
  run --separate-stderr bash "$R" claude overseer
  [ "$status" -eq 2 ]
  [[ "$stderr" == "blocked: "*"opus-latest"* ]]
}

@test "resolver: project file without the entry table falls back with a note" {
  project_repo "$TMPDIR/repo" '{"version":1,"routes":{"claude":{}}}'
  cd "$TMPDIR/repo"
  run --separate-stderr bash "$R" cursor
  [ "$status" -eq 0 ]
  [ "$(jq -r .source <<<"$output")" = "$DEFAULT" ]
  [[ "$(jq -r .note <<<"$output")" == *"has no 'cursor' table"* ]]
}

@test "resolver: malformed project file blocks and names the file" {
  project_repo "$TMPDIR/repo" '{"version":1,"routes":'
  cd "$TMPDIR/repo"
  run --separate-stderr bash "$R" claude implementer
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == "blocked: "*".dev-process/routes.json"* ]]
}

@test "resolver: an effort outside the known levels blocks" {
  project_repo "$TMPDIR/repo" '{"version":1,"routes":{"claude":{"overseer":{"harness":"claude","family":"opus","effort":"turbo"}}}}'
  cd "$TMPDIR/repo"
  run --separate-stderr bash "$R" claude overseer
  [ "$status" -eq 2 ]
  [[ "$stderr" == "blocked: "*"turbo"* ]]
}
