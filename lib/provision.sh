# lib/provision.sh — machine-state provisioning shared by install.sh and
# aicoding-sync: MCP server registration, marketplace plugins, and the npm
# packages backing stdio MCPs. Everything here is idempotent and fail-open so
# sync can re-run it on every boot (throttled) to converge existing machines,
# not just fresh provisions. Sourced (no shebang / set -e); matches lib/*.sh.

# Managed component lists (also used for unmanaged component detection).
MANAGED_MCPS=("firecrawl" "brave-search" "context7" "playwright" "logfire")
MANAGED_PLUGINS=(
  "superpowers@claude-plugins-official"
  "frontend-design@claude-plugins-official"
  "playwright@claude-plugins-official"
  "code-simplifier@claude-plugins-official"
  "skill-creator@claude-plugins-official"
  "code-review@claude-plugins-official"
  "claude-code-setup@claude-plugins-official"
  "pyright-lsp@claude-plugins-official"
  "context7@claude-plugins-official"
)

# Plugins we used to manage and now actively remove. The logfire plugin's
# bundled MCP server hardcodes the US-region URL with no way to repoint or
# individually disable it — useless against our EU-only Logfire account, and
# it nags "needs authentication" forever. The EU hosted MCP is registered at
# user scope in install_claude_mcps instead.
RETIRED_PLUGINS=(
  "logfire@claude-plugins-official"
)

# Logging fallbacks — install.sh defines colored variants; sync.sh doesn't,
# so plain-echo versions fill in. declare -F (not command -v) so a same-named
# binary on PATH (e.g. texinfo's `info`) can't satisfy the check.
declare -F info   >/dev/null || info()   { echo "INFO: $*"; }
declare -F ok     >/dev/null || ok()     { echo "  OK: $*"; }
declare -F warn   >/dev/null || warn()   { echo "WARN: $*"; }
declare -F header >/dev/null || header() { echo "=== $* ==="; }

# --- MCP npm packages ---
# Install MCP server binaries that aren't run via npx
install_mcp_packages() {
  header "MCP npm packages"

  if ! command -v npm &>/dev/null; then
    warn "npm not found — skipping MCP package installation"
    return
  fi

  local packages=("firecrawl-mcp" "@brave/brave-search-mcp-server")
  for pkg in "${packages[@]}"; do
    if npm list -g "$pkg" &>/dev/null; then
      ok "$pkg already installed"
    else
      if npm install -g "$pkg" 2>/dev/null; then
        ok "$pkg installed"
      else
        warn "Failed to install $pkg — install manually with: npm install -g $pkg"
      fi
    fi
  done
}

# --- Claude Code MCPs ---
install_claude_mcps() {
  header "Claude Code MCPs"

  if ! command -v claude &>/dev/null; then
    warn "Claude Code CLI not found — skipping MCP installation"
    return
  fi

  # firecrawl
  if [[ -n "${FIRECRAWL_API_KEY:-}" ]]; then
    if claude mcp add firecrawl -s user -e "FIRECRAWL_API_KEY=${FIRECRAWL_API_KEY}" -- firecrawl-mcp 2>/dev/null; then
      ok "firecrawl MCP configured"
    elif claude mcp get firecrawl &>/dev/null; then
      ok "firecrawl MCP already configured"
    else
      warn "firecrawl MCP may need manual setup"
    fi
  else
    warn "Skipping firecrawl MCP — no API key"
  fi

  # brave-search
  if [[ -n "${BRAVE_API_KEY:-}" ]]; then
    if claude mcp add brave-search -s user -e "BRAVE_API_KEY=${BRAVE_API_KEY}" -- brave-search-mcp-server 2>/dev/null; then
      ok "brave-search MCP configured"
    elif claude mcp get brave-search &>/dev/null; then
      ok "brave-search MCP already configured"
    else
      warn "brave-search MCP may need manual setup"
    fi
  else
    warn "Skipping brave-search MCP — no API key"
  fi

  # context7 — register at user scope explicitly. The plugin reports
  # "installed" but doesn't always surface the MCP, so we don't rely on it.
  if claude mcp add context7 -s user -- npx -y @upstash/context7-mcp 2>/dev/null; then
    ok "context7 MCP configured"
  elif claude mcp get context7 &>/dev/null; then
    ok "context7 MCP already configured"
  else
    warn "context7 MCP may need manual setup"
  fi

  # playwright — provided by the playwright plugin, not as a standalone MCP
  # The plugin install (install_claude_plugins) handles this
  ok "playwright MCP provided by playwright plugin"

  # logfire — hosted MCP, EU region. The logfire plugin hardcodes the US URL
  # in its bundled .mcp.json (no env override); its README tells EU users to
  # register a user-scope entry at the EU endpoint instead. The plugin's US
  # server stays unauthenticated. Auth: run /mcp once (OAuth).
  if claude mcp add --transport http -s user logfire https://logfire-eu.pydantic.dev/mcp 2>/dev/null; then
    ok "logfire MCP configured (EU)"
  elif claude mcp get logfire &>/dev/null; then
    ok "logfire MCP already configured"
  else
    warn "logfire MCP may need manual setup"
  fi
}

# --- Claude Code marketplace plugins ---
install_claude_plugins() {
  header "Claude Code Plugins"

  if ! command -v claude &>/dev/null; then
    warn "Claude Code CLI not found — skipping plugin installation"
    return
  fi

  local plugin
  for plugin in "${MANAGED_PLUGINS[@]}"; do
    # Try install first; if already installed, try update
    if claude plugin install "$plugin" 2>/dev/null; then
      ok "Installed $plugin"
    elif claude plugin update "$plugin" 2>/dev/null; then
      ok "Updated $plugin"
    else
      # Already installed and up to date, or install failed
      ok "$plugin (already installed)"
    fi
  done

  for plugin in "${RETIRED_PLUGINS[@]}"; do
    if claude plugin uninstall "$plugin" 2>/dev/null; then
      ok "Removed retired plugin $plugin"
    fi
  done
}

# --- Retired CLI shims ---
# aicoding-update and update-status were back-compat symlinks for one release;
# sweep them off existing machines. (install.sh no longer creates them.)
remove_deprecated_shims() {
  rm -f "$HOME/.local/bin/aicoding-update" "$HOME/.local/bin/update-status"
}
