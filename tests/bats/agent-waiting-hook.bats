#!/usr/bin/env bats
setup() {
  : "${BLUEPRINT_ROOT:?unset — run via tests/bats/run.sh}"
  HOOK="$BLUEPRINT_ROOT/configs/claude/hooks/agent-waiting.sh"
  TMPDIR=$(mktemp -d); export HOME="$TMPDIR"
  mkdir -p "$HOME/.local/bin"
  cat > "$HOME/.local/bin/agent-notify" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" > "$HOME/notify-args"
STUB
  chmod +x "$HOME/.local/bin/agent-notify"
  unset LLMWIKI_DISTILLER
}
teardown() { case "${TMPDIR:-}" in */tmp.*) rm -rf "$TMPDIR" ;; esac }

@test "forwards notification message as body with high priority" {
  run bash "$HOOK" <<< '{"message":"Claude needs your permission to use Bash","cwd":"/x"}'
  [ "$status" -eq 0 ]
  grep -q -- '--source' "$HOME/notify-args"
  grep -q 'permission' "$HOME/notify-args"
  grep -q 'high' "$HOME/notify-args"
}

@test "recursion guard: distiller sessions never notify" {
  export LLMWIKI_DISTILLER=1
  run bash "$HOOK" <<< '{"message":"x"}'
  unset LLMWIKI_DISTILLER
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/notify-args" ]
}

@test "malformed stdin exits 0 without calling agent-notify" {
  run bash "$HOOK" <<< 'not json'
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/notify-args" ]
}

@test "settings.json wires the hook and manifest deploys it" {
  grep -q 'agent-waiting.sh' "$BLUEPRINT_ROOT/configs/claude/settings.json"
  grep -q 'Notification' "$BLUEPRINT_ROOT/configs/claude/settings.json"
  grep -q '.claude/hooks/agent-waiting.sh|overwrite|configs/claude/hooks/agent-waiting.sh' \
    "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
}

@test "agent-working.sh clears the flag on turn start for both CLIs" {
  local hook="$BLUEPRINT_ROOT/configs/claude/hooks/agent-working.sh"
  run bash "$hook" <<< '{"prompt":"go"}'
  [ "$status" -eq 0 ]
  grep -qx -- '--clear' "$HOME/notify-args"
  grep -q 'agent-working.sh' "$BLUEPRINT_ROOT/configs/claude/settings.json"
  grep -q '.claude/hooks/agent-working.sh|overwrite|configs/claude/hooks/agent-working.sh' \
    "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  grep -q '^\[\[hooks.UserPromptSubmit\]\]' "$BLUEPRINT_ROOT/configs/codex/requirements.toml"
  grep -q 'hooks/agent-working.sh' "$BLUEPRINT_ROOT/configs/codex/requirements.toml"
}

@test "agent-working.sh distiller sessions never touch the flag" {
  export LLMWIKI_DISTILLER=1
  run bash "$BLUEPRINT_ROOT/configs/claude/hooks/agent-working.sh" <<< '{}'
  unset LLMWIKI_DISTILLER
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/notify-args" ]
}
