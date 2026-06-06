# aicoding sync/status (Phase 1) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse the in-container install/update surface into one routine
`aicoding-sync` (auth plumbing + config reconcile + binary refresh) plus a
read-only `aicoding-status`, with create/boot/manual as flags — and self-heal
blueprint-owned config that goes stale after a home reset.

**Architecture:** Extract the shared logic into `lib/sync.sh`, sourced by a thin
`bin/aicoding-sync` CLI. `install.sh` and the renamed boot hook `on-start.sh` call
it with `--first` / `--boot`. `update-status` becomes `aicoding-status` (dvw entry
dropped). Old names kept as shims. The deploy engine `lib/blueprint-deploy.sh`
gains a force-restore path for owned overwrite files.

**Tech Stack:** Bash, `jq`, `git`, bats. Single repo: aiCodingBaseSetup.

Spec: `docs/superpowers/specs/2026-06-06-aicoding-sync-status-unification-design.md`.

---

## File structure

- Create `lib/sync.sh` — the `aicoding_sync` routine: plumbing → config reconcile → binaries; modes `--first|--boot|` (interactive default).
- Create `bin/aicoding-sync` — thin CLI: arg parse, source lib, call `aicoding_sync`.
- Rename `bin/update-status` → `bin/aicoding-status`; drop dvw registry entry.
- Rename `update.sh` → `on-start.sh` — boot bootstrap prologue, then `aicoding-sync --boot`.
- Shims: `bin/aicoding-update`, `bin/update-status`, `update.sh` → exec new targets.
- Modify `lib/blueprint-deploy.sh` — force-restore owned overwrite files in reconcile.
- Modify `install.sh` — route provisioning through `aicoding_sync --first`; symlink new CLIs.
- Modify `configs/bash/update-notify.sh` — call `aicoding-status`.
- Modify `devcontainer.json` — `postStartCommand` → `on-start.sh`.
- Tests in `tests/bats/`.

---

### Task 1: Force-restore owned overwrite files (self-heal core)

**Files:**
- Modify: `lib/blueprint-deploy.sh`
- Test: `tests/bats/install.bats`

- [ ] **Step 1: Write the failing test** — a stale blueprint-owned snippet is restored by reconcile (with `.bak`), while an edited user file is preserved.

```bash
# tests/bats/install.bats
@test "reconcile force-restores a drifted owned bashrc.d snippet (with backup)" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  # Simulate a home-reset stale snippet: overwrite the deployed owned file with old content.
  echo "# STALE old version" > "$HOME/.bashrc.d/aicoding-env.sh"
  # Change the blueprint too so the bucket is drifted_and_updating, not drifted_but_aligned.
  printf '\n# blueprint moved\n' >> "$BLUEPRINT_ROOT/configs/bash/env.sh"

  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]
  # Owned file restored to blueprint (no longer the stale marker).
  ! grep -q "STALE old version" "$HOME/.bashrc.d/aicoding-env.sh"
  grep -q "blueprint moved" "$HOME/.bashrc.d/aicoding-env.sh"
  # A backup of the stale version was kept.
  ls "$HOME"/.bashrc.d/aicoding-env.sh.bak.* >/dev/null 2>&1
  # Cleanup blueprint edit.
  git -C "$BLUEPRINT_ROOT" checkout -- configs/bash/env.sh
}

@test "reconcile still preserves an edited non-owned overwrite file" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  echo "# user tweak" >> "$HOME/.tmux.conf"
  local edited; edited=$(sha256sum "$HOME/.tmux.conf" | awk '{print $1}')
  printf '\n# blueprint moved\n' >> "$BLUEPRINT_ROOT/configs/tmux/tmux.conf"
  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]
  [ "$(sha256sum "$HOME/.tmux.conf" | awk '{print $1}')" = "$edited" ]
  git -C "$BLUEPRINT_ROOT" checkout -- configs/tmux/tmux.conf
}
```

- [ ] **Step 2: Run, verify RED**

Run: `BLUEPRINT_ROOT="$PWD" bats -f 'force-restores' tests/bats/install.bats`
Expected: FAIL — reconcile skips `drifted_and_updating`, stale file remains.

- [ ] **Step 3: Add an owned-file predicate + reconcile upgrade**

