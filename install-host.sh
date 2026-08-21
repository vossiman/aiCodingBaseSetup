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

# Host day-2 commands must not point into the throwaway tracking clone used by
# aicoding-install/aicoding-sync. Refresh a complete, durable runtime first,
# then re-exec this installer from it so every SCRIPT_DIR-derived CLI symlink
# survives /tmp cleanup and reboot. A tar stream preserves executable modes
# and includes dirty/untracked local-blueprint work exactly as supplied.
_install_host_durable_runtime() {
  local source=$SCRIPT_DIR
  local durable=${AICODING_HOST_BLUEPRINT_DIR:-$HOME/.local/share/aicoding/blueprint}
  local source_real durable_real parent base stage backup exclude=()
  source_real=$(realpath -m "$source") || return 1
  durable_real=$(realpath -m "$durable") || return 1
  [ "$source_real" != "$durable_real" ] || return 0

  parent=$(dirname "$durable_real"); base=$(basename "$durable_real")
  mkdir -p "$parent" || return 1
  stage=$(mktemp -d "$parent/.${base}.stage.XXXXXX") || return 1
  backup=$(mktemp -d "$parent/.${base}.old.XXXXXX") || { rm -rf -- "$stage"; return 1; }
  rmdir -- "$backup" || { rm -rf -- "$stage"; return 1; }
  case "$stage" in
    "$parent"/."$base".stage.*) ;;
    *) rmdir -- "$stage" 2>/dev/null || true; return 1 ;;
  esac
  case "$backup" in
    "$parent"/."$base".old.*) ;;
    *) rm -rf -- "$stage"; return 1 ;;
  esac

  # A deliberately broad source checkout can contain the durable destination
  # (for example source=$HOME). Exclude it from the snapshot to prevent the
  # old runtime or our staging directory recursively copying into itself.
  # --anchored + the ./ prefix pin each pattern to the archive root: tar
  # patterns are unanchored by default, and a bare --exclude=$rel would also
  # silently drop every DEEPER path ending in the same suffix (a legitimate
  # project/.runtime/blueprint elsewhere in the tree).
  local nested rel
  for nested in "$durable_real" "$stage" "$backup"; do
    case "$nested/" in
      "$source_real"/*)
        rel=${nested#"$source_real"/}
        exclude+=(--anchored "--exclude=./$rel")
        ;;
    esac
  done
  if ! tar -C "$source_real" "${exclude[@]}" -cf - . | tar -C "$stage" -xf -; then
    rm -rf -- "$stage"
    return 1
  fi
  if [ -e "$durable_real" ] || [ -L "$durable_real" ]; then
    mv -- "$durable_real" "$backup" || { rm -rf -- "$stage"; return 1; }
  fi
  if ! mv -- "$stage" "$durable_real"; then
    { [ -e "$backup" ] || [ -L "$backup" ]; } && mv -- "$backup" "$durable_real"
    rm -rf -- "$stage"
    return 1
  fi
  if [ -e "$backup" ] || [ -L "$backup" ]; then rm -rf -- "$backup"; fi
  AICODING_HOST_BLUEPRINT_DIR=$durable_real
  export AICODING_HOST_BLUEPRINT_DIR
}

# Sourcing install-host.sh is the library/test contract and stays side-effect
# free. Executing it always finishes from the durable runtime.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _install_host_durable_runtime
  durable_runtime=${AICODING_HOST_BLUEPRINT_DIR:-$HOME/.local/share/aicoding/blueprint}
  if [[ "$(realpath -m "$SCRIPT_DIR")" != "$(realpath -m "$durable_runtime")" ]]; then
    exec env AICODING_BLUEPRINT_CLONE="$durable_runtime" \
      AICODING_HOST_BLUEPRINT_DIR="$durable_runtime" \
      bash "$durable_runtime/install-host.sh" "$@"
  fi
fi

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
  # Register the HTTPS credential helpers NOW, not just at sync time
  # (_sync_plumbing): the wiki clone below and the first boot-sync both
  # need them, and on a bare host nothing else has ever registered them
  # (2026-08-12 Mint field failure: clone prompted for a username).
  ensure_gh_credential_helper
  ensure_git_credential_file_fallback
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

  ensure_codex_managed_hooks
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
