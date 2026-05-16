# Stabilize the forwarded SSH agent socket across devpod / VS Code reconnects.
# devpod forwards the host's ssh-agent into the container, but the inner
# socket path rotates per SSH session — VS Code Remote uses
# /tmp/auth-agent<N>/listener.sock; OpenSSH -A uses /tmp/ssh-XXX/agent.<pid>.
# Long-lived shells (tmux panes spawned before a reconnect) hold the old
# path in SSH_AUTH_SOCK and fail every ssh/git operation until reset.
#
# We route every shell through ~/.ssh/agent.sock, a symlink we maintain.
# A fresh shell with a live forwarded socket re-points the symlink, which
# silently heals every existing pane already exporting SSH_AUTH_SOCK=
# ~/.ssh/agent.sock — they keep the same env path, just with a new target.

_aicoding_stable_sock="$HOME/.ssh/agent.sock"

if [ -n "${SSH_AUTH_SOCK:-}" ] \
   && [ -S "$SSH_AUTH_SOCK" ] \
   && [ "$SSH_AUTH_SOCK" != "$_aicoding_stable_sock" ]; then
  mkdir -p "$HOME/.ssh"
  ln -sfn "$SSH_AUTH_SOCK" "$_aicoding_stable_sock"
fi

if [ -S "$_aicoding_stable_sock" ]; then
  export SSH_AUTH_SOCK="$_aicoding_stable_sock"
fi

unset _aicoding_stable_sock
