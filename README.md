# AI Coding Base Setup

Cross-platform installer/updater for **Claude Code, opencode, OpenAI Codex, and Cursor Agent** configurations. Syncs the same set of MCPs across all four CLIs, plus Claude-specific skills, hooks, plugins, and statusline. Runs on Mint Linux, WSL, Windows, and devcontainers (DevPod / Codespaces / Dev Containers).

## Quick Start

```bash
git clone https://github.com/vossiman/aiCodingBaseSetup.git
cd aiCodingBaseSetup
./install.sh
```

On first run, you'll be prompted for API keys. Press Enter to skip any you don't have yet.

## What Gets Installed

### CLIs

The installer ensures four AI coding CLIs are present and configured:

| CLI | Binary | Login | Auth file persisted at |
|-----|--------|-------|------------------------|
| Claude Code | `claude` | `claude` (browser OAuth) | `~/.claude/.credentials.json` |
| opencode | `opencode` | `opencode auth login <provider>` | `~/.local/share/opencode/auth.json` |
| OpenAI Codex | `codex` | `codex` (first run — ChatGPT sign-in or `OPENAI_API_KEY`) | `~/.codex/auth.json` |
| Cursor Agent | `agent` (or `cursor-agent` on older releases) | `agent login` (or `CURSOR_API_KEY`) | `~/.config/cursor/auth.json` — `install.sh` symlinks `~/.config/cursor` into the bind-mounted `~/.aicodingsetup/cursor-config` so login is once-ever across pods (the mounted `~/.cursor` holds only MCP config, not credentials) |

All four read the same 4 MCP servers; auth state persists across containers via bind-mounted home directories (DevPod setup — see "Devcontainers" below).

### MCP Servers

