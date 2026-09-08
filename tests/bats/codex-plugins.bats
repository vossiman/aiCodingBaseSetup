#!/usr/bin/env bats
setup() {
  : "${BLUEPRINT_ROOT:?run via tests/bats/run.sh}"
  TEST_DIR=$(mktemp -d)
  export HOME="$TEST_DIR/home" LOG="$TEST_DIR/calls"
  unset CODEX_HOME
  export PACKAGE="$HOME/.codex/plugins/cache/openai-curated-remote/superpowers/6.3.0"
  mkdir -p "$PACKAGE/skills/using-superpowers"
  touch "$PACKAGE/skills/using-superpowers/SKILL.md"
  mkdir -p "$HOME" "$TEST_DIR/bin"
  cat > "$TEST_DIR/bin/codex" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$LOG"
case "$*" in
  'plugin add '*) printf '{"installedPath":"%s"}\n' "$PACKAGE"; exit "${ADD_STATUS:-0}" ;;
  'plugin list --json') printf '%s\n' "${LIST_RESULT}" ;;
esac
STUB
  chmod +x "$TEST_DIR/bin/codex"
  export PATH="$TEST_DIR/bin:/usr/bin:/bin"
  export LIST_RESULT='{"installed":[{"pluginId":"superpowers@openai-curated-remote","enabled":true}]}'
  unset ADD_STATUS
  . "$BLUEPRINT_ROOT/lib/provision.sh"
}
teardown() { rm -rf "$TEST_DIR"; }
@test "offline install never launches Codex" {
  run install_codex_plugins
  [ "$status" -eq 0 ]
  [ ! -e "$LOG" ]
}
@test "Codex plugin install uses native catalog and verifies activation on every run" {
  export AICODINGSETUP_SKIP_NETWORK=0
  run install_codex_plugins
  [ "$status" -eq 0 ]
  [[ "$output" == *'installed, enabled and linked'* ]]
  grep -qx 'plugin add superpowers@openai-curated-remote --json' "$LOG"
  grep -qx 'plugin list --json' "$LOG"
  run install_codex_plugins
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$LOG")" -eq 4 ]
}
@test "failed install is fail-open and never claims success" {
  export AICODINGSETUP_SKIP_NETWORK=0 ADD_STATUS=1
  run install_codex_plugins
  [ "$status" -eq 0 ]
  [[ "$output" == *'Could not install/update'* ]]
  [[ "$output" != *'installed, enabled and linked'* ]]
}
@test "successful install with disabled plugin warns" {
  export AICODINGSETUP_SKIP_NETWORK=0 LIST_RESULT='{"installed":[]}'
  run install_codex_plugins
  [ "$status" -eq 0 ]
  [[ "$output" == *'activation could not be verified'* ]]
}
@test "host without Codex skips installation" {
  rm "$TEST_DIR/bin/codex"
  export AICODINGSETUP_SKIP_NETWORK=0
  run install_codex_plugins
  [ "$status" -eq 0 ]
  [ ! -e "$LOG" ]
}

@test "plugin update refreshes discovery link without touching other skills" {
  export AICODINGSETUP_SKIP_NETWORK=0
  install_codex_plugins
  [ "$(readlink "$HOME/.codex/skills/superpowers")" = "$PACKAGE/skills" ]
  export PACKAGE="$HOME/.codex/plugins/cache/openai-curated-remote/superpowers/6.4.0"
  mkdir -p "$PACKAGE/skills/using-superpowers" "$HOME/.codex/skills/mine"
  touch "$PACKAGE/skills/using-superpowers/SKILL.md"
  install_codex_plugins
  [ "$(readlink "$HOME/.codex/skills/superpowers")" = "$PACKAGE/skills" ]
  [ -d "$HOME/.codex/skills/mine" ]
}
@test "user-owned Superpowers directory is preserved" {
  export AICODINGSETUP_SKIP_NETWORK=0
  mkdir -p "$HOME/.codex/skills/superpowers"
  echo keep > "$HOME/.codex/skills/superpowers/mine"
  run install_codex_plugins
  [ "$status" -eq 0 ]
  [[ "$output" == *'user-owned'* ]]
  [ "$(cat "$HOME/.codex/skills/superpowers/mine")" = keep ]
}
