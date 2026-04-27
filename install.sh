#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# AI Coding Base Setup — Installer/Updater
# Configures Claude Code and opencode with shared MCPs, skills, hooks, plugins
# Supports: Linux, WSL (bash only — run install.ps1 on Windows)
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
OPENCODE_DIR="$HOME/.config/opencode"
SECRETS_DIR="$HOME/.aicodingsetup"
SECRETS_FILE="$SECRETS_DIR/.secrets.env"

# Managed component lists (used for unmanaged component detection)
MANAGED_MCPS=("firecrawl" "brave-search" "context7" "playwright")
MANAGED_HOOKS=("custom-statusline.js" "bw-deny-files.sh")
MANAGED_SKILLS=("cloudflare-browser")
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
header(){ echo -e "\n${GREEN}=== $* ===${NC}"; }

# --- Environment Detection ---
detect_environment() {
  if [[ -f /.dockerenv ]] || [[ -f /run/.containerenv ]] \
     || [[ -n "${REMOTE_CONTAINERS:-}" ]] || [[ -n "${DEVCONTAINER:-}" ]] \
     || [[ -n "${CODESPACES:-}" ]]; then
    echo "container"
    return
  fi
  local kernel
  kernel="$(uname -r 2>/dev/null || echo "")"
  if [[ "$kernel" == *microsoft* || "$kernel" == *Microsoft* ]]; then
    echo "wsl"
  else
    echo "linux"
  fi
}

ENV_TYPE="$(detect_environment)"
info "Detected environment: $ENV_TYPE"

# --- Install helpers (used by auto-install in container mode) ---
SUDO=""
if [[ "$(id -u)" -ne 0 ]] && command -v sudo &>/dev/null; then
  SUDO="sudo"
fi

apt_install() {
  if ! command -v apt-get &>/dev/null; then
    err "apt-get not available — cannot auto-install: $*"
    return 1
  fi
  # Tolerate a non-zero update exit — third-party repos (yarn, etc.) often fail
  # on stale GPG keys but the rest of the lists still refresh fine.
  $SUDO apt-get update -qq || warn "apt-get update had issues — continuing"
  DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y --no-install-recommends "$@"
}

ensure_node() {
  command -v npm &>/dev/null && return 0

  # Try common Node installer hooks (nvm, nvs) — non-interactive shells skip rc files
  [[ -f /usr/local/share/nvs/nvs.sh ]] && . /usr/local/share/nvs/nvs.sh >/dev/null 2>&1 && nvs use lts >/dev/null 2>&1 || true
  [[ -f "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]] && . "${NVM_DIR:-$HOME/.nvm}/nvm.sh" >/dev/null 2>&1 || true
  command -v npm &>/dev/null && return 0

  # Fall back to NodeSource (Node 20.x) — apt's npm is too old for modern packages
  if command -v curl &>/dev/null && command -v apt-get &>/dev/null; then
    info "Installing Node.js 20 via NodeSource"
    curl -fsSL https://deb.nodesource.com/setup_20.x | $SUDO -E bash - >/dev/null
    apt_install nodejs
  else
    err "No Node.js available and cannot bootstrap (need curl + apt-get)"
    return 1
  fi
}

npm_install_global() {
  ensure_node || return 1
  # Try unprivileged first (works with user-mode npm prefix); fall back to sudo
  npm install -g "$@" 2>/dev/null || $SUDO npm install -g "$@"
}

ensure_locales() {
  command -v locale-gen &>/dev/null || apt_install locales || return 0
  local need_gen=false
  for loc in "de_AT.UTF-8" "en_US.UTF-8"; do
    local short="${loc%.UTF-8}.utf8"
    if ! locale -a 2>/dev/null | grep -qi "^${short}$"; then
      $SUDO sed -i "s/^# *${loc}/${loc}/" /etc/locale.gen 2>/dev/null || true
      need_gen=true
    fi
  done
  if [[ "$need_gen" == "true" ]]; then
    $SUDO locale-gen >/dev/null 2>&1 || warn "locale-gen failed — locale warnings may persist"
  fi
}

ensure_opencode() {
  command -v opencode &>/dev/null && return 0
  command -v curl &>/dev/null || { warn "curl not available — skipping opencode install"; return 0; }
  info "Installing opencode"
  curl -fsSL https://opencode.ai/install | bash 2>&1 | tail -5 || warn "opencode install failed"
  [[ -d "$HOME/.opencode/bin" ]] && export PATH="$HOME/.opencode/bin:$PATH"
}

ensure_go() {
  command -v go &>/dev/null && return 0
  command -v curl &>/dev/null || { warn "curl not available — skipping Go install"; return 0; }
  local goversion="1.22.5"
  local arch
  case "$(uname -m)" in
    x86_64)  arch="amd64" ;;
    aarch64) arch="arm64" ;;
    *)       warn "unsupported arch for Go install: $(uname -m)"; return 0 ;;
  esac
  info "Installing Go ${goversion}"
  curl -fsSL "https://go.dev/dl/go${goversion}.linux-${arch}.tar.gz" | $SUDO tar -C /usr/local -xz \
    || { warn "Go install failed"; return 0; }
  export PATH="/usr/local/go/bin:$PATH"
  # Persist for future shells in this user
  if [[ -w "$HOME" ]]; then
    grep -q '/usr/local/go/bin' "$HOME/.bashrc" 2>/dev/null || echo 'export PATH="/usr/local/go/bin:$PATH"' >> "$HOME/.bashrc"
  fi
}