In `lib/blueprint-deploy.sh`, add near the classify helpers:

```bash
# Owned overwrite files: blueprint-managed plumbing the user is never meant to
# hand-edit (escape hatch is ~/.bashrc.d/local-*.sh). After a home reset these
# revert to stale base-image versions and classify as drifted_and_updating;
# reconcile must force-restore them (with backup) rather than skip.
_is_owned_overwrite() {
  case "$1" in
    "$HOME"/.bashrc.d/aicoding-*.sh) return 0 ;;
    "$HOME"/.claude/hooks/*)         return 0 ;;
    *) return 1 ;;
  esac
}
```

In `reconcile_existing_install` (install.sh) the apply set excludes
`drifted_and_updating`. Instead of widening it globally, re-bucket owned files
*before* apply. Add this in `classify_managed_files` (or right after it is called
in reconcile), after BUCKETS is populated:

```bash
  # Owned overwrite files self-heal even in the conservative reconcile path.
  local _d
  for _d in "${!BUCKETS[@]}"; do
    if [[ "${BUCKETS[$_d]}" == drifted_and_updating ]] && _is_owned_overwrite "$_d"; then
      BUCKETS[$_d]=will_update_owned
    fi
  done
```

Add a `will_update_owned` case to `apply_managed_buckets` (back up, then deploy —
same as drifted_and_updating):

```bash
      will_update_owned)
        [[ -e "$dest" ]] && _backup_file "$dest"
        _apply_deploy "$mode" "$dest" "$src"
        ;;
```

And add `will_update_owned` to reconcile's apply list in `install.sh`:

```bash
  apply_managed_buckets "restore new_file will_update will_update_owned drifted_but_aligned merge"
```

- [ ] **Step 4: Run, verify GREEN**

Run: `BLUEPRINT_ROOT="$PWD" bats -f 'force-restores|preserves an edited' tests/bats/install.bats`
Expected: both PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/blueprint-deploy.sh install.sh tests/bats/install.bats
git commit -m "feat(deploy): self-heal owned overwrite files in reconcile (drifted->restore+backup)"
```

---

### Task 2: `lib/sync.sh` — the unified sync routine

**Files:**
- Create: `lib/sync.sh`
- Test: `tests/bats/sync.bats`

- [ ] **Step 1: Write the failing test** — `aicoding_sync` runs the three steps; `--boot` is non-interactive and honours the throttle; failures are non-fatal.

```bash
# tests/bats/sync.bats
#!/usr/bin/env bats
setup() {
  : "${BLUEPRINT_ROOT:?run via run.sh}"
  TMP=$(mktemp -d); export HOME="$TMP"
  export AICODING_BLUEPRINT_CLONE="$BLUEPRINT_ROOT"
  export AICODING_MANIFEST="$TMP/.aicodingsetup/manifest.json"
  export AICODING_UPDATE_STATE="$TMP/state/updates"
  export AICODINGSETUP_NONINTERACTIVE=1
  mkdir -p "$TMP/stubs"
  # Record which "binary update" commands ran.
  for c in claude opencode agent; do
    printf '#!/bin/sh\necho "%s $*" >> "$TMP/ran.log"\n' "$c" > "$TMP/stubs/$c"
    chmod +x "$TMP/stubs/$c"
  done
  export PATH="$TMP/stubs:$PATH"
  . "$BLUEPRINT_ROOT/lib/sync.sh"
}
teardown() { rm -rf "$TMP"; }

@test "sync --boot is non-interactive and refreshes binaries" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null   # provision a manifest first
  AICODING_UPDATE_TTL=0 aicoding_sync --boot
  grep -q "claude" "$TMP/ran.log"
  grep -q "opencode" "$TMP/ran.log"
}

