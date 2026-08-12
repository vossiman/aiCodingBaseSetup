# Bare-Host Install Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A core-only `install-host.sh` entry point (plus profile-aware day-2 tooling) that brings the managed Claude layer to bare Linux hosts (Mint desktop, Surface WSL).

**Architecture:** `install-host.sh` is a thin step list over the existing `lib/` functions, exactly like `install.sh`'s 156-line `main()`. A `"profile": "host"` key in the manifest (absent = `container`) makes the managed-file inventories and binary refresh profile-aware. Spec: `docs/superpowers/specs/2026-08-12-host-install-design.md`.

**Tech Stack:** bash, jq, bats (run ONLY via `tests/bats/run.sh`).

## Global Constraints

- Tests must stay offline: `tests/bats/run.sh` sets `AICODINGSETUP_SKIP_NETWORK=1`; every new network call needs that guard.
- The host installer never runs sudo/apt; missing prereqs abort with a printed `sudo apt install …` line.
- Provisioning functions fail open (`warn` + continue), matching existing `lib/` style; only missing prereqs abort.
- Absent `profile` key in the manifest MUST behave exactly as today (`container`) — zero behavior change for existing machines.
- Run a task's test file as `tests/bats/run.sh <basename>` (e.g. `tests/bats/run.sh install-host`), never bare `bats`.
- All work happens in the `/var/tmp/aicoding-wt-host-install` worktree on branch `feat/host-install`.

---

### Task 1: Manifest profile helpers

**Files:**
- Modify: `lib/blueprint-deploy.sh` (after `manifest_stamp_provision`, ~line 95)
- Test: `tests/bats/blueprint-deploy.bats`

**Interfaces:**
- Consumes: `AICODING_MANIFEST` (defaulted at `lib/blueprint-deploy.sh:9`), `read_manifest`/`write_manifest` conventions.
- Produces: `manifest_get_profile` (echoes `host` or `container`, no trailing newline beyond printf; precedence: `$AICODING_PROFILE` env override → manifest `.profile` → `container`) and `manifest_set_profile <profile>` (persists `.profile`, creating the manifest if absent; preserves all other keys). Tasks 2, 4, 5, 6 rely on these exact names.

- [ ] **Step 1: Write the failing tests**

