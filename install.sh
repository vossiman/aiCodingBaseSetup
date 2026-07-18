#!/usr/bin/env bash
set -euo pipefail
set -E
_CURRENT_STEP="(startup)"
trap '_rc=$?; printf "INSTALL FAILED  step=%s  line=%s\n" "$_CURRENT_STEP" "$LINENO" >&2; exit "$_rc"' ERR

# ============================================================================
# AI Coding Base Setup — Installer/Updater
# Configures Claude Code and opencode with shared MCPs, skills, hooks, plugins
# Supports: Linux, WSL (bash). Windows is unsupported (see contrib/windows/).
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
OPENCODE_DIR="$HOME/.config/opencode"
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

# MCP/plugin provisioning — shared with aicoding-sync. Sourced after the
# colored loggers so its plain-echo fallbacks don't kick in here.
. "$SCRIPT_DIR/lib/provision.sh"

# Machine bootstrap and prerequisite checks must load before the direct-run
# guard below. The remaining installer-only modules are loaded after it to
# preserve install.sh's existing top-level execution order.
. "$SCRIPT_DIR/lib/provision-system.sh"

# Top-level actions run only when executed, not when sourced — so tests can
# `source install.sh` to unit-test individual functions without triggering the
# prereq auto-install (and main) as a side effect. `if` (not `&&`) so a sourced
# run's final statement still exits 0 and doesn't trip the caller's set -e.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then check_prerequisites; fi

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

  header "AI Coding Base Setup"

  seed_github_known_host

  if [[ $force_reinstall -eq 1 ]]; then
    info "--force-reinstall: deleting existing manifest"
    rm -f "$AICODING_MANIFEST"
  fi

  load_or_prompt_secrets
  report_unmanaged
  install_mcp_packages
  install_claude_mcps
  ensure_claude_onboarding_state
  install_claude_plugins
  install_aicoding_sync_symlink
  install_aicoding_install_symlink
  install_update_status_symlink
  remove_deprecated_shims
  install_ssh_agent_watch_symlink

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

  install_templates
  install_tmux_plugins
  install_bubblewrap
  install_infra_audit
  check_playwright
  ensure_lfs_autopull_safe

  header "Done!"
  info "Mode: $mode"
  info "Secrets: $SECRETS_FILE"
  info "Claude Code: $CLAUDE_DIR"

  _print_install_summary
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
