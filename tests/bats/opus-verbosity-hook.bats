#!/usr/bin/env bats
# The UserPromptSubmit hook that injects response-shape guidance for Opus 5
# only: payload .model wins, transcript grep is the fallback, everything else
# stays silent.

setup() {
  : "${BLUEPRINT_ROOT:?unset — run via tests/bats/run.sh}"
  HOOK="$BLUEPRINT_ROOT/configs/claude/hooks/opus-verbosity.sh"
  TMPDIR=$(mktemp -d)
}

teardown() { rm -rf "$TMPDIR"; }

@test "opus 5 in payload: injects the guidance" {
  run bash -c "printf '%s' '{\"model\":\"claude-opus-5\"}' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"lead with the outcome"* ]]
}

@test "opus 5 with a context suffix still matches" {
  run bash -c "printf '%s' '{\"model\":\"claude-opus-5[1m]\"}' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"lead with the outcome"* ]]
}

@test "another model: silent" {
  run bash -c "printf '%s' '{\"model\":\"claude-sonnet-5\"}' | bash '$HOOK'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "no model field: falls back to the last model in the transcript" {
  t="$TMPDIR/t.jsonl"
  printf '{"model":"claude-sonnet-5"}\n{"model":"claude-opus-5"}\n' > "$t"
  run bash -c "printf '%s' '{\"transcript_path\":\"$t\"}' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"lead with the outcome"* ]]
}

@test "transcript whose last model is not opus: silent" {
  t="$TMPDIR/t.jsonl"
  printf '{"model":"claude-opus-5"}\n{"model":"claude-sonnet-5"}\n' > "$t"
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
  grep -q 'hooks/opus-verbosity.sh' "$BLUEPRINT_ROOT/configs/claude/settings.json"
  grep -q 'hooks/opus-verbosity.sh' "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  grep -q '"opus-verbosity.sh"' "$BLUEPRINT_ROOT/lib/provision-managed-files.sh"
}
