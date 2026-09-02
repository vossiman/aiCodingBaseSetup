#!/usr/bin/env bats
# The UserPromptSubmit hook that injects response-shape guidance for Fable 5
# and Mythos 5 only: payload .model wins, transcript grep is the fallback,
# everything else stays silent.

setup() {
  : "${BLUEPRINT_ROOT:?unset, run via tests/bats/run.sh}"
  HOOK="$BLUEPRINT_ROOT/configs/claude/hooks/fable-guidance.sh"
  TMPDIR=$(mktemp -d)
}

teardown() { rm -rf "$TMPDIR"; }

@test "fable 5.1 in payload: injects the guidance" {
  run bash -c "printf '%s' '{\"model\":\"claude-fable-5-1\"}' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"targeted edit"* ]]
}

@test "mythos 5.1 in payload: injects the guidance" {
  run bash -c "printf '%s' '{\"model\":\"claude-mythos-5-1\"}' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"targeted edit"* ]]
}

@test "fable with a context suffix still matches" {
  run bash -c "printf '%s' '{\"model\":\"claude-fable-5-1[1m]\"}' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"targeted edit"* ]]
}

@test "opus, sonnet and haiku: silent" {
  for m in claude-opus-5 claude-sonnet-5 claude-haiku-4-5-20251001; do
    run bash -c "printf '%s' '{\"model\":\"$m\"}' | bash '$HOOK'"
    [ "$status" -eq 0 ]; [ -z "$output" ]
  done
}

@test "guidance does not repeat what the harness already injects" {
  run bash -c "printf '%s' '{\"model\":\"claude-fable-5-1\"}' | bash '$HOOK'"
  [[ "$output" != *"operating autonomously"* ]]
  [[ "$output" != *"privately list"* ]]
  [[ "$output" != *"short recap"* ]]
}

@test "no model field: falls back to the last model in the transcript" {
  t="$TMPDIR/t.jsonl"
  printf '{"model":"claude-sonnet-5"}\n{"model":"claude-fable-5-1"}\n' > "$t"
  run bash -c "printf '%s' '{\"transcript_path\":\"$t\"}' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"targeted edit"* ]]
}

@test "transcript whose last model is not fable: silent" {
  t="$TMPDIR/t.jsonl"
  printf '{"model":"claude-fable-5-1"}\n{"model":"claude-opus-5"}\n' > "$t"
  run bash -c "printf '%s' '{\"transcript_path\":\"$t\"}' | bash '$HOOK'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "unreadable transcript path: silent success" {
  run bash -c "printf '%s' '{\"transcript_path\":\"$TMPDIR/nope.jsonl\"}' | bash '$HOOK'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "malformed json: silent success" {
  run bash -c "printf 'not-json' | bash '$HOOK'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "empty payload: silent success" {
  run bash -c "printf '' | bash '$HOOK'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "registered in settings.json, the deploy manifest and MANAGED_HOOKS" {
  grep -q 'hooks/fable-guidance.sh' "$BLUEPRINT_ROOT/configs/claude/settings.json"
  grep -q 'hooks/fable-guidance.sh' "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  grep -q '"fable-guidance.sh"' "$BLUEPRINT_ROOT/lib/provision-managed-files.sh"
}
