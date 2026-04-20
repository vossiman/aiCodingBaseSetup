# AI Coding Base Setup

Cross-platform installer/updater for Claude Code and opencode configurations. Syncs MCPs, skills, hooks, plugins, and statusline across Mint Linux, WSL, and Windows.

## Quick Start

```bash
git clone https://github.com/vossiman/aiCodingBaseSetup.git
cd aiCodingBaseSetup
./install.sh
```

On first run, you'll be prompted for API keys. Press Enter to skip any you don't have yet.

## What Gets Installed

### MCP Servers

| MCP | Purpose | Auth |
|-----|---------|------|
| firecrawl | Web scraping and content extraction | API key |
| brave-search | Web, news, image, video search | API key |
| context7 | Library documentation lookup (via Docker) | None |
| playwright | Browser automation, screenshots, testing | None (via plugin) |

### Claude Code Plugins (Marketplace)

- superpowers (brainstorming, TDD, plans, code review, debugging)
- frontend-design
- playwright
- code-simplifier
- skill-creator
- code-review
- claude-code-setup
- pyright-lsp

### Custom Skills (shared by Claude Code and opencode)

| Skill | Purpose | Auth |
|-------|---------|------|
| cloudflare-browser | Fetch web content via Cloudflare Browser Rendering REST API (backup for firecrawl) | API token |

### Hooks

- **custom-statusline.js** — Powerline-style status bar with context window, rate limits, git branch
- **bw-deny-files.sh** — Blocks AI access to sensitive files (from [bw-AICode](https://github.com/vossiman/bw-AICode))
- **check-archived-docs.sh** — SessionStart hook. Emits a one-line banner when a scaffolded project has docs with `status: done` in any `docs/*/active/` folder. Fail-open.

### Slash commands

- **/scaffold-project** — Drops the canonical project layout (`CLAUDE.md`, `TODO.md`, `docs/{specs,plans,notes}/{active,archive}/`, project `.claude/settings.json`) into the current directory. Interactive: asks for name and one-line purpose. Refuses to clobber existing files.
- **/housekeep** — Sweeps `docs/*/active/` for docs with `status: done` frontmatter and moves them into the sibling `archive/`. Also prunes `[x]` items older than 14 days from `TODO.md`.

### Project templates

Installed to `~/.aicodingsetup/templates/project/`. Used by `/scaffold-project` to materialize a new project. The repo is the source of truth — re-running `install.sh` mirrors the latest templates over.

### External Tools (detected, not installed)

- **infra-audit** — Python project infrastructure auditor ([python-infra-audit-cc](https://github.com/vossiman/python-infra-audit-cc))
## Secrets

Secrets are stored at `~/.aicodingsetup/.secrets.env` (outside the repo).

| Key | Used By |
|-----|---------|
| `FIRECRAWL_API_KEY` | firecrawl MCP |
| `BRAVE_API_KEY` | brave-search MCP |
| `CLOUDFLARE_API_TOKEN` | cloudflare-browser skill |
| `CLOUDFLARE_ACCOUNT_ID` | cloudflare-browser skill |
- **Install:** prompts for all keys (Enter to skip)
- **Update:** only prompts for new keys, never overwrites existing values
- MCP keys are injected into MCP config blocks
- Skill keys are substituted directly into SKILL.md files

## Update

Just run the installer again:

```bash
./install.sh
```

It's idempotent:
- Existing secrets are preserved
- Configs are merged (never overwritten)
- Unmanaged MCPs, hooks, and skills are reported but never removed
- bubblewrap repo is git-pulled
- Plugins are updated if newer versions exist

## Windows

```powershell
.\install.ps1
```

> **Note:** Windows support is a stub. MCPs, plugins, hooks, and skills work. Settings merge and opencode config are deferred until Windows config paths are verified.

## How It Works

```
install.sh
  1. Detect environment (Linux / WSL)
  2. Load or prompt for secrets (~/.aicodingsetup/.secrets.env)
  3. Report unmanaged components (leave untouched)
  4. Configure Claude Code MCPs (claude mcp add)
  5. Merge Claude Code settings.json (deep merge, preserve existing)
  6. Install Claude Code marketplace plugins
  7. Merge opencode config (opencode.json with MCPs)
  8. Copy hooks and statusline (including SessionStart archive-reminder)
  9. Install slash commands (/scaffold-project, /housekeep)
 10. Mirror project templates to ~/.aicodingsetup/templates/project/
 11. Deploy custom skills (with secret substitution)
 12. Clone/update bubblewrap, symlink hook
 13. Detect infra-audit
 14. Check Playwright installation
```

## Repo Structure

```
aiCodingBaseSetup/
├── install.sh                     # Linux/WSL installer
├── install.ps1                    # Windows installer (stub)
├── .secrets.env.example           # Template for required API keys
├── configs/
│   ├── claude/
│   │   ├── settings.json          # Base Claude Code settings
│   │   └── hooks/
│   │       └── custom-statusline.js
│   ├── opencode/
│   │   └── opencode.json          # Base opencode config
│   └── mcps.json                  # Shared MCP definitions
├── commands/                      # Slash commands deployed to ~/.claude/commands
│   ├── scaffold-project.md
│   └── housekeep.md
├── hooks/                         # Hooks deployed to ~/.claude/hooks
│   └── check-archived-docs.sh
├── templates/
│   └── project/                   # Mirrored to ~/.aicodingsetup/templates/project
│       ├── CLAUDE.md.tpl
│       ├── README.md.tpl
│       ├── TODO.md.tpl
│       ├── dot-claude/
│       │   └── settings.json.tpl
│       └── docs/
│           ├── specs/{active,archive}/.gitkeep
│           ├── plans/{active,archive}/.gitkeep
│           └── notes/{active,archive}/.gitkeep
├── skills/
│   └── cloudflare-browser/
│       └── SKILL.md
└── vendor/                        # External repos (gitignored)
    └── bw-AICode/
```

## Test Your Setup

After running the installer, paste the test prompt from `test-prompt.md` into Claude Code or opencode to verify everything works.
