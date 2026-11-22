#!/usr/bin/env bats
# Superpowers is retired: install_codex_plugins removes the Codex plugin and
# the skills link earlier syncs made, and leaves user-owned files alone.
setup() {
  : "${BLUEPRINT_ROOT:?run via tests/bats/run.sh}"
  TEST_DIR=$(mktemp -d)
  export HOME="$TEST_DIR/home" LOG="$TEST_DIR/calls"
  unset CODEX_HOME
  export PACKAGE="$HOME/.codex/plugins/cache/openai-curated-remote/superpowers/6.3.0"
  mkdir -p "$PACKAGE/skills/using-superpowers" "$HOME" "$TEST_DIR/bin"
  cat > "$TEST_DIR/bin/codex" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$LOG"
case "$*" in
  'plugin list --json') printf '%s\n' "${LIST_RESULT}" ;;
  'plugin remove '*) exit "${REMOVE_STATUS:-0}" ;;
esac
STUB
  chmod +x "$TEST_DIR/bin/codex"
  export PATH="$TEST_DIR/bin:/usr/bin:/bin"
  export LIST_RESULT='{"installed":[{"pluginId":"superpowers@openai-curated-remote","enabled":true}]}'
  unset REMOVE_STATUS
  . "$BLUEPRINT_ROOT/lib/provision.sh"
}
teardown() { rm -rf "$TEST_DIR"; }

@test "offline sync never launches Codex" {
  run install_codex_plugins
  [ "$status" -eq 0 ]
  [ ! -e "$LOG" ]
}

@test "an installed Superpowers plugin is removed with its managed skills link" {
  export AICODINGSETUP_SKIP_NETWORK=0
  mkdir -p "$HOME/.codex/skills/mine"
  ln -s "$PACKAGE/skills" "$HOME/.codex/skills/superpowers"
  run install_codex_plugins
  [ "$status" -eq 0 ]
  [[ "$output" == *'removed (retired)'* ]]
  grep -qx 'plugin remove superpowers@openai-curated-remote' "$LOG"
  [ ! -e "$HOME/.codex/skills/superpowers" ] && [ ! -L "$HOME/.codex/skills/superpowers" ]
  [ -d "$HOME/.codex/skills/mine" ]
}

@test "nothing installed means no remove call" {
  export AICODINGSETUP_SKIP_NETWORK=0 LIST_RESULT='{"installed":[]}'
  run install_codex_plugins
  [ "$status" -eq 0 ]
  grep -qx 'plugin list --json' "$LOG"
  if grep -q 'plugin remove' "$LOG"; then false; fi
}

@test "a failed removal is fail-open and never claims success" {
  export AICODINGSETUP_SKIP_NETWORK=0 REMOVE_STATUS=1
  run install_codex_plugins
  [ "$status" -eq 0 ]
  [[ "$output" == *'Could not remove'* ]]
  [[ "$output" != *'removed (retired)'* ]]
}

@test "host without Codex skips the step" {
  rm "$TEST_DIR/bin/codex"
  export AICODINGSETUP_SKIP_NETWORK=0
  run install_codex_plugins
  [ "$status" -eq 0 ]
  [ ! -e "$LOG" ]
}

@test "a user-owned Superpowers directory is preserved" {
  export AICODINGSETUP_SKIP_NETWORK=0 LIST_RESULT='{"installed":[]}'
  mkdir -p "$HOME/.codex/skills/superpowers"
  echo keep > "$HOME/.codex/skills/superpowers/mine"
  run install_codex_plugins
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.codex/skills/superpowers/mine")" = keep ]
}

@test "a user-owned Superpowers link elsewhere is preserved" {
  export AICODINGSETUP_SKIP_NETWORK=0 LIST_RESULT='{"installed":[]}'
  mkdir -p "$HOME/my-skills" "$HOME/.codex/skills"
  ln -s "$HOME/my-skills" "$HOME/.codex/skills/superpowers"
  run install_codex_plugins
  [ "$status" -eq 0 ]
  [ "$(readlink "$HOME/.codex/skills/superpowers")" = "$HOME/my-skills" ]
}
