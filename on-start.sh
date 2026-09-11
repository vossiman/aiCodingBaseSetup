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

# Keep the homelab-wiki clone fresh if one exists (cloning is the agent's job
# per the global CLAUDE.md). Gated like every other network call; fail-open.
if [ -z "${AICODINGSETUP_SKIP_NETWORK:-}" ] && [ -d "$HOME/homelab-wiki/.git" ]; then
  git -C "$HOME/homelab-wiki" pull --ff-only --quiet 2>/dev/null \
    || echo "WARN: homelab-wiki pull failed (non-fatal)" >&2
fi

# Resolve the sync entrypoint. ~/.local/bin/aicoding-sync is a SYMLINK into the
# blueprint clone under /tmp (tmpfs). A container restart wipes /tmp, the link
# dangles, and `command -v` fails — and the re-clone that would heal it lives
# inside aicoding-sync itself. Before 2026-08-20 this hook then skipped the sync
# silently, leaving every aicoding-* command "not found" until someone ran the
# submodule copy by hand. Break the loop: fall back to the bin/ next to this
# script (submodule projects), else re-clone the blueprint ourselves
# (self-contained curl|bash projects, where $0 is the stashed copy).
sync_cmd=""
if command -v aicoding-sync >/dev/null 2>&1; then
  sync_cmd=aicoding-sync
else
  echo "WARN: aicoding-sync not on PATH (stale symlink after a /tmp wipe?) — bootstrapping" >&2
  self_dir=$(cd "$(dirname -- "$0")" && pwd -P)
  if [ -x "$self_dir/bin/aicoding-sync" ]; then
    sync_cmd="$self_dir/bin/aicoding-sync"
  elif [ -x "$AICODING_BLUEPRINT_CLONE/bin/aicoding-sync" ]; then
    sync_cmd="$AICODING_BLUEPRINT_CLONE/bin/aicoding-sync"
  elif [ -z "${AICODINGSETUP_SKIP_NETWORK:-}" ]; then
    : "${AICODING_BLUEPRINT_REMOTE:=https://github.com/vossiman/aiCodingBaseSetup}"
    echo "WARN: re-cloning blueprint to $AICODING_BLUEPRINT_CLONE" >&2
    rm -rf "$AICODING_BLUEPRINT_CLONE"
    if git clone --quiet "$AICODING_BLUEPRINT_REMOTE" "$AICODING_BLUEPRINT_CLONE" \
       && [ -x "$AICODING_BLUEPRINT_CLONE/bin/aicoding-sync" ]; then
      sync_cmd="$AICODING_BLUEPRINT_CLONE/bin/aicoding-sync"
    else
      echo "WARN: blueprint clone failed — skipping boot sync (non-fatal)" >&2
    fi
  fi
fi

# Plumbing (ssh-agent watcher, GitHub host key), config reconcile and throttled
# binary refresh all live in aicoding_sync now — let it own the work. Fail-open:
# a transient sync error must never block container start.
if [ -n "$sync_cmd" ]; then
  "$sync_cmd" --boot || echo "WARN: aicoding-sync failed (non-fatal)" >&2
fi

# uv state. ~/.local/share/uv is a host bind mount (devcontainer.json) so the
# interpreters uv downloads survive a rebuild or image bump; before that,
# every rebuild left the workspace's persisted .venv pointing at an
# interpreter that no longer existed, and each .venv/bin/* died with exit
# 127 until someone ran uv by hand (dataEnv, 2026-08-17 and 2026-09-09).
# Docker creates a missing bind source root-owned, so hand it to the user
# first. Then heal a .venv whose interpreter link dangles anyway (first boot
# after this mount arrived, or a .python-version bump).
uv_dir="$HOME/.local/share/uv"
if [ -d "$uv_dir" ] && [ ! -w "$uv_dir" ] && command -v sudo >/dev/null 2>&1; then
  sudo -n chown "$(id -u):$(id -g)" "$uv_dir" 2>/dev/null \
    || echo "WARN: $uv_dir is not writable; uv cannot persist interpreters" >&2
fi
# Two triggers: the interpreter link dangles, or .python-version asks for a
# version the (persisted) venv does not run. The second is a prefix match so
# "3.12" accepts 3.12.7; anything odder just costs one idempotent uv sync.
uv_heal_reason=""
if [ -f uv.lock ] && [ -L .venv/bin/python ] && command -v uv >/dev/null 2>&1; then
  if [ ! -e .venv/bin/python ]; then
    uv_heal_reason="points at a missing interpreter (rebuild or python bump)"
  elif [ -f .python-version ]; then
    uv_want=$(head -n1 .python-version | tr -d '[:space:]' | sed 's/^cpython[@-]//')
    uv_have=$(.venv/bin/python -c 'import platform; print(platform.python_version())' 2>/dev/null || true)
    case "$uv_have" in
      "$uv_want"*) ;;
      *) uv_heal_reason="runs ${uv_have:-nothing}, .python-version wants $uv_want" ;;
    esac
  fi
fi
if [ -n "$uv_heal_reason" ] && [ -z "${AICODINGSETUP_SKIP_NETWORK:-}" ]; then
  echo "uv: .venv $uv_heal_reason; running uv sync" >&2
  timeout 900 uv sync 2>&1 | tail -3 || echo "WARN: uv sync failed (non-fatal)" >&2
fi

# Boot sweep: scrub transcripts left by crashed sessions or other containers.
# Detach from the startup session and its pipes so DevPod can finish while
# the sweep runs to completion. A separate lock skips overlapping boot jobs;
# the scrubber's own state lock still protects individual updates. Gate the
# worker in tests so it cannot outlive a temporary HOME's teardown.
if [ -z "${AICODINGSETUP_SKIP_NETWORK:-}" ] && command -v redact-sessions >/dev/null 2>&1; then
  sweep_state="${REDACT_SESSIONS_STATE:-$HOME/.claude/state/redact-sessions}"
  if (umask 077; mkdir -p "$sweep_state"); then
    nohup setsid flock -n "$sweep_state/boot-sweep.lock" redact-sessions --sweep \
      </dev/null >/dev/null 2>&1 &
    echo "INFO: Transcript redaction sweep dispatched in background"
  fi
fi
exit 0
