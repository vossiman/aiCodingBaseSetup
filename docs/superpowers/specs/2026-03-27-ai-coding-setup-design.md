# AI Coding Base Setup - Design Spec

Cross-platform installer/updater for Claude Code and opencode configurations, MCPs, skills, hooks, and plugins.

## Target Environments

| Environment | Shell | Claude Code config | opencode config |
|-------------|-------|-------------------|-----------------|
| Mint Linux | bash | `~/.claude/` | `~/.config/opencode/` |
| WSL | bash | `~/.claude/` | `~/.config/opencode/` |
| Windows | PowerShell | `%USERPROFILE%\.claude\` (verify) | `%USERPROFILE%\.config\opencode\` (verify) |

**Open TODO:** Verify exact Windows paths for both Claude Code desktop app and opencode desktop app on a Windows machine.

**WSL known issues:** OAuth-based MCPs (Cloudflare, Logfire) have bugs in WSL. This is why we use REST API skills with tokens instead of MCP servers for those.

## Repo Structure

```
aiCodingBaseSetup/
├── install.sh                     # Linux/WSL installer (bash)
├── install.ps1                    # Windows installer (PowerShell)
├── .secrets.env.example           # Template: all required API keys
├── .gitignore                     # Ignores .secrets.env
│
├── configs/
│   ├── claude/
│   │   ├── settings.json          # Base Claude Code settings
│   │   └── hooks/
│   │       ├── custom-statusline.js
│   │       └── bw-deny-files.sh
│   ├── opencode/
│   │   └── opencode.json          # Base opencode config
│   └── mcps.json                  # Shared MCP definitions (source of truth)
│
├── skills/
│   ├── cloudflare-browser/
│   │   └── SKILL.md               # Cloudflare Browser Rendering REST API wrapper
│   └── logfire/
│       └── SKILL.md               # Logfire REST API reader
│
└── vendor/                        # External repos (gitignored)
    └── bw-AICode/                 # Cloned from vossiman/bw-AICode
```

## Secrets Management

### Storage

Secrets are stored in `~/.aicodingsetup/.secrets.env` (outside the repo, in home directory).

### Required Keys

```env
FIRECRAWL_API_KEY=
BRAVE_API_KEY=
CLOUDFLARE_API_TOKEN=
CLOUDFLARE_ACCOUNT_ID=
LOGFIRE_TOKEN=
```

### Flow

- **First install:** Script prompts for each key interactively. Skippable with Enter.
- **Update:** Script reads existing secrets file, checks for new keys added to `.secrets.env.example`, only prompts for missing ones. Never overwrites existing values.
- **Usage:** MCP env vars are injected into MCP config blocks. Skill env vars (Cloudflare, Logfire) are substituted directly into SKILL.md files as literal values (replacing `{{PLACEHOLDER}}` tokens).

## Install/Update Script Logic

### Mode Detection

- **Install:** `~/.aicodingsetup/.secrets.env` does not exist
- **Update:** secrets file exists

### Environment Detection

`uname -s` and `uname -r` (check for "microsoft" in kernel for WSL). Windows uses `install.ps1` directly.

### Step-by-Step Flow

#### 1. Detect environment and set paths

```bash
CLAUDE_DIR="$HOME/.claude"
OPENCODE_DIR="$HOME/.config/opencode"
SECRETS_DIR="$HOME/.aicodingsetup"
SECRETS_FILE="$SECRETS_DIR/.secrets.env"
```

#### 2. Secrets: load or prompt

- If secrets file exists: source it, check for new keys in `.secrets.env.example`, prompt only for missing
- If not: prompt for all keys, create secrets file

#### 3. Report unmanaged components

Before making changes, scan existing configs and report anything not managed by this installer:

```
INFO: Found MCP 'my-custom-server' not managed by this installer -- leaving untouched
INFO: Found skill 'my-custom-skill' not managed by this installer -- leaving untouched
INFO: Found hook 'my-hook.sh' not managed by this installer -- leaving untouched
```

Never remove unmanaged components.

#### 4. Claude Code MCPs

Use `claude mcp add` CLI for each MCP server (idempotent -- updates if exists):

| MCP | Command | Env Vars |
|-----|---------|----------|
| firecrawl | `firecrawl-mcp` | `FIRECRAWL_API_KEY` |
| brave-search | `brave-search-mcp-server` | `BRAVE_API_KEY` |
| context7 | `docker run -i --rm context7-mcp` | none |
| playwright | `npx @playwright/mcp@latest --browser chromium` | none |

#### 5. Claude Code settings.json

**Merge strategy** -- read existing, deep merge the following, write back:

- `permissions.allow`: union with existing
- `hooks`: merge by event type (SessionStart, PreToolUse, PostToolUse), deduplicate by command string
- `statusLine`: overwrite (repo is source of truth)
- `enabledPlugins`: union with existing
- `effortLevel`: set if not present, don't overwrite
- `skipDangerousModePermissionPrompt`: set if not present, don't overwrite

#### 6. Claude Code marketplace plugins

Enable each via CLI:

- `superpowers@claude-plugins-official`
- `frontend-design@claude-plugins-official`
- `playwright@claude-plugins-official`
- `code-simplifier@claude-plugins-official`
- `skill-creator@claude-plugins-official`
- `code-review@claude-plugins-official`
- `claude-code-setup@claude-plugins-official`
- `pyright-lsp@claude-plugins-official`

#### 7. opencode config

Merge into `~/.config/opencode/opencode.json`:

- `model`: set if not present
- `mcp`: merge MCP definitions (same 4 servers), substitute secrets into environment blocks
- `agent`: merge GSD agent config
- `permission`: merge, don't reduce existing permissions

#### 8. Hooks and statusline

Copy from `configs/claude/hooks/` to `~/.claude/hooks/`:

- `custom-statusline.js` -- always overwrite (repo is source of truth)
- `bw-deny-files.sh` -- always overwrite

GSD hooks (`gsd-*.js`, `infra-*.js`) are **not managed by this installer** -- they are installed by their respective skills. The installer leaves them untouched.

#### 9. Custom skills

Copy from `skills/` to `~/.claude/skills/`:

- `cloudflare-browser/SKILL.md` -- substitute `{{CLOUDFLARE_API_TOKEN}}` and `{{CLOUDFLARE_ACCOUNT_ID}}` with actual values
- `logfire/SKILL.md` -- substitute `{{LOGFIRE_TOKEN}}` with actual value

On update: extract existing token values from installed SKILL.md before overwriting, then re-inject them (so tokens survive skill content updates).

Both skills include opencode-compatible frontmatter:
```yaml
---
name: <skill-name>
description: "<trigger description>"
allowed-tools:
  - Bash
  - Read