ensure_uv() {
  command -v uv &>/dev/null && return 0
  command -v curl &>/dev/null || { warn "curl not available — skipping uv install"; return 0; }
  info "Installing uv (Python package manager)"
  curl -LsSf https://astral.sh/uv/install.sh | sh 2>&1 | tail -3 || { warn "uv install failed"; return 0; }
  [[ -d "$HOME/.local/bin" ]] && export PATH="$HOME/.local/bin:$PATH"
}

ensure_playwright_browsers() {
  command -v npx &>/dev/null || return 0
  local cache_dir="${PLAYWRIGHT_BROWSERS_PATH:-$HOME/.cache/ms-playwright}"
  if [[ -d "$cache_dir" ]] && [[ -n "$(ls -A "$cache_dir" 2>/dev/null)" ]]; then
    ok "Playwright browsers already installed"
    return 0
  fi
  info "Installing Playwright browsers (chromium)"
  npx -y playwright install chromium 2>&1 | tail -5 || warn "Playwright browser install failed"
}

auto_install_prereqs() {
  header "Auto-installing prerequisites"
  command -v git    &>/dev/null || { info "Installing git";    apt_install git; }
  command -v jq     &>/dev/null || { info "Installing jq";     apt_install jq; }
  command -v tmux   &>/dev/null || { info "Installing tmux";   apt_install tmux; }
  command -v bwrap  &>/dev/null || { info "Installing bubblewrap"; apt_install bubblewrap; }
  # Modern terminal terminfos so tmux works for kitty/alacritty/wezterm users.
  infocmp -1 xterm-kitty &>/dev/null || { info "Installing kitty-terminfo"; apt_install kitty-terminfo; }
  command -v claude &>/dev/null || { info "Installing Claude Code CLI"; npm_install_global @anthropic-ai/claude-code; }
  ensure_opencode
  ensure_go
  ensure_uv
  ensure_locales
  ensure_playwright_browsers
}

# --- Prerequisite checks ---
check_prerequisites() {
  # Auto-install on container mode or explicit opt-in (AICODINGSETUP_AUTO_INSTALL=1)
  if [[ "$ENV_TYPE" == "container" ]] || [[ "${AICODINGSETUP_AUTO_INSTALL:-}" == "1" ]]; then
    auto_install_prereqs
  fi

  local missing=()
  command -v git   &>/dev/null || missing+=("git")
  command -v jq    &>/dev/null || missing+=("jq")
  command -v claude &>/dev/null || missing+=("claude (Claude Code CLI)")

  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing required tools: ${missing[*]}"
    err "Please install them and re-run."
    exit 1
  fi

  # opencode is optional — warn if missing
  if ! command -v opencode &>/dev/null; then
    warn "opencode CLI not found — skipping opencode configuration"
  fi
}

check_prerequisites

