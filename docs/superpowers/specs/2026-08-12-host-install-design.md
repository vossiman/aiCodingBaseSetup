# Bare-host install mode (`install-host.sh`) — design

*2026-08-12. Brainstormed with the user; approved in-conversation.*

## Problem

The blueprint's managed Claude layer (global CLAUDE.md, agents, hooks,
skills, settings, MCPs, plugins) only reaches devpod containers today —
`install.sh` provisions the full container toolchain and `on-start.sh`
triggers day-2 sync on attach. The user's two physical thin clients (the
Linux Mint desktop and the Surface laptop's WSL2 Ubuntu) get none of it.
Goal: the same convenience on bare metal — central CLAUDE.md, agents,
hooks, homelab-wiki awareness, self-updating — without dragging in the
container-only toolchain.

## Decisions (from brainstorming)

- **Profile: core only.** claude CLI + managed `~/.claude` layer + MCP
  servers with their npm backends + `aicoding-*` symlinks + homelab-wiki
  clone + a boot-sync trigger. NOT installed on hosts: codex/opencode/
  cursor CLIs, Playwright + system libs, Go, uv, tmux plugins, templates,
  bubblewrap, ssh-agent-watch, LFS autopull.
- **Structure: separate thin entry point, shared library** (user choice —
  "C with shared functions"). `install.sh`'s `main()` is already a thin
  step list over `lib/`; `install-host.sh` is a sibling step list, zero
  duplicated logic. No auto-detection of the environment; running the
  host installer IS the classification.
- **Profile is persisted**: the installer writes `"profile": "host"` to
  the manifest (`~/.local/state/aicoding/manifest.json`). Absent key
  means `container`, so all existing machines are untouched. Day-2
  tooling branches on the manifest, never re-guesses.
- **No sudo from the installer.** Missing system prereqs abort with the
  exact `sudo apt install …` line printed for the user to run.
- **Settings promotion rejected**: the six hand-set keys on the current
  devbox (model, defaultMode, theme, push-notif, two skip-warning flags)
  self-persist locally after one confirmation per machine — not worth
  managing. Cross-machine agent communication explicitly not wanted
  (`isolatePeerMachines: true` stays).

## `install-host.sh`

Same skeleton as `install.sh`: source `lib/` modules, colored loggers,
`main()` guarded by the `BASH_SOURCE` direct-run check so bats can source
individual functions.

Step list, shared functions used verbatim:

1. `check_prerequisites_host` (new, in `lib/provision-system.sh`):
   verify `git`, `curl`, `jq`, `node`/`npm` exist; on any miss, print one
   `sudo apt install …` line and exit 1. Never runs apt itself.
2. `seed_github_known_host`, `load_or_prompt_secrets` — shared. The
   secrets file on hosts is a plain `~/.aicodingsetup/.secrets.env`
   (already present on both target machines), not a bind mount; the
   loader does not care.
3. `ensure_claude_code` (shared, `lib/provision-system.sh:150`) — claude
   only; user-local native installer, no sudo.
4. `report_unmanaged`, `install_mcp_packages`, `install_claude_mcps`,
   `ensure_claude_onboarding_state`, `install_claude_plugins` — shared.
5. Symlinks: `install_aicoding_sync_symlink`,
   `install_aicoding_install_symlink`, `install_update_status_symlink` —
   shared. (No agent-notify or ssh-agent-watch on hosts.)
6. Managed files: the shared `detect_install_mode` →
   `deploy_all_managed_files` / `adopt_existing_files` /
   `reconcile_existing_install` engine, unchanged. This is the heart.
7. `install_boot_sync_trigger` (new): deploy managed
   `~/.bashrc.d/aicoding-boot-sync.sh` that runs `aicoding-sync --boot
   --yes` (self-throttled; `--yes` because a login shell is
   non-interactive for our purposes — see the 2026-08-12 devMachine note
   on sync's no-TTY behavior), plus a marker block in `~/.bashrc` that
   sources `~/.bashrc.d/*.sh` — stock Mint/WSL bashrc doesn't; the
   container image does it via `/etc/profile`. Marker-block machinery
   already exists in `lib/blueprint-deploy.sh`.
8. `ensure_homelab_wiki` (new): `git clone
   https://github.com/vossiman/homelab-wiki ~/homelab-wiki` if missing;
   a failed clone warns and continues (agents self-heal per CLAUDE.md).
9. Manifest: stamp provision commit (shared) and write
   `"profile": "host"`.

## Day-2 behavior

- `aicoding-sync` reads `profile` from the manifest. `host` profile:
  managed files, MCP/plugin/npm reconcile, and per-CLI refresh for
  **claude only**; skip codex/opencode/cursor update paths and any
  container-only reconcile steps. `container` (or absent): unchanged
  behavior.
- `aicoding-install` re-executes the installer matching the manifest
  profile (`install-host.sh` vs `install.sh`), so the day-2 muscle
  memory is identical everywhere.
- The boot-sync bashrc snippet gives hosts the equivalent of the
  container's `on-start.sh` attach sync: freshness on terminal open,
  throttled. No systemd dependency (WSL user sessions often lack it).

## Testing

Bats, existing patterns, offline via `AICODINGSETUP_SKIP_NETWORK`:

- `install-host.bats`: source `install-host.sh`; assert the step list
  excludes container-only steps, profile lands in the manifest, prereq
  check aborts with the apt hint, marker block + bashrc.d snippet deploy
  and are idempotent.
- `sync.bats` additions: host profile skips codex/opencode/cursor
  refresh; container/absent profile unchanged.
- `install.bats` regression: container flow writes no `profile` /
  behaves identically.

## Out of scope (recorded)

- `devMachine`'s `dvw-install.sh` calling `install-host.sh` for
  one-command thin-client bootstrap — natural follow-up, separate PR.
- Cross-machine agent messaging.
- Promoting the six local settings keys into the blueprint.
- Windows-native (non-WSL) support on the Surface.
