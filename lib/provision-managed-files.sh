# lib/provision-managed-files.sh - initial deployment, adoption, and
# conservative reconciliation of blueprint-managed files. Relies on
# blueprint-deploy.sh plus install.sh globals/loggers; sourced only.

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
        AICODING_REQUIRE_SHARED_COMPATIBILITY=1 \
        aicoding_config_is_compatible "$dest"); then
    return 0
  fi
  [ -n "$reason" ] || reason=runtime_compatibility_unavailable
  _AICODING_INITIAL_CONFIG_DEFERRED=1
  warn "preserving $dest because its runtime is not ready ($reason)"
  return 1
}

_aicoding_managed_source_version() {
  local root=$1 marker
  marker=$(cat "$root/.aicoding-version" 2>/dev/null || true)
  if [[ "$marker" =~ ^[0-9a-f]{40}$ ]]; then printf '%s\n' "$marker"; return 0; fi
  git -C "$root" rev-parse HEAD 2>/dev/null || printf 'unknown\n'
}

# deploy_all_managed_files — wraps every managed-file deployment in a single
# manifest staging session. Skill files are enumerated from MANAGED_SKILLS.
deploy_all_managed_files() {
  manifest_stage_begin

  local entry dest mode source
  while IFS='|' read -r dest mode source; do
    [[ -z "$dest" ]] && continue
    _aicoding_initial_config_ready "$dest" || continue
    if [[ -f "$SCRIPT_DIR/$source" ]]; then
      # _rendered, not _substituted: the inventory mixes configs with
      # markdown every agent reads (~/.claude/CLAUDE.md, ~/.codex/AGENTS.md,
      # ~/.claude/agents/*.md), and the destination decides which is which.
      deploy_overwrite_file_rendered "$SCRIPT_DIR/$source" "$dest" "$source"
      ok "deployed $dest"
    else
      warn "missing source in blueprint: $source — skipping $dest"
    fi
  done < <(managed_inventory_overwrite)

  while IFS='|' read -r dest mode source; do
    [[ -z "$dest" ]] && continue
    _aicoding_initial_config_ready "$dest" || continue
    if [[ -f "$SCRIPT_DIR/$source" ]]; then
      _ensure_merge_dest "$dest"
      deploy_merge_file_substituted "$SCRIPT_DIR/$source" "$dest" "$source"
      ok "merged $dest"
    fi
  done < <(managed_inventory_merge)

  # ~/.bashrc managed block.
  deploy_marker_block "$HOME/.bashrc" "$(managed_bashrc_block_body)" \
    "$BASHRC_BLOCK_START" "$BASHRC_BLOCK_END"
  ok "managed block written to ~/.bashrc"

  # Skills — every file of every skill dir, via the same enumeration the
  # sync inventory uses (enumerate_skill_files in blueprint-deploy.sh).
  # Divergence between the two paths would get files to_remove'd by sync.
  # Markdown gets {{HOME}} expanded and NOTHING else (CAF-003: an agent must
  # read a skill to use it, so a substituted credential landed in model
  # context on every use). Everything else (binaries, CSS, JSON) deploys
  # verbatim — the sed substitution pass corrupts non-text files.
  mkdir -p "$CLAUDE_DIR/skills"
  local skill_dir skill_rel src_file dest_file
  for skill_dir in "$SCRIPT_DIR/skills"/*/; do
    [[ -d "$skill_dir" && ! -f "$skill_dir/SKILL.md" ]] && warn "no SKILL.md in $skill_dir"
  done
  while IFS= read -r skill_rel; do
    [[ -z "$skill_rel" ]] && continue
    src_file="$SCRIPT_DIR/skills/$skill_rel"
    dest_file="$CLAUDE_DIR/skills/$skill_rel"
    mkdir -p "$(dirname "$dest_file")"
    if [[ "$skill_rel" == *.md ]]; then
      deploy_overwrite_file_prose "$src_file" "$dest_file" "skills/$skill_rel"
    else
      deploy_overwrite_file "$src_file" "$dest_file" "skills/$skill_rel"
    fi
    ok "skill file $skill_rel installed"
  done < <(enumerate_skill_files "$SCRIPT_DIR/skills")

  # Slash commands — dynamic enumeration, parallel to skills.
  mkdir -p "$CLAUDE_DIR/commands"
  local cmd_file cmd_name
  for cmd_file in "$SCRIPT_DIR/commands"/*.md; do
    [[ ! -f "$cmd_file" ]] && continue
    cmd_name=$(basename "$cmd_file")
    deploy_overwrite_file_prose "$cmd_file" "$CLAUDE_DIR/commands/$cmd_name" "commands/$cmd_name"
    ok "command $cmd_name installed"
  done

  # Record blueprint origin/commit metadata at the top of the manifest.
  local commit origin
  commit=$(_aicoding_managed_source_version "$SCRIPT_DIR")
  origin=$(blueprint_origin "$SCRIPT_DIR")
  manifest_stage_set_blueprint "$commit" "$origin"

  manifest_stage_commit
}

# Managed component lists (used for unmanaged component detection).
# MANAGED_MCPS / MANAGED_PLUGINS live in lib/provision.sh (sourced below,
# after the colored loggers are defined) — shared with aicoding-sync so both
# reconcile the same MCP/plugin set.
MANAGED_HOOKS=("agent-working.sh" "custom-statusline.js" "bw-deny-files.sh" "check-archived-docs.sh" "llmwiki-distill.sh" "agent-waiting.sh" "memory-hint.sh" "opus-verbosity.sh" "fable-guidance.sh" "redact-sessions-hook.sh" "redact-sessions-pending.sh")
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
# JSON merge lives in lib/blueprint-deploy.sh as _json_merge_into (unions both
# permissions.allow and permissions.deny). Do not reintroduce a local merger.

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
      # Skip the installer's own timestamped backups (_backup_file siblings).
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
      if [[ "$managed" == "false" ]]; then
        info "Found skill '$skill_name' not managed by this installer — leaving untouched"
      fi
    done
  fi
}

# install_mcp_packages / install_claude_mcps / install_claude_plugins live in
# lib/provision.sh (shared with aicoding-sync).
# Detect which deploy mode this install.sh run should use.
detect_install_mode() {
  if [[ -f "$AICODING_MANIFEST" ]]; then
    echo "reconcile"
    return
  fi
  # No manifest. Check whether any managed files already exist on disk.
  # Capture the inventory BEFORE looping: an early `return` while the process
  # substitution is still writing SIGPIPEs the producer's heredoc `cat`, and
  # with `set -E` + the ERR trap that subshell prints a phantom
  # "INSTALL FAILED ... line=414" even though nothing failed (dataEnv
  # rebuild, 2026-08-17). Command substitution waits for the producer, so
  # there is no concurrent writer left to kill.
  local inventory dest
  inventory=$(managed_inventory_overwrite; managed_inventory_merge)
  while IFS='|' read -r dest _ _; do
    [[ -z "$dest" ]] && continue
    [[ -e "$dest" ]] && { echo "adopt"; return; }
  done <<< "$inventory"
  [[ -f "$HOME/.bashrc" ]] && grep -qxF "$BASHRC_BLOCK_START" "$HOME/.bashrc" \
    && { echo "adopt"; return; }
  # Legacy: today's install.sh appends a standalone Go-PATH export to
  # ~/.bashrc. Its presence signals a prior install, so treat as adopt
  # (adopt_existing_files strips the line before deploying the managed block).
  [[ -f "$HOME/.bashrc" ]] \
    && grep -qxF 'export PATH="/usr/local/go/bin:$PATH"' "$HOME/.bashrc" \
    && { echo "adopt"; return; }
  echo "first"
}

# adopt_existing_files — record current hashes for existing managed files
# without overwriting them. Files missing on disk are still deployed.
adopt_existing_files() {
  manifest_stage_begin
  local dest mode source
  local -a adopted=() deployed=()

  while IFS='|' read -r dest mode source; do
    [[ -z "$dest" ]] && continue
    _aicoding_initial_config_ready "$dest" || continue
    if [[ -e "$dest" ]]; then
      local h
      h=$(compute_managed_hash "$dest")
      manifest_set_file "$dest" \
        "$(jq -n --arg s "$source" --arg h "$h" \
            '{mode:"overwrite",source:$s,deployed_hash:$h}')"
      adopted+=("$dest")
    elif [[ -f "$SCRIPT_DIR/$source" ]]; then
      # Same dest-driven choice as deploy_all_managed_files above; adopt must
      # not be the one path that still substitutes secrets into prose.
      deploy_overwrite_file_rendered "$SCRIPT_DIR/$source" "$dest" "$source"
      deployed+=("$dest")
    fi
  done < <(managed_inventory_overwrite)

  while IFS='|' read -r dest mode source; do
    [[ -z "$dest" ]] && continue
    _aicoding_initial_config_ready "$dest" || continue
    if [[ -e "$dest" ]]; then
      manifest_set_file "$dest" \
        "$(jq -n --arg s "$source" '{mode:"merge",source:$s}')"
      adopted+=("$dest")
    elif [[ -f "$SCRIPT_DIR/$source" ]]; then
      _ensure_merge_dest "$dest"
      deploy_merge_file_substituted "$SCRIPT_DIR/$source" "$dest" "$source"
      deployed+=("$dest")
    fi
  done < <(managed_inventory_merge)

  # One-time fixup: today's install.sh appends a standalone Go-PATH export
  # to ~/.bashrc. The managed block now absorbs this export, so we strip
  # the standalone line during adopt to avoid duplication.
  if [[ -f "$HOME/.bashrc" ]]; then
    local tmp_bashrc
    tmp_bashrc=$(mktemp)
    grep -vxF 'export PATH="/usr/local/go/bin:$PATH"' "$HOME/.bashrc" > "$tmp_bashrc" || true
    mv "$tmp_bashrc" "$HOME/.bashrc"
  fi

  # ~/.bashrc managed block — adopt if marker block exists, else deploy.
  if [[ -f "$HOME/.bashrc" ]] && grep -qxF "$BASHRC_BLOCK_START" "$HOME/.bashrc"; then
    local h
    h=$(compute_block_hash "$HOME/.bashrc" "$BASHRC_BLOCK_START" "$BASHRC_BLOCK_END")
    manifest_set_file "$HOME/.bashrc" \
      "$(jq -n --arg s "$BASHRC_BLOCK_START" --arg e "$BASHRC_BLOCK_END" --arg h "$h" \
          '{mode:"marker_block",source:"(composed)",marker_start:$s,marker_end:$e,deployed_block_hash:$h}')"
    adopted+=("$HOME/.bashrc")
  else
    deploy_marker_block "$HOME/.bashrc" "$(managed_bashrc_block_body)" \
      "$BASHRC_BLOCK_START" "$BASHRC_BLOCK_END"
    deployed+=("$HOME/.bashrc")
  fi

  local commit origin
  commit=$(_aicoding_managed_source_version "$SCRIPT_DIR")
  origin=$(blueprint_origin "$SCRIPT_DIR")
  manifest_stage_set_blueprint "$commit" "$origin"

  manifest_stage_commit

  info "Adopt mode: ${#adopted[@]} existing managed files captured into manifest:"
  local f
  for f in "${adopted[@]}"; do info "    $f"; done
  if [[ ${#deployed[@]} -gt 0 ]]; then
    info "Adopt mode: ${#deployed[@]} new managed files deployed from blueprint:"
    for f in "${deployed[@]}"; do info "    $f"; done
  fi
  info "Adopted files were not modified. To see what diverges from the blueprint,"
  info "run: aicoding-sync --dry-run"
}

# reconcile_existing_install — manifest exists; classify each managed file
# and auto-apply only the conservative bucket set (restore, will_update,
# drifted_but_aligned, merge, plus new_file where the dest is absent).
# new_file_existing and to_remove are skipped — replacing a personal file at
# a newly managed path stays with the human-driven `aicoding-sync`.
#
# Strictly more conservative than `aicoding-sync --yes`: never auto-applies
# drifted_and_updating or to_remove, because automatic provisioning should
# never silently overwrite or delete files the user has touched.
reconcile_existing_install() {
  export AICODING_BLUEPRINT_CLONE="$SCRIPT_DIR"

  declare -gA BUCKETS FILE_MODE FILE_SOURCE
  classify_managed_files

  # Owned overwrite files self-heal even in the conservative reconcile path.
  local _d
  for _d in "${!BUCKETS[@]}"; do
    if [[ "${BUCKETS[$_d]}" == drifted_and_updating ]] && _is_owned_overwrite "$_d"; then
      BUCKETS[$_d]=will_update_owned
    fi
  done

  # A persistent enrollment may be reconciling an existing installation.
  # Apply the same destination capability and shared-consumer gate used by a
  # fresh deployment before any actionable bucket reaches the write engine.
  for _d in "${!BUCKETS[@]}"; do
    case "${BUCKETS[$_d]}" in
      drifted_and_updating|new_file_existing|to_remove)
        report_managed_conflict "$_d" "${BUCKETS[$_d]}"
        _AICODING_INITIAL_CONFIG_DEFERRED=1
        ;;
      restore|new_file|will_update|will_update_owned|drifted_but_aligned|merge)
        _aicoding_initial_config_ready "$_d" || BUCKETS[$_d]=blocked
        ;;
    esac
  done

  manifest_stage_begin
  apply_managed_buckets "restore new_file will_update will_update_owned drifted_but_aligned merge"
  # Stamp the blueprint commit/origin we reconciled to, so the manifest's
  # recorded version matches what's actually deployed. Without this, reconcile
  # leaves blueprint_commit stale (first-deploy/adopt set it, reconcile didn't),
  # which makes anything reading it — e.g. the update notifier — report wrongly.
  local rc_commit rc_origin
  rc_commit=$(_aicoding_managed_source_version "$SCRIPT_DIR")
  rc_origin=$(blueprint_origin "$SCRIPT_DIR")
  manifest_stage_set_blueprint "$rc_commit" "$rc_origin"
  manifest_stage_commit

  # Counts for the end-of-run summary. drifted_but_aligned is auto-handled
  # (silent hash refresh) and not counted.
  local n_new=0 n_restored=0 n_updated=0 n_merged=0 n_drifted=0 n_to_review=0
  local dest bucket
  for dest in "${!BUCKETS[@]}"; do
    bucket=${BUCKETS[$dest]}
    case "$bucket" in
      new_file)             n_new=$((n_new+1)) ;;
      new_file_existing)    n_to_review=$((n_to_review+1)) ;;
      restore)              n_restored=$((n_restored+1)) ;;
      will_update)          n_updated=$((n_updated+1)) ;;
      will_update_owned)    n_updated=$((n_updated+1)) ;;
      merge)                n_merged=$((n_merged+1)) ;;
      drifted_and_updating) n_drifted=$((n_drifted+1)) ;;
      to_remove)            n_to_review=$((n_to_review+1)) ;;
    esac
  done

  _RECONCILE_NEW=$n_new
  _RECONCILE_RESTORED=$n_restored
  _RECONCILE_UPDATED=$n_updated
  _RECONCILE_MERGED=$n_merged
  _RECONCILE_DRIFTED=$n_drifted
  _RECONCILE_TO_REVIEW=$n_to_review
}

# _print_install_summary — emit the fixed-format summary line plus an
# optional NOTE follow-up. Counters default to 0 when not set by the mode.
_print_install_summary() {
  local commit_short
  commit_short=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)
  local n_new=${_RECONCILE_NEW:-0}
  local n_restored=${_RECONCILE_RESTORED:-0}
  local n_updated=${_RECONCILE_UPDATED:-0}
  local n_merged=${_RECONCILE_MERGED:-0}
  local n_drifted=${_RECONCILE_DRIFTED:-0}
  local n_to_review=${_RECONCILE_TO_REVIEW:-0}
  printf 'INSTALL OK  blueprint %s  new %d  restored %d  updated %d  merged %d  drifted %d  to_review %d\n' \
    "$commit_short" "$n_new" "$n_restored" "$n_updated" "$n_merged" "$n_drifted" "$n_to_review"
  if (( n_drifted > 0 || n_to_review > 0 )); then
    printf 'NOTE: %d drifted file(s), %d file(s) to review. Run aicoding-sync to address.\n' \
      "$n_drifted" "$n_to_review"
  fi
}

# remove_legacy_project_templates: /scaffold-project was retired (it never
# worked in-container: the secrets deny hook blankets ~/.aicodingsetup, so the
# command could not read its own template mirror there). The reference layout
# stays in the repo at templates/project/; agents copy it from the blueprint
# checkout instead. This cleans up the old mirror, which lived outside the
# manifest and would otherwise persist forever in the host mount.
remove_legacy_project_templates() {
  local legacy_dir="$SECRETS_DIR/templates/project"
  [[ -d "$legacy_dir" ]] || return 0
  rm -rf "$legacy_dir"
  rmdir "$SECRETS_DIR/templates" 2>/dev/null || true
  ok "removed legacy project-template mirror ($legacy_dir)"
}
