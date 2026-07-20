# lib/provision-integrations.sh - user-facing CLI links and optional tool
# integrations installed by install.sh. Relies on install.sh globals and
# provision-system.sh environment detection; sourced only.

# --- Claude onboarding state ---
# Without these flags ~/.claude.json, the CLI treats every session as a fresh
# install and prompts for login even when ~/.claude/.credentials.json holds
# valid OAuth tokens (the case in containers that mount creds from the host).
ensure_claude_onboarding_state() {
  header "Claude onboarding state"
  local f="$HOME/.claude.json"
  [[ -f "$f" ]] || echo '{}' > "$f"
  local tmp
  tmp="$(mktemp)"
  jq '. + {hasCompletedOnboarding: true, installMethod: "native"}' "$f" > "$tmp" && mv "$tmp" "$f"
  ok "hasCompletedOnboarding=true, installMethod=native"
}

# --- GitHub SSH host key ---
# Containers start with an empty ~/.ssh/known_hosts, so the first git-over-SSH to
# seed_github_known_host lives in lib/sync.sh (canonical; also used on boot).

# --- aicoding-sync CLI symlink ---
install_aicoding_sync_symlink() {
  header "aicoding-sync CLI"
  local src="$SCRIPT_DIR/bin/aicoding-sync"
  local dest="$HOME/.local/bin/aicoding-sync"
  if [[ ! -f "$src" ]]; then
    warn "bin/aicoding-sync not found in blueprint — skipping symlink"
    return
  fi
  mkdir -p "$HOME/.local/bin"
  ln -sf "$src" "$dest"
  chmod +x "$src"
  ok "aicoding-sync installed at $dest -> $src"
}

# --- aicoding-install CLI symlink ---
install_aicoding_install_symlink() {
  header "aicoding-install CLI"
  local src="$SCRIPT_DIR/bin/aicoding-install"
  local dest="$HOME/.local/bin/aicoding-install"
  if [[ ! -f "$src" ]]; then
    warn "bin/aicoding-install not found in blueprint — skipping symlink"
    return
  fi
  mkdir -p "$HOME/.local/bin"
  ln -sf "$src" "$dest"
  chmod +x "$src"
  ok "aicoding-install installed at $dest -> $src"
}

install_update_status_symlink() {
  header "aicoding-status CLI"
  local src="$SCRIPT_DIR/bin/aicoding-status" dest="$HOME/.local/bin/aicoding-status"
  [[ -f "$src" ]] || { warn "bin/aicoding-status not found — skipping"; return; }
  mkdir -p "$HOME/.local/bin"; chmod +x "$src"; ln -sf "$src" "$dest"
  ok "aicoding-status installed at $dest -> $src"
}

# --- SSH agent socket self-heal watcher (container only) ---
# Deploys the watcher onto PATH. We only DEPLOY here (a pure symlink); the
  # daemon is *started* by on-start.sh on each container start — that keeps full
# install.sh runs (and the bats suite, which run install.sh end-to-end) free of
# a lingering background process. The watcher keeps ~/.ssh/agent.sock pointed at
# the live forwarded ssh-agent for non-interactive processes; the bashrc snippet
# (configs/bash/ssh-auth-sock.sh) covers interactive shells.
install_ssh_agent_watch_symlink() {
  header "SSH agent socket watcher"
  if [[ "$ENV_TYPE" != "container" ]]; then
    info "Skipping (host manages its own ssh-agent)"
    return
  fi
  local src="$SCRIPT_DIR/bin/aicoding-ssh-agent-watch"
  local dest="$HOME/.local/bin/aicoding-ssh-agent-watch"
  if [[ ! -f "$src" ]]; then
    warn "bin/aicoding-ssh-agent-watch not found in blueprint — skipping"
    return
  fi
  mkdir -p "$HOME/.local/bin"
  chmod +x "$src"
  ln -sf "$src" "$dest"
  ok "aicoding-ssh-agent-watch installed at $dest -> $src (started by on-start.sh)"
}