Append to `tests/bats/blueprint-deploy.bats` (it already sources the lib in its setup; follow the file's existing test style):

```bash
@test "manifest_get_profile: defaults to container when manifest absent" {
  run manifest_get_profile
  [ "$status" -eq 0 ]
  [ "$output" = "container" ]
}

@test "manifest_set_profile then get round-trips host" {
  manifest_set_profile host
  run jq -r '.profile' "$AICODING_MANIFEST"
  [ "$output" = "host" ]
  run manifest_get_profile
  [ "$output" = "host" ]
}

@test "manifest_set_profile preserves existing manifest keys" {
  manifest_stamp_provision deadbeef
  manifest_set_profile host
  run jq -r '.provision_commit' "$AICODING_MANIFEST"
  [ "$output" = "deadbeef" ]
}

@test "manifest_get_profile: AICODING_PROFILE env overrides manifest" {
  manifest_set_profile container
  AICODING_PROFILE=host run manifest_get_profile
  [ "$output" = "host" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `tests/bats/run.sh blueprint-deploy`
Expected: the four new tests FAIL with "manifest_get_profile: command not found" (or equivalent); all pre-existing tests still pass.

- [ ] **Step 3: Implement the helpers**

In `lib/blueprint-deploy.sh`, directly after `manifest_stamp_provision`:

```bash
# manifest_get_profile — echo this machine's install profile: "host" or
# "container". Precedence: AICODING_PROFILE env (set by install-host.sh
# before the first manifest write) → manifest .profile → "container".
# Absent key = container so every pre-profile machine behaves as before.
manifest_get_profile() {
  if [ -n "${AICODING_PROFILE:-}" ]; then
    printf '%s' "$AICODING_PROFILE"
    return 0
  fi
  if [ -f "$AICODING_MANIFEST" ]; then
    jq -r '.profile // "container"' "$AICODING_MANIFEST" 2>/dev/null && return 0
  fi
  printf 'container'
}

# manifest_set_profile <profile> — persist the install profile. Same
# create-or-amend pattern as manifest_stamp_provision.
manifest_set_profile() {
  local profile=$1 dir tmp
  [ -n "$profile" ] || return 0
  dir=$(dirname "$AICODING_MANIFEST"); mkdir -p "$dir" 2>/dev/null || return 0
  tmp="$AICODING_MANIFEST.tmp"
  if [ -f "$AICODING_MANIFEST" ]; then
    jq --arg p "$profile" '. + {profile:$p}' "$AICODING_MANIFEST" > "$tmp" 2>/dev/null || return 0
  else
    jq -n --arg p "$profile" '{profile:$p}' > "$tmp" 2>/dev/null || return 0
  fi
  mv "$tmp" "$AICODING_MANIFEST"
}
```

Note: `jq -r` prints a trailing newline; that matches how other helpers' output is consumed (`$(...)` strips it). Don't fight it.

- [ ] **Step 4: Run tests to verify they pass**

Run: `tests/bats/run.sh blueprint-deploy`
Expected: PASS, including all pre-existing tests.

- [ ] **Step 5: Commit**

```bash
git add lib/blueprint-deploy.sh tests/bats/blueprint-deploy.bats
git commit -m "feat(profile): manifest get/set helpers for install profile"
```

---

### Task 2: Profile-aware inventories + boot-sync snippet

**Files:**
- Create: `configs/bash/boot-sync.sh`
- Modify: `lib/blueprint-deploy.sh` — `managed_inventory_overwrite` (~line 360) and `managed_inventory_merge` (~line 380)
- Test: `tests/bats/blueprint-deploy.bats`

**Interfaces:**
- Consumes: `manifest_get_profile` from Task 1.
- Produces: inventories whose output depends on profile. Host profile: excludes `~/.tmux.conf`, `~/.bashrc.d/aicoding-ssh-auth-sock.sh`, `~/.codex/config.toml` (overwrite) and `~/.config/opencode/opencode.json`, `~/.cursor/mcp.json`, `~/.cursor/cli-config.json` (merge); adds `$HOME/.bashrc.d/aicoding-boot-sync.sh|overwrite|configs/bash/boot-sync.sh`. Container profile: byte-identical output to today.

- [ ] **Step 1: Write the failing tests**

Append to `tests/bats/blueprint-deploy.bats`:

```bash
@test "inventories: container profile output is unchanged (no boot-sync, has tmux/codex/cursor)" {
  run managed_inventory_overwrite
  [[ "$output" == *"/.tmux.conf|"* ]]
  [[ "$output" == *"aicoding-ssh-auth-sock.sh|"* ]]
  [[ "$output" == *"/.codex/config.toml|"* ]]
  [[ "$output" != *"aicoding-boot-sync.sh"* ]]
  run managed_inventory_merge
  [[ "$output" == *"opencode.json|"* ]]
  [[ "$output" == *"/.cursor/mcp.json|"* ]]
}

@test "inventories: host profile drops container-only files, adds boot-sync" {
  export AICODING_PROFILE=host
  run managed_inventory_overwrite
  [[ "$output" != *"/.tmux.conf|"* ]]
  [[ "$output" != *"aicoding-ssh-auth-sock.sh|"* ]]
  [[ "$output" != *"/.codex/config.toml|"* ]]
  [[ "$output" == *"$HOME/.bashrc.d/aicoding-boot-sync.sh|overwrite|configs/bash/boot-sync.sh"* ]]
  [[ "$output" == *"/.claude/CLAUDE.md|"* ]]
  run managed_inventory_merge
  [[ "$output" == *"/.claude/settings.json|"* ]]
  [[ "$output" != *"opencode.json|"* ]]
  [[ "$output" != *"cursor"* ]]
  unset AICODING_PROFILE
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `tests/bats/run.sh blueprint-deploy`
Expected: the two new tests FAIL (host test: boot-sync line missing; container test may pass already — that's fine, it's the regression pin).

- [ ] **Step 3: Implement**

Replace `managed_inventory_overwrite` and `managed_inventory_merge` in `lib/blueprint-deploy.sh`:

```bash
# managed_inventory_overwrite — whole-file managed deployments. Emits
# "dest|overwrite|blueprint-relative-source" lines. Profile-aware: hosts
# (manifest_get_profile = host) skip container-only tooling configs and
# gain the boot-sync trigger; containers are byte-identical to before.
managed_inventory_overwrite() {
  local profile
  profile=$(manifest_get_profile)
  cat <<EOF
$HOME/.claude/hooks/custom-statusline.js|overwrite|configs/claude/hooks/custom-statusline.js
$HOME/.claude/hooks/bw-deny-files.sh|overwrite|configs/claude/hooks/bw-deny-files.sh
$HOME/.claude/hooks/check-archived-docs.sh|overwrite|configs/claude/hooks/check-archived-docs.sh
$HOME/.claude/hooks/llmwiki-distill.sh|overwrite|configs/claude/hooks/llmwiki-distill.sh
$HOME/.claude/hooks/agent-waiting.sh|overwrite|configs/claude/hooks/agent-waiting.sh
$HOME/.claude/agents/llmwiki-distiller.md|overwrite|configs/claude/agents/llmwiki-distiller.md
$HOME/.claude/CLAUDE.md|overwrite|configs/claude/CLAUDE.md
$HOME/.bashrc.d/aicoding-env.sh|overwrite|configs/bash/env.sh
$HOME/.bashrc.d/aicoding-update-notify.sh|overwrite|configs/bash/update-notify.sh
$HOME/.bashrc.d/aicoding-aliases.sh|overwrite|configs/bash/aliases.sh
$HOME/.local/bin/git-credential-aicoding|overwrite|configs/git/git-credential-aicoding
EOF
  if [[ "$profile" == host ]]; then
    echo "$HOME/.bashrc.d/aicoding-boot-sync.sh|overwrite|configs/bash/boot-sync.sh"
  else
    cat <<EOF
$HOME/.tmux.conf|overwrite|configs/tmux/tmux.conf
$HOME/.bashrc.d/aicoding-ssh-auth-sock.sh|overwrite|configs/bash/ssh-auth-sock.sh
$HOME/.codex/config.toml|overwrite|configs/codex/config.toml
EOF
  fi
}

# managed_inventory_merge — JSON configs deep-merged into user files.
# Hosts manage only Claude's settings; opencode/cursor are container-only.
managed_inventory_merge() {
  local profile
  profile=$(manifest_get_profile)
  echo "$HOME/.claude/settings.json|merge|configs/claude/settings.json"
  if [[ "$profile" != host ]]; then
    cat <<EOF
$HOME/.config/opencode/opencode.json|merge|configs/opencode/opencode.json
$HOME/.cursor/mcp.json|merge|configs/cursor/mcp.json
$HOME/.cursor/cli-config.json|merge|configs/cursor/cli-config.json
EOF
  fi
}
```

(The container branch preserves every original line — only their grouping moved. `report_unmanaged` and `classify_managed_files` consume these functions and need no change.)

Create `configs/bash/boot-sync.sh`:

```bash
# aicoding boot sync — deployed on host-profile machines only. Containers
# get day-2 sync from on-start.sh on attach; this gives bare hosts the same
# freshness on terminal open. Own 6h throttle (aicoding-sync --boot throttles
# binaries/provision but fetches the blueprint every run — too much for every
# shell), stamped BEFORE the run so parallel shells don't pile up, and
# backgrounded so shell startup never blocks on the network.
_aicoding_boot_sync() {
  command -v aicoding-sync >/dev/null 2>&1 || return 0
  [ "${AICODINGSETUP_SKIP_NETWORK:-}" = 1 ] && return 0
  local stamp="$HOME/.local/state/aicoding/updates/.boot-sync.stamp"
  [ -n "$(find "$stamp" -newermt "-21600 seconds" 2>/dev/null)" ] && return 0
  mkdir -p "${stamp%/*}" "$HOME/.cache/aicoding" 2>/dev/null || return 0
  : > "$stamp"
  (aicoding-sync --boot >> "$HOME/.cache/aicoding/boot-sync.log" 2>&1 &)
}
_aicoding_boot_sync
unset -f _aicoding_boot_sync
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `tests/bats/run.sh blueprint-deploy`
Expected: PASS, all pre-existing tests included.

- [ ] **Step 5: Regression-run the deploy-adjacent suites**

Run: `tests/bats/run.sh install sync regressions`
Expected: PASS — proves container-profile output is unchanged where it matters.

- [ ] **Step 6: Commit**

```bash
git add lib/blueprint-deploy.sh configs/bash/boot-sync.sh tests/bats/blueprint-deploy.bats
git commit -m "feat(profile): profile-aware managed-file inventories + host boot-sync snippet"
```

---

### Task 3: Host prereq check and homelab-wiki clone

**Files:**
- Modify: `lib/provision-system.sh` (after `check_prerequisites`, end of file)
- Modify: `lib/provision-integrations.sh` (end of file)
- Test: `tests/bats/install-host.bats` (create — this file grows in Task 4 too)

**Interfaces:**
- Consumes: `err`/`info`/`ok`/`warn`/`header` loggers (defined by the sourcing installer; `lib/provision.sh` provides fallbacks), `apt_install` NOT used.
- Produces: `check_prerequisites_host` (exits 1 with an `sudo apt install …` hint listing every missing tool; never installs) and `ensure_homelab_wiki` (clones `https://github.com/vossiman/homelab-wiki` to `$HOME/homelab-wiki` if absent; fail-open warn; no-op under `AICODINGSETUP_SKIP_NETWORK=1`). Task 4's step list calls both.

- [ ] **Step 1: Write the failing tests**

Create `tests/bats/install-host.bats` (mirror `install.bats`'s setup: fresh `$HOME`, stubs dir on PATH — copy its `setup()` shape, minus the stubs the host flow doesn't touch):

```bash
#!/usr/bin/env bats

setup() {
  : "${BLUEPRINT_ROOT:?unset — run via tests/bats/run.sh; refusing to default to / and copy the whole filesystem}"
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  export AICODING_MANIFEST="$TMPDIR/.local/state/aicoding/manifest.json"
  export AICODINGSETUP_NONINTERACTIVE=1
  export PATH="$TMPDIR/stubs:$PATH"
  mkdir -p "$TMPDIR/stubs" "$TMPDIR/.local/bin"
  # Prereq stubs present by default; individual tests remove them.
  for t in git curl jq node npm claude; do
    printf '#!/bin/bash\nexit 0\n' > "$TMPDIR/stubs/$t"; chmod +x "$TMPDIR/stubs/$t"
  done
}

teardown() { rm -rf "$TMPDIR"; }

_source_host_lib() {
  # Source under the same guard install-host.sh uses; loggers come along.
  ( cd "$BLUEPRINT_ROOT" && source ./install-host.sh >/dev/null 2>&1; "$@" )
}

@test "check_prerequisites_host: all present -> success" {
  run _source_host_lib check_prerequisites_host
  [ "$status" -eq 0 ]
}

@test "check_prerequisites_host: missing tools abort with one apt hint line" {
  rm "$TMPDIR/stubs/jq" "$TMPDIR/stubs/npm"
  run _source_host_lib check_prerequisites_host
  [ "$status" -eq 1 ]
  [[ "$output" == *"sudo apt install"*"jq"* ]]
  [[ "$output" == *"npm"* ]]
}

@test "ensure_homelab_wiki: no-op when clone exists, no git call" {
  mkdir -p "$HOME/homelab-wiki/.git"
  printf '#!/bin/bash\necho GIT-CALLED; exit 1\n' > "$TMPDIR/stubs/git"; chmod +x "$TMPDIR/stubs/git"
  run _source_host_lib ensure_homelab_wiki
  [ "$status" -eq 0 ]
  [[ "$output" != *"GIT-CALLED"* ]]
}

@test "ensure_homelab_wiki: skipped under AICODINGSETUP_SKIP_NETWORK" {
  export AICODINGSETUP_SKIP_NETWORK=1
  printf '#!/bin/bash\necho GIT-CALLED; exit 1\n' > "$TMPDIR/stubs/git"; chmod +x "$TMPDIR/stubs/git"
  run _source_host_lib ensure_homelab_wiki
  [ "$status" -eq 0 ]
  [[ "$output" != *"GIT-CALLED"* ]]
}

@test "ensure_homelab_wiki: failed clone warns but exits 0" {
  printf '#!/bin/bash\nexit 128\n' > "$TMPDIR/stubs/git"; chmod +x "$TMPDIR/stubs/git"
  run _source_host_lib ensure_homelab_wiki
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN"* ]]
}
```

Note: `_source_host_lib` sources `install-host.sh`, which doesn't exist until Task 4. For THIS task, make the helper source the two lib files directly instead — then Task 4 switches it to `install-host.sh`:

```bash
_source_host_lib() {
  ( cd "$BLUEPRINT_ROOT" \
    && source lib/provision.sh >/dev/null 2>&1 \
    && source lib/provision-system.sh >/dev/null 2>&1 \
    && source lib/provision-integrations.sh >/dev/null 2>&1; "$@" )
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `tests/bats/run.sh install-host`
Expected: FAIL — `check_prerequisites_host: command not found` etc.

- [ ] **Step 3: Implement**

Append to `lib/provision-system.sh`:

```bash
# check_prerequisites_host — host-profile prereq gate. Unlike container
# check_prerequisites it NEVER auto-installs and never touches apt/sudo:
# it verifies and, on any miss, prints the exact apt line for the user.
# node/npm are needed for the npm packages backing stdio MCPs.
check_prerequisites_host() {
  local missing=()
  command -v git  &>/dev/null || missing+=("git")
  command -v curl &>/dev/null || missing+=("curl")
  command -v jq   &>/dev/null || missing+=("jq")
  command -v node &>/dev/null || missing+=("nodejs")
  command -v npm  &>/dev/null || missing+=("npm")
  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing required tools: ${missing[*]}"
    err "Install them, then re-run:  sudo apt install ${missing[*]}"
    exit 1
  fi
}
```

Append to `lib/provision-integrations.sh`:

```bash
# ensure_homelab_wiki — host-profile step: agents expect ~/homelab-wiki
# (global CLAUDE.md tells them to consult it). Clone if missing; fail-open
# (agents clone on demand per their own instructions).
ensure_homelab_wiki() {
  header "homelab-wiki"
  if [[ -d "$HOME/homelab-wiki/.git" ]]; then
    ok "~/homelab-wiki already present"
    return 0
  fi
  if [[ "${AICODINGSETUP_SKIP_NETWORK:-}" == "1" ]]; then
    info "Skipping homelab-wiki clone (network provisioning disabled)"
    return 0
  fi
  if git clone https://github.com/vossiman/homelab-wiki "$HOME/homelab-wiki" 2>&1 | tail -1; then
    ok "cloned ~/homelab-wiki"
  else
    warn "homelab-wiki clone failed — agents will clone on demand"
  fi
  return 0
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `tests/bats/run.sh install-host`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/provision-system.sh lib/provision-integrations.sh tests/bats/install-host.bats
git commit -m "feat(host): host prereq gate (no sudo) + homelab-wiki clone step"
```

---

### Task 4: `install-host.sh` entry point

**Files:**
- Create: `install-host.sh` (repo root, executable)
- Modify: `tests/bats/install-host.bats` (switch `_source_host_lib` to source `install-host.sh`; add main-flow tests)

**Interfaces:**
- Consumes: everything from Tasks 1–3 plus shared steps (exact names): `seed_github_known_host`, `load_or_prompt_secrets`, `ensure_claude_code`, `report_unmanaged`, `install_mcp_packages`, `install_claude_mcps`, `ensure_claude_onboarding_state`, `install_claude_plugins`, `install_aicoding_sync_symlink`, `install_aicoding_install_symlink`, `install_update_status_symlink`, `remove_deprecated_shims`, `detect_install_mode`, `deploy_all_managed_files`, `adopt_existing_files`, `reconcile_existing_install`, `manifest_stamp_provision`, `_print_install_summary`.
- Produces: `bash install-host.sh [--force-reinstall]`; sourcing it defines all functions without running (same `BASH_SOURCE` guard as `install.sh`). Task 6's dispatcher exec's it by path.

**Ordering constraint (important):** `export AICODING_PROFILE=host` happens at the top of the script so inventories are host-shaped from the first call — but `manifest_set_profile host` must run only AFTER the `detect_install_mode` case block. Writing the manifest earlier would flip a fresh machine from `first`-mode to `reconcile`-mode (`detect_install_mode` keys off manifest existence).

- [ ] **Step 1: Extend the tests (failing)**

In `tests/bats/install-host.bats`, replace `_source_host_lib` with:

```bash
_source_host_lib() {
  ( cd "$BLUEPRINT_ROOT" && source ./install-host.sh >/dev/null 2>&1; "$@" )
}
```

Append:

```bash
@test "install-host.sh: sourcing defines functions without executing main" {
  run _source_host_lib true
  [ "$status" -eq 0 ]
  [ ! -f "$AICODING_MANIFEST" ]
}

@test "install-host.sh: main writes profile=host and provision stamp to manifest" {
  export AICODINGSETUP_SKIP_NETWORK=1
  run bash -c "cd '$BLUEPRINT_ROOT' && bash install-host.sh"
  [ "$status" -eq 0 ]
  run jq -r '.profile' "$AICODING_MANIFEST"
  [ "$output" = "host" ]
}

@test "install-host.sh: deploys host-shaped managed set (boot-sync yes, tmux/codex no)" {
  export AICODINGSETUP_SKIP_NETWORK=1
  bash -c "cd '$BLUEPRINT_ROOT' && bash install-host.sh"
  [ -f "$HOME/.bashrc.d/aicoding-boot-sync.sh" ]
  [ -f "$HOME/.claude/CLAUDE.md" ]
  [ ! -f "$HOME/.tmux.conf" ]
  [ ! -f "$HOME/.codex/config.toml" ]
  grep -q 'aicoding managed block' "$HOME/.bashrc"
}

@test "install-host.sh: second run is reconcile mode, still exits 0" {
  export AICODINGSETUP_SKIP_NETWORK=1
  bash -c "cd '$BLUEPRINT_ROOT' && bash install-host.sh"
  run bash -c "cd '$BLUEPRINT_ROOT' && bash install-host.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"reconcile"* ]]
}
```

Check `install.bats`'s setup for env vars the deploy engine needs in tests (e.g. secrets-related vars) and mirror any that the main-flow tests fail without.

- [ ] **Step 2: Run tests to verify they fail**

Run: `tests/bats/run.sh install-host`
Expected: new tests FAIL (`install-host.sh: No such file`); Task 3's tests now also fail until the script exists (they source it) — that's the point of switching the helper.

- [ ] **Step 3: Write `install-host.sh`**

Model it on `install.sh` lines 1–84 (shebang, `set -uo pipefail`, `SCRIPT_DIR`, colored loggers, `header()`) — copy that prelude verbatim, then:

```bash
# Host profile: inventories and day-2 sync branch on this. Exported before
# any lib call so the very first classify/deploy pass is host-shaped.
export AICODING_PROFILE=host

. "$SCRIPT_DIR/lib/provision.sh"
. "$SCRIPT_DIR/lib/provision-system.sh"

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then check_prerequisites_host; fi

. "$SCRIPT_DIR/lib/provision-secrets.sh"
. "$SCRIPT_DIR/lib/provision-managed-files.sh"
. "$SCRIPT_DIR/lib/provision-integrations.sh"

main() {
  local force_reinstall=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force-reinstall) force_reinstall=1; shift ;;
      *) shift ;;
    esac
  done

  header "AI Coding Base Setup — host profile (core only)"

  seed_github_known_host

  if [[ $force_reinstall -eq 1 ]]; then
    info "--force-reinstall: deleting existing manifest"
    rm -f "$AICODING_MANIFEST"
  fi

  load_or_prompt_secrets
  ensure_claude_code
  report_unmanaged
  install_mcp_packages
  install_claude_mcps
  ensure_claude_onboarding_state
  install_claude_plugins
  install_aicoding_sync_symlink
  install_aicoding_install_symlink
  install_update_status_symlink
  remove_deprecated_shims

  local mode
  if [[ $force_reinstall -eq 1 ]]; then
    mode=first
  else
    mode=$(detect_install_mode)
  fi

  case "$mode" in
    first)
      info "Mode: first-deploy (no manifest, no managed files on disk)"
      deploy_all_managed_files
      ;;
    adopt)
      info "Mode: adopt-existing (no manifest, managed files present)"
      adopt_existing_files
      ;;
    reconcile)
      info "Mode: reconcile (manifest exists — restoring missing files, applying safe blueprint updates)"
      reconcile_existing_install
      ;;
  esac

  ensure_homelab_wiki

  # AFTER the mode case: writing the manifest earlier would make
  # detect_install_mode see "reconcile" on a fresh machine.
  manifest_set_profile host
  manifest_stamp_provision "$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || true)"

  header "Done!"
  info "Mode: $mode  (profile: host)"
  info "Secrets: $SECRETS_FILE"
  info "Claude Code: $CLAUDE_DIR"

  _print_install_summary
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
```

`chmod +x install-host.sh`. Check `install.sh`'s prelude for where `SECRETS_FILE`/`CLAUDE_DIR` come from (`lib/` or prelude) and keep whatever the prelude defines. Deliberately absent vs `install.sh`: `check_prerequisites` (host variant instead), `install_agent_notify_symlink`, `install_ssh_agent_watch_symlink`, `install_templates`, `install_tmux_plugins`, `install_bubblewrap`, `install_infra_audit`, `check_playwright`, `ensure_lfs_autopull_safe`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `tests/bats/run.sh install-host`
Expected: PASS (Task 3's tests too, now through the real entry point).

- [ ] **Step 5: Regression-run the container installer suite**

Run: `tests/bats/run.sh install e2e`
Expected: PASS — container flow untouched.

- [ ] **Step 6: Commit**

```bash
git add install-host.sh tests/bats/install-host.bats
git commit -m "feat(host): install-host.sh — core-only thin-client installer"
```

---

### Task 5: Profile-aware binary refresh in sync

**Files:**
- Modify: `lib/sync.sh` — `_sync_binaries` (~line 476)
- Test: `tests/bats/sync.bats`

**Interfaces:**
- Consumes: `manifest_get_profile` (defined once `_sync_reconcile` has sourced `lib/blueprint-deploy.sh` from the refreshed clone; older clones may lack it — guard with `command -v`).
- Produces: host profile refreshes claude only; container profile identical to today. (`_sync_devcontainer_pin` intentionally unchanged: its `[ -f target ]` guard already no-ops outside workspaces, and a devMachine checkout on a host SHOULD get pin syncs.)

- [ ] **Step 1: Write the failing tests**

Look at existing `_sync_binaries` tests in `tests/bats/sync.bats` (search for `sync_binaries` / `claude update`) and follow their stub pattern. Add:

```bash
@test "_sync_binaries: host profile refreshes claude only" {
  for t in claude opencode agent codex; do
    printf '#!/bin/bash\necho "%s-CALLED $*"\n' "$t" > "$TMPDIR/stubs/$t"; chmod +x "$TMPDIR/stubs/$t"
  done
  mkdir -p "$(dirname "$AICODING_MANIFEST")"
  echo '{"profile":"host"}' > "$AICODING_MANIFEST"
  run bash -c "source '$BLUEPRINT_ROOT/lib/sync.sh'; source '$BLUEPRINT_ROOT/lib/blueprint-deploy.sh'; _sync_binaries"
  [[ "$output" == *"claude-CALLED update"* ]]
  [[ "$output" != *"opencode-CALLED"* ]]
  [[ "$output" != *"agent-CALLED"* ]]
}

