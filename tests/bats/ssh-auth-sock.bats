#!/usr/bin/env bats
#
# Unit tests for configs/bash/ssh-auth-sock.sh — the bashrc snippet that keeps
# ~/.ssh/agent.sock pointed at a LIVE forwarded ssh-agent across reconnects.
#
# Liveness is determined by `ssh-add -l`, which we stub: a socket path listed in
# $LIVE_SOCKS is "live" (exit 0), anything else is "dead" (exit 2). Real AF_UNIX
# socket nodes are created with python3 so the snippet's `[ -S ]` test passes.
# The discovery search path is redirected via AICODING_AGENT_SOCK_GLOBS so the
# test never touches the real /tmp/auth-agent* sockets of the running session.

setup() {
  : "${BLUEPRINT_ROOT:?unset — run via tests/bats/run.sh}"
  SNIPPET="$BLUEPRINT_ROOT/configs/bash/ssh-auth-sock.sh"
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"

  # Stub ssh-add: live iff $SSH_AUTH_SOCK is in $LIVE_SOCKS.
  mkdir -p "$TMPDIR/stubs"
  cat > "$TMPDIR/stubs/ssh-add" <<'STUB'
#!/bin/sh
# Resolve symlinks so the stable ~/.ssh/agent.sock symlink counts as live when
# it points at a socket listed in $LIVE_SOCKS (a real ssh-add connects through
# the symlink to the same agent regardless of the path string).
resolved=$(readlink -f "${SSH_AUTH_SOCK:-}" 2>/dev/null || printf '%s' "${SSH_AUTH_SOCK:-}")
case " ${LIVE_SOCKS:-} " in
  *" $resolved "*) exit 0 ;;   # agent answers, has keys
  *) exit 2 ;;                  # cannot connect to agent
esac
STUB
  chmod +x "$TMPDIR/stubs/ssh-add"
  export PATH="$TMPDIR/stubs:$PATH"
}

teardown() { rm -rf "$TMPDIR"; }

# Create a real AF_UNIX socket node at $1 (left on disk after the process exits).
mksock() { python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$1"; }

@test "ssh-auth-sock: adopts a fresh live inherited socket as the stable target" {
  local a="$TMPDIR/agentA.sock"; mksock "$a"
  export LIVE_SOCKS="$a"
  export SSH_AUTH_SOCK="$a"           # fresh forwarded socket handed in
  # stable symlink does not exist yet

  source "$SNIPPET"

  [ "$(readlink "$HOME/.ssh/agent.sock")" = "$a" ]
  [ "$SSH_AUTH_SOCK" = "$HOME/.ssh/agent.sock" ]
}

@test "ssh-auth-sock: self-heals a dead stable symlink via newest-live discovery" {
  mkdir -p "$TMPDIR/fakesock/a" "$TMPDIR/fakesock/b"
  local old="$TMPDIR/fakesock/a/listener.sock" new="$TMPDIR/fakesock/b/listener.sock"
  mksock "$old"; mksock "$new"
  touch -d '2020-01-01' "$old"        # make `new` unambiguously newest (ls -1t)
  export LIVE_SOCKS="$old $new"       # both alive → newest must win
  export AICODING_AGENT_SOCK_GLOBS="$TMPDIR/fakesock/*/listener.sock"

  # This shell inherited only the already-stale stable path (dangling) — the
  # exact post-reconnect situation the old snippet could not recover from.
  mkdir -p "$HOME/.ssh"
  ln -sfn "$TMPDIR/gone.sock" "$HOME/.ssh/agent.sock"
  export SSH_AUTH_SOCK="$HOME/.ssh/agent.sock"

  source "$SNIPPET"

  [ "$(readlink "$HOME/.ssh/agent.sock")" = "$new" ]
  [ "$SSH_AUTH_SOCK" = "$HOME/.ssh/agent.sock" ]
}

@test "ssh-auth-sock: leaves a dead symlink untouched when nothing live exists" {
  mkdir -p "$TMPDIR/fakesock"            # no sockets inside
  export AICODING_AGENT_SOCK_GLOBS="$TMPDIR/fakesock/*/listener.sock"
  mkdir -p "$HOME/.ssh"
  ln -sfn "$TMPDIR/gone.sock" "$HOME/.ssh/agent.sock"
  export SSH_AUTH_SOCK="$HOME/.ssh/agent.sock"

  source "$SNIPPET"

  # No live socket to point at → the snippet must not invent one.
  [ "$(readlink "$HOME/.ssh/agent.sock")" = "$TMPDIR/gone.sock" ]
}

@test "ssh-auth-sock: ignores a dead inherited socket and falls back to discovery" {
  local dead="$TMPDIR/dead.sock" live="$TMPDIR/fakesock/x/listener.sock"
  mksock "$dead"
  mkdir -p "$TMPDIR/fakesock/x"; mksock "$live"
  export LIVE_SOCKS="$live"            # inherited `dead` is NOT live
  export AICODING_AGENT_SOCK_GLOBS="$TMPDIR/fakesock/*/listener.sock"
  export SSH_AUTH_SOCK="$dead"         # a stale per-session socket handed in

  source "$SNIPPET"

  [ "$(readlink "$HOME/.ssh/agent.sock")" = "$live" ]
  [ "$SSH_AUTH_SOCK" = "$HOME/.ssh/agent.sock" ]
}
