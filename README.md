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

## Devcontainers (DevPod / Codespaces / VS Code Dev Containers)

When run inside a container, `install.sh` detects the environment automatically and:

- Auto-installs prerequisites it needs (`git`, `jq`, `claude` CLI, `locales` + `de_AT.UTF-8`/`en_US.UTF-8`) via apt/npm. No manual prep.
- Skips interactive prompts for missing API keys (assumes secrets are bind-mounted from the host or absent).

Detection triggers on any of: `/.dockerenv`, `/run/.containerenv`, `REMOTE_CONTAINERS`, `DEVCONTAINER`, or `CODESPACES` env vars.

To force the same behaviour on a host (e.g. CI), set:

```bash
AICODINGSETUP_AUTO_INSTALL=1 AICODINGSETUP_NONINTERACTIVE=1 ./install.sh
```

### Drop-in `.devcontainer/devcontainer.json`

Canonical template lives next to this README at [`devcontainer.json`](./devcontainer.json). Copy it into your project's `.devcontainer/` directory:

```bash
mkdir -p .devcontainer
curl -fsSL https://raw.githubusercontent.com/vossiman/aiCodingBaseSetup/main/devcontainer.json \
  -o .devcontainer/devcontainer.json
```

`postCreateCommand` runs this repo's `install.sh` once on container creation; `postStartCommand` curls `update.sh` from this repo on every container start to keep `claude` and `opencode` binaries fresh.

`containerEnv` overrides three `BASH_FUNC_*%%` env vars that universal:6 leaks with truncated multi-line bodies — without it bash errors on every spawn (see [vscode#3928](https://github.com/Microsoft/vscode/issues/3928), [vscode-remote-release#9457](https://github.com/microsoft/vscode-remote-release/issues/9457)). `install.sh` and `update.sh` further re-exec themselves under `env -u` to belt-and-braces the same problem.

`remoteUser` must match the image's hardcoded user — `codespace` for `universal:6`, `vscode` for most others (`python`, `base`, etc.). Mismatch → mounts land at the wrong path and nothing works.

Add `"mounts": [...]` for project- or host-specific bind mounts (e.g. to share `~/.aicodingsetup/` and `~/.claude/` across containers from a backend like DevPod's host). The shipped template has no `mounts` so it stays portable.

### Why both `.credentials.json` and `~/.claude.json` matter

Claude Code reads OAuth tokens from `~/.claude/.credentials.json` *and* checks `~/.claude.json` (a file at home root, **not** inside `.claude/`) for `hasCompletedOnboarding: true`. Without that flag, the CLI treats every session as a fresh install and prompts for login even when valid tokens exist. `install.sh` writes that flag automatically when it sets up MCPs — without it, copying the credentials file alone is not sufficient to authenticate a container.

### MCPs needing one-time interactive auth

HTTP-based MCPs (logfire, claude.ai Google Drive, etc.) can't be set up by `install.sh` — they require a browser OAuth flow. Auth once in any DevPod workspace via `claude` → `/mcp` → select the MCP → follow the link. State persists in the bind-mounted `~/.claude/`, so every future workspace inherits it.

## How It Works

```
install.sh
  1. Detect environment (Linux / WSL / container)
  2. Auto-install prereqs in container mode (git, jq, claude CLI, locales, tmux)
  3. Load or prompt for secrets (~/.aicodingsetup/.secrets.env — non-interactive in containers)
  4. Report unmanaged components (leave untouched)
  5. Configure Claude Code MCPs (claude mcp add)
  6. Merge Claude Code settings.json (deep merge, preserve existing)
  7. Install Claude Code marketplace plugins
  8. Merge opencode config (opencode.json with MCPs)
  9. Copy hooks and statusline (including SessionStart archive-reminder)
 10. Install slash commands (/scaffold-project, /housekeep)
 11. Mirror project templates to ~/.aicodingsetup/templates/project/
 12. Deploy custom skills (with secret substitution)
 13. Clone/update bubblewrap, symlink hook
 14. Detect infra-audit
 15. Check Playwright installation
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