@test "_sync_binaries: container/absent profile refreshes all CLIs" {
  for t in claude opencode agent; do
    printf '#!/bin/bash\necho "%s-CALLED $*"\n' "$t" > "$TMPDIR/stubs/$t"; chmod +x "$TMPDIR/stubs/$t"
  done
  run bash -c "source '$BLUEPRINT_ROOT/lib/sync.sh'; source '$BLUEPRINT_ROOT/lib/blueprint-deploy.sh'; _sync_binaries"
  [[ "$output" == *"claude-CALLED update"* ]]
  [[ "$output" == *"opencode-CALLED upgrade"* ]]
  [[ "$output" == *"agent-CALLED update"* ]]
}
```

Adapt `$TMPDIR/stubs` / `$AICODING_MANIFEST` names to `sync.bats`'s actual setup() conventions — read its setup() first and reuse its variables.

- [ ] **Step 2: Run tests to verify they fail**

Run: `tests/bats/run.sh sync`
Expected: host test FAILS (opencode/agent called); container test passes (regression pin).

- [ ] **Step 3: Implement**

In `_sync_binaries`, before the updater calls:

```bash
_sync_binaries() {            # throttled network refresh
  # Host profile (bare-metal thin clients): claude is the only CLI the
  # core profile installs, so it's the only one to refresh. Guarded: an
  # old blueprint clone may predate manifest_get_profile.
  local profile=container
  command -v manifest_get_profile >/dev/null 2>&1 && profile=$(manifest_get_profile)
```

Then wrap the opencode / cursor / codex sections (keep the claude line unguarded):

```bash
  command -v claude   >/dev/null 2>&1 && { echo "--- claude update ---";    claude update    || true; }
  if [ "$profile" != host ]; then
    command -v opencode >/dev/null 2>&1 && { echo "--- opencode upgrade ---"; opencode upgrade || true; }
    if command -v agent >/dev/null 2>&1; then
      echo "--- cursor (agent update) ---"; agent update || true
    elif command -v cursor-agent >/dev/null 2>&1; then
      echo "--- cursor (cursor-agent update) ---"; cursor-agent update || true
    fi
    _update_codex || true
  fi
```

(Preserve the existing header comment about attributable error text.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `tests/bats/run.sh sync`
Expected: PASS, all pre-existing sync tests included.

- [ ] **Step 5: Commit**

```bash
git add lib/sync.sh tests/bats/sync.bats
git commit -m "feat(host): sync refreshes only claude on host profile"
```

---

### Task 6: `aicoding-install` dispatches on profile + README

**Files:**
- Modify: `bin/aicoding-install` (the two `exec bash … install.sh` lines at the end)
- Modify: `README.md` — Update section (decision table around line 120) + a short "Bare-host install" subsection
- Test: `tests/bats/install.bats` (or wherever `aicoding-install` is covered — `grep -l aicoding-install tests/bats/*.bats` and extend that file; if nowhere, add to `tests/bats/install-host.bats`)

**Interfaces:**
- Consumes: manifest `.profile` (read with jq directly — `bin/` scripts don't source `blueprint-deploy.sh`; default path `$HOME/.local/state/aicoding/manifest.json`, overridable via `AICODING_MANIFEST`).
- Produces: on host machines `aicoding-install` re-runs `install-host.sh`; containers keep `install.sh`. Muscle memory identical everywhere.

- [ ] **Step 1: Write the failing test**

In the test file found above (its conventions for invoking `bin/aicoding-install` with stubs; if none exist, use this in `install-host.bats`):

```bash
@test "aicoding-install: dispatches to install-host.sh when profile=host" {
  mkdir -p "$HOME/.local/state/aicoding"
  echo '{"profile":"host"}' > "$HOME/.local/state/aicoding/manifest.json"
  # Fake blueprint clone with sentinel installers; no network.
  CLONE="$TMPDIR/clone"; mkdir -p "$CLONE/lib"
  printf '#!/bin/bash\necho HOST-INSTALLER-RAN\n' > "$CLONE/install-host.sh"
  printf '#!/bin/bash\necho CONTAINER-INSTALLER-RAN\n' > "$CLONE/install.sh"
  run env AICODING_BLUEPRINT_CLONE="$CLONE" bash "$BLUEPRINT_ROOT/bin/aicoding-install"
  [[ "$output" == *"HOST-INSTALLER-RAN"* ]]
  [[ "$output" != *"CONTAINER-INSTALLER-RAN"* ]]
}
```

(No `lib/sync.sh` in the fake clone → `refresh_blueprint` resolution falls back to `$SCRIPT_DIR/lib/sync.sh`; if that makes the test hit the network, stub `git` on PATH to exit 0 — check how existing aicoding-install/sync tests neutralize `refresh_blueprint` and copy that.)

- [ ] **Step 2: Run test to verify it fails**

Run: `tests/bats/run.sh install-host` (or the file extended)
Expected: FAIL — container installer runs.

- [ ] **Step 3: Implement dispatch**

In `bin/aicoding-install`, replace the final exec block:

```bash
# Host-profile machines re-run the host installer; everything else keeps
# the container installer. Read the profile straight from the manifest —
# bin scripts don't source blueprint-deploy.sh.
manifest="${AICODING_MANIFEST:-$HOME/.local/state/aicoding/manifest.json}"
profile=container
if command -v jq >/dev/null 2>&1 && [ -f "$manifest" ]; then
  profile=$(jq -r '.profile // "container"' "$manifest" 2>/dev/null || echo container)
fi
installer=install.sh
[ "$profile" = host ] && installer=install-host.sh

if [ -f "$AICODING_BLUEPRINT_CLONE/$installer" ]; then
  exec bash "$AICODING_BLUEPRINT_CLONE/$installer" "${AICODING_REMAINING_ARGS[@]}"
fi
exec bash "$SCRIPT_DIR/$installer" "${AICODING_REMAINING_ARGS[@]}"
```

Also update the `--help` text to mention the profile dispatch.

- [ ] **Step 4: Run test to verify it passes**

Run: `tests/bats/run.sh install-host install`
Expected: PASS.

- [ ] **Step 5: README**

In the decision table area (README ~line 120), add a row/note: bare hosts bootstrap with `./install-host.sh` (core only: claude CLI + managed Claude layer + MCPs/plugins + wiki + terminal-open auto-sync; no codex/opencode/cursor/Playwright/Go/tmux), day-2 commands identical (`aicoding-sync`, `aicoding-install` — both are profile-aware via the manifest). Keep it to ~10 lines in the README's existing voice, with the fresh-box quickstart:

```bash
gh auth login          # or place GH_TOKEN in ~/.aicodingsetup/.secrets.env
git clone https://github.com/vossiman/aiCodingBaseSetup && cd aiCodingBaseSetup
./install-host.sh
```

- [ ] **Step 6: Full suite + commit**

Run: `tests/bats/run.sh`
Expected: PASS (269 pre-existing + new).

```bash
git add bin/aicoding-install README.md tests/bats/
git commit -m "feat(host): aicoding-install dispatches on manifest profile; document host mode"
```

---

### Task 7: Finish the branch

- [ ] **Step 1: Full suite once more**

Run: `tests/bats/run.sh`
Expected: PASS, zero failures.

- [ ] **Step 2: Push and open PR**

```bash
git push -u origin feat/host-install
gh pr create --repo vossiman/aiCodingBaseSetup --head feat/host-install \
  --title "feat: bare-host install mode (install-host.sh, profile-aware sync)" \
  --body "Implements docs/superpowers/specs/2026-08-12-host-install-design.md — core-only installer for bare Linux hosts (Mint desktop, Surface WSL): claude CLI + managed Claude layer + MCPs/plugins + homelab-wiki + terminal-open auto-sync. Manifest profile key (absent = container) keeps every existing machine byte-identical. Full bats suite green.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

Ask the user before merging (repo rule).
