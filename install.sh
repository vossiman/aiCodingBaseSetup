#!/usr/bin/env bash
set -euo pipefail
set -E
_CURRENT_STEP="(startup)"
trap '_rc=$?; printf "INSTALL FAILED  step=%s  line=%s\n" "$_CURRENT_STEP" "$LINENO" >&2; exit "$_rc"' ERR

# ============================================================================
# AI Coding Base Setup — Installer/Updater
# Configures Claude Code and opencode with shared MCPs, skills, hooks, plugins
# Container installer (bash). Direct WSL uses install-host.sh.
# Native Windows is unsupported (see contrib/windows/).
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
: "${AICODING_BLUEPRINT_CLONE:=$SCRIPT_DIR}"
export AICODING_BLUEPRINT_CLONE

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
  local force_reinstall=0 persistent_provision_failed=0
  local _AICODING_INITIAL_CONFIG_DEFERRED=0 _AICODING_PREPARATION_DEFERRED=0
  local _AICODING_GUARDED_PROVISION_DEFERRED=0
  local _AICODING_INSTALL_SHARED_LOCKS_READY=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force-reinstall) force_reinstall=1; shift ;;
      *) shift ;;
    esac
  done

  if [[ "${ENV_TYPE:-}" == wsl ]]; then
    err "Container installer cannot run directly in WSL; use --profile host with bootstrap-aicoding.sh. For a local blueprint: AICODING_PROFILE=host aicoding-install --blueprint /path/to/checkout"
    return 1
  fi

  header "AI Coding Base Setup"

  seed_github_known_host

  if [[ $force_reinstall -eq 1 ]]; then
    info "--force-reinstall: deleting existing manifest"
    rm -f "$AICODING_MANIFEST"
  fi

  load_or_prompt_secrets
  # Authenticate git and gh HERE, not only at sync time. install-host.sh has
  # done this since the 2026-08-12 Mint field failure; the container profile
  # never did, so the ONLY path that ever logged gh in was _sync_plumbing on
  # boot — one unretried network call per container start, fail-open at five
  # points. Three containers were found with gh unauthenticated after a
  # rebuild, each needing a manual `aicoding-sync --yes` to recover, because a
  # rebuild runs install.sh and install.sh did not do this. All three are
  # idempotent and fail-open, so running them here and again on the next boot
  # sync costs nothing and makes a rebuild a second chance instead of a hole.
  ensure_gh_credential_helper
  ensure_gh_stored_auth
  ensure_git_credential_file_fallback
  # Hold writer locks before any tool-owned mutation or managed-file mode
  # detection. A busy shared root is handled per destination as a deferral so
  # confirmed-local setup can continue.
  _provision_recover_scheduler_locks
  if ! aicoding_shared_locks_acquire_managed_roots; then
    _AICODING_INSTALL_SHARED_LOCKS_READY=0
  fi
  report_unmanaged
  install_mcp_packages \
    || { warn "MCP package preparation failed"; persistent_provision_failed=1; }
  if [[ "${AICODING_PERSISTENT_ENROLLMENT:-0}" == 1 ]]; then
    aicoding_prepare_installed_config_tools </dev/null \
      || { warn "Tool update failed; dependent config will remain unchanged"; persistent_provision_failed=1; }
    aicoding_prepare_exact_mcps --register-claude </dev/null \
      || { warn "Exact MCP preparation failed; dependent config will remain unchanged"; persistent_provision_failed=1; }
    export AICODING_REQUIRE_UPDATE_RECEIPT=1
  fi
  install_claude_mcps \
    || { warn "Claude MCP provisioning failed"; persistent_provision_failed=1; }
  ensure_claude_onboarding_state
  install_claude_plugins \
    || { warn "Claude plugin provisioning failed"; persistent_provision_failed=1; }
  install_codex_plugins \
    || { warn "Codex plugin provisioning failed"; persistent_provision_failed=1; }
  install_aicoding_sync_symlink
  install_aicoding_install_symlink
  install_update_status_symlink
  install_aicoding_auto_update_symlink
  install_agent_notify_symlink
  install_dvw_probe_symlink
  install_clip_shim_symlinks
  install_kanban_post_symlink
  install_measure_remote_symlink
  install_dokploy_api_symlink
  install_bugsink_api_symlink
  install_kuma_admin_symlink
  install_redact_transcript_symlink
  install_redact_sessions_symlinks
  install_clip_x11_bridge_symlink
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

  remove_legacy_project_templates
  ensure_agents_skills_symlink
  ensure_codex_managed_hooks
  install_tmux_plugins
  install_bubblewrap \
    || { warn "bw-AICode provisioning failed"; persistent_provision_failed=1; }
  install_infra_audit
  check_playwright
  ensure_lfs_autopull_safe
  ensure_aicoding_auto_update

  # Provisioning completed — stamp the commit for the ⬆install staleness check.
  # Fail-open: a non-repo blueprint (curl bootstrap) just skips the stamp.
  if [[ "$persistent_provision_failed" == 1 ]]; then
    command -v aicoding_result_record >/dev/null 2>&1 \
      && aicoding_result_record provision failed "$(_aicoding_managed_source_version "$SCRIPT_DIR")" partial_provision_failure || true
    header "Incomplete"
    warn "Required provisioning is incomplete; a scheduled pass will retry"
    return 1
  elif [[ "${_AICODING_INITIAL_CONFIG_DEFERRED:-0}" == 1 \
      || "${_AICODING_GUARDED_PROVISION_DEFERRED:-0}" == 1 \
      || ( "${AICODING_PERSISTENT_ENROLLMENT:-0}" == 1 \
        && "${_AICODING_PREPARATION_DEFERRED:-0}" == 1 ) ]]; then
    command -v aicoding_result_record >/dev/null 2>&1 \
      && aicoding_result_record provision blocked "$(_aicoding_managed_source_version "$SCRIPT_DIR")" preparation_deferred || true
    if [[ "${AICODING_PERSISTENT_ENROLLMENT:-0}" == 1 ]]; then
      header "Enrolled with deferrals"
      info "Runtime enrollment succeeded; some tool or configuration changes were deferred"
    else
      header "Completed with deferrals"
      info "Some tool or configuration changes were deferred"
    fi
    _print_install_summary DEFERRED
    return 0
  else
    manifest_stamp_provision "$(_aicoding_managed_source_version "$SCRIPT_DIR")"
  fi

  header "Done!"
  info "Mode: $mode"
  info "Secrets: $SECRETS_FILE"
  info "Claude Code: $CLAUDE_DIR"

  _print_install_summary
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
