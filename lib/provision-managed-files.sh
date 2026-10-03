# lib/provision-managed-files.sh - installer side of blueprint-managed files.
# Relies on blueprint-deploy.sh plus install.sh globals/loggers; sourced only.

_aicoding_initial_config_ready() {
  local dest=$1 reason classification_rc=2
  # Local-source development changes where bytes come from; it must not waive
  # destination safety. Load the classifier even on an offline legacy install,
  # where install_mcp_packages may have returned before sourcing it.
  if ! declare -F aicoding_config_shared_root >/dev/null 2>&1; then
    _provision_ensure_update_components >/dev/null 2>&1 || {
      _AICODING_INITIAL_CONFIG_DEFERRED=1
      warn "preserving $dest because destination compatibility is unavailable"
      return 1
    }
  fi
  if aicoding_config_shared_root "$dest" >/dev/null; then
    classification_rc=0
  else
    classification_rc=$?
  fi
  # Preserve the legacy local-development interface only for a root that the
  # classifier positively identifies as local.
  if [ "${AICODING_REQUIRE_UPDATE_RECEIPT:-0}" != 1 ] \
      && [ "$classification_rc" -eq 1 ]; then
    return 0
  fi
  # Installer main acquires all managed-root locks before mode detection and
  # classification. Direct helper callers acquire the relevant root here.
  if [ "$classification_rc" -ne 1 ]; then
    if [ "${_AICODING_INSTALL_SHARED_LOCKS_READY:-}" = 0 ] \
        || { [ "${_AICODING_INSTALL_SHARED_LOCKS_READY:-}" != 1 ] \
          && ! aicoding_shared_locks_acquire "$dest"; }; then
      _AICODING_INITIAL_CONFIG_DEFERRED=1
      warn "preserving $dest because its shared writer lock is busy"
      return 1
    fi
  fi
  if declare -F aicoding_config_is_compatible >/dev/null 2>&1 \
      && reason=$(AICODING_REQUIRE_UPDATE_RECEIPT=1 \
        aicoding_config_is_compatible "$dest"); then
    return 0
  fi
  [ -n "$reason" ] || reason=runtime_compatibility_unavailable
  _AICODING_INITIAL_CONFIG_REASON=$reason
  if [ "$reason" = cursor_not_installed ]; then
    warn "skipping $dest: no supported Linux agent or cursor-agent found on PATH; host profile does not install absent tools ($reason)"
  elif [[ "$reason" == *_not_installed ]]; then
    warn "skipping $dest: ${reason%_not_installed} is not installed ($reason)"
  else
    _AICODING_INITIAL_CONFIG_DEFERRED=1
    warn "preserving $dest because its runtime is not ready ($reason)"
  fi
  return 1
}

_aicoding_managed_source_version() {
  local root=$1 marker
  marker=$(cat "$root/.aicoding-version" 2>/dev/null || true)
  if [[ "$marker" =~ ^[0-9a-f]{40}$ ]]; then printf '%s\n' "$marker"; return 0; fi
  git -C "$root" rev-parse HEAD 2>/dev/null || printf 'unknown\n'
}

# Installer side of managed config: the same pass as aicoding-sync, gated
# per destination by _aicoding_initial_config_ready (shared-root lock and
# tool readiness). Returns nonzero only when a write failed.
_install_config_gate() {
  _AICODING_INITIAL_CONFIG_REASON=
  _aicoding_initial_config_ready "$1" >&2 && return 0
  printf '%s\n' "$_AICODING_INITIAL_CONFIG_REASON"
  return 1
}

install_managed_config() {
  header "Managed config"
  local rc=0 dest
  MANAGED_CONFIG_GATE=_install_config_gate managed_config_apply || rc=1
  for dest in "${!MANAGED_RESULT[@]}"; do
    [[ "${MANAGED_RESULT[$dest]}" == blocked:* ]] && _AICODING_INITIAL_CONFIG_DEFERRED=1
  done
  if [[ "$rc" -eq 0 && "${_AICODING_INITIAL_CONFIG_DEFERRED:-0}" != 1 ]]; then
    aicoding_stamp_blueprint "$(_aicoding_managed_source_version "$SCRIPT_DIR")"
    aicoding_remove_legacy_state
  fi
  return "$rc"
}