@test "sync exits 0 even if a binary update fails (fail-open)" {
  printf '#!/bin/sh\nexit 7\n' > "$TMP/stubs/claude"; chmod +x "$TMP/stubs/claude"
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  run env AICODING_UPDATE_TTL=0 bash -c '. "$BLUEPRINT_ROOT/lib/sync.sh"; aicoding_sync --boot'
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run, verify RED**

Run: `BLUEPRINT_ROOT="$PWD" bats tests/bats/sync.bats`
Expected: FAIL — `lib/sync.sh` / `aicoding_sync` missing.

- [ ] **Step 3: Write `lib/sync.sh`**

```bash
# lib/sync.sh — the one routine that brings THIS container current.
# Steps: (1) auth plumbing [always], (2) blueprint config reconcile,
# (3) binary refresh [throttled]. Modes: --first (provision), --boot
# (non-interactive, throttled), default (interactive). Fail-open throughout.

: "${AICODING_BLUEPRINT_CLONE:=/tmp/aicoding}"
: "${AICODING_UPDATE_TTL:=21600}"

_sync_plumbing() {            # never throttled — must be correct now
  command -v aicoding-ssh-agent-watch >/dev/null 2>&1 && aicoding-ssh-agent-watch --ensure 2>/dev/null || true
  command -v seed_github_known_host >/dev/null 2>&1 && seed_github_known_host || true
}

_sync_config() {              # config reconcile via the deploy engine
  . "$AICODING_BLUEPRINT_CLONE/lib/blueprint-deploy.sh"
  command -v load_secrets_env >/dev/null 2>&1 && load_secrets_env || true
  [ -f "$AICODING_MANIFEST" ] || return 0
  declare -gA BUCKETS FILE_MODE FILE_SOURCE
  export AICODING_BLUEPRINT_CLONE
  classify_managed_files
  local d
  for d in "${!BUCKETS[@]}"; do
    if [[ "${BUCKETS[$d]}" == drifted_and_updating ]] && _is_owned_overwrite "$d"; then
      BUCKETS[$d]=will_update_owned
    fi
  done
  manifest_stage_begin
  apply_managed_buckets "restore new_file will_update will_update_owned drifted_but_aligned merge"
  manifest_stage_set_top blueprint_commit "$(git -C "$AICODING_BLUEPRINT_CLONE" rev-parse HEAD 2>/dev/null || echo unknown)"
  manifest_stage_commit
}

_sync_binaries() {            # throttled network refresh
  command -v claude   >/dev/null 2>&1 && { claude update    || true; }
  command -v opencode >/dev/null 2>&1 && { opencode upgrade || true; }
  if command -v agent >/dev/null 2>&1; then agent update || true
  elif command -v cursor-agent >/dev/null 2>&1; then cursor-agent update || true; fi
}

# Returns 0 if the binary-refresh throttle window is still fresh.
_sync_binaries_fresh() {
  local stamp="${AICODING_UPDATE_STATE:-$HOME/.aicodingsetup/state/updates}/.binaries.stamp"
  [ -n "$(find "$stamp" -newermt "-${AICODING_UPDATE_TTL} seconds" 2>/dev/null)" ]
}
_sync_binaries_stamp() {
  local s="${AICODING_UPDATE_STATE:-$HOME/.aicodingsetup/state/updates}"
  mkdir -p "$s"; : > "$s/.binaries.stamp"
}

aicoding_sync() {
  local mode=interactive
  case "${1:-}" in --first) mode=first ;; --boot) mode=boot ;; "" ) ;; *) mode=interactive ;; esac
  _sync_plumbing
  _sync_config
  if [ "$mode" = boot ] && _sync_binaries_fresh; then :; else _sync_binaries; _sync_binaries_stamp; fi
  return 0
}
```

> Note: `seed_github_known_host` is currently defined inside `update.sh`. Task 4
> moves it into `lib/sync.sh` (or a sourced helper) so `_sync_plumbing` can call
> it. Until then the `command -v` guard makes it a safe no-op.

- [ ] **Step 4: Run, verify GREEN**

Run: `BLUEPRINT_ROOT="$PWD" bats tests/bats/sync.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/sync.sh tests/bats/sync.bats
git commit -m "feat(sync): unified aicoding_sync routine (plumbing + config + binaries, modes)"
```

---

### Task 3: `bin/aicoding-sync` CLI + `aicoding-update` shim

**Files:**
- Create: `bin/aicoding-sync`
- Rewrite: `bin/aicoding-update` (shim)
- Test: `tests/bats/sync.bats`

- [ ] **Step 1: Write the failing test**

```bash
@test "aicoding-sync --boot runs end to end (exit 0)" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  run env AICODING_BLUEPRINT_CLONE="$BLUEPRINT_ROOT" AICODING_UPDATE_TTL=0 \
      "$BLUEPRINT_ROOT/bin/aicoding-sync" --boot
  [ "$status" -eq 0 ]
}
@test "aicoding-update shim still works (delegates to aicoding-sync)" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  run env AICODING_BLUEPRINT_CLONE="$BLUEPRINT_ROOT" AICODING_UPDATE_TTL=0 \
      "$BLUEPRINT_ROOT/bin/aicoding-update" --yes
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run, verify RED**

Run: `BLUEPRINT_ROOT="$PWD" bats -f 'aicoding-sync --boot|shim still works' tests/bats/sync.bats`
Expected: FAIL — `bin/aicoding-sync` missing.

- [ ] **Step 3: Write `bin/aicoding-sync`**

```bash
#!/usr/bin/env bash
set -uo pipefail
SCRIPT_REAL=$(readlink -f "$0"); SCRIPT_DIR=$(dirname "$(dirname "$SCRIPT_REAL")")
: "${AICODING_BLUEPRINT_CLONE:=/tmp/aicoding}"
: "${AICODING_MANIFEST:=$HOME/.aicodingsetup/manifest.json}"
case "${1:-}" in
  -h|--help) echo "usage: aicoding-sync [--first|--boot]   (default: interactive)"; exit 0 ;;
