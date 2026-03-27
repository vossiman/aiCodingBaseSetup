# AI Coding Base Setup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a cross-platform installer/updater that configures Claude Code and opencode with shared MCPs, skills, hooks, plugins, and statusline across Linux, WSL, and Windows.

**Architecture:** A bash script (`install.sh`) reads shared config templates and a secrets file, then merges configurations into Claude Code (`~/.claude/`) and opencode (`~/.config/opencode/`). JSON merging is done with `jq`. A PowerShell script (`install.ps1`) mirrors this for Windows (deferred — blocked on verifying Windows paths).

**Tech Stack:** Bash, jq, PowerShell (Windows), git

---

## File Structure

| File | Responsibility |
|------|---------------|
| `install.sh` | Main installer/updater for Linux/WSL |
| `install.ps1` | Windows installer (stub with TODOs until paths verified) |
| `.gitignore` | Ignore vendor/, .secrets.env, local artifacts |
| `.secrets.env.example` | Template documenting all required API keys |
| `configs/mcps.json` | Shared MCP server definitions (source of truth) |
| `configs/claude/settings.json` | Base Claude Code settings (hooks, permissions, plugins, statusline) |
| `configs/claude/hooks/custom-statusline.js` | Powerline statusline script |
| `configs/opencode/opencode.json` | Base opencode config (model, agents, permissions) |
| `skills/cloudflare-browser/SKILL.md` | Cloudflare Browser Rendering REST API skill |
| `skills/logfire/SKILL.md` | Logfire REST API reader skill (placeholder — needs API research) |

---

### Task 1: Repo scaffolding

**Files:**
- Create: `.gitignore`
- Create: `.secrets.env.example`

- [ ] **Step 1: Create .gitignore**

```gitignore
# Secrets (stored at ~/.aicodingsetup/, but just in case)
.secrets.env

# Vendor repos (cloned by install script)
vendor/

# OS artifacts
.DS_Store
Thumbs.db
```

- [ ] **Step 2: Create .secrets.env.example**

```env
# AI Coding Base Setup - Required API Keys
# Copy to ~/.aicodingsetup/.secrets.env or run install.sh to be prompted

FIRECRAWL_API_KEY=
BRAVE_API_KEY=
CLOUDFLARE_API_TOKEN=
CLOUDFLARE_ACCOUNT_ID=
LOGFIRE_TOKEN=
```

- [ ] **Step 3: Commit**

```bash
git add .gitignore .secrets.env.example
git commit -m "chore: add repo scaffolding with gitignore and secrets template"
```

---

### Task 2: Shared MCP definitions

**Files:**
- Create: `configs/mcps.json`

This is the single source of truth for MCP servers. The install script reads this and writes into both Claude Code and opencode configs.

- [ ] **Step 1: Create configs/mcps.json**

```json
{
  "firecrawl": {
    "command": ["firecrawl-mcp"],
    "environment": {
      "FIRECRAWL_API_KEY": "{{FIRECRAWL_API_KEY}}"
    }
  },
  "brave-search": {
    "command": ["brave-search-mcp-server"],
    "environment": {
      "BRAVE_API_KEY": "{{BRAVE_API_KEY}}"
    }
  },
  "context7": {
    "command": ["docker", "run", "-i", "--rm", "context7-mcp"],
    "environment": {}
  },
  "playwright": {
    "command": ["npx", "@playwright/mcp@latest", "--browser", "chromium"],
    "environment": {}
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add configs/mcps.json
git commit -m "feat: add shared MCP definitions as single source of truth"
```

---

### Task 3: Claude Code base settings

**Files:**
- Create: `configs/claude/settings.json`

This contains only the settings this installer manages. The install script merges these into the user's existing `~/.claude/settings.json`. Note: hooks referencing `$HOME` use a placeholder `{{HOME}}` that the install script replaces with the actual home path.

- [ ] **Step 1: Create configs/claude/settings.json**