# Managed component lists (used for unmanaged component detection).
# MANAGED_MCPS / MANAGED_PLUGINS live in lib/provision.sh (sourced below,
# after the colored loggers are defined) — shared with aicoding-sync so both
# reconcile the same MCP/plugin set.
MANAGED_HOOKS=("agent-working.sh" "custom-statusline.js" "bw-deny-files.sh" "check-archived-docs.sh" "llmwiki-distill.sh" "agent-waiting.sh" "memory-hint.sh" "opus-verbosity.sh" "fable-guidance.sh" "redact-sessions-hook.sh" "redact-sessions-pending.sh" "kanban-work-hook.sh")
# Skills are whatever skills/ ships; the deploy loop above enumerates the
# same dir. A hand-kept list here only falls behind and then flags a shipped
# skill as unmanaged (review-by-harness, 2026-09-08).
MANAGED_SKILLS=()
for _skill_dir in "$SCRIPT_DIR/skills"/*/; do
  [[ -d "$_skill_dir" ]] || continue
  _skill_dir="${_skill_dir%/}"
  MANAGED_SKILLS+=("${_skill_dir##*/}")
done
unset _skill_dir

# --- Report unmanaged components ---
report_unmanaged() {
  header "Checking for unmanaged components"

  # Check MCPs in Claude Code
  if command -v claude &>/dev/null; then
    local mcp_list
    mcp_list="$(claude mcp list 2>/dev/null || true)"
    while IFS= read -r line; do
      # Lines with MCP names look like: "name: command..."
      if [[ "$line" =~ ^([a-zA-Z0-9_-]+):\ .* ]]; then
        local mcp_name="${BASH_REMATCH[1]}"
        # Skip plugin-provided MCPs (e.g. plugin:playwright:playwright)
        [[ "$mcp_name" == plugin* ]] && continue
        # Skip health check lines
        [[ "$mcp_name" == "Checking" ]] && continue
        local managed=false
        for m in "${MANAGED_MCPS[@]}"; do
          [[ "$mcp_name" == "$m" ]] && managed=true && break
        done
        if [[ "$managed" == "false" ]]; then
          info "Found MCP '$mcp_name' not managed by this installer — leaving untouched"
        fi
      fi
    done <<< "$mcp_list"
  fi

  # Check hooks
  if [[ -d "$CLAUDE_DIR/hooks" ]]; then
    for hook_file in "$CLAUDE_DIR/hooks"/*; do
      [[ ! -f "$hook_file" ]] && continue
      local hook_name
      hook_name="$(basename "$hook_file")"
      [[ "$hook_name" == *.bak.* ]] && continue
      local managed=false
      for m in "${MANAGED_HOOKS[@]}"; do
        [[ "$hook_name" == "$m" ]] && managed=true && break
      done
      # Also skip infra hooks (managed by their own installer)
      [[ "$hook_name" == infra-* ]] && managed=true
      if [[ "$managed" == "false" ]]; then
        info "Found hook '$hook_name' not managed by this installer — leaving untouched"
      fi
    done
  fi

  # Check skills
  if [[ -d "$CLAUDE_DIR/skills" ]]; then
    for skill_dir in "$CLAUDE_DIR/skills"/*/; do
      [[ ! -d "$skill_dir" ]] && continue
      local skill_name
      skill_name="$(basename "$skill_dir")"
      local managed=false
      for m in "${MANAGED_SKILLS[@]}"; do
        [[ "$skill_name" == "$m" ]] && managed=true && break
      done
      # Also skip infra skills (managed by their own installer)
      [[ "$skill_name" == infra-* ]] && managed=true
      # Claude Code's own store for skills synced from the claude.ai account.
      [[ "$skill_name" == synced ]] && managed=true
      if [[ "$managed" == "false" ]]; then
        info "Found skill '$skill_name' not managed by this installer — leaving untouched"
      fi
    done
  fi
}

# _print_install_summary [outcome] — one fixed-format line for log scrapers.
_print_install_summary() {
  local commit dest updated=0
  commit=$(_aicoding_managed_source_version "$SCRIPT_DIR")
  for dest in "${!MANAGED_RESULT[@]}"; do
    [[ "${MANAGED_RESULT[$dest]}" == updated ]] && updated=$((updated + 1))
  done
  printf 'INSTALL %s  blueprint %s  updated %d\n' "${1:-OK}" "${commit:0:7}" "$updated"
}

# remove_legacy_project_templates: /scaffold-project was retired (it never
# worked in-container: the secrets deny hook blankets ~/.aicodingsetup, so the
# command could not read its own template mirror there). The reference layout
# stays in the repo at templates/project/; agents copy it from the blueprint
# checkout instead. This cleans up the old mirror, which would otherwise
# persist forever in the host mount.
remove_legacy_project_templates() {
  local legacy_dir="$SECRETS_DIR/templates/project"
  [[ -d "$legacy_dir" ]] || return 0
  rm -rf "$legacy_dir"
  rmdir "$SECRETS_DIR/templates" 2>/dev/null || true
  ok "removed legacy project-template mirror ($legacy_dir)"
}
