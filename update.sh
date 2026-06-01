#!/bin/bash
# update.sh — postStartCommand runner. Updates claude + opencode binaries
# on every devpod container start. Invoked two ways:
#   - submodule projects:  bash devpod/aicoding/update.sh    ($0 is a real file)
#   - self-contained:      curl -fsSL .../update.sh | bash   ($0 is the bash bin)
set -uo pipefail

SOURCE_URL="https://raw.githubusercontent.com/vossiman/aiCodingBaseSetup/main/update.sh"

# universal:6 leaks broken multi-line BASH_FUNC_nvs%% / BASH_FUNC_nvsudo%%
# / BASH_FUNC_nvm%% env exports into every shell devpod spawns. Bash fails
# to import them ("syntax error: unexpected end of file") on startup. The
# only way to actually strip them is `env -u` at the process boundary —
# `unset` from inside bash silently does nothing because the names contain
# `%%`, which bash rejects as an invalid identifier. See KNOWN_ISSUES.md.
#
# We re-exec under env -u, but `bash` needs a REAL script path to re-run. Under
# `curl ... | bash`, $0 is the bash binary itself (e.g. /usr/bin/bash), so
# `bash "$0"` tries to execute that ELF as a script — "cannot execute binary
# file", exit 126, which aborts the devcontainer postStart. Note $0 there IS a
# readable file, so an `-f` guard is not enough; we key off the basename and
# stash a real copy to ~/.aicodingsetup/update.sh when we weren't run from one.
if [[ "${_NVS_STRIPPED:-}" != 1 ]]; then
  self="$0"
  if [[ "$(basename -- "$self")" == bash || ! -r "$self" ]]; then
    self="$HOME/.aicodingsetup/update.sh"
    mkdir -p "$(dirname "$self")"
    curl -fsSL "$SOURCE_URL" -o "$self" || { echo "WARN: could not stash update.sh — skipping update" >&2; exit 0; }
  fi
  exec env -u 'BASH_FUNC_nvs%%' -u 'BASH_FUNC_nvsudo%%' -u 'BASH_FUNC_nvm%%' \
    _NVS_STRIPPED=1 bash "$self" "$@"
fi

warn() { printf 'WARN: %s\n' "$*" >&2; }

# Surface ~/.local/bin where install.sh's ensure_* functions drop the four
# CLIs (claude, opencode, codex, agent). postStartCommand runs in a non-
# interactive shell that doesn't source ~/.bashrc, so PATH lacks ~/.local/bin
# unless we add it here. Without this, every update line below fails with
# "command not found" on every container start — silent skip until you read
# the postStart log carefully. Discovered during Plan 3 verification.
export PATH="$HOME/.local/bin:$PATH"

# Seed GitHub's SSH host key so git-over-SSH (forwarded agent) works on this
# start. Fresh containers have an empty ~/.ssh/known_hosts, so the first push/pull
# dies with "Host key verification failed" before auth. install.sh seeds this on
# create; doing it here too means already-running containers self-heal on their
# next start without a rebuild. Fingerprint-verified (not TOFU), idempotent.
seed_github_known_host() {
  local expected="SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"  # GitHub's published ed25519 fingerprint
  local kh="$HOME/.ssh/known_hosts" tmp scanned
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"; touch "$kh"
  ssh-keygen -F github.com -f "$kh" >/dev/null 2>&1 && return 0
  tmp="$(mktemp)"
  if ! ssh-keyscan -t ed25519 github.com >"$tmp" 2>/dev/null || [[ ! -s "$tmp" ]]; then
    warn "ssh-keyscan github.com failed (offline?) — git over SSH may prompt"; rm -f "$tmp"; return 0
  fi
  scanned="$(ssh-keygen -lf "$tmp" | awk '{print $2}')"
  if [[ "$scanned" == "$expected" ]]; then
    cat "$tmp" >>"$kh"
  else
    warn "github.com host-key fingerprint mismatch ($scanned) — NOT seeding"
  fi
  rm -f "$tmp"
}
seed_github_known_host

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