Configured for **all four CLIs**: `claude mcp add` for Claude Code (existing), `~/.config/opencode/opencode.json` `mcp` field for opencode, `~/.codex/config.toml` `[mcp_servers.*]` tables for codex, and `~/.cursor/mcp.json` `mcpServers` object for cursor-agent. Same four servers, four config formats — `install.sh` deploys each from a template in `configs/`.

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
- **bw-deny-files.sh** — PreToolUse hook that blocks agent access to secrets and private keys
  (`~/.aicodingsetup/.secrets.env`, `*-ship`, `*.pem`, `*.key`, `id_rsa`/`id_ed25519`, `.netrc`, `.pgpass`)
  across Read/Edit/Write/Grep/Glob **and** Bash. Originally vendored from
  [bw-AICode](https://github.com/vossiman/bw-AICode); **forked 2026-08-21** because upstream only armed
  it inside the bubblewrap sandbox (`BW_DENY_PATTERNS_FILE`), making it a no-op everywhere else. The
  built-in list is now always enforced and that env var only *adds* patterns. Escape hatch: `secrets-check`.
  Also runs on **Codex** — same script, installed as a managed hook (see Secrets).
  Covered by `tests/bats/secrets-deny-hook.bats` and `tests/bats/codex-managed-hooks.bats`.
- **check-archived-docs.sh** — SessionStart hook. Emits a one-line banner when a scaffolded project has docs with `status: done` in any `docs/*/active/` folder. Fail-open.

### Slash commands

- **/scaffold-project** — Drops the canonical project layout (`CLAUDE.md`, `TODO.md`, `docs/{specs,plans,notes}/{active,archive}/`, project `.claude/settings.json`) into the current directory. Interactive: asks for name and one-line purpose. Refuses to clobber existing files.
- **/housekeep** — Sweeps `docs/*/active/` for docs with `status: done` frontmatter and moves them into the sibling `archive/`. Also prunes `[x]` items older than 14 days from `TODO.md`.

### Project templates

Installed to `~/.aicodingsetup/templates/project/`. Used by `/scaffold-project` to materialize a new project. **Intentional scaffold material outside the manifest:** `install_templates()` rsyncs with `--delete` every run — the repo tree is always SoT; these are not user-edited managed dotfiles, so they skip classify/hash tracking.

### Container-side helpers

- **`~/.bashrc.d/aicoding-env.sh`** — empty by default; put container-wide `export FOO=bar` lines here. Sourced from every login shell via the managed block in `~/.bashrc`.
- **`~/.bashrc.d/aicoding-ssh-auth-sock.sh`** — stabilizes the forwarded SSH agent socket across DevPod / Cursor reconnects. Routes every shell through `~/.ssh/agent.sock` (a symlink we keep current). Without it, long-lived tmux panes hold a stale `SSH_AUTH_SOCK` path after the host's SSH session rotates, and `git push` fails with `Permission denied (publickey)` until you open a new pane.
- **`~/.codex/config.toml`** — overwrite-mode managed file; declares the 4 MCPs in TOML `[mcp_servers.<name>]` tables with secrets substituted at deploy time. Tracked in `manifest.json`; redeployed on every rebuild via `reconcile`.
- **`~/.cursor/mcp.json`** — merge-mode managed file; declares the 4 MCPs in JSON `{mcpServers: ...}` (Claude-Desktop-compatible schema). User-added entries are preserved by the merge.

### External Tools (detected, not installed)

- **infra-audit** — Python project infrastructure auditor ([python-infra-audit-cc](https://github.com/vossiman/python-infra-audit-cc))
## Secrets

Secrets are stored at `~/.aicodingsetup/.secrets.env` (outside the repo).

**Agents must never read that file.** Reading it copies live credentials into a
transcript that is persisted and distilled to the wiki. Four layers enforce this:

| Layer | Agent | Kind |
|-------|-------|------|
| `bw-deny-files.sh` PreToolUse hook | Claude Code | hard — blocks Bash too |
| `permissions.deny` in `settings.json` | Claude Code | hard — file tools |
| `permissions.deny` in `cli-config.json` | Cursor | hard — file tools |
| `permission.read` / `permission.bash` maps | OpenCode | hard — file tools + shell patterns |
| `bw-deny-files.sh` as a codex **managed** hook | Codex | hard — blocks Bash and apply_patch |
| `AGENTS.md` / `CLAUDE.md` prohibition | all four | soft — backstop |

Codex implements the *same* PreToolUse contract as Claude Code — same
`tool_name`/`tool_input.command` input, same
`hookSpecificOutput.permissionDecision: "deny"` response — so it runs the very
same script (verified against codex-cli 0.148.0). The catch: codex gates every
**non-managed** hook behind a trust hash and silently skips it until a human
runs `/hooks` in the TUI. `~/.codex/hooks.json` would therefore be inert on a
fresh machine — the exact bug this change exists to fix — so
`ensure_codex_managed_hooks()` installs it to `/etc/codex/requirements.toml`
instead, where hooks are trusted by policy and cannot be disabled from the user
hook browser.

That one step is the only part of the install that needs root, and it escalates
for itself — **never run `sudo aicoding-install`**. Behaviour by context:

| Context | What happens |
|---|---|
| root, or passwordless sudo (containers) | writes silently |
| sudo needs a password, terminal attached | explains why, then prompts for that step alone |
| non-interactive (CI, `--yes` in a pipe) | warns once and continues |
| `--boot` sync | silent skip — it runs on every container start and must not nag |

`aicoding-sync` reconciles it too, not just `aicoding-install`, so an existing
container self-heals on its next boot instead of waiting for someone to re-run
the installer.

To answer "is this key set?" without reading anything, run **`secrets-check`**:
it prints key names, set/empty, length and a per-machine salted fingerprint —
never a value — and exits non-zero if a requested key is empty.

```
$ secrets-check GH_TOKEN
KEY                          STATUS       LEN  FINGERPRINT
GH_TOKEN                     set           93  d8ee9caf
```

### The token is not only in the file

Denying the secrets file alone still left three routes to the same GitHub
token. All closed 2026-08-21:

- **The environment.** `GH_TOKEN` used to be exported into every shell, so
  `printenv GH_TOKEN` handed it straight over. No longer exported — see
  `unset GH_TOKEN GITHUB_TOKEN` in `configs/bash/env.sh`.
- **The credential helper.** `git-credential-aicoding get` and
  `git credential fill` print the token by design. Agent-typed invocations
  are denied; git's own internal calls are not tool calls and still work.
- **`gh auth token`**, likewise denied.

Nothing lost GitHub access, because neither client actually needed the
variable: **git** authenticates through `git-credential-aicoding`, which
reads the secrets file directly, and **gh** now has its own stored login,
refreshed from that same file on every boot sync by
`ensure_gh_stored_auth()`. Its `~/.config/gh/hosts.yml` is deny-listed too.

The ceiling is unchanged and worth stating plainly: a devpod is not a
security boundary, and anything that can run `git` can still make it produce
a credential. This stops a cooperative agent from copying a live token into a
transcript — the failure that actually happens — not a determined attacker.

| Key | Used By |
|-----|---------|
| `FIRECRAWL_API_KEY` | firecrawl MCP |
| `BRAVE_API_KEY` | brave-search MCP |
| `CLOUDFLARE_API_TOKEN` | `cloudflare-render` broker (read in-process, never rendered into the skill) |
| `CLOUDFLARE_ACCOUNT_ID` | `cloudflare-render` broker (read in-process, never rendered into the skill) |
- **Install:** prompts for all keys (Enter to skip)
- **Update:** only prompts for new keys, never overwrites existing values
- MCP keys are injected into MCP config blocks
- Agent-readable markdown (skills, slash commands, subagents, `CLAUDE.md`,
  `AGENTS.md`) gets `{{HOME}}` expanded and **nothing else** — no key is ever
  substituted into a file an agent reads as prose. A skill that needs a
  credential calls a broker (`cloudflare-render`, `kanban-post`,
  `git-credential-aicoding`), which reads the value in-process and never
  prints it.

In devcontainers the file is bind-mounted **read-only** (a single-file mount
stacked over the rw `~/.aicodingsetup` mount) so no in-container tooling or
agent can rewrite or delete the host-side source of truth. Two consequences:

- The file must **exist on the host before provisioning** (`touch
  ~/devpod/aicodingsetup/.secrets.env` on a fresh host) — Docker creates a
  *directory* in place of a missing single-file bind source.
- A single-file bind pins the file's inode: after editing on the host with a
  rename-on-save editor (vim, `sed -i`), running containers keep seeing the
  old content until restarted. Edit in place (`nano`, `echo >>`) or restart
  the container after rotating tokens.

## Update

Two distinct flows after the initial install:

### Which one do I run?

Normally neither, by hand — the tmux badges from `aicoding-status` decide:

| Badge | What moved on blueprint `main` | You run |
|-------|--------------------------------|---------|
| ⬆`sync` | anything sync can deliver: managed configs, MCP/plugin definitions, agent-CLI updates, sync's own code | `aicoding-sync` — or nothing; boot/attach runs it on a throttle |
| ⬆`install` | provisioning itself: `install.sh`, `lib/provision*`, `image/` | `aicoding-install` |
| ⬆`rebuild` | the base image | rebuild the container from your laptop |

Rule of thumb: **agent harness, plugins, MCPs, and the agent CLIs
themselves are sync territory** (the CLIs self-update via
`claude update` / `opencode upgrade` / `agent update` / codex's
version-gated reinstall). **System tools are install territory** —
apt prereqs, node, go, uv, tmux (built from source at a pinned
commit), Playwright deps, and first-time bootstrap of a missing CLI.
Sync deliberately doesn't touch those.

Both commands bring the blueprint clone (`/tmp/aicoding`) current to
`origin/main` before doing any work, and fall back to the cached clone
when offline (`--blueprint` mode never fetches). One asymmetry:
`aicoding-install` re-executes the freshly pulled `install.sh`, so the
code doing the work is always the just-fetched version — whereas
`aicoding-sync` sources its library *before* refreshing the clone, so a
change to sync's **own code** is pulled by one run and first executed by
the next. Content it deploys (configs, MCP/plugin definitions) is
always same-run current.

### `aicoding-sync` — day-2 reconciliation (recommended)

```bash
aicoding-sync --dry-run    # show what would change vs your environment
aicoding-sync              # interactive — single y/N confirm, inline diff for drift
aicoding-sync --yes        # scripted — auto-confirms; backs up anything drifted
aicoding-sync --blueprint /path/to/aiCodingBaseSetup --dry-run  # test a local checkout verbatim
```

`aicoding-sync` is installed into `~/.local/bin/` by `install.sh`. It compares three hashes per managed file (currently on disk, last-deployed per the manifest, current blueprint source) and classifies each file into one of seven outcomes. Drifted files (you modified them) are surfaced with full inline `diff -u` output and backed up to `<file>.bak.<YYYYMMDD-HHMMSS>` before being overwritten. Missing-on-disk managed files are classified as `restore` and silently re-deployed. It also reconciles machine state shared with `install.sh` via `lib/provision.sh` — MCP registrations, marketplace plugins, and the npm packages backing stdio MCPs (throttled on `--boot`, always on manual runs).

(The former `aicoding-update` and `update-status` names were back-compat shims and have been removed; use `aicoding-sync` and `aicoding-status`.)

The manifest at `~/.local/state/aicoding/manifest.json` records the blueprint commit and a per-file hash for every overwrite-mode file, plus a block-hash for the marker-guarded section of `~/.bashrc`.

It is deliberately **container-local**, not under `~/.aicodingsetup`: that directory is a host bind mount shared by every devpod container, whereas the manifest describes container-local paths (`~/.bashrc`, `~/.tmux.conf`, …). While it was shared, whichever container synced last stamped the global `blueprint_commit`, so every other container computed `installed == latest` and its `aicoding-status` CTA went quiet while it was still running stale files. The update-status cache (`~/.local/state/aicoding/updates/`) is container-local for the same reason, and stores **only the remote `latest` SHA** — `aicoding-status` reads the installed commit fresh from the manifest at print time, so a manifest write can never leave a stale "behind" verdict pinned behind the cache TTL. A manifest left on the shared mount by an older install is adopted once, on first read; the shared copy is left in place so sibling containers can adopt it too.

### `aicoding-install` — pull latest and re-run the installer

```bash
aicoding-install                     # refresh /tmp/aicoding to origin/main, re-run install.sh
aicoding-install --force-reinstall   # same, but deletes the manifest first (nuke drift, first-deploy)
aicoding-install --blueprint /path/to/aiCodingBaseSetup  # provision from a local checkout
```

Re-running the installer on an initialized container (manifest exists) re-runs the apt/build/locale prereq steps (idempotent) **and** then runs **reconcile mode**, which automatically applies the conservative buckets without any prompts. Use it when provisioning-only pieces broke or changed (tool bootstrap incl. codex, templates, tmux plugins, Playwright browser + system libs) — `aicoding-sync` deliberately doesn't touch those. Running `./install.sh` from a checkout does the same against that checkout's version.

`aicoding-install` is profile-aware: it reads `.profile` from the manifest and re-runs `install-host.sh` on host machines, `install.sh` everywhere else — same muscle memory either way. Containers continue to refresh through the throwaway `/tmp/aicoding` tracking clone. Host installs first copy that exact released or local (including dirty) blueprint into `~/.local/share/aicoding/blueprint` and run from there, so `aicoding-sync`, `aicoding-install`, and `aicoding-status` never depend on `/tmp` surviving a cleanup or reboot. Set `AICODING_HOST_BLUEPRINT_DIR` to choose a different durable host location.

### Bare-host install (no devcontainer)

For a laptop or server that isn't a devpod container, `install-host.sh` deploys a thin, core-only profile: the `claude` CLI, the managed Claude layer (CLAUDE.md, hooks, MCPs/plugins), the homelab-wiki clone, and terminal-open auto-sync (6h-throttled) — plus the sandbox prereq (`bwrap`) and `bw-AICode` tooling. It skips everything container-only: codex/opencode/cursor, Playwright, Go, tmux. Day-2 commands are identical to the container flow — `aicoding-sync` and `aicoding-install` both read the manifest's `.profile` and stay on the host installer.

```bash
gh auth login          # or put GH_TOKEN in the secrets file and run
                       # aicoding-sync, which logs gh in from it
git clone https://github.com/vossiman/aiCodingBaseSetup && cd aiCodingBaseSetup
./install-host.sh
```

### Per-CLI binary refresh (`aicoding-sync --boot`)

Different CLIs have different in-place update stories. Container `postStartCommand`
runs `on-start.sh` → `aicoding-sync --boot`, which (among other things) refreshes
CLI binaries on a throttle. Behaviour per CLI:

| CLI | Update path | Run on every start? |
|-----|-------------|---------------------|
| Claude Code | `claude update` | ✅ (throttled) |
| opencode | `opencode upgrade` | ✅ (throttled) |
| Cursor Agent | `agent update` (or `cursor-agent update` on older releases) | ✅ (throttled) |
| OpenAI Codex | Version-gated reinstall: sync compares the installed version against the npm registry and re-runs the official installer only on a real change (no in-place subcommand exists upstream; spec: `docs/superpowers/specs/2026-08-09-codex-self-update-design.md`) | ✅ (throttled) |

Each updater's output is prefaced with a `--- <tool> ---` header so error
text is attributable — Cursor's binary is named `agent`, so without one
its errors read as someone else's (its expired-session
`Error: Update failed: [unauthenticated] Error` was once chased as a
codex failure). Failures on any of the updates are non-fatal (the step
is `|| true`; codex prints self-labeled `ERROR:` lines) so a transient
network blip doesn't block container start.

### Install modes

`install.sh` picks one of three modes based on what it finds:

| State on disk | Mode | Behaviour |
|---|---|---|
| No manifest, no managed files exist | `first` | Deploys everything; writes initial manifest. |
| No manifest, but managed files already on disk (older install) | `adopt` | Captures current file hashes into the manifest without overwriting. Surfaces accumulated drift on the next `aicoding-sync --dry-run`. |
| Manifest exists | `reconcile` | Re-runs prereqs, then auto-applies the conservative buckets (see below). |

**Reconcile mode** runs every time `install.sh` is invoked on a container that already has a manifest (e.g., every devcontainer rebuild). It classifies each managed file and automatically applies the conservative buckets:
- `restore` (file tracked but missing on disk → redeploy from blueprint)
- `new_file` (in blueprint inventory, not yet in manifest → deploy)
- `will_update` (tracked, unedited locally, blueprint changed → deploy)
- `drifted_but_aligned` (you edited to match the new blueprint → refresh manifest hash, no file write)
- `merge` (settings.json / opencode.json → deep-merge blueprint over local)

It deliberately does **not** auto-apply two buckets:
- `drifted_and_updating` (you edited AND blueprint changed differently) — reported, left for `aicoding-sync`.
- `to_remove` (file dropped from blueprint inventory) — reported, never auto-deleted.

This is strictly more conservative than `aicoding-sync --yes`, which DOES auto-resolve drift (with backup) and DOES auto-remove. The automatic provisioning path is intentionally more cautious about touching files the user has edited.

The `~/.bashrc.d/` convention for user additions: anything matching `local-*.sh` (or any name *not* prefixed `aicoding-`) is sourced by the managed block but never touched by the blueprint. Personal aliases, env vars, and shell tweaks belong there.

### Why the model

The pre-manifest installer would silently clobber any file you'd hand-edited on every re-run. The manifest + drift detection lets the installer guarantee "your changes are never overwritten without a prompt." See `docs/superpowers/specs/2026-05-16-blueprint-sync-design.md` in the parent [devMachine](https://github.com/vossiman/devMachine) repo for the full design.

> The container hostname is set to the workspace name via runArgs:
> `["--hostname", "${containerWorkspaceFolderBasename}"]`, so shells and logs
> show e.g. `devmachine` instead of a docker id.

## Windows

Unsupported. A quarantined PowerShell stub lives at `contrib/windows/install.ps1` for archaeology only — use Linux/WSL `install.sh`.

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

`postCreateCommand` clones this repo and runs its `install.sh` once on container creation; `postStartCommand` curls `on-start.sh` from this repo on every container start, which runs the unified sync in `--boot` mode to keep `claude` and `opencode` binaries fresh.

`containerEnv` overrides three `BASH_FUNC_*%%` env vars that universal:6 leaks with truncated multi-line bodies — without it bash errors on every spawn (see [vscode#3928](https://github.com/Microsoft/vscode/issues/3928), [vscode-remote-release#9457](https://github.com/microsoft/vscode-remote-release/issues/9457)). `install.sh` and `on-start.sh` further re-exec themselves under `env -u` to belt-and-braces the same problem.

`remoteUser` must match the image's hardcoded user — `codespace` for `universal:6`, `vscode` for most others (`python`, `base`, etc.). Mismatch → mounts land at the wrong path and nothing works.

The template ships with `"mounts": [...]` wired for a DevPod-style backend (e.g. `vossisrv` hosting all containers): bind-mounting five dirs gives all four CLIs persistent state across every container the user spins up:

| Host source | Container target | What persists |
|---|---|---|
| `…/aicodingsetup/` | `~/.aicodingsetup/` | `.secrets.env`, `manifest.json` |
| `…/aicodingsetup/.secrets.env` | `~/.aicodingsetup/.secrets.env` (**read-only**) | overlay on the row above — see "Secrets" |
| `…/claude/` | `~/.claude/` | Claude credentials, settings, plugins |
| `…/opencode/` | `~/.local/share/opencode/` | opencode `auth.json` (per-provider tokens) |
| `…/codex/` | `~/.codex/` | codex `auth.json` + `config.toml` |
| `…/cursor/` | `~/.cursor/` | cursor-agent credentials + `mcp.json` |

`install.sh` re-deploys `~/.codex/config.toml` and `~/.cursor/mcp.json` on every rebuild via `reconcile`, so config drift heals automatically — auth files persist untouched.

These `source=` paths assume a `~/devpod/...` host layout. If your host differs, edit the `source=` paths to match, or drop any mounts you don't need — the template works without them, you just lose cross-container persistence for those tools.

### Why both `.credentials.json` and `~/.claude.json` matter

Claude Code reads OAuth tokens from `~/.claude/.credentials.json` *and* checks `~/.claude.json` (a file at home root, **not** inside `.claude/`) for `hasCompletedOnboarding: true`. Without that flag, the CLI treats every session as a fresh install and prompts for login even when valid tokens exist. `install.sh` writes that flag automatically when it sets up MCPs — without it, copying the credentials file alone is not sufficient to authenticate a container.

### Agent logins (one-time interactive)

All four CLIs use the same pattern: log in once in any DevPod workspace, and the credential file lands in the bind-mounted home directory — every future workspace inherits the auth automatically.

| CLI | Login command | Where the token lands |
|-----|---------------|------------------------|
| Claude Code | `claude` → browser OAuth flow | `~/.claude/.credentials.json` |
| opencode | `opencode auth login <provider>` | `~/.local/share/opencode/auth.json` |
| OpenAI Codex | `codex` on first run → ChatGPT sign-in (or `OPENAI_API_KEY` env var) | `~/.codex/auth.json` |
| Cursor Agent | `agent login` (or `cursor-agent login`) — or `CURSOR_API_KEY` env var | inside `~/.cursor/` |

HTTP-based MCPs that need their own OAuth (logfire, claude.ai Google Drive, etc.) still require a browser flow per-MCP via `claude` → `/mcp` → select the MCP → follow the link. State persists in the bind-mounted `~/.claude/`, so every future workspace inherits it.

## How It Works

```
install.sh
  1. Detect environment (Linux / WSL / container)
  2. Auto-install prereqs in container mode (git, jq, claude CLI, locales, tmux)
  3. Load or prompt for secrets (~/.aicodingsetup/.secrets.env — non-interactive in containers)
  4. Report unmanaged components (leave untouched)
  5. Configure Claude Code MCPs (claude mcp add)
  6. Install Claude Code marketplace plugins
  7. Install aicoding-sync symlink → ~/.local/bin/aicoding-sync
  8. Detect install mode (first / adopt / reconcile) — see Update section
  9. Deploy managed files (first mode) OR adopt existing hashes (adopt mode) OR
     auto-apply conservative buckets (reconcile mode). Writes / updates the manifest.
 10. Install tmux plugins (TPM), clone/update bubblewrap, detect infra-audit,
     check Playwright
```

File deployment is centralised in `lib/blueprint-deploy.sh`. Every managed file flows through one of three deploy modes (`overwrite`, `merge`, `marker_block`), captured in the manifest at `~/.local/state/aicoding/manifest.json` so subsequent `aicoding-sync` runs can detect and surface drift.

The same persist-once-share-everywhere property applies to all four CLIs once their bind mounts are wired: `claude`, `opencode`, `codex`, and `agent` each persist their auth into their respective bind-mounted home directories, so a single login in any container is reusable from every other.

## Repo Structure

```
aiCodingBaseSetup/
├── install.sh                     # Linux/WSL installer (three-mode dispatch)
├── on-start.sh                    # postStartCommand entry → aicoding-sync --boot
├── contrib/windows/               # quarantined Windows stub (unsupported)
├── bin/
│   ├── aicoding-install           # refresh /tmp/aicoding to origin/main, re-run install
│   ├── aicoding-sync              # day-2 reconcile + boot sync
│   ├── aicoding-status            # update-notifier status (banner/tmux/print)
│   └── aicoding-ssh-agent-watch   # legacy ssh-agent socket watcher
├── lib/
│   ├── blueprint-deploy.sh        # hash, manifest, classify, deploy primitives
│   ├── blueprint-source.sh        # --blueprint PATH parsing + validation
│   ├── provision.sh               # MCPs, plugins, npm packages (shared w/ sync)
│   ├── provision-system.sh        # environment, tool bootstrap, prerequisites
│   ├── provision-secrets.sh       # secrets loading and prompting
│   ├── provision-managed-files.sh # first/adopt/reconcile managed-file paths
│   ├── provision-integrations.sh  # CLI links, TPM, bubblewrap, Playwright
│   └── sync.sh                    # auth plumbing + aicoding-sync core
├── .secrets.env.example           # Template for required API keys
├── configs/
│   ├── bash/                      # env, aliases, ssh-auth-sock, update-notify
│   ├── claude/                    # settings, CLAUDE.md, hooks/
│   ├── codex/                     # config.toml (overwrite-managed MCPs)
│   ├── cursor/                    # mcp.json + cli-config.json
│   ├── git/                       # git-credential-aicoding
│   ├── opencode/                  # opencode.json
│   └── tmux/                      # tmux.conf
├── commands/                      # Slash commands → ~/.claude/commands
├── skills/                        # Shared skills → ~/.claude/skills
├── templates/project/             # Mirrored to ~/.aicodingsetup/templates/project
├── tests/bats/                    # bats-core suite (run via tests/bats/run.sh)
├── tools/render-debug/            # Optional tmux/statusline debug harness
└── vendor/                        # External clones (gitignored), e.g. bw-AICode
```

Per-CLI MCP configs live under `configs/{codex,cursor,opencode}/` plus Claude
registration via `lib/provision.sh` (`MANAGED_MCPS`). There is no shared
`mcps.json` generator yet — keep those lists in sync by hand when adding an MCP.

## Two delivery channels (dev vs runtime)

| Channel | What | When |
|---------|------|------|
| **Parent submodule** (`devMachine` → `devpod/aicoding`) | Editable checkout pinned to a SHA | Developing / reviewing this repo |
| **Runtime tracking clone** (`/tmp/aicoding` → GitHub `main`) | What containers install & sync from | `postCreate`, `aicoding-install`, `aicoding-sync` refresh |

Edits in the submodule do **not** affect a running container until they land on
`main` unless you explicitly select it with `--blueprint`. Local mode resolves
and validates the path, reports its branch/commit/dirty state, and performs no
fetch or reset—the working tree, including uncommitted edits, is the source of
truth for that command:

```bash
aicoding-sync --blueprint "$PWD/devpod/aicoding" --dry-run
aicoding-sync --blueprint "$PWD/devpod/aicoding"       # review, then apply

# For installer/provisioning changes rather than day-2 config sync:
aicoding-install --blueprint "$PWD/devpod/aicoding"
```

The option is per invocation; normal boot sync continues to use the released
`/tmp/aicoding` tracking clone. `AICODING_BLUEPRINT_CLONE` and
`AICODING_BLUEPRINT_REMOTE` remain internal tracking-clone controls, not the
safe local-checkout interface. `dvw new` separately seeds `devcontainer.json`
from tip-of-`main` by default (`DVW_BLUEPRINT_DEVCONTAINER_URL`).

## Test Your Setup

After running the installer, paste the test prompt from `test-prompt.md` into Claude Code or opencode to verify everything works.
