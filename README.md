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

### Container-side helpers

- **`~/.bashrc.d/aicoding-env.sh`** — empty by default; put container-wide `export FOO=bar` lines here. Sourced from every login shell via the managed block in `~/.bashrc`.
- **`~/.bashrc.d/aicoding-ssh-auth-sock.sh`** — stabilizes the forwarded SSH agent socket across DevPod / Cursor reconnects. Routes every shell through `~/.ssh/agent.sock` (a symlink we keep current). Without it, long-lived tmux panes hold a stale `SSH_AUTH_SOCK` path after the host's SSH session rotates, and `git push` fails with `Permission denied (publickey)` until you open a new pane.

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

Two distinct flows after the initial install:

### `aicoding-update` — for blueprint file changes (recommended)

```bash
aicoding-update --dry-run    # show what would change vs your environment
aicoding-update              # interactive — single y/N confirm, inline diff for drift
aicoding-update --yes        # scripted — auto-confirms; backs up anything drifted
```

`aicoding-update` is installed into `~/.local/bin/` by `install.sh`. It compares three hashes per managed file (currently on disk, last-deployed per the manifest, current blueprint source) and classifies each file into one of seven outcomes. Drifted files (you modified them) are surfaced with full inline `diff -u` output and backed up to `<file>.bak.<YYYYMMDD-HHMMSS>` before being overwritten. Missing-on-disk managed files are classified as `restore` and silently re-deployed.

The manifest at `~/.aicodingsetup/manifest.json` records the blueprint commit and a per-file hash for every overwrite-mode file, plus a block-hash for the marker-guarded section of `~/.bashrc`.

### `./install.sh` — reconciles on every rebuild

Re-running `install.sh` on an initialized container (manifest exists) re-runs the apt/build/locale prereq steps (idempotent) **and** then runs **reconcile mode**, which automatically applies the conservative buckets without any prompts. If you genuinely want to nuke local drift and re-deploy from scratch, use the escape hatch:

```bash
./install.sh --force-reinstall   # deletes manifest, falls through to first-deploy
```

### Install modes

`install.sh` picks one of three modes based on what it finds:

| State on disk | Mode | Behaviour |
|---|---|---|
| No manifest, no managed files exist | `first` | Deploys everything; writes initial manifest. |
| No manifest, but managed files already on disk (older install) | `adopt` | Captures current file hashes into the manifest without overwriting. Surfaces accumulated drift on the next `aicoding-update --dry-run`. |
| Manifest exists | `reconcile` | Re-runs prereqs, then auto-applies the conservative buckets (see below). |

**Reconcile mode** runs every time `install.sh` is invoked on a container that already has a manifest (e.g., every devcontainer rebuild). It classifies each managed file and automatically applies the conservative buckets:
- `restore` (file tracked but missing on disk → redeploy from blueprint)
- `new_file` (in blueprint inventory, not yet in manifest → deploy)
- `will_update` (tracked, unedited locally, blueprint changed → deploy)
- `drifted_but_aligned` (you edited to match the new blueprint → refresh manifest hash, no file write)
- `merge` (settings.json / opencode.json → deep-merge blueprint over local)

It deliberately does **not** auto-apply two buckets:
- `drifted_and_updating` (you edited AND blueprint changed differently) — reported, left for `aicoding-update`.
- `to_remove` (file dropped from blueprint inventory) — reported, never auto-deleted.

This is strictly more conservative than `aicoding-update --yes`, which DOES auto-resolve drift (with backup) and DOES auto-remove. The automatic provisioning path is intentionally more cautious about touching files the user has edited.

The `~/.bashrc.d/` convention for user additions: anything matching `local-*.sh` (or any name *not* prefixed `aicoding-`) is sourced by the managed block but never touched by the blueprint. Personal aliases, env vars, and shell tweaks belong there.

### Why the model

The pre-manifest installer would silently clobber any file you'd hand-edited on every re-run. The manifest + drift detection lets the installer guarantee "your changes are never overwritten without a prompt." See `docs/superpowers/specs/2026-05-16-blueprint-sync-design.md` in the parent [devMachine](https://github.com/vossiman/devMachine) repo for the full design.

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
  2. Auto-install prereqs in container mode (git, jq, claude CLI, locales)
  3. Load or prompt for secrets (~/.aicodingsetup/.secrets.env — non-interactive in containers)
  4. Report unmanaged components (leave untouched)
  5. Configure Claude Code MCPs (claude mcp add)
  6. Install Claude Code marketplace plugins
  7. Install aicoding-update symlink → ~/.local/bin/aicoding-update
  8. Detect install mode (first / adopt / reconcile) — see Update section
  9. Deploy managed files (first mode) OR adopt existing hashes (adopt mode) OR
     auto-apply conservative buckets (reconcile mode). Writes / updates the manifest.
 10. Install tmux plugins (TPM), clone/update bubblewrap, detect infra-audit,
     check Playwright
```

File deployment is centralised in `lib/blueprint-deploy.sh`. Every managed file flows through one of three deploy modes (`overwrite`, `merge`, `marker_block`), captured in the manifest at `~/.aicodingsetup/manifest.json` so subsequent `aicoding-update` runs can detect and surface drift.

## Repo Structure

```
aiCodingBaseSetup/
├── install.sh                     # Linux/WSL installer with three-mode dispatch
├── install.ps1                    # Windows installer (stub)
├── update.sh                      # postStartCommand: refresh claude + opencode binaries
├── bin/
│   └── aicoding-update            # CLI for applying blueprint changes to a live container
├── lib/
│   └── blueprint-deploy.sh        # Shared library: hash, manifest, classify, deploy primitives
├── .secrets.env.example           # Template for required API keys
├── configs/
│   ├── bash/
│   │   ├── env.sh                 # Empty — container-wide env vars go here
│   │   └── ssh-auth-sock.sh       # SSH_AUTH_SOCK stabilizer across reconnects
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
├── tests/
│   └── bats/                      # bats-core unit + integration + regression tests
└── vendor/                        # External repos (gitignored)
    └── bw-AICode/
```

## Test Your Setup

After running the installer, paste the test prompt from `test-prompt.md` into Claude Code or opencode to verify everything works.
