#!/usr/bin/env bats
# The UserPromptSubmit wrapper: extract .prompt, pipe to memory-hint, never fail.

setup() {
  : "${BLUEPRINT_ROOT:?unset — run via tests/bats/run.sh}"
  HOOK="$BLUEPRINT_ROOT/configs/claude/hooks/memory-hint.sh"
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  mkdir -p "$HOME/.local/bin"
  cat > "$HOME/.local/bin/memory-hint" <<'STUB'
#!/bin/sh
input=$(cat)
echo "HINT-FOR:$input CLIENT:$2"
STUB
  chmod +x "$HOME/.local/bin/memory-hint"
}

teardown() { rm -rf "$TMPDIR"; }

@test "extracts prompt and forwards with claude-code client tag" {
  run bash -c "printf '%s' '{\"prompt\": \"which ports on vossisrv\"}' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [[ "$output" == "HINT-FOR:which ports on vossisrv CLIENT:hook:claude-code" ]]
}

@test "malformed json: silent success" {
  run bash -c "printf 'not-json' | bash '$HOOK'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "missing memory-hint binary: silent success" {
  rm "$HOME/.local/bin/memory-hint"
  run bash -c "printf '%s' '{\"prompt\": \"which ports on vossisrv\"}' | bash '$HOOK'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}
