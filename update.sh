#!/bin/bash
# update.sh — postStartCommand runner. Updates claude + opencode binaries
# on every devpod container start. Shipped from aiCodingBaseSetup, fetched
# via `curl https://.../update.sh | bash` from devcontainer.json.
set -euo pipefail

SELF="$HOME/.aicodingsetup/update.sh"
SOURCE_URL="https://raw.githubusercontent.com/vossiman/aiCodingBaseSetup/main/update.sh"

# universal:6 leaks broken multi-line BASH_FUNC_nvs%% / BASH_FUNC_nvsudo%%
# / BASH_FUNC_nvm%% env exports into every shell devpod spawns. Bash fails
# to import them ("syntax error: unexpected end of file") on startup. The
# only way to actually strip them is `env -u` at the process boundary —
# `unset` from inside bash silently does nothing because the names contain
# `%%`, which bash rejects as an invalid identifier. See KNOWN_ISSUES.md.
# We self-stash so $0 is a real path we can re-exec under env -u.
if [[ "${_NVS_STRIPPED:-}" != 1 ]]; then
  mkdir -p "$(dirname "$SELF")"
  curl -fsSL "$SOURCE_URL" -o "$SELF"
  exec env -u 'BASH_FUNC_nvs%%' -u 'BASH_FUNC_nvsudo%%' -u 'BASH_FUNC_nvm%%' \
    _NVS_STRIPPED=1 bash "$SELF" "$@"
fi

# === actual work ===
claude update    2>/dev/null || true
opencode upgrade 2>/dev/null || true
