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

@test "resolver: project file with the wrong shape blocks and names the file" {
  project_repo "$TMPDIR/repo" '{"version":1,"routes":[]}'
  cd "$TMPDIR/repo"
  run --separate-stderr bash "$R" claude implementer
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == "blocked: "*".dev-process/routes.json"* ]]
  project_repo "$TMPDIR/repo2" '{"version":1,"routes":{"claude":"x"}}'
  cd "$TMPDIR/repo2"
  run --separate-stderr bash "$R" claude implementer
  [ "$status" -eq 2 ]
  [[ "$stderr" == "blocked: "*".dev-process/routes.json"* ]]
}

@test "resolver: codex sol resolves to the newest listed, non-retiring slug" {
  run --separate-stderr bash "$R" codex overseer
  [ "$status" -eq 0 ]
  [ "$(jq -r .model <<<"$output")" = "gpt-6.1-sol" ]
  [ "$(jq -r .resolved <<<"$output")" = "family" ]
}

@test "resolver: codex luna and astra resolve" {
  run --separate-stderr bash "$R" codex implementer
  [ "$status" -eq 0 ]
  [ "$(jq -r .model <<<"$output")" = "gpt-6-luna" ]
  run --separate-stderr bash "$R" cursor reviewer
  [ "$status" -eq 0 ]
  [ "$(jq -r .harness <<<"$output")" = "codex" ]
  [ "$(jq -r .model <<<"$output")" = "gpt-6-astra" ]
}

@test "resolver: codex family with no listed model blocks and names the list" {
  project_repo "$TMPDIR/repo" '{"version":1,"routes":{"codex":{"implementer":{"harness":"codex","family":"terra","effort":"high"}}}}'
  cd "$TMPDIR/repo"
  run --separate-stderr bash "$R" codex implementer
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == "blocked: "*"terra"*"codex debug models"* ]]
}

@test "resolver: codex pin present in the list is returned, absent pin blocks" {
  project_repo "$TMPDIR/repo" '{"version":1,"routes":{"codex":{"overseer":{"harness":"codex","model":"gpt-5.6-sol","family":"sol","effort":"high"},"implementer":{"harness":"codex","model":"gpt-4-sol","effort":"high"}}}}'
  cd "$TMPDIR/repo"
  run --separate-stderr bash "$R" codex overseer
  [ "$status" -eq 0 ]
  [ "$(jq -r .model <<<"$output")" = "gpt-5.6-sol" ]
  [ "$(jq -r .resolved <<<"$output")" = "pinned" ]
  run --separate-stderr bash "$R" codex implementer
  [ "$status" -eq 2 ]
  [[ "$stderr" == "blocked: "*"gpt-4-sol"* ]]
}

@test "resolver: empty codex model list blocks instead of printing an empty model" {
  : > "$TMPDIR/empty.json"
  run --separate-stderr env DEV_PROCESS_LITE_CODEX_MODELS="$TMPDIR/empty.json" bash "$R" codex overseer
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == "blocked: "*"codex debug models"* ]]
}

@test "resolver: cursor grok xhigh picks unprefixed 4.7 over prefixed 4.6" {
  run --separate-stderr bash "$R" cursor overseer
  [ "$status" -eq 0 ]
  [ "$(jq -r .model <<<"$output")" = "grok-4.7-xhigh" ]
  run --separate-stderr bash "$R" cursor implementer
  [ "$status" -eq 0 ]
  [ "$(jq -r .model <<<"$output")" = "grok-4.7-medium" ]
}

@test "resolver: cursor fast flag selects the -fast selector, plain does not" {
  project_repo "$TMPDIR/repo" '{"version":1,"routes":{"cursor":{"implementer":{"harness":"cursor","family":"grok","effort":"high","fast":true},"overseer":{"harness":"cursor","family":"grok","effort":"high"}}}}'
  cd "$TMPDIR/repo"
  run --separate-stderr bash "$R" cursor implementer
  [ "$status" -eq 0 ]
  [ "$(jq -r .model <<<"$output")" = "cursor-grok-4.6-high-fast" ]
  run --separate-stderr bash "$R" cursor overseer
  [ "$status" -eq 2 ]
  [[ "$stderr" == "blocked: "*"grok"*"cursor-agent --list-models"* ]]
}

@test "resolver: cursor variant tokens and dashed versions resolve, missing effort blocks" {
  project_repo "$TMPDIR/repo" '{"version":1,"routes":{"cursor":{"reviewer":{"harness":"cursor","family":"claude-fable","effort":"high"},"overseer":{"harness":"cursor","family":"claude-opus","effort":"high"},"implementer":{"harness":"cursor","family":"gpt","effort":"xhigh"}}}}'
  cd "$TMPDIR/repo"
  run --separate-stderr bash "$R" cursor reviewer
  [ "$status" -eq 0 ]
  [ "$(jq -r .model <<<"$output")" = "claude-fable-5-thinking-high" ]
  run --separate-stderr bash "$R" cursor overseer
  [ "$status" -eq 0 ]
  [ "$(jq -r .model <<<"$output")" = "claude-opus-5-5-high" ]
  run --separate-stderr bash "$R" cursor implementer
  [ "$status" -eq 2 ]
}

@test "resolver: cursor pin present is returned, absent pin blocks" {
  project_repo "$TMPDIR/repo" '{"version":1,"routes":{"cursor":{"overseer":{"harness":"cursor","model":"cursor-grok-4.6-xhigh","effort":"xhigh"},"implementer":{"harness":"cursor","model":"grok-9-low","effort":"low"}}}}'
  cd "$TMPDIR/repo"
  run --separate-stderr bash "$R" cursor overseer
  [ "$status" -eq 0 ]
  [ "$(jq -r .model <<<"$output")" = "cursor-grok-4.6-xhigh" ]
  run --separate-stderr bash "$R" cursor implementer
  [ "$status" -eq 2 ]
  [[ "$stderr" == "blocked: "*"grok-9-low"* ]]
}