# --- tmux plugins (TPM) ---
# Container-only: bootstraps Tmux Plugin Manager and installs every plugin
# declared in configs/tmux/tmux.conf (resurrect, continuum, catppuccin, fzf,
# thumbs). Without this, the trailing `run '~/.tmux/plugins/tpm/tpm'` in
# tmux.conf exits 127 and the theme + session save/restore + fzf binding
# are all dead. Idempotent: re-running just updates clones in place.
install_tmux_plugins() {
  header "tmux plugins (TPM)"

  # Network provisioning disabled (test suite) — TPM + each plugin is a github
  # clone, slow and hang-prone offline. See AICODINGSETUP_SKIP_NETWORK in run.sh.
  if [[ "${AICODINGSETUP_SKIP_NETWORK:-}" == "1" ]]; then
    info "Skipping TPM install (AICODINGSETUP_SKIP_NETWORK)"
    return
  fi

  if [[ "$ENV_TYPE" != "container" ]]; then
    info "Skipping TPM install (host manages its own tmux plugins)"
    return
  fi

  if ! command -v git &>/dev/null; then
    warn "git not found — skipping TPM install"
    return
  fi

  local tpm_dir="$HOME/.tmux/plugins/tpm"
  if [[ ! -d "$tpm_dir" ]]; then
    git clone --quiet --depth=1 https://github.com/tmux-plugins/tpm "$tpm_dir"
    ok "TPM cloned to $tpm_dir"
  else
    ok "TPM already present at $tpm_dir"
  fi

  # Headless plugin install. Reads `set -g @plugin '...'` lines from
  # ~/.tmux.conf; skips already-cloned plugins. Output is left visible —
  # TPM is verbose on success ("Installing X / download success") and any
  # failure surfaces inline rather than disappearing into /dev/null.
  if [[ -x "$tpm_dir/bin/install_plugins" ]]; then
    if "$tpm_dir/bin/install_plugins"; then
      ok "tmux plugins installed/updated"
    else
      warn "TPM install_plugins exited non-zero (see output above)"
    fi
  else
    warn "$tpm_dir/bin/install_plugins missing or not executable"
  fi
}

# --- bubblewrap (bw-AICode) ---
install_bubblewrap() {
  header "bubblewrap (bw-AICode)"

  # Network provisioning disabled (test suite) — this clones/pulls bw-AICode from
  # github and runs its installer. See AICODINGSETUP_SKIP_NETWORK in run.sh.
  if [[ "${AICODINGSETUP_SKIP_NETWORK:-}" == "1" ]]; then
    info "Skipping bw-AICode (AICODINGSETUP_SKIP_NETWORK)"
    return
  fi

  local vendor_dir="$SCRIPT_DIR/vendor/bw-AICode"

  if [[ -d "$vendor_dir/.git" ]]; then
    info "Updating bw-AICode..."
    git -C "$vendor_dir" pull --ff-only 2>/dev/null && \
      ok "bw-AICode updated" || warn "bw-AICode update failed — check manually"
  else
    info "Cloning bw-AICode..."
    mkdir -p "$SCRIPT_DIR/vendor"
    git clone https://github.com/vossiman/bw-AICode.git "$vendor_dir" 2>/dev/null && \
      ok "bw-AICode cloned" || { err "Failed to clone bw-AICode"; return; }
  fi

  # Run bw-AICode's own installer (bw CLI / sandbox tooling). The
  # bw-deny-files PreToolUse hook is owned by managed_inventory_overwrite
  # (configs/claude/hooks/bw-deny-files.sh); bw's copy is the same content.
  if [[ -f "$vendor_dir/install.sh" ]]; then
    info "Running bw-AICode installer..."
    bash "$vendor_dir/install.sh" && \
      ok "bw-AICode installed" || warn "bw-AICode installer had issues — check output above"
  else
    err "bw-AICode install.sh not found"
  fi
}

# --- infra-audit ---
install_infra_audit() {
  header "infra-audit (python-infra-audit-cc)"

  # infra-audit has its own install mechanism via the repo
  if [[ -f "$CLAUDE_DIR/infra-audit-manifest.json" ]]; then
    info "infra-audit already installed — run /infra-update in Claude Code to update"
  else
    info "infra-audit not installed"
    info "To install, clone https://github.com/vossiman/python-infra-audit-cc and follow its README"
  fi
}

# --- Playwright check ---
check_playwright() {
  header "Playwright"

  if [[ -d "$HOME/.cache/ms-playwright" ]] || [[ -d "$HOME/Library/Caches/ms-playwright" ]]; then
    ok "Playwright browsers installed"
  else
    warn "Playwright browsers not found"
    info "Run: npx playwright install"
  fi
}
