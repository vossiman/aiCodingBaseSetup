#!/usr/bin/env bats
#
# bin/aicoding-ssh-agent-watch --ensure is called from sync while sync holds
# its writer locks. The detached daemon must not inherit those descriptors,
# or the lock stays held for the daemon's lifetime and every later sync
# reports "update already running".

bats_require_minimum_version 1.5.0

setup() {
  : "${BLUEPRINT_ROOT:?unset — run via tests/bats/run.sh}"
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  WATCH="$BLUEPRINT_ROOT/bin/aicoding-ssh-agent-watch"
  mkdir -p "$TMPDIR/stubs"
  # No daemon counts as running, so --ensure always launches one.
  printf '#!/bin/sh\nexit 1\n' > "$TMPDIR/stubs/pgrep"
  chmod +x "$TMPDIR/stubs/pgrep"
  export PATH="$TMPDIR/stubs:$PATH"
  export AICODING_AGENT_SOCK_GLOBS="$TMPDIR/none/*"
  export AICODING_SSH_WATCH_POLL=1
}

teardown() {
  pkill -f "^bash $WATCH\$" 2>/dev/null || true
  case "${TMPDIR:-}" in */tmp.*) rm -rf "$TMPDIR" ;; esac
}

@test "ssh-agent-watch: --ensure daemon does not inherit the caller's lock" {
  lock="$TMPDIR/sync.lock"
  exec 9>"$lock"
  flock -x 9
  run -0 "$WATCH" --ensure
  exec 9>&-
  for _ in $(seq 1 20); do
    command -p pgrep -f "^bash $WATCH\$" >/dev/null && break
    sleep 0.1
  done
  run -0 command -p pgrep -f "^bash $WATCH\$"
  run -0 flock -n "$lock" true
}
