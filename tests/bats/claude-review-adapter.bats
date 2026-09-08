#!/usr/bin/env bats
setup() {
  : "${BLUEPRINT_ROOT:?run via tests/bats/run.sh}"
  TEST_DIR=$(mktemp -d)
  export HOME="$TEST_DIR/home" LOG="$TEST_DIR/args"
  mkdir -p "$HOME" "$TEST_DIR/bin" "$TEST_DIR/repo/.review-round"
  export PATH="$TEST_DIR/bin:$PATH"
  cat > "$TEST_DIR/bin/claude" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" > "$LOG"
echo 'Adapter report'
STUB
  printf '#!/bin/sh\nexit 1\n' > "$TEST_DIR/bin/unshare"
  chmod +x "$TEST_DIR/bin/claude" "$TEST_DIR/bin/unshare"
  git init -q "$TEST_DIR/repo"
  git -C "$TEST_DIR/repo" -c user.name=t -c user.email=t@t commit --allow-empty -qm base
  ADAPTER="$BLUEPRINT_ROOT/skills/review-by-harness/harnesses/claude.sh"
  unset REVIEW_SANDBOX REVIEW_MODEL REVIEW_EFFORT
}
teardown() { rm -rf "$TEST_DIR"; }
@test "Claude review restricts tools and appends rules without disabling hooks" {
  run "$ADAPTER" review "$TEST_DIR/repo" HEAD "$TEST_DIR/repo/.review-round"
  [ "$status" -eq 0 ]
  grep -qx Read,Glob,Grep "$LOG"
  grep -qx dontAsk "$LOG"
  grep -qx -- --strict-mcp-config "$LOG"
  grep -q 'Review session rules' "$LOG"
  if grep -qE 'skip-permissions|disableAllHooks|--bare|--safe-mode' "$LOG"; then false; fi
  [ "$(cat "$TEST_DIR/repo/.review-round/review.md")" = 'Adapter report' ]
}
@test "Claude fix requires appropriate opt-in when namespaces unavailable" {
  REVIEW_APPROVAL=--force run "$ADAPTER" fix "$TEST_DIR/repo" "$TEST_DIR/repo/.review-round"
  [ "$status" -eq 1 ]
  [ ! -e "$LOG" ]
  REVIEW_SANDBOX='-s danger-full-access' run "$ADAPTER" fix "$TEST_DIR/repo" "$TEST_DIR/repo/.review-round"
  [ "$status" -eq 0 ]
  grep -qx acceptEdits "$LOG"
  grep -qx '{"sandbox":{"enabled":false}}' "$LOG"
}
@test "Claude fix uses native sandbox even with full access config on a capable host" {
  printf '#!/bin/sh\nexit 0\n' > "$TEST_DIR/bin/unshare"
  REVIEW_SANDBOX='-s danger-full-access' run "$ADAPTER" fix "$TEST_DIR/repo" "$TEST_DIR/repo/.review-round"
  [ "$status" -eq 0 ]
  grep -qx '{"sandbox":{"enabled":true,"failIfUnavailable":true,"allowUnsandboxedCommands":false}}' "$LOG"
}
