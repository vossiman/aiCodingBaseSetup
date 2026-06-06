#!/bin/bash
# on-start.sh — postStartCommand boot hook. Bootstrap prologue (nvs-strip, PATH,
# blueprint clone) then run the unified sync in --boot mode. Fail-open.
# Invoked two ways:
#   - submodule projects:  bash devpod/aicoding/on-start.sh   ($0 is a real file)
#   - self-contained:      curl -fsSL .../on-start.sh | bash  ($0 is the bash bin)
set -uo pipefail

SOURCE_URL="https://raw.githubusercontent.com/vossiman/aiCodingBaseSetup/main/on-start.sh"

# universal:6 leaks broken multi-line BASH_FUNC_nvs%% / BASH_FUNC_nvsudo%%
# / BASH_FUNC_nvm%% env exports into every shell devpod spawns. Bash fails to
# import them ("syntax error: unexpected end of file") on startup. The only way
# to actually strip them is `env -u` at the process boundary — `unset` from
# inside bash silently does nothing because the names contain `%%`, which bash
# rejects as an invalid identifier. See KNOWN_ISSUES.md.
#
# We re-exec under env -u, but `bash` needs a REAL script path to re-run. Under
# `curl ... | bash`, $0 is the bash binary itself (e.g. /usr/bin/bash), so
# `bash "$0"` tries to execute that ELF as a script — "cannot execute binary
# file", exit 126, which aborts the devcontainer postStart. Note $0 there IS a
# readable file, so an `-f` guard is not enough; we key off the basename and
# stash a real copy to ~/.aicodingsetup/on-start.sh when we weren't run from one.
if [[ "${_NVS_STRIPPED:-}" != 1 ]]; then
  self="$0"
  if [[ "$(basename -- "$self")" == bash || ! -r "$self" ]]; then
    self="$HOME/.aicodingsetup/on-start.sh"
    mkdir -p "$(dirname "$self")"
    curl -fsSL "$SOURCE_URL" -o "$self" || { echo "WARN: could not stash on-start.sh" >&2; exit 0; }
  fi
  exec env -u 'BASH_FUNC_nvs%%' -u 'BASH_FUNC_nvsudo%%' -u 'BASH_FUNC_nvm%%' \
    _NVS_STRIPPED=1 bash "$self" "$@"
fi

# Surface ~/.local/bin where install.sh's ensure_* functions drop the CLIs
# (claude, opencode, codex, agent) and aicoding-sync. postStartCommand runs in a
# non-interactive shell that doesn't source ~/.bashrc, so PATH lacks ~/.local/bin
# unless we add it here. Without this, aicoding-sync (and the CLIs it refreshes)
# are "command not found" on every container start.
export PATH="$HOME/.local/bin:$PATH"

: "${AICODING_BLUEPRINT_CLONE:=/tmp/aicoding}"

# Plumbing (ssh-agent watcher, GitHub host key), config reconcile and throttled
# binary refresh all live in aicoding_sync now — let it own the work. Fail-open:
# a transient sync error must never block container start.
if command -v aicoding-sync >/dev/null 2>&1; then
  aicoding-sync --boot || echo "WARN: aicoding-sync failed (non-fatal)" >&2
fi
exit 0
