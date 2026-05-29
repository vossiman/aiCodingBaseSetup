#!/bin/bash
# update.sh — postStartCommand runner. Updates claude + opencode binaries
# on every devpod container start. Invoked by the parent project's
# devcontainer.json as `bash devpod/aicoding/update.sh`.
set -uo pipefail

# universal:6 leaks broken multi-line BASH_FUNC_nvs%% / BASH_FUNC_nvsudo%%
# / BASH_FUNC_nvm%% env exports into every shell devpod spawns. Bash fails
# to import them ("syntax error: unexpected end of file") on startup. The
# only way to actually strip them is `env -u` at the process boundary —
# `unset` from inside bash silently does nothing because the names contain
# `%%`, which bash rejects as an invalid identifier. See KNOWN_ISSUES.md.
# Re-exec under env -u using $0 (a real submodule path).
if [[ "${_NVS_STRIPPED:-}" != 1 ]]; then
  exec env -u 'BASH_FUNC_nvs%%' -u 'BASH_FUNC_nvsudo%%' -u 'BASH_FUNC_nvm%%' \
    _NVS_STRIPPED=1 bash "$0" "$@"
fi

warn() { printf 'WARN: %s\n' "$*" >&2; }

# === actual work ===
# Failures are non-fatal (a transient upgrade error shouldn't block container
# start) but they're announced — the previous '2>/dev/null || true' hid both.
claude update    || warn "claude update failed (non-fatal — container will still start)"
opencode upgrade || warn "opencode upgrade failed (non-fatal — container will still start)"

# Cursor CLI: 'agent update' (or 'cursor-agent update' on older releases).
# Codex has no in-place update subcommand upstream — re-running the curl-pipe-sh
# installer is the only path, which is too aggressive for postStartCommand-on-
# every-start. Codex stays pinned at install-time; bump manually when wanted.
if command -v agent &>/dev/null; then
  agent update        || warn "agent update failed (non-fatal — container will still start)"
elif command -v cursor-agent &>/dev/null; then
  cursor-agent update || warn "cursor-agent update failed (non-fatal — container will still start)"
fi
