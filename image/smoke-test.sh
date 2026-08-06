#!/usr/bin/env bash
# smoke-test.sh <image-ref> — assert the built devbox-base image honors the
# contract provisioning and the blueprint devcontainer.json rely on.
# Runs plain `docker run` checks first, then a privileged dind boot.
set -euo pipefail

IMG="${1:?usage: smoke-test.sh <image-ref>}"

fail=0
check() { # <desc> <cmd...>
  local desc="$1"; shift
  if docker run --rm --user codespace "$IMG" bash -lc "$*" >/dev/null 2>&1; then
    echo "ok:   $desc"
  else
    echo "FAIL: $desc  ($*)" >&2; fail=1
  fi
}

check "user codespace uid 1000"        '[ "$(id -un):$(id -u)" = codespace:1000 ]'
check "passwordless sudo"              'sudo -n true'
check "home is /home/codespace"        '[ "$HOME" = /home/codespace ]'
check "git"                            'command -v git'
check "gh"                             'command -v gh'
check "jq"                             'command -v jq'
check "ripgrep"                        'command -v rg'
check "GNU parallel (not moreutils)"   'parallel --version | head -1 | grep -q "GNU parallel"'
check "bubblewrap"                     'command -v bwrap'
check "kitty terminfo"                 'ls /usr/share/terminfo/x/xterm-kitty /etc/terminfo/x/xterm-kitty 2>/dev/null | grep -q .'
check "node + npm"                     'command -v node && command -v npm'
check "python3"                        'command -v python3'
check "uv seed"                        '[ -x ~/.local/bin/uv ]'
check "tmux runs (deps resolved)"      'tmux -V'
check "tmux commit marker matches"     '[ "$(cat /usr/local/share/aicoding/tmux-commit)" = b07424224b88fcc02bcb9b58d8655f00b97909c6 ]'
check "daemon.json log rotation baked" 'jq -e ".\"log-opts\".\"max-size\" == \"20m\"" /etc/docker/daemon.json'
check "docker-init.sh present"         '[ -x /usr/local/share/docker-init.sh ]'
check "claude seed"                    '[ -x ~/.local/bin/claude ]'
check "opencode seed"                  '[ -x ~/.local/bin/opencode ]'
check "codex seed"                     '[ -x ~/.local/bin/codex ]'
check "cursor-agent seed (both names)" '[ -x ~/.local/bin/agent ] && [ -x ~/.local/bin/cursor-agent ]'
check "no mount-shadowed codex seed"   '[ ! -e ~/.codex ]'
check "locales de_AT + en_US"          'locale -a | grep -qi de_AT.utf8 && locale -a | grep -qi en_US.utf8'
check "no nvs/nvm land mines"          '! ls /usr/local/nvs 2>/dev/null && ! ls /usr/local/share/nvs 2>/dev/null'

echo "-- dind boot (privileged) --"
if docker run --rm --privileged "$IMG" \
     /usr/local/share/docker-init.sh bash -c 'timeout 90 docker info >/dev/null && docker run --rm hello-world >/dev/null' \
     >/dev/null 2>&1; then
  echo "ok:   nested dockerd boots and runs a container"
else
  echo "FAIL: nested dockerd" >&2; fail=1
fi

size_bytes=$(docker image inspect "$IMG" --format '{{.Size}}')
echo "image size: $((size_bytes / 1024 / 1024)) MB"
if [ "$size_bytes" -gt $((4 * 1024 * 1024 * 1024)) ]; then
  echo "FAIL: image exceeds 4GB hard cap (spec target 2-3GB)" >&2; fail=1
fi

exit "$fail"