esac
# Prefer the refreshed blueprint clone if present; else the install dir.
[ -f "$AICODING_BLUEPRINT_CLONE/lib/sync.sh" ] && . "$AICODING_BLUEPRINT_CLONE/lib/sync.sh" \
  || . "$SCRIPT_DIR/lib/sync.sh"
aicoding_sync "${1:-}"
```

- [ ] **Step 4: Replace `bin/aicoding-update` with a shim**

```bash
#!/usr/bin/env bash
# Back-compat shim: aicoding-update -> aicoding-sync. Remove after one release.
exec "$(dirname "$(readlink -f "$0")")/aicoding-sync" "$@"
```

- [ ] **Step 5: Make executable, run, verify GREEN**

```bash
chmod +x bin/aicoding-sync bin/aicoding-update
BLUEPRINT_ROOT="$PWD" bats -f 'aicoding-sync --boot|shim still works' tests/bats/sync.bats
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add bin/aicoding-sync bin/aicoding-update tests/bats/sync.bats
git commit -m "feat(sync): bin/aicoding-sync CLI; aicoding-update becomes a shim"
```

---

### Task 4: Rename `update.sh` → `on-start.sh` (+ shim); move `seed_github_known_host`

**Files:**
- Create: `on-start.sh`
- Modify: `lib/sync.sh` (add `seed_github_known_host`)
- Rewrite: `update.sh` (shim)
- Modify: `devcontainer.json`
- Test: `tests/bats/sync.bats`

- [ ] **Step 1: Write the failing test** — `on-start.sh` exists and exits 0 non-interactively.

```bash
@test "on-start.sh runs the boot path (exit 0)" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  run env AICODING_BLUEPRINT_CLONE="$BLUEPRINT_ROOT" AICODING_UPDATE_TTL=0 \
      bash "$BLUEPRINT_ROOT/on-start.sh"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run, verify RED**

Run: `BLUEPRINT_ROOT="$PWD" bats -f 'on-start.sh runs' tests/bats/sync.bats`
Expected: FAIL — `on-start.sh` missing.

- [ ] **Step 3: Move `seed_github_known_host` into `lib/sync.sh`**

Cut the `seed_github_known_host() { ... }` function body from `update.sh` and paste
it into `lib/sync.sh` (above `_sync_plumbing`). Remove the `command -v` guard's
need — it is now always defined when the lib is sourced.

- [ ] **Step 4: Write `on-start.sh`** (the boot bootstrap prologue, then sync)