```json
{
  "permissions": {
    "allow": [
      "Bash(git show:*)"
    ]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Read|Edit|Write|Bash|Grep",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"{{HOME}}/.claude/hooks/bw-deny-files.sh\""
          }
        ]
      }
    ]
  },
  "statusLine": {
    "type": "command",
    "command": "node \"{{HOME}}/.claude/hooks/custom-statusline.js\""
  },
  "enabledPlugins": {
    "frontend-design@claude-plugins-official": true,
    "superpowers@claude-plugins-official": true,
    "playwright@claude-plugins-official": true,
    "code-simplifier@claude-plugins-official": true,
    "skill-creator@claude-plugins-official": true,
    "code-review@claude-plugins-official": true,
    "claude-code-setup@claude-plugins-official": true,
    "pyright-lsp@claude-plugins-official": true
  }
}
```

Note: `effortLevel` and `skipDangerousModePermissionPrompt` are NOT in the base — the script sets them only if absent in the user's existing config.

- [ ] **Step 2: Commit**

```bash
git add configs/claude/settings.json
git commit -m "feat: add Claude Code base settings template"
```

---

### Task 4: Hooks and statusline

**Files:**
- Create: `configs/claude/hooks/custom-statusline.js`

The `bw-deny-files.sh` hook is NOT stored here — it comes from the bubblewrap repo (symlinked in Task 10).

- [ ] **Step 1: Copy existing custom-statusline.js into repo**

Copy from `/home/vossi/.claude/hooks/custom-statusline.js` to `configs/claude/hooks/custom-statusline.js`. This is the current 220-line powerline statusline with context window, rate limits, git branch, GSD task, and update notices.

- [ ] **Step 2: Commit**

```bash
git add configs/claude/hooks/custom-statusline.js
git commit -m "feat: add custom powerline statusline script"
```

---

### Task 5: opencode base config

**Files:**
- Create: `configs/opencode/opencode.json`

- [ ] **Step 1: Create configs/opencode/opencode.json**

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "anthropic/claude-opus-4-6",
  "mcp": {},
  "agent": {
    "gsd-executor": { "mode": "subagent" },
    "gsd-planner": { "mode": "subagent" },
    "gsd-verifier": { "mode": "subagent" },
    "gsd-plan-checker": { "mode": "subagent" },
    "gsd-debugger": { "mode": "subagent" },
    "gsd-phase-researcher": { "mode": "subagent" },
    "gsd-project-researcher": { "mode": "subagent" },
    "gsd-research-synthesizer": { "mode": "subagent" },
    "gsd-roadmapper": { "mode": "subagent" },
    "gsd-codebase-mapper": { "mode": "subagent" },
    "gsd-integration-checker": { "mode": "subagent" }
  },
  "permission": {
    "*": "allow",
    "read": {
      "~/.config/opencode/get-shit-done/*": "allow"
    },
    "external_directory": {
      "~/.config/opencode/get-shit-done/*": "allow"
    }
  }
}
```

The `mcp` block is left empty here — the install script populates it from `configs/mcps.json` with secrets substituted.

- [ ] **Step 2: Commit**

```bash
git add configs/opencode/opencode.json
git commit -m "feat: add opencode base config template"
```

---

### Task 6: Cloudflare Browser Rendering skill

**Files:**
- Create: `skills/cloudflare-browser/SKILL.md`

- [ ] **Step 1: Create the SKILL.md**

```markdown
---
name: cloudflare-browser
description: "Fetch web content via Cloudflare Browser Rendering API. Use as backup when firecrawl/playwright fail. Supports markdown, content, screenshot, links, scrape, json, pdf, crawl."
allowed-tools:
  - Bash
  - Read
argument-hint: "<url> [format: markdown|content|screenshot|links|scrape|json|pdf|crawl] (default: markdown)"
---

# Cloudflare Browser Rendering

Fetch web content using the Cloudflare Browser Rendering REST API. Use this when firecrawl or playwright are unavailable or return errors.

## Configuration