argument-hint: "<usage hint>"
---
```

These are auto-discovered by opencode from `~/.claude/skills/` (opencode reads this path natively).

#### 10. bubblewrap (bw-AICode)

- First install: `git clone https://github.com/vossiman/bw-AICode.git vendor/bw-AICode`
- Update: `git -C vendor/bw-AICode pull`
- Symlink: `~/.claude/hooks/bw-deny-files.sh -> <repo>/vendor/bw-AICode/bw-deny-files.sh` (bubblewrap repo is source of truth for this hook; remove it from `configs/claude/hooks/`)

#### 11. infra-audit

Run its own install/update mechanism (the repo has its own installer).

#### 12. Playwright check

Check if Playwright browsers are installed. If not, print:
```
NOTE: Playwright browsers not installed. Run: npx playwright install
```

## Custom Skills Detail

### Cloudflare Browser Rendering

```yaml
---
name: cloudflare-browser
description: "Fetch web content via Cloudflare Browser Rendering API. Use as backup when firecrawl/playwright fail. Supports markdown, content, screenshot, links, scrape, json, pdf, crawl."
allowed-tools:
  - Bash
  - Read
argument-hint: "<url> [format: markdown|content|screenshot|links|scrape|json|pdf|crawl] (default: markdown)"
---
```

Wraps these REST API endpoints:

| Endpoint | Purpose |
|----------|---------|
| `/markdown` | Convert page to markdown (default, most useful for LLMs) |
| `/content` | Fully rendered HTML after JS execution |
| `/pdf` | Render page as PDF |
| `/screenshot` | Capture PNG/JPEG screenshot |
| `/snapshot` | Combined HTML + screenshot |
| `/scrape` | Extract elements via CSS selectors |
| `/json` | AI-powered structured data extraction |
| `/links` | Extract all links from a page |
| `/crawl` | Async multi-page crawl |

Base URL: `https://api.cloudflare.com/client/v4/accounts/{{CLOUDFLARE_ACCOUNT_ID}}/browser-rendering/<endpoint>`

Auth: `Authorization: Bearer {{CLOUDFLARE_API_TOKEN}}`

### Logfire Reader

```yaml
---
name: logfire-reader
description: "Query and read logs from Pydantic Logfire via REST API. Use when debugging or investigating application behavior."
allowed-tools:
  - Bash
  - Read
argument-hint: "<query> [--project <name>] [--limit <n>]"
---
```

Wraps Logfire REST API query endpoints. Auth: `Authorization: Bearer {{LOGFIRE_TOKEN}}`

**Open TODO:** Research exact Logfire REST API endpoints and query format before implementation.

## Idempotency Guarantees

| Component | Install behavior | Update behavior |
|-----------|-----------------|-----------------|
| Secrets | Prompt for all | Prompt only for new keys, never overwrite |
| MCPs | `claude mcp add` (creates) | `claude mcp add` (updates) |
| settings.json | Deep merge into existing | Deep merge, preserve user additions |
| opencode.json | Deep merge into existing | Deep merge, preserve user additions |
| Marketplace plugins | Enable | Skip if already enabled |
| Hooks/statusline | Copy (overwrite) | Copy (overwrite, repo is source of truth) |
| Custom skills | Copy + substitute tokens | Extract tokens, overwrite, re-inject tokens |
| bubblewrap | Clone + symlink | Git pull |
| infra-audit | Install | Update via own mechanism |
| Unmanaged components | Report, leave untouched | Report, leave untouched |

## Windows (install.ps1)

Mirrors `install.sh` logic in PowerShell. Key differences:

- Paths use `$env:USERPROFILE\.claude\` and Windows opencode path (to be verified)
- Uses `Invoke-WebRequest` instead of `curl` for any HTTP needs
- Git commands are the same (git is cross-platform)
- `claude mcp add` CLI works the same on Windows
- Secrets stored at `$env:USERPROFILE\.aicodingsetup\.secrets.env`

**Open TODO:** Verify Windows config paths on an actual Windows machine before implementing `install.ps1`.

## What This Installer Does NOT Manage

- GSD skill/commands/hooks (installed by GSD's own mechanism)
- infra-audit hooks (installed by infra-audit's own mechanism)
- Project-level `.claude/` or `.opencode/` configs
- Claude Code credentials/auth
- opencode credentials/auth
- Any MCP, skill, hook, or plugin not listed above