```bash
#!/bin/bash
# on-start.sh — postStartCommand boot hook. Bootstrap prologue (nvs-strip, PATH,
# blueprint clone) then run the unified sync in --boot mode. Fail-open.
set -uo pipefail
SOURCE_URL="https://raw.githubusercontent.com/vossiman/aiCodingBaseSetup/main/on-start.sh"
if [[ "${_NVS_STRIPPED:-}" != 1 ]]; then
  self="$0"
  if [[ "$(basename -- "$self")" == bash || ! -r "$self" ]]; then
    self="$HOME/.aicodingsetup/on-start.sh"; mkdir -p "$(dirname "$self")"
    curl -fsSL "$SOURCE_URL" -o "$self" || { echo "WARN: could not stash on-start.sh" >&2; exit 0; }
  fi
  exec env -u 'BASH_FUNC_nvs%%' -u 'BASH_FUNC_nvsudo%%' -u 'BASH_FUNC_nvm%%' _NVS_STRIPPED=1 bash "$self" "$@"
fi
export PATH="$HOME/.local/bin:$PATH"
: "${AICODING_BLUEPRINT_CLONE:=/tmp/aicoding}"
if command -v aicoding-sync >/dev/null 2>&1; then
  aicoding-sync --boot || echo "WARN: aicoding-sync failed (non-fatal)" >&2
fi
exit 0
```

- [ ] **Step 5: Replace `update.sh` with a shim**

```bash
#!/bin/bash
# Back-compat shim: update.sh -> on-start.sh. Remove after one release.
exec bash "$HOME/.aicodingsetup/on-start.sh" "$@" 2>/dev/null \
  || exec bash "$(dirname "$(readlink -f "$0")")/on-start.sh" "$@"
```

- [ ] **Step 6: Point `devcontainer.json` at the new hook**

In `devcontainer.json`, change `postStartCommand` to curl `on-start.sh`:

```jsonc
"postStartCommand": "curl -fsSL https://raw.githubusercontent.com/vossiman/aiCodingBaseSetup/main/on-start.sh | bash"
```

- [ ] **Step 7: Make executable, run, verify GREEN + full suite**

```bash
chmod +x on-start.sh update.sh
BLUEPRINT_ROOT="$PWD" bats -f 'on-start.sh runs' tests/bats/sync.bats
bash tests/bats/run.sh
```
Expected: target PASS; suite green.

- [ ] **Step 8: Commit**

```bash
git add on-start.sh update.sh lib/sync.sh devcontainer.json
git commit -m "feat(boot): rename update.sh -> on-start.sh (shim kept); call aicoding-sync --boot"
```

---

### Task 5: `bin/aicoding-status` (rename, drop dvw) + `update-status` shim

**Files:**
- Rename: `bin/update-status` → `bin/aicoding-status`
- Rewrite: `bin/update-status` (shim)
- Modify: `configs/bash/update-notify.sh`
- Modify: `tests/bats/update-status.bats`

- [ ] **Step 1: Update the test to drive `aicoding-status` and assert no dvw entry**

In `tests/bats/update-status.bats` set `BIN="$BLUEPRINT_ROOT/bin/aicoding-status"`,
and add:

```bash
@test "registry is aicoding-only (no dvw entry) in-container" {
  run "$BIN" --print
  ! echo "$output" | grep -qi dvw
}
@test "update-status shim still works" {
  run "$BLUEPRINT_ROOT/bin/update-status" --tmux
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run, verify RED**

Run: `BLUEPRINT_ROOT="$PWD" bats tests/bats/update-status.bats`
Expected: FAIL — `bin/aicoding-status` missing.

- [ ] **Step 3: `git mv` + drop the dvw registry line**

```bash
git mv bin/update-status bin/aicoding-status
```

In `bin/aicoding-status` `_registry()`, delete the `dvw|...` line so only the
aicoding entry (and the TESTONLY hook) remain.

- [ ] **Step 4: Add the `update-status` shim**

```bash
#!/usr/bin/env bash
# Back-compat shim: update-status -> aicoding-status. Remove after one release.
exec "$(dirname "$(readlink -f "$0")")/aicoding-status" "$@"
```

- [ ] **Step 5: Point the bashrc snippet at the new name**

In `configs/bash/update-notify.sh`, replace `update-status --banner` with
`aicoding-status --banner` (keep the interactive guard + `command -v`).

- [ ] **Step 6: Make executable, run, verify GREEN**

```bash
chmod +x bin/aicoding-status bin/update-status
BLUEPRINT_ROOT="$PWD" bats tests/bats/update-status.bats
```
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add bin/aicoding-status bin/update-status configs/bash/update-notify.sh tests/bats/update-status.bats
git commit -m "feat(status): rename update-status -> aicoding-status (shim kept); drop in-container dvw entry"
```

