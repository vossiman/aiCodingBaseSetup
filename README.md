# AI Coding Base Setup

Cross-platform installer/updater for Claude Code and opencode configurations. Syncs MCPs, skills, hooks, plugins, and statusline across Mint Linux, WSL, Windows, and devcontainers (DevPod / Codespaces / Dev Containers).

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

## Devcontainers (DevPod / Codespaces / VS Code Dev Containers)

When run inside a container, `install.sh` detects the environment automatically and:

- Auto-installs prerequisites it needs (`git`, `jq`, `claude` CLI, `locales` + `de_AT.UTF-8`/`en_US.UTF-8`) via apt/npm. No manual prep.
- Skips interactive prompts for missing API keys (assumes secrets are bind-mounted from the host or absent).

Detection triggers on any of: `/.dockerenv`, `/run/.containerenv`, `REMOTE_CONTAINERS`, `DEVCONTAINER`, or `CODESPACES` env vars.

To force the same behaviour on a host (e.g. CI), set:

```bash
AICODINGSETUP_AUTO_INSTALL=1 AICODINGSETUP_NONINTERACTIVE=1 ./install.sh
```

### Minimal `.devcontainer/devcontainer.json` snippet

Drop into any project repo to get a fully-configured Claude Code workspace:

```json
{
  "image": "mcr.microsoft.com/devcontainers/universal:2",
  "remoteUser": "vscode",
  "mounts": [
    "source=/home/vossi/devpod/aicodingsetup,target=/home/vscode/.aicodingsetup,type=bind",
    "source=/home/vossi/devpod/claude-creds/.credentials.json,target=/home/vscode/.claude/.credentials.json,type=bind"
  ],
  "postCreateCommand": "git clone https://github.com/vossiman/aiCodingBaseSetup /tmp/aicoding && bash /tmp/aicoding/install.sh"
}
```

The two bind mounts (host paths assume vossisrv as the DevPod backend) carry your existing secrets file and Claude Code login state into every workspace, so each container comes up signed in and pre-configured.

## How It Works

```
install.sh
  1. Detect environment (Linux / WSL / container)
  2. Auto-install prereqs in container mode (git, jq, claude CLI, locales)
  3. Load or prompt for secrets (~/.aicodingsetup/.secrets.env — non-interactive in containers)
  4. Report unmanaged components (leave untouched)
  5. Configure Claude Code MCPs (claude mcp add)
  6. Merge Claude Code settings.json (deep merge, preserve existing)
  7. Install Claude Code marketplace plugins
  8. Merge opencode config (opencode.json with MCPs)
  9. Copy hooks and statusline
 10. Deploy custom skills (with secret substitution)
 11. Clone/update bubblewrap, symlink hook
 12. Detect infra-audit
 13. Check Playwright installation
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
├── skills/
│   └── cloudflare-browser/
│       └── SKILL.md
└── vendor/                        # External repos (gitignored)
    └── bw-AICode/
```

## Test Your Setup

After running the installer, paste the test prompt from `test-prompt.md` into Claude Code or opencode to verify everything works.