- Account ID: `{{CLOUDFLARE_ACCOUNT_ID}}`
- API Token: `{{CLOUDFLARE_API_TOKEN}}`
- Base URL: `https://api.cloudflare.com/client/v4/accounts/{{CLOUDFLARE_ACCOUNT_ID}}/browser-rendering`

## Usage

Parse `$ARGUMENTS` to extract the URL and optional format. Default format is `markdown`.

### Supported Formats

| Format | Endpoint | Description |
|--------|----------|-------------|
| markdown | `/markdown` | Convert page to markdown (default, best for LLM consumption) |
| content | `/content` | Fully rendered HTML after JS execution |
| screenshot | `/screenshot` | Capture PNG screenshot |
| pdf | `/pdf` | Render page as PDF |
| snapshot | `/snapshot` | Combined HTML + screenshot |
| scrape | `/scrape` | Extract elements via CSS selectors (requires selectors in args) |
| json | `/json` | AI-powered structured data extraction (requires prompt in args) |
| links | `/links` | Extract all links from a page |
| crawl | `/crawl` | Async multi-page crawl |

### Execution

1. Parse the URL and format from `$ARGUMENTS`
2. Run the appropriate curl command via Bash:

**For markdown (default):**
```bash
curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/{{CLOUDFLARE_ACCOUNT_ID}}/browser-rendering/markdown" \
  -H "Authorization: Bearer {{CLOUDFLARE_API_TOKEN}}" \
  -H "Content-Type: application/json" \
  -d '{"url": "<URL>"}'
```

**For content:**
```bash
curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/{{CLOUDFLARE_ACCOUNT_ID}}/browser-rendering/content" \
  -H "Authorization: Bearer {{CLOUDFLARE_API_TOKEN}}" \
  -H "Content-Type: application/json" \
  -d '{"url": "<URL>"}'
```

**For screenshot:**
```bash
curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/{{CLOUDFLARE_ACCOUNT_ID}}/browser-rendering/screenshot" \
  -H "Authorization: Bearer {{CLOUDFLARE_API_TOKEN}}" \
  -H "Content-Type: application/json" \
  -d '{"url": "<URL>", "fullPage": true}' \
  --output /tmp/cf-screenshot.png
```
Then use Read to display the screenshot.

**For links:**
```bash
curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/{{CLOUDFLARE_ACCOUNT_ID}}/browser-rendering/links" \
  -H "Authorization: Bearer {{CLOUDFLARE_API_TOKEN}}" \
  -H "Content-Type: application/json" \
  -d '{"url": "<URL>"}'
```

**For scrape (requires CSS selectors):**
```bash
curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/{{CLOUDFLARE_ACCOUNT_ID}}/browser-rendering/scrape" \
  -H "Authorization: Bearer {{CLOUDFLARE_API_TOKEN}}" \
  -H "Content-Type: application/json" \
  -d '{"url": "<URL>", "selectors": ["h1", "p", "article"]}'
```

**For json (requires prompt):**
```bash
curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/{{CLOUDFLARE_ACCOUNT_ID}}/browser-rendering/json" \
  -H "Authorization: Bearer {{CLOUDFLARE_API_TOKEN}}" \
  -H "Content-Type: application/json" \
  -d '{"url": "<URL>", "prompt": "<extraction prompt>"}'
```

**For pdf:**
```bash
curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/{{CLOUDFLARE_ACCOUNT_ID}}/browser-rendering/pdf" \
  -H "Authorization: Bearer {{CLOUDFLARE_API_TOKEN}}" \
  -H "Content-Type: application/json" \
  -d '{"url": "<URL>"}' \
  --output /tmp/cf-page.pdf
```
Then use Read to display the PDF.

**For crawl (async):**
```bash
# Start crawl job
JOB=$(curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/{{CLOUDFLARE_ACCOUNT_ID}}/browser-rendering/crawl" \
  -H "Authorization: Bearer {{CLOUDFLARE_API_TOKEN}}" \
  -H "Content-Type: application/json" \
  -d '{"url": "<URL>", "limit": 10, "formats": ["markdown"]}')
echo "$JOB"

# Check status (extract job ID from response)
JOB_ID=$(echo "$JOB" | jq -r '.id // .result.id // empty')
curl -s "https://api.cloudflare.com/client/v4/accounts/{{CLOUDFLARE_ACCOUNT_ID}}/browser-rendering/crawl/$JOB_ID" \
  -H "Authorization: Bearer {{CLOUDFLARE_API_TOKEN}}"
```

