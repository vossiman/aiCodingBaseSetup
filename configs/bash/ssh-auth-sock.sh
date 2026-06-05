# Stabilize the forwarded SSH agent socket across devpod / VS Code reconnects.
# devpod forwards the host's ssh-agent into the container, but the inner
# socket path rotates per SSH session — VS Code Remote uses
# /tmp/auth-agent<N>/listener.sock; OpenSSH -A uses /tmp/ssh-XXX/agent.<pid>.
# Long-lived shells (tmux panes spawned before a reconnect) hold the old
# path in SSH_AUTH_SOCK and fail every ssh/git operation until reset.
#
# We route every shell through ~/.ssh/agent.sock, a symlink we maintain, and
# keep it pointed at a LIVE socket via two paths:
#   1. A fresh shell that inherited a live forwarded socket adopts it (and so
#      heals existing panes already exporting SSH_AUTH_SOCK=~/.ssh/agent.sock —
#      same env path, new target).
#   2. If the stable symlink is dead AND nothing live was inherited (e.g. this
#      shell inherited only the already-stale stable path — exactly what
#      non-interactive/tool shells get after a reconnect), discover the newest
#      live forwarded socket on disk and repoint to it. This self-heal is what
#      the old version lacked: it only ever reacted to a fresh inherited socket.
# A background daemon (aicoding-ssh-agent-watch) does the same for processes
# that never source this file.

_aicoding_stable_sock="$HOME/.ssh/agent.sock"

# _aicoding_live <path> — true if <path> is a socket whose agent answers.
# Falls back to a plain socket-file test if ssh-add is unavailable.
_aicoding_live() {
  [ -S "$1" ] || return 1
  command -v ssh-add >/dev/null 2>&1 || return 0
  local rc
  SSH_AUTH_SOCK="$1" ssh-add -l >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 1 ]   # 0=has keys, 1=agent up no keys; 2=dead
}

if [ -n "${SSH_AUTH_SOCK:-}" ] \
   && [ "$SSH_AUTH_SOCK" != "$_aicoding_stable_sock" ] \
   && _aicoding_live "$SSH_AUTH_SOCK"; then
  # 1. Fresh, live inherited socket → adopt as the stable target.
  mkdir -p "$HOME/.ssh"
  ln -sfn "$SSH_AUTH_SOCK" "$_aicoding_stable_sock"
elif ! _aicoding_live "$_aicoding_stable_sock"; then
  # 2. Stable symlink stale and nothing live inherited → hunt for the newest
  #    live forwarded socket and repoint. `ls -1t` orders newest first.
  #    Search paths are overridable (AICODING_AGENT_SOCK_GLOBS) for testing.
  for _aicoding_cand in $(ls -1t ${AICODING_AGENT_SOCK_GLOBS:-/tmp/auth-agent*/listener.sock /tmp/ssh-*/agent.*} 2>/dev/null); do
    if _aicoding_live "$_aicoding_cand"; then
      mkdir -p "$HOME/.ssh"
      ln -sfn "$_aicoding_cand" "$_aicoding_stable_sock"
      break
    fi
  done
fi

# 3. Route this shell through the stable path when it resolves to a live agent.
if _aicoding_live "$_aicoding_stable_sock"; then
  export SSH_AUTH_SOCK="$_aicoding_stable_sock"
fi

unset -f _aicoding_live
unset _aicoding_stable_sock _aicoding_cand
