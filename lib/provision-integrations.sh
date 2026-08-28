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

# --- agent-notify CLI symlink ---
# Flags a waiting tmux window. Called by
# Claude Code's Notification hook, codex's notify hook, and tmux alert hooks.
install_agent_notify_symlink() {
  header "agent-notify CLI"
  local src="$SCRIPT_DIR/bin/agent-notify" dest="$HOME/.local/bin/agent-notify"
  [[ -f "$src" ]] || { warn "bin/agent-notify not found — skipping"; return; }
  mkdir -p "$HOME/.local/bin"; chmod +x "$src"; ln -sf "$src" "$dest"
  ok "agent-notify installed at $dest -> $src"
}

# --- clipboard-bridge shims (container only) ---
# Fake xclip/wl-paste that answer agent CLIs' image-paste reads from the dvw
# clipboard bridge socket (/tmp/dvw-clip.sock, reverse-forwarded to the
# client's dvw-clipd). Containers have no real clipboard tools, so shadowing
# the names is safe; NEVER install these on a host profile — hosts have real
# clipboards and real tools.
install_clip_shim_symlinks() {
  header "clipboard-bridge shims (xclip, wl-paste)"
  local src="$SCRIPT_DIR/bin/clip-shim" name
  [[ -f "$src" ]] || { warn "bin/clip-shim not found — skipping"; return; }
  mkdir -p "$HOME/.local/bin"; chmod +x "$src"
  for name in xclip wl-paste; do
    ln -sf "$src" "$HOME/.local/bin/$name"
  done
  ok "clip shims installed at ~/.local/bin/{xclip,wl-paste} -> $src"
}

# --- kanban board client ---
# The homelab backlog (kanban.dataprospectors.at) authenticates agents with a
# bearer token kept in the shared secrets store. An agent cannot use it
# directly: the secrets deny hook refuses any command that expands
# $KANBAN_TOKEN, and it cannot tell "send it in a header" from "print it".
# kanban-post is the same answer git got — a helper that reads the store
# itself, so the value never appears in a command an agent writes.
install_kanban_post_symlink() {
  header "kanban board client"
  local src="$SCRIPT_DIR/bin/kanban-post"
  [[ -f "$src" ]] || { warn "bin/kanban-post not found — skipping"; return; }
  mkdir -p "$HOME/.local/bin"; chmod +x "$src"
  ln -sf "$src" "$HOME/.local/bin/kanban-post"
  ok "kanban-post installed at ~/.local/bin/kanban-post -> $src"
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
# declared in configs/tmux/tmux.conf (sensible, catppuccin, fzf, thumbs).
# Without this, the trailing `run '~/.tmux/plugins/tpm/tpm'` in tmux.conf
# exits 127 and the theme + fzf/thumbs bindings are all dead. Idempotent:
# re-running just updates clones in place. Note TPM sources only *declared*
# plugins, so dropping a @plugin line is enough to disable it — an orphaned
# ~/.tmux/plugins dir is inert (prune it with prefix + Alt-u).
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

  if [[ ! -d "$(playwright_cache_dir)" ]] && [[ ! -d "$HOME/Library/Caches/ms-playwright" ]]; then
    warn "Playwright browsers not found"
    info "Run: npx playwright install"
    return 0
  fi
  ok "Playwright browsers installed"

  # A downloaded browser is not a working browser — report unresolved system
  # libraries here too, so a Chromium that can't launch can't pass as a green
  # check (helpers live in lib/provision-system.sh).
  local bin missing rc=0
  bin="$(playwright_chromium_bin)" || return 0
  missing="$(playwright_missing_libs "$bin")" || rc=$?
  if [[ $rc -ne 0 ]]; then
    warn "Playwright chromium present but unreadable — ldd failed (truncated download?)"
    info "Run: npx playwright install --force chromium"
  elif [[ -n "$missing" ]]; then
    warn "Playwright system libraries missing: $(tr '\n' ' ' <<<"$missing")"
    info "Run: sudo npx playwright install-deps chromium"
  else
    ok "Playwright system libraries present"
  fi
}

# ensure_homelab_wiki — host-profile step: agents expect ~/homelab-wiki
# (global CLAUDE.md tells them to consult it). Clone if missing; fail-open
# (agents clone on demand per their own instructions).
ensure_homelab_wiki() {
  header "homelab-wiki"
  if [[ -d "$HOME/homelab-wiki/.git" ]]; then
    ok "~/homelab-wiki already present"
    return 0
  fi
  if [[ "${AICODINGSETUP_SKIP_NETWORK:-}" == "1" ]]; then
    info "Skipping homelab-wiki clone (network provisioning disabled)"
    return 0
  fi
  # Capture into a var and branch on `if out=$(...)`, not a piped `git clone
  # | tail -1` with a separate PIPESTATUS check: under install-host.sh's
  # `set -euo pipefail` + ERR trap, a failing command left of a pipe still
  # aborts the whole installer before the PIPESTATUS check ever runs. `if
  # out=$(...)` puts the failing command directly in the `if` condition,
  # which is the one place errexit is suspended for it.
  # GIT_TERMINAL_PROMPT=0: with no usable credential helper this must fail
  # into the warn path below, never hang on an interactive username prompt.
  local out
  if out=$(GIT_TERMINAL_PROMPT=0 git clone https://github.com/vossiman/homelab-wiki "$HOME/homelab-wiki" 2>&1); then
    ok "cloned ~/homelab-wiki"
  else
    printf '%s\n' "$out" | tail -1
    warn "homelab-wiki clone failed — agents will clone on demand"
  fi
  return 0
}