3. Present the results to the user
```

- [ ] **Step 2: Commit**

```bash
git add skills/cloudflare-browser/SKILL.md
git commit -m "feat: add Cloudflare Browser Rendering skill"
```

---

### Task 7: Logfire reader skill (placeholder)

**Files:**
- Create: `skills/logfire/SKILL.md`

The Logfire REST API endpoints need to be researched before full implementation. This creates a working placeholder that documents what's needed.

- [ ] **Step 1: Create the SKILL.md**

```markdown
---
name: logfire-reader
description: "Query and read logs from Pydantic Logfire via REST API. Use when debugging or investigating application behavior."
allowed-tools:
  - Bash
  - Read
argument-hint: "<query> [--project <name>] [--limit <n>]"
---

# Logfire Reader

Query and read application logs from Pydantic Logfire via REST API.

## Configuration

- API Token: `{{LOGFIRE_TOKEN}}`

## Usage

Parse `$ARGUMENTS` to extract the query and optional flags.

### Execution

<!-- TODO: Research exact Logfire REST API endpoints and query format -->
<!-- Expected base URL: https://logfire-api.pydantic.dev/v1/ or similar -->
<!-- Auth header: Authorization: Bearer {{LOGFIRE_TOKEN}} -->

Use Bash to query the Logfire REST API:

```bash
curl -s "https://logfire-api.pydantic.dev/v1/query" \
  -H "Authorization: Bearer {{LOGFIRE_TOKEN}}" \
  -H "Content-Type: application/json" \
  -d '{"query": "<QUERY>", "limit": <LIMIT>}'
```

