#!/bin/bash
# on-start.sh — container startup maintenance and scheduler enrollment.
# Persistent templates resolve this hook through the active immutable release;
# older templates may still invoke their retained source copy.
# Invoked two ways:
#   - submodule projects:  bash devpod/aicoding/on-start.sh   ($0 is a real file)
#   - self-contained:      curl -fsSL .../on-start.sh | bash  ($0 is the bash bin)
set -uo pipefail

# universal:6 leaks broken multi-line BASH_FUNC_nvs%% / BASH_FUNC_nvsudo%%
# / BASH_FUNC_nvm%% env exports into every shell devpod spawns. Bash fails to
# import them ("syntax error: unexpected end of file") on startup. The only way
# to actually strip them is `env -u` at the process boundary — `unset` from
# inside bash silently does nothing because the names contain `%%`, which bash
# rejects as an invalid identifier. See KNOWN_ISSUES.md.
#
# New templates never curl this hook. A legacy curl-pipe invocation must not
# run this downloaded body or fetch anything else: it hands off to the release
# the updater already activated, or does nothing. The check runs before and
# independently of _NVS_STRIPPED, so an inherited marker cannot skip it. It
# mirrors _aicoding_runtime_release_target (lib/runtime.sh) without sourcing
# anything from the candidate release. Bash reads a piped script one command
# at a time, so this whole branch stays a single compound command.
if [[ "$(basename -- "$0")" == bash || ! -r "$0" ]]; then
  legacy_data="${AICODING_DATA_DIR:-$HOME/.local/share/aicoding}"
  legacy_link="$legacy_data/current/aicoding"
  legacy_target=""
  legacy_hook=""
  if [ -L "$legacy_link" ]; then
    legacy_target=$(readlink -- "$legacy_link" </dev/null) || legacy_target=""
  fi
  legacy_version="${legacy_target#../versions/aicoding/}"
  if [ "$legacy_target" = "../versions/aicoding/$legacy_version" ] \
      && [[ "$legacy_version" =~ ^[A-Za-z0-9._-]+$ ]] \
      && [ "$legacy_version" != . ] && [ "$legacy_version" != .. ]; then
    legacy_release="$legacy_data/versions/aicoding/$legacy_version"
    legacy_candidate="$legacy_release/on-start.sh"
    legacy_release_real=$(readlink -f -- "$legacy_release" </dev/null) || legacy_release_real=""
    legacy_hook_real=$(readlink -f -- "$legacy_candidate" </dev/null) || legacy_hook_real=""
    if [ -d "$legacy_release" ] && [ ! -L "$legacy_release" ] && [ -n "$legacy_release_real" ] \
        && [ -f "$legacy_hook_real" ] && [ -r "$legacy_hook_real" ]; then
      case "$legacy_hook_real" in
        "$legacy_release_real"/*) legacy_hook="$legacy_hook_real" ;;
      esac
    fi
  fi
  if [ -n "$legacy_hook" ]; then
    echo "INFO: legacy curl start hook; running verified runtime $legacy_version" >&2
    exec env -u 'BASH_FUNC_nvs%%' -u 'BASH_FUNC_nvsudo%%' -u 'BASH_FUNC_nvm%%' \
      _NVS_STRIPPED=1 bash "$legacy_hook" "$@" </dev/null
  fi
  echo "WARN: legacy curl start hook and no verified runtime enrolled; migrate postStartCommand to the template form" >&2
  exit 0
fi
if [[ "${_NVS_STRIPPED:-}" != 1 ]]; then
  exec env -u 'BASH_FUNC_nvs%%' -u 'BASH_FUNC_nvsudo%%' -u 'BASH_FUNC_nvm%%' \
    _NVS_STRIPPED=1 bash "$0" "$@"
fi

# Surface ~/.local/bin where install.sh's ensure_* functions drop the CLIs
# (claude, opencode, codex, agent) and aicoding-sync. postStartCommand runs in a
# non-interactive shell that doesn't source ~/.bashrc, so PATH lacks ~/.local/bin
# unless we add it here. Without this, aicoding-sync (and the CLIs it refreshes)
# are "command not found" on every container start.
export PATH="$HOME/.local/bin:$PATH"

auto_update="$HOME/.local/bin/aicoding-auto-update"
if [ -x "$auto_update" ]; then
  "$auto_update" --ensure </dev/null || echo "WARN: automatic updater ensure failed (non-fatal)" >&2
else
  echo "WARN: persistent automatic updater is not enrolled" >&2
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

# T3 Code: restart this workspace's server where the owner enabled it with
# t3-start. State sits on the host mount ~/.t3-envs; Docker creates a missing
# bind source root-owned, so hand it to the user first. Detached like the
# sweep below so DevPod's startup is never held open.
t3_envs="$HOME/.t3-envs"
if [ -d "$t3_envs" ] && [ ! -w "$t3_envs" ] && command -v sudo >/dev/null 2>&1; then
  sudo -n chown "$(id -u):$(id -g)" "$t3_envs" 2>/dev/null \
    || echo "WARN: $t3_envs is not writable; t3 cannot keep its state" >&2
fi
if [ -z "${AICODINGSETUP_SKIP_NETWORK:-}" ] \
    && [ -f "$t3_envs/${DEVPOD_WORKSPACE_ID:-.none}/aicoding/enabled" ] \
    && command -v t3-start >/dev/null 2>&1; then
  mkdir -p "$HOME/.cache/aicoding"
  nohup setsid t3-start --boot </dev/null >>"$HOME/.cache/aicoding/t3-boot.log" 2>&1 &
  echo "INFO: T3 Code boot start dispatched in background"
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