---

### Task 6: Route `install.sh` provisioning + symlinks through the new names

**Files:**
- Modify: `install.sh`
- Test: `tests/bats/install.bats`

- [ ] **Step 1: Write the failing test** — install symlinks the new CLIs and deploys the renamed boot hook reference.

```bash
@test "install.sh symlinks aicoding-sync and aicoding-status" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ -x "$HOME/.local/bin/aicoding-sync" ]
  [ -x "$HOME/.local/bin/aicoding-status" ]
  # back-compat shims still resolve
  [ -e "$HOME/.local/bin/aicoding-update" ]
  [ -e "$HOME/.local/bin/update-status" ]
}
```

- [ ] **Step 2: Run, verify RED**

Run: `BLUEPRINT_ROOT="$PWD" bats -f 'symlinks aicoding-sync' tests/bats/install.bats`
Expected: FAIL — only old symlinks created.

- [ ] **Step 3: Update the symlink installer in `install.sh`**

Find `install_update_status_symlink` (and any `aicoding-update` symlink helper) and
generalise to symlink all four into `~/.local/bin`: `aicoding-sync`,
`aicoding-status`, plus shims `aicoding-update`, `update-status`:

```bash
install_cli_symlinks() {
  header "aicoding CLIs"
  mkdir -p "$HOME/.local/bin"
  local f
  for f in aicoding-sync aicoding-status aicoding-update update-status; do
    [[ -f "$SCRIPT_DIR/bin/$f" ]] || continue
    chmod +x "$SCRIPT_DIR/bin/$f"; ln -sf "$SCRIPT_DIR/bin/$f" "$HOME/.local/bin/$f"
  done
  ok "aicoding CLIs symlinked into ~/.local/bin"
}
```

Call `install_cli_symlinks` in `main` (replacing the old per-CLI calls).

- [ ] **Step 4: Run, verify GREEN + full suite**

```bash
BLUEPRINT_ROOT="$PWD" bats -f 'symlinks aicoding-sync' tests/bats/install.bats
bash tests/bats/run.sh
```
Expected: target PASS; suite green.

- [ ] **Step 5: Commit**

```bash
git add install.sh tests/bats/install.bats
git commit -m "feat(install): symlink aicoding-sync/aicoding-status (+ back-compat shims)"
```

---

### Task 7: Full suite + PR

- [ ] **Step 1: Run the whole suite**

Run: `bash tests/bats/run.sh`
Expected: all green.

- [ ] **Step 2: Push + PR**

```bash
git push -u origin HEAD
gh pr create -R vossiman/aiCodingBaseSetup --base main --head "$(git branch --show-current)" \
  --title "aicoding sync/status unification (Phase 1)" \
  --body "Unifies install/update into aicoding-sync (plumbing+config+binaries, modes) + read-only aicoding-status; self-heals owned overwrite files; old names kept as shims. Spec: docs/superpowers/specs/2026-06-06-aicoding-sync-status-unification-design.md"
```

---

## Self-review

**Spec coverage:** two verbs ✔ (Tasks 2,3,5); triggers-as-flags ✔ (`--first/--boot`,
Tasks 2,4,6); plumbing+config+binaries in one routine ✔ (Task 2); self-heal owned
files ✔ (Task 1); throttle ✔ (Task 2 `_sync_binaries_fresh`); separate-script
naming + shims ✔ (Tasks 3,4,5); drop in-container dvw ✔ (Task 5); status =
read-only ✔ (Task 5); fail-open ✔ (Task 2 test). Deferred 3-way diff: not in scope.

**Placeholder scan:** none — every step has concrete code/commands.

**Type/name consistency:** `aicoding_sync` routine (lib/sync.sh) called by
`bin/aicoding-sync` and `on-start.sh`; `will_update_owned` bucket + `_is_owned_overwrite`
used identically in Tasks 1 and 2; shims `aicoding-update`/`update-status`/`update.sh`
all delegate to the new targets; symlink set in Task 6 matches the files created.