Present the results to the user, formatted for readability.
```

- [ ] **Step 2: Commit**

```bash
git add skills/logfire/SKILL.md
git commit -m "feat: add Logfire reader skill placeholder (needs API research)"
```

---

### Task 8: install.sh — core framework

**Files:**
- Create: `install.sh`

This task builds the script skeleton: environment detection, secrets management, helper functions, and the main flow orchestration. Subsequent tasks add the individual installation functions.

- [ ] **Step 1: Create install.sh with core framework**

```bash
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
MANAGED_SKILLS=("cloudflare-browser" "logfire")
MANAGED_PLUGINS=(
  "superpowers@claude-plugins-official"
  "frontend-design@claude-plugins-official"
  "playwright@claude-plugins-official"
  "code-simplifier@claude-plugins-official"
  "skill-creator@claude-plugins-official"
  "code-review@claude-plugins-official"
  "claude-code-setup@claude-plugins-official"
  "pyright-lsp@claude-plugins-official"
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

# --- Prerequisite checks ---
check_prerequisites() {
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

  # Prompt for missing keys
  local prompted=false
  for key in "${required_keys[@]}"; do
    if [[ -z "${secrets[$key]:-}" ]]; then
      prompted=true
      read -rp "Enter $key [or press Enter to skip]: " value
      secrets["$key"]="${value:-}"
    else
      ok "$key already set"
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
# Arrays in "permissions.allow" are unioned; objects are recursively merged
# Keys in $1 that don't exist in $2 are preserved
json_merge() {
  local target="$1"
  local source="$2"

  if [[ ! -f "$target" ]]; then
    cp "$source" "$target"
    return
  fi

  local merged
  merged="$(jq -s '
    def deep_merge(a; b):
      a as $a | b as $b |
      if ($a | type) == "object" and ($b | type) == "object" then
        ($a | keys_unsorted) + ($b | keys_unsorted) | unique |
        reduce .[] as $key (
          {};
          . + { ($key):
            if ($a | has($key)) and ($b | has($key)) then
              if ($key == "allow") and (($a[$key] | type) == "array") then
                (($a[$key]) + ($b[$key])) | unique
              elif (($a[$key] | type) == "object") and (($b[$key] | type) == "object") then
                deep_merge($a[$key]; $b[$key])
              else
                $b[$key]
              end
            elif ($b | has($key)) then $b[$key]
            else $a[$key]
            end
          }
        )
      else $b
      end;
    deep_merge(.[0]; .[1])
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
  content="${content//\{\{LOGFIRE_TOKEN\}\}/${LOGFIRE_TOKEN:-}}"
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
        # Skip plugin-provided MCPs
        [[ "$mcp_name" == plugin:* ]] && continue
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
      # Also skip GSD and infra hooks (managed by their own installers)
      [[ "$hook_name" == gsd-* ]] && managed=true
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

# --- Main flow ---
main() {
  header "AI Coding Base Setup"
  load_or_prompt_secrets
  report_unmanaged
  install_claude_mcps
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
```

- [ ] **Step 2: Make executable and commit**

```bash
chmod +x install.sh
git add install.sh
git commit -m "feat: add install.sh core framework with env detection, secrets, JSON merge"
```

---

### Task 9: install.sh — Claude Code MCPs

**Files:**
- Modify: `install.sh` (append function before `main`)

- [ ] **Step 1: Add install_claude_mcps function**

This function goes after `report_unmanaged` and before `main`. It uses `claude mcp add` CLI which is idempotent.

```bash
# --- Claude Code MCPs ---
install_claude_mcps() {
  header "Claude Code MCPs"

  if ! command -v claude &>/dev/null; then
    warn "Claude Code CLI not found — skipping MCP installation"
    return
  fi

  # Read MCP definitions from shared config
  local mcps_file="$SCRIPT_DIR/configs/mcps.json"
  if [[ ! -f "$mcps_file" ]]; then
    err "Missing configs/mcps.json"
    return
  fi

  # firecrawl
  if [[ -n "${FIRECRAWL_API_KEY:-}" ]]; then
    claude mcp add firecrawl -s user -e "FIRECRAWL_API_KEY=${FIRECRAWL_API_KEY}" -- firecrawl-mcp 2>/dev/null && \
      ok "firecrawl MCP configured" || warn "firecrawl MCP may need manual setup"
  else
    warn "Skipping firecrawl MCP — no API key"
  fi

  # brave-search
  if [[ -n "${BRAVE_API_KEY:-}" ]]; then
    claude mcp add brave-search -s user -e "BRAVE_API_KEY=${BRAVE_API_KEY}" -- brave-search-mcp-server 2>/dev/null && \
      ok "brave-search MCP configured" || warn "brave-search MCP may need manual setup"
  else
    warn "Skipping brave-search MCP — no API key"
  fi

  # context7
  claude mcp add context7 -s user -- docker run -i --rm context7-mcp 2>/dev/null && \
    ok "context7 MCP configured" || warn "context7 MCP may need manual setup"

  # playwright
  claude mcp add playwright -s user -- npx @playwright/mcp@latest --browser chromium 2>/dev/null && \
    ok "playwright MCP configured" || warn "playwright MCP may need manual setup"
}
```

- [ ] **Step 2: Commit**

```bash
git add install.sh
git commit -m "feat: add Claude Code MCP installation via claude mcp add"
```

---

### Task 10: install.sh — Claude Code settings merge

**Files:**
- Modify: `install.sh` (append function before `main`)

- [ ] **Step 1: Add install_claude_settings function**

```bash
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

  # Merge: base into existing (existing values take precedence for scalar fields)
  # But for enabledPlugins and permissions.allow, we union
  json_merge "$target_settings" "$tmp_source"

  # Set defaults only if absent
  local needs_effort needs_dangerous
  needs_effort="$(jq 'has("effortLevel") | not' "$target_settings")"
  needs_dangerous="$(jq 'has("skipDangerousModePermissionPrompt") | not' "$target_settings")"

  if [[ "$needs_effort" == "true" ]]; then
    jq '.effortLevel = "medium"' "$target_settings" > "$tmp_source" && mv "$tmp_source" "$target_settings"
  fi
  if [[ "$needs_dangerous" == "true" ]]; then
    jq '.skipDangerousModePermissionPrompt = true' "$target_settings" > "$tmp_source" && mv "$tmp_source" "$target_settings"
  fi

  rm -f "$tmp_source"
  ok "Claude Code settings.json merged"
}
```

- [ ] **Step 2: Commit**

```bash
git add install.sh
git commit -m "feat: add Claude Code settings.json merge with union strategy"
```

---

### Task 11: install.sh — Claude Code plugins

**Files:**
- Modify: `install.sh` (append function before `main`)

- [ ] **Step 1: Add install_claude_plugins function**

```bash
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
```

- [ ] **Step 2: Commit**

```bash
git add install.sh
git commit -m "feat: add Claude Code marketplace plugin installation"
```

---

### Task 12: install.sh — opencode config

**Files:**
- Modify: `install.sh` (append function before `main`)

- [ ] **Step 1: Add install_opencode_config function**

```bash
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
```

- [ ] **Step 2: Commit**

```bash
git add install.sh
git commit -m "feat: add opencode config merge with shared MCP definitions"
```

---

### Task 13: install.sh — hooks, skills, vendor repos, playwright check

**Files:**
- Modify: `install.sh` (append remaining functions before `main`)

- [ ] **Step 1: Add install_hooks function**

```bash
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

  # bw-deny-files.sh is handled by bubblewrap install (symlink)
}
```

- [ ] **Step 2: Add install_skills function**

```bash
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

    # On update: extract existing token values before overwriting
    declare -A existing_tokens
    if [[ -f "$dest_skill" ]]; then
      # Extract any non-placeholder values that were previously substituted
      while IFS= read -r line; do
        if [[ "$line" =~ Bearer\ ([a-zA-Z0-9_-]+) && ! "$line" =~ \{\{ ]]; then
          # Has a real token, not a placeholder
          true  # tokens are already in secrets file
        fi
      done < "$dest_skill"
    fi

    # Copy and substitute placeholders
    local content
    content="$(cat "$src_skill")"
    content="$(substitute_secrets "$content")"
    echo "$content" > "$dest_skill"
    ok "$skill_name skill installed"
  done
}
```

- [ ] **Step 3: Add install_bubblewrap function**

```bash
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

  # Symlink the hook into Claude hooks dir
  mkdir -p "$CLAUDE_DIR/hooks"
  local hook_src="$vendor_dir/bw-deny-files.sh"
  local hook_dest="$CLAUDE_DIR/hooks/bw-deny-files.sh"

  if [[ -f "$hook_src" ]]; then
    # Remove existing file/symlink and create fresh symlink
    rm -f "$hook_dest"
    ln -s "$hook_src" "$hook_dest"
    ok "bw-deny-files.sh symlinked"
  else
    warn "bw-deny-files.sh not found in cloned repo"
  fi
}
```

- [ ] **Step 4: Add install_infra_audit function**

```bash
# --- infra-audit ---
install_infra_audit() {
  header "infra-audit (python-infra-audit-cc)"

  # infra-audit has its own install mechanism via the repo
  # Check if already installed by looking for the manifest
  if [[ -f "$CLAUDE_DIR/infra-audit-manifest.json" ]]; then
    info "infra-audit already installed — run /infra-update in Claude Code to update"
  else
    info "infra-audit not installed"
    info "To install, run in Claude Code: claude plugin install python-infra-audit-cc"
    info "Or clone https://github.com/vossiman/python-infra-audit-cc and follow its README"
  fi
}
```

- [ ] **Step 5: Add check_playwright function**

```bash
# --- Playwright check ---
check_playwright() {
  header "Playwright"

  if npx playwright --version &>/dev/null 2>&1; then
    ok "Playwright CLI available"
    # Check if browsers are installed by looking for the chromium dir
    if [[ -d "$HOME/.cache/ms-playwright" ]] || [[ -d "$HOME/Library/Caches/ms-playwright" ]]; then
      ok "Playwright browsers appear to be installed"
    else
      warn "Playwright browsers may not be installed"
      info "Run: npx playwright install"
    fi
  else
    warn "Playwright not found"
    info "Run: npx playwright install"
  fi
}
```

- [ ] **Step 6: Commit**

```bash
git add install.sh
git commit -m "feat: add hooks, skills, bubblewrap, infra-audit, and playwright install functions"
```

---

### Task 14: install.ps1 — Windows stub

**Files:**
- Create: `install.ps1`

Windows paths are not yet verified. This creates a working stub that documents what needs to happen.

- [ ] **Step 1: Create install.ps1**

```powershell
# ============================================================================
# AI Coding Base Setup — Windows Installer/Updater (PowerShell)
# Configures Claude Code and opencode with shared MCPs, skills, hooks, plugins
#
# STATUS: STUB — Windows config paths need verification before full implementation
# TODO: Verify Claude Code desktop app config path on Windows
# TODO: Verify opencode desktop app config path on Windows
# ============================================================================

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ClaudeDir = Join-Path $env:USERPROFILE ".claude"
$OpencodeDir = Join-Path $env:USERPROFILE ".config\opencode"  # TODO: verify
$SecretsDir = Join-Path $env:USERPROFILE ".aicodingsetup"
$SecretsFile = Join-Path $SecretsDir ".secrets.env"

Write-Host "============================================" -ForegroundColor Green
Write-Host " AI Coding Base Setup — Windows Installer" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""

# --- Prerequisite checks ---
$missing = @()
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { $missing += "git" }
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { $missing += "claude (Claude Code CLI)" }

if ($missing.Count -gt 0) {
    Write-Host "ERROR: Missing required tools: $($missing -join ', ')" -ForegroundColor Red
    exit 1
}

# --- Secrets Management ---
if (-not (Test-Path $SecretsDir)) { New-Item -ItemType Directory -Path $SecretsDir -Force | Out-Null }

$requiredKeys = @(
    "FIRECRAWL_API_KEY",
    "BRAVE_API_KEY",
    "CLOUDFLARE_API_TOKEN",
    "CLOUDFLARE_ACCOUNT_ID",
    "LOGFIRE_TOKEN"
)

$secrets = @{}
if (Test-Path $SecretsFile) {
    Write-Host "INFO: Found existing secrets file" -ForegroundColor Blue
    Get-Content $SecretsFile | ForEach-Object {
        if ($_ -match '^([^#][^=]+)=(.*)$') {
            $secrets[$Matches[1]] = $Matches[2]
        }
    }
}

foreach ($key in $requiredKeys) {
    if (-not $secrets.ContainsKey($key) -or [string]::IsNullOrEmpty($secrets[$key])) {
        $value = Read-Host "Enter $key [or press Enter to skip]"
        $secrets[$key] = $value
    } else {
        Write-Host "  OK: $key already set" -ForegroundColor Green
    }
}

# Write secrets file
$secretsContent = "# AI Coding Base Setup - Secrets`n# Auto-generated by install.ps1`n"
foreach ($key in $requiredKeys) {
    $secretsContent += "$key=$($secrets[$key])`n"
}
Set-Content -Path $SecretsFile -Value $secretsContent

# --- Claude Code MCPs ---
Write-Host "`n=== Claude Code MCPs ===" -ForegroundColor Green

if ($secrets["FIRECRAWL_API_KEY"]) {
    & claude mcp add firecrawl -s user -e "FIRECRAWL_API_KEY=$($secrets['FIRECRAWL_API_KEY'])" -- firecrawl-mcp 2>$null
    Write-Host "  OK: firecrawl MCP configured" -ForegroundColor Green
}

if ($secrets["BRAVE_API_KEY"]) {
    & claude mcp add brave-search -s user -e "BRAVE_API_KEY=$($secrets['BRAVE_API_KEY'])" -- brave-search-mcp-server 2>$null
    Write-Host "  OK: brave-search MCP configured" -ForegroundColor Green
}

& claude mcp add context7 -s user -- docker run -i --rm context7-mcp 2>$null
Write-Host "  OK: context7 MCP configured" -ForegroundColor Green

& claude mcp add playwright -s user -- npx "@playwright/mcp@latest" --browser chromium 2>$null
Write-Host "  OK: playwright MCP configured" -ForegroundColor Green

# --- Claude Code Plugins ---
Write-Host "`n=== Claude Code Plugins ===" -ForegroundColor Green
$plugins = @(
    "superpowers@claude-plugins-official",
    "frontend-design@claude-plugins-official",
    "playwright@claude-plugins-official",
    "code-simplifier@claude-plugins-official",
    "skill-creator@claude-plugins-official",
    "code-review@claude-plugins-official",
    "claude-code-setup@claude-plugins-official",
    "pyright-lsp@claude-plugins-official"
)
foreach ($plugin in $plugins) {
    & claude plugin install $plugin 2>$null
    Write-Host "  OK: $plugin" -ForegroundColor Green
}

# --- Copy hooks and skills ---
Write-Host "`n=== Hooks & Skills ===" -ForegroundColor Green

# Statusline
$hooksDest = Join-Path $ClaudeDir "hooks"
if (-not (Test-Path $hooksDest)) { New-Item -ItemType Directory -Path $hooksDest -Force | Out-Null }
Copy-Item (Join-Path $ScriptDir "configs\claude\hooks\custom-statusline.js") (Join-Path $hooksDest "custom-statusline.js") -Force
Write-Host "  OK: custom-statusline.js installed" -ForegroundColor Green

# Skills
$skillsDest = Join-Path $ClaudeDir "skills"
Get-ChildItem (Join-Path $ScriptDir "skills") -Directory | ForEach-Object {
    $skillName = $_.Name
    $destDir = Join-Path $skillsDest $skillName
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    $content = Get-Content (Join-Path $_.FullName "SKILL.md") -Raw
    foreach ($key in $requiredKeys) {
        $content = $content.Replace("{{$key}}", $secrets[$key])
    }
    Set-Content -Path (Join-Path $destDir "SKILL.md") -Value $content
    Write-Host "  OK: $skillName skill installed" -ForegroundColor Green
}

# --- TODO: settings.json merge, opencode config, bubblewrap ---
Write-Host "`nWARN: settings.json merge, opencode config, and bubblewrap symlink not yet implemented for Windows" -ForegroundColor Yellow
Write-Host "INFO: These require verifying Windows config paths first" -ForegroundColor Blue

Write-Host "`n=== Done! ===" -ForegroundColor Green
```

- [ ] **Step 2: Commit**

```bash
git add install.ps1
git commit -m "feat: add Windows PowerShell installer stub"
```

---

### Task 15: End-to-end dry run test

**Files:** none (verification only)

- [ ] **Step 1: Review install.sh for syntax errors**

```bash
bash -n install.sh
```

Expected: no output (clean parse).

- [ ] **Step 2: Test with --help or dry output**

Run the script on the current machine and verify:
- Environment detected correctly
- Secrets prompt works (test with existing secrets file)
- Unmanaged components are reported
- MCPs are configured (verify with `claude mcp list`)
- Settings are merged correctly (diff before/after)
- Plugins are installed
- opencode config is merged
- Hooks and skills are copied
- bubblewrap is cloned and symlinked

```bash
# Backup existing configs first
cp ~/.claude/settings.json ~/.claude/settings.json.bak
cp ~/.config/opencode/opencode.json ~/.config/opencode/opencode.json.bak

# Run the installer
./install.sh

# Verify
claude mcp list
diff ~/.claude/settings.json ~/.claude/settings.json.bak
cat ~/.claude/skills/cloudflare-browser/SKILL.md | head -5
ls -la ~/.claude/hooks/bw-deny-files.sh
```

- [ ] **Step 3: Commit any fixes from dry run**

```bash
git add -A
git commit -m "fix: address issues found during dry run testing"
```