# --- Secrets Management ---
load_or_prompt_secrets() {
  header "Secrets Management"
  mkdir -p "$SECRETS_DIR"

  local example_file="$SCRIPT_DIR/.secrets.env.example"
  if [[ ! -f "$example_file" ]]; then
    err "Missing .secrets.env.example in repo"
    exit 1
  fi

  # Parse required keys from example file
  local required_keys=()
  while IFS= read -r line; do
    # Skip comments and blank lines
    [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
    local key="${line%%=*}"
    required_keys+=("$key")
  done < "$example_file"

  # Load existing secrets if present
  declare -A secrets
  if [[ -f "$SECRETS_FILE" ]]; then
    info "Found existing secrets file"
    while IFS='=' read -r key value; do
      [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
      secrets["$key"]="$value"
    done < "$SECRETS_FILE"
  else
    info "No secrets file found — will prompt for all keys"
  fi

  # Decide whether we can prompt (no tty, container mode, or env opt-out → no)
  local can_prompt=true
  [[ ! -t 0 ]] && can_prompt=false
  [[ "$ENV_TYPE" == "container" ]] && can_prompt=false
  [[ "${AICODINGSETUP_NONINTERACTIVE:-}" == "1" ]] && can_prompt=false

  # Prompt for missing keys (keys with empty values are treated as "skipped", not missing)
  local prompted=false
  for key in "${required_keys[@]}"; do
    if [[ ! -v "secrets[$key]" ]]; then
      if [[ "$can_prompt" == "true" ]]; then
        prompted=true
        read -rp "Enter $key [or press Enter to skip]: " value
        secrets["$key"]="${value:-}"
      else
        info "$key not set (non-interactive — leaving empty)"
        secrets["$key"]=""
      fi
    else
      if [[ -n "${secrets[$key]}" ]]; then
        ok "$key already set"
      else
        ok "$key skipped (empty)"
      fi
    fi
  done

  # Write secrets file (always rewrite to pick up new keys)
  {
    echo "# AI Coding Base Setup — Secrets"
    echo "# Auto-generated by install.sh — do not commit"
    echo ""
    for key in "${required_keys[@]}"; do
      echo "${key}=${secrets[$key]:-}"
    done
  } > "$SECRETS_FILE"
  chmod 600 "$SECRETS_FILE"

  if [[ "$prompted" == "true" ]]; then
    ok "Secrets saved to $SECRETS_FILE"
  fi

  # Export secrets for use by other functions
  for key in "${required_keys[@]}"; do
    export "$key"="${secrets[$key]:-}"
  done
}

# --- JSON merge helper ---
# Deep merges $2 into $1, writing result to $1
# Arrays in "allow" keys are unioned; objects are recursively merged
# Keys in $1 that don't exist in $2 are preserved
json_merge() {
  local target="$1"
  local source="$2"

  if [[ ! -f "$target" ]]; then
    cp "$source" "$target"
    return
  fi

  # Strategy: use jq recursive merge (.*) for objects, but handle arrays specially
  # For hooks arrays: concatenate and deduplicate by command string
  # For permissions.allow: union arrays
  # For enabledPlugins: merge objects (union keys)
  # For everything else: source wins for scalars, recursive merge for objects

  local merged
  merged="$(jq -s '
    # Deep merge: source values override target, objects merge recursively
    # "allow" arrays are unioned; all other arrays: source wins (preserves order)
    def deep_merge(key):
      if length == 2 then
        .[0] as $a | .[1] as $b |
        if ($a | type) == "object" and ($b | type) == "object" then
          ($a | keys_unsorted) + ($b | keys_unsorted) | unique |
          map(. as $k |
            if ($a | has($k)) and ($b | has($k)) then
              {($k): ([$a[$k], $b[$k]] | deep_merge($k))}
            elif ($b | has($k)) then
              {($k): $b[$k]}
            else
              {($k): $a[$k]}
            end
          ) | add // {}
        elif ($a | type) == "array" and ($b | type) == "array" then
          if key == "allow" then ($a + $b) | unique
          else $b
          end
        else
          if ($b == null or $b == "") then $a else $b end
        end
      else
        .[0]
      end;
    [.[0], .[1]] | deep_merge("")
  ' "$target" "$source")"

  echo "$merged" > "$target"
}

# --- Substitute placeholders in a string ---
substitute_secrets() {
  local content="$1"
  content="${content//\{\{HOME\}\}/$HOME}"
  content="${content//\{\{FIRECRAWL_API_KEY\}\}/${FIRECRAWL_API_KEY:-}}"
  content="${content//\{\{BRAVE_API_KEY\}\}/${BRAVE_API_KEY:-}}"
  content="${content//\{\{CLOUDFLARE_API_TOKEN\}\}/${CLOUDFLARE_API_TOKEN:-}}"
  content="${content//\{\{CLOUDFLARE_ACCOUNT_ID\}\}/${CLOUDFLARE_ACCOUNT_ID:-}}"
  echo "$content"
}

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
}

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

# --- Claude Code settings.json ---
install_claude_settings() {
  header "Claude Code settings.json"

  mkdir -p "$CLAUDE_DIR"

  local base_settings="$SCRIPT_DIR/configs/claude/settings.json"
  local target_settings="$CLAUDE_DIR/settings.json"

  if [[ ! -f "$base_settings" ]]; then
    err "Missing configs/claude/settings.json"
    return
  fi

  # Substitute {{HOME}} placeholder in base settings
  local resolved_settings
  resolved_settings="$(substitute_secrets "$(cat "$base_settings")")"

  # Write to temp file for jq merge
  local tmp_source
  tmp_source="$(mktemp)"
  echo "$resolved_settings" > "$tmp_source"

  # Create target if it doesn't exist
  if [[ ! -f "$target_settings" ]]; then
    echo '{}' > "$target_settings"
  fi

  # Merge: base into existing (existing values preserved, new ones added)
  json_merge "$target_settings" "$tmp_source"

  # Set defaults only if absent
  local tmp_out
  tmp_out="$(mktemp)"

  if jq -e 'has("effortLevel") | not' "$target_settings" &>/dev/null; then
    jq '.effortLevel = "medium"' "$target_settings" > "$tmp_out" && mv "$tmp_out" "$target_settings"
  fi
  if jq -e 'has("skipDangerousModePermissionPrompt") | not' "$target_settings" &>/dev/null; then
    jq '.skipDangerousModePermissionPrompt = true' "$target_settings" > "$tmp_out" && mv "$tmp_out" "$target_settings"
  fi

  rm -f "$tmp_source" "$tmp_out"
  ok "Claude Code settings.json merged"
}

# --- Claude Code marketplace plugins ---
install_claude_plugins() {
  header "Claude Code Plugins"

  if ! command -v claude &>/dev/null; then
    warn "Claude Code CLI not found — skipping plugin installation"
    return
  fi

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
}

# --- opencode configuration ---
install_opencode_config() {
  header "opencode Configuration"

  if ! command -v opencode &>/dev/null; then
    warn "opencode CLI not found — skipping opencode configuration"
    return
  fi

  mkdir -p "$OPENCODE_DIR"

  local base_config="$SCRIPT_DIR/configs/opencode/opencode.json"
  local target_config="$OPENCODE_DIR/opencode.json"

  if [[ ! -f "$base_config" ]]; then
    err "Missing configs/opencode/opencode.json"
    return
  fi

  # Build MCP block from shared definitions with secrets substituted
  local mcps_file="$SCRIPT_DIR/configs/mcps.json"
  local mcp_block
  mcp_block="$(substitute_secrets "$(cat "$mcps_file")")"

  # Transform mcps.json format into opencode format (add "type": "local" to each)
  local opencode_mcps
  opencode_mcps="$(echo "$mcp_block" | jq '
    to_entries | map(
      .value += {"type": "local"} |
      if (.value.environment | length) == 0 then .value |= del(.environment) else . end
    ) | from_entries
  ')"

  # Read base config and inject MCPs
  local resolved_config
  resolved_config="$(jq --argjson mcps "$opencode_mcps" '.mcp = $mcps' "$base_config")"

  # Write to temp file for merge
  local tmp_source
  tmp_source="$(mktemp)"
  echo "$resolved_config" > "$tmp_source"

  # Create target if it doesn't exist
  if [[ ! -f "$target_config" ]]; then
    echo '{}' > "$target_config"
  fi

  json_merge "$target_config" "$tmp_source"

  rm -f "$tmp_source"
  ok "opencode config merged at $target_config"
}

# --- Hooks and statusline ---
install_hooks() {
  header "Hooks & Statusline"

  mkdir -p "$CLAUDE_DIR/hooks"

  # Statusline — always overwrite (repo is source of truth)
  local statusline_src="$SCRIPT_DIR/configs/claude/hooks/custom-statusline.js"
  if [[ -f "$statusline_src" ]]; then
    cp "$statusline_src" "$CLAUDE_DIR/hooks/custom-statusline.js"
    ok "custom-statusline.js installed"
  else
    warn "custom-statusline.js not found in repo"
  fi

}

# --- Custom skills ---
install_skills() {
  header "Custom Skills"

  mkdir -p "$CLAUDE_DIR/skills"

  for skill_dir in "$SCRIPT_DIR/skills"/*/; do
    [[ ! -d "$skill_dir" ]] && continue
    local skill_name
    skill_name="$(basename "$skill_dir")"
    local src_skill="$skill_dir/SKILL.md"
    local dest_dir="$CLAUDE_DIR/skills/$skill_name"
    local dest_skill="$dest_dir/SKILL.md"

    if [[ ! -f "$src_skill" ]]; then
      warn "No SKILL.md found in $skill_dir"
      continue
    fi

    mkdir -p "$dest_dir"

    # Copy and substitute placeholders
    local content
    content="$(cat "$src_skill")"
    content="$(substitute_secrets "$content")"
    echo "$content" > "$dest_skill"
    ok "$skill_name skill installed"
  done
}

# --- bubblewrap (bw-AICode) ---
install_bubblewrap() {
  header "bubblewrap (bw-AICode)"

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

  # Run bw-AICode's own installer
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

# --- Main flow ---
main() {
  header "AI Coding Base Setup"
  load_or_prompt_secrets
  report_unmanaged
  install_mcp_packages
  install_claude_mcps
  ensure_claude_onboarding_state
  install_claude_settings
  install_claude_plugins
  install_opencode_config
  install_hooks
  install_skills
  install_bubblewrap
  install_infra_audit
  check_playwright

  header "Done!"
  info "Environment: $ENV_TYPE"
  info "Secrets: $SECRETS_FILE"
  info "Claude Code: $CLAUDE_DIR"
  if command -v opencode &>/dev/null; then
    info "opencode: $OPENCODE_DIR"
  fi
}

main "$@"
