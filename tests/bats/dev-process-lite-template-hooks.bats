#!/usr/bin/env bats
# Project template hooks: North Star injection at session start and the
# ship-check read-back after git commit. Both are fail-open.

bats_require_minimum_version 1.5.0

setup() {
  : "${BLUEPRINT_ROOT:?unset, run via tests/bats/run.sh}"
  TMPDIR=$(mktemp -d)
  H="$BLUEPRINT_ROOT/templates/project/dot-claude/hooks"
  mkdir -p "$TMPDIR/proj/docs"
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "template hooks: settings.json.tpl is valid JSON and wires both hooks" {
  local s="$BLUEPRINT_ROOT/templates/project/dot-claude/settings.json.tpl"
  jq -e . "$s" >/dev/null
  [ "$(jq -r '.hooks.SessionStart[0].matcher' "$s")" = "startup|resume" ]
  [[ "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$s")" == *'/.claude/hooks/north-star.sh' ]]
  [ "$(jq -r '.hooks.PostToolUse[0].matcher' "$s")" = "Bash" ]
  [ "$(jq '.hooks.PostToolUse[0].hooks[0] | has("if")' "$s")" = "false" ]
  [[ "$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$s")" == *'/.claude/hooks/ship-check.sh' ]]
  [ "$(jq -r '.permissions.allow | length' "$s")" = "0" ]
}

@test "template hooks: scripts are committed executable" {
  [ -x "$H/north-star.sh" ]
  [ -x "$H/ship-check.sh" ]
  run git -C "$BLUEPRINT_ROOT" ls-files -s templates/project/dot-claude/hooks
  [[ "$output" == *"100755"*"north-star.sh"* ]]
  [[ "$output" == *"100755"*"ship-check.sh"* ]]
}

@test "north-star: no REQUIREMENTS.md prints nothing and exits 0" {
  run env CLAUDE_PROJECT_DIR="$TMPDIR/proj" bash "$H/north-star.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run env CLAUDE_PROJECT_DIR="$TMPDIR/does-not-exist" bash "$H/north-star.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "north-star: a short file is injected after a header" {
  seq 1 10 | sed 's/^/line /' > "$TMPDIR/proj/docs/REQUIREMENTS.md"
  run env CLAUDE_PROJECT_DIR="$TMPDIR/proj" bash "$H/north-star.sh"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"North Star"* ]]
  [[ "$output" == *"line 1"* ]]
  [[ "$output" == *"line 10"* ]]
}

@test "north-star: a file over 200 lines is replaced by a warning" {
  seq 1 300 | sed 's/^/line /' > "$TMPDIR/proj/docs/REQUIREMENTS.md"
  run env CLAUDE_PROJECT_DIR="$TMPDIR/proj" bash "$H/north-star.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"300 lines"* ]]
  [[ "$output" != *"line 150"* ]]
}

@test "ship-check: no SHIP_CHECK.md prints nothing and exits 0" {
  run bash -c "printf '%s' '{\"tool_input\":{\"command\":\"git commit -m x\"}}' | CLAUDE_PROJECT_DIR='$TMPDIR/proj' bash '$H/ship-check.sh'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ship-check: awkward content round-trips through valid JSON" {
  printf 'Say "done" only if:\n\tC:\\path holds\nUmlaut \xc3\xa4 ok\n' > "$TMPDIR/proj/docs/SHIP_CHECK.md"
  run bash -c "printf '%s' '{\"tool_input\":{\"command\":\"git commit -m x\"}}' | CLAUDE_PROJECT_DIR='$TMPDIR/proj' bash '$H/ship-check.sh'"
  [ "$status" -eq 0 ]
  jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' <<<"$output" >/dev/null
  jq -j '.hookSpecificOutput.additionalContext' <<<"$output" > "$TMPDIR/back"
  cmp -s "$TMPDIR/proj/docs/SHIP_CHECK.md" "$TMPDIR/back"
}

@test "ship-check: fires for git commit with global options or chains, not for other commands" {
  echo "check" > "$TMPDIR/proj/docs/SHIP_CHECK.md"
  local c out
  for c in "git commit -m x" "git -c user.email=a@b commit -m x" "git -C /tmp/w commit -m x" "git add f && git -C w commit -m x" "cd w; git commit --amend"; do
    out=$(jq -cn --arg c "$c" '{tool_input:{command:$c}}' | CLAUDE_PROJECT_DIR="$TMPDIR/proj" bash "$H/ship-check.sh")
    [ -n "$out" ] || { echo "no output for: $c"; false; }
  done
  for c in "git status" "git log --grep commit" "echo git commit" "git commit-tree abc"; do
    out=$(jq -cn --arg c "$c" '{tool_input:{command:$c}}' | CLAUDE_PROJECT_DIR="$TMPDIR/proj" bash "$H/ship-check.sh")
    [ -z "$out" ] || { echo "output for: $c"; false; }
  done
  out=$(CLAUDE_PROJECT_DIR="$TMPDIR/proj" bash "$H/ship-check.sh" </dev/null)
  [ -z "$out" ]
}

@test "template: SHIP_CHECK.md example ships with three questions" {
  local f="$BLUEPRINT_ROOT/templates/project/docs/SHIP_CHECK.md.tpl"
  [ "$(grep -cE '^[0-9]+\. ' "$f")" -eq 3 ]
}
