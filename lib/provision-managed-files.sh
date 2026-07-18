# lib/provision-managed-files.sh - initial deployment, adoption, and
# conservative reconciliation of blueprint-managed files. Relies on
# blueprint-deploy.sh plus install.sh globals/loggers; sourced only.

# deploy_all_managed_files — wraps every managed-file deployment in a single
# manifest staging session. Skill files are enumerated from MANAGED_SKILLS.
deploy_all_managed_files() {
  manifest_stage_begin

  local entry dest mode source
  while IFS='|' read -r dest mode source; do
    [[ -z "$dest" ]] && continue
    if [[ -f "$SCRIPT_DIR/$source" ]]; then
      deploy_overwrite_file_substituted "$SCRIPT_DIR/$source" "$dest" "$source"
      ok "deployed $dest"
    else
      warn "missing source in blueprint: $source — skipping $dest"
    fi
  done < <(managed_inventory_overwrite)

  while IFS='|' read -r dest mode source; do
    [[ -z "$dest" ]] && continue
    if [[ -f "$SCRIPT_DIR/$source" ]]; then
      mkdir -p "$(dirname "$dest")"
      [[ -f "$dest" ]] || echo '{}' > "$dest"
      deploy_merge_file_substituted "$SCRIPT_DIR/$source" "$dest" "$source"
      ok "merged $dest"
    fi
  done < <(managed_inventory_merge)

  # ~/.bashrc managed block.
  deploy_marker_block "$HOME/.bashrc" "$(managed_bashrc_block_body)" \
    "$BASHRC_BLOCK_START" "$BASHRC_BLOCK_END"
  ok "managed block written to ~/.bashrc"

  # Skills — dynamic enumeration.
  mkdir -p "$CLAUDE_DIR/skills"
  local skill_dir skill_name src_skill dest_dir dest_skill
  for skill_dir in "$SCRIPT_DIR/skills"/*/; do
    [[ ! -d "$skill_dir" ]] && continue
    skill_name=$(basename "$skill_dir")
    src_skill="$skill_dir/SKILL.md"
    dest_dir="$CLAUDE_DIR/skills/$skill_name"
    dest_skill="$dest_dir/SKILL.md"
    [[ ! -f "$src_skill" ]] && { warn "no SKILL.md in $skill_dir"; continue; }
    mkdir -p "$dest_dir"
    deploy_overwrite_file_substituted "$src_skill" "$dest_skill" "skills/$skill_name/SKILL.md"
    ok "skill $skill_name installed"
  done

  # Slash commands — dynamic enumeration, parallel to skills.
  mkdir -p "$CLAUDE_DIR/commands"
  local cmd_file cmd_name
  for cmd_file in "$SCRIPT_DIR/commands"/*.md; do
    [[ ! -f "$cmd_file" ]] && continue
    cmd_name=$(basename "$cmd_file")
    deploy_overwrite_file_substituted "$cmd_file" "$CLAUDE_DIR/commands/$cmd_name" "commands/$cmd_name"
    ok "command $cmd_name installed"
  done

  # Record blueprint origin/commit metadata at the top of the manifest.
  local commit origin
  commit=$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
  origin=$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || echo unknown)
  manifest_stage_set_top blueprint_commit "$commit"
  manifest_stage_set_top blueprint_origin "$origin"

  manifest_stage_commit
}

# Managed component lists (used for unmanaged component detection).
# MANAGED_MCPS / MANAGED_PLUGINS live in lib/provision.sh (sourced below,
# after the colored loggers are defined) — shared with aicoding-sync so both
# reconcile the same MCP/plugin set.
MANAGED_HOOKS=("custom-statusline.js" "bw-deny-files.sh" "check-archived-docs.sh")
MANAGED_SKILLS=("cloudflare-browser")
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
  local dest
  while IFS='|' read -r dest _ _; do
    [[ -z "$dest" ]] && continue
    [[ -e "$dest" ]] && { echo "adopt"; return; }
  done < <(managed_inventory_overwrite; managed_inventory_merge)
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
    if [[ -e "$dest" ]]; then
      local h
      h=$(compute_hash "$dest")
      manifest_set_file "$dest" \
        "$(jq -n --arg s "$source" --arg h "$h" \
            '{mode:"overwrite",source:$s,deployed_hash:$h}')"
      adopted+=("$dest")
    elif [[ -f "$SCRIPT_DIR/$source" ]]; then
      deploy_overwrite_file_substituted "$SCRIPT_DIR/$source" "$dest" "$source"
      deployed+=("$dest")
    fi
  done < <(managed_inventory_overwrite)

  while IFS='|' read -r dest mode source; do
    [[ -z "$dest" ]] && continue
    if [[ -e "$dest" ]]; then
      manifest_set_file "$dest" \
        "$(jq -n --arg s "$source" '{mode:"merge",source:$s}')"
      adopted+=("$dest")
    elif [[ -f "$SCRIPT_DIR/$source" ]]; then
      mkdir -p "$(dirname "$dest")"
      echo '{}' > "$dest"
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
  commit=$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
  origin=$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || echo unknown)
  manifest_stage_set_top blueprint_commit "$commit"
  manifest_stage_set_top blueprint_origin "$origin"

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
# drifted_but_aligned, merge). new_file and to_remove are skipped — they stay
# for the human-driven `aicoding-sync`.
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

  manifest_stage_begin
  apply_managed_buckets "restore new_file will_update will_update_owned drifted_but_aligned merge"
  # Stamp the blueprint commit/origin we reconciled to, so the manifest's
  # recorded version matches what's actually deployed. Without this, reconcile
  # leaves blueprint_commit stale (first-deploy/adopt set it, reconcile didn't),
  # which makes anything reading it — e.g. the update notifier — report wrongly.
  local rc_commit rc_origin
  rc_commit=$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
  rc_origin=$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || echo unknown)
  manifest_stage_set_top blueprint_commit "$rc_commit"
  manifest_stage_set_top blueprint_origin "$rc_origin"
  manifest_stage_commit

  # Counts for the end-of-run summary. drifted_but_aligned is auto-handled
  # (silent hash refresh) and not counted.
  local n_new=0 n_restored=0 n_updated=0 n_merged=0 n_drifted=0 n_to_review=0
  local dest bucket
  for dest in "${!BUCKETS[@]}"; do
    bucket=${BUCKETS[$dest]}
    case "$bucket" in
      new_file)             n_new=$((n_new+1)) ;;
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

# install_templates — mirror the project-scaffold templates into
# ~/.aicodingsetup/templates/project. INTENTIONAL: outside the manifest.
# Scaffold source for /scaffold-project (not user-edited managed dotfiles), so
# every run mirrors the repo tree over (rsync --delete; cp -r fallback).
install_templates() {
  header "Project Templates"

  local src_dir="$SCRIPT_DIR/templates/project"
  local dest_dir="$SECRETS_DIR/templates/project"

  if [[ ! -d "$src_dir" ]]; then
    warn "No templates/project directory in repo — skipping"
    return
  fi

  mkdir -p "$dest_dir"
  if command -v rsync &>/dev/null; then
    rsync -a --delete "$src_dir/" "$dest_dir/"
  else
    rm -rf "$dest_dir"
    mkdir -p "$dest_dir"
    cp -r "$src_dir/." "$dest_dir/"
  fi
  ok "templates/project mirrored to $dest_dir"
}
