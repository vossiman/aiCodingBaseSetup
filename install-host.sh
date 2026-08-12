#!/usr/bin/env bash
set -euo pipefail
set -E
_CURRENT_STEP="(startup)"
trap '_rc=$?; printf "INSTALL FAILED  step=%s  line=%s\n" "$_CURRENT_STEP" "$LINENO" >&2; exit "$_rc"' ERR

# ============================================================================
# AI Coding Base Setup — Host Installer (core only, no sudo)
# Thin-client profile for bare hosts: Claude Code + MCPs + managed dotfiles,
# without the container-only tooling (tmux build, codex/cursor, ssh-agent
# watch, playwright, infra audit, templates). See install.sh for the
# container/devbox profile.
# ============================================================================

# Microsoft's devcontainer universal images ship `/etc/profile` sourcing
# `/usr/local/nvs/nvs.sh` (and `/etc/bash.bashrc` sourcing `nvm.sh`), which
# `export -f` multi-line `nvs`/`nvsudo`/`nvm` bash functions. Some layer in
# the devpod/docker-exec/su chain truncates multi-line BASH_FUNC env values
# to one line — known issue, see VSCode #3928 and vscode-remote-release
# #9457. Every child bash that inherits the truncated env then errors with
# `syntax error: unexpected end of file` on import.
#
# Failed-import env vars can't be removed from inside bash:
#   - `unset -f nvs` is a no-op because the function was never defined
#   - `unset 'BASH_FUNC_nvs%%'` silently fails because `%%` is not a valid
#     identifier, so bash refuses to unset it
# Only `env -u` at the process boundary actually strips them. Self-reexec.
if [[ "${_AICODINGSETUP_NVS_STRIPPED:-}" != 1 ]]; then
  exec env -u 'BASH_FUNC_nvs%%' -u 'BASH_FUNC_nvsudo%%' -u 'BASH_FUNC_nvm%%' \
    _AICODINGSETUP_NVS_STRIPPED=1 bash "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Shared deployment library — used by both install.sh and aicoding-sync.
. "$SCRIPT_DIR/lib/blueprint-deploy.sh"
# Auth plumbing helpers (seed_github_known_host, credential helpers, …).
. "$SCRIPT_DIR/lib/sync.sh"

# Managed file inventory + marker-block content live in lib/blueprint-deploy.sh
# (managed_inventory_overwrite, managed_inventory_merge, managed_bashrc_*).
# Cache the marker strings once; the body is re-emitted on each deploy.
BASHRC_BLOCK_START="$(managed_marker_block_start)"
BASHRC_BLOCK_END="$(managed_marker_block_end)"

CLAUDE_DIR="$HOME/.claude"
SECRETS_DIR="$HOME/.aicodingsetup"
SECRETS_FILE="$SECRETS_DIR/.secrets.env"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()  { echo -e "${BLUE}INFO:${NC} $*"; }
ok()    { echo -e "${GREEN}  OK:${NC} $*"; }
warn()  { echo -e "${YELLOW}WARN:${NC} $*"; }
err()   { echo -e "${RED}ERROR:${NC} $*"; }
header(){
  _CURRENT_STEP="$*"
  echo -e "\n${GREEN}=== $* ===${NC}"
}

# Host profile: inventories and day-2 sync branch on this. Exported before
# any lib call so the very first classify/deploy pass is host-shaped.
export AICODING_PROFILE=host

. "$SCRIPT_DIR/lib/provision.sh"
. "$SCRIPT_DIR/lib/provision-system.sh"

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then check_prerequisites_host; fi

. "$SCRIPT_DIR/lib/provision-secrets.sh"
. "$SCRIPT_DIR/lib/provision-managed-files.sh"
. "$SCRIPT_DIR/lib/provision-integrations.sh"

main() {
  local force_reinstall=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force-reinstall) force_reinstall=1; shift ;;
      *) shift ;;
    esac
  done

  header "AI Coding Base Setup — host profile (core only)"

  seed_github_known_host

  if [[ $force_reinstall -eq 1 ]]; then
    info "--force-reinstall: deleting existing manifest"
    rm -f "$AICODING_MANIFEST"
  fi

  load_or_prompt_secrets
  ensure_claude_code
  report_unmanaged
  install_mcp_packages
  install_claude_mcps
  ensure_claude_onboarding_state
  install_claude_plugins
  install_aicoding_sync_symlink
  install_aicoding_install_symlink
  install_update_status_symlink
  remove_deprecated_shims

  local mode
  if [[ $force_reinstall -eq 1 ]]; then
    mode=first
  else
    mode=$(detect_install_mode)
  fi

  case "$mode" in
    first)
      info "Mode: first-deploy (no manifest, no managed files on disk)"
      deploy_all_managed_files
      ;;
    adopt)
      info "Mode: adopt-existing (no manifest, managed files present)"
      adopt_existing_files
      ;;
    reconcile)
      info "Mode: reconcile (manifest exists — restoring missing files, applying safe blueprint updates)"
      reconcile_existing_install
      ;;
  esac

  # AFTER the mode case (writing the manifest earlier would make
  # detect_install_mode see "reconcile" on a fresh machine), and BEFORE the
  # fail-open extras below (install_bubblewrap, ensure_homelab_wiki) so a
  # crash in one of those can't leave the machine without a profile stamp.
  manifest_set_profile host

  install_bubblewrap
  ensure_homelab_wiki

  manifest_stamp_provision "$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || true)"

  header "Done!"
  info "Mode: $mode  (profile: host)"
  info "Secrets: $SECRETS_FILE"
  info "Claude Code: $CLAUDE_DIR"

  _print_install_summary
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
