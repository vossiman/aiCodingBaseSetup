# Update Notifier — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a long-lived devbox container *notice* when its installed tools (aiCodingBaseSetup, dvw) are behind `main` and persistently show a CTA to update — never updating on its own.

**Architecture:** A throttled, clone-free checker (`git ls-remote` vs each tool's installed SHA) writes a per-tool JSON cache; a managed bashrc snippet prints a CTA banner from that cache on every interactive shell. Each tool owns its own installed-version marker; an aicoding-side registry knows how to read each. CTA-only — nothing auto-applies.

**Tech Stack:** Bash, `git ls-remote`, `jq`, bats (tests). Two repos / two PRs: **dvw** (Part A — version marker + `dvw update`) then **aicoding** (Part B — checker + banner). Part B's dvw registry entry reads the marker Part A creates, so do Part A first.

Spec: `docs/superpowers/specs/2026-06-05-update-notifier-cta-design.md`.
Phase 2 (tmux badge) is a separate plan — out of scope here.

---

## File structure

**Part A — dvw repo (`devpod/dvw`)**
- Create `lib/version.sh` — owns the dvw version marker (path, write, read). Single responsibility: version state. Sourced by the installer, the dispatcher, and tests.
- Modify `dvw-install.sh` — source `lib/version.sh`, write the marker at install.
- Modify `lib/commands.sh` — add `cmd_update` (manual in-place update).
- Modify `dvw` — dispatch `update` → `cmd_update`.
- Create `tests/bats/version.bats` — unit tests for `lib/version.sh`.

**Part B — aicoding repo (`devpod/aicoding`)**
- Create `bin/update-status` — registry + checker + cache (throttle/stale-lock/timeout) + `--refresh`/`--banner`.
- Create `configs/bash/update-notify.sh` — interactive bashrc snippet → `update-status --banner`.
- Modify `lib/blueprint-deploy.sh` — add the snippet to `managed_inventory_overwrite`.
- Modify `install.sh` — symlink `bin/update-status` into `~/.local/bin` (mirrors `install_aicoding_update_symlink`).
- Create `tests/bats/update-status.bats` — checker/throttle/lock/timeout/banner tests.

---

# Part A — dvw: version marker + `dvw update`

### Task A1: `lib/version.sh` — version marker library

**Files:**
- Create: `devpod/dvw/lib/version.sh`
- Test: `devpod/dvw/tests/bats/version.bats`

- [ ] **Step 1: Write the failing test**

```bash
# devpod/dvw/tests/bats/version.bats
#!/usr/bin/env bats

setup() {
  : "${DVW_ROOT_TEST:?}"            # repo root, exported by tests/bats/run or below
  TMP=$(mktemp -d); export HOME="$TMP"
  export DVW_STATE_DIR="$TMP/state/dvw"     # override so we never touch real ~/.local/state
  source "$DVW_ROOT_TEST/lib/version.sh"
  # a throwaway git repo to act as the "dvw checkout"
  REPO="$TMP/repo"; mkdir -p "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m one
}
teardown() { rm -rf "$TMP"; }

@test "marker path honors DVW_STATE_DIR override" {
  [ "$(dvw_version_marker_path)" = "$DVW_STATE_DIR/version" ]
}

@test "write records the repo HEAD; read returns it" {
  dvw_write_version_marker "$REPO"
  local head; head=$(git -C "$REPO" rev-parse HEAD)
  [ "$(cat "$DVW_STATE_DIR/version")" = "$head" ]
  [ "$(dvw_installed_version)" = "$head" ]
}

@test "installed_version is empty when no marker exists" {
  [ -z "$(dvw_installed_version)" ]
}
```

- [ ] **Step 2: Run it, verify it fails**

Run: `DVW_ROOT_TEST="$PWD" bats tests/bats/version.bats` (from `devpod/dvw`)
Expected: FAIL — `lib/version.sh` does not exist / functions undefined.

- [ ] **Step 3: Write `lib/version.sh`**

```bash
# devpod/dvw/lib/version.sh
# dvw's own installed-version marker. dvw owns this file; external tools (e.g.
# the aicoding update notifier) only READ it — they never write here.

# Path to the marker. Overridable via DVW_STATE_DIR for tests.
dvw_version_marker_path() {
  printf '%s/version' "${DVW_STATE_DIR:-$HOME/.local/state/dvw}"
}

# Record <repo_dir>'s HEAD SHA into the marker. No-op (warn) if not a git repo.
dvw_write_version_marker() {
  local repo=$1 sha marker dir
  sha=$(git -C "$repo" rev-parse HEAD 2>/dev/null) || { echo "WARN: $repo is not a git checkout — not recording dvw version" >&2; return 0; }
  marker=$(dvw_version_marker_path); dir=$(dirname "$marker")
  mkdir -p "$dir"
  printf '%s\n' "$sha" > "$marker"
}

# Echo the installed SHA, or empty if no marker.
dvw_installed_version() {
  local marker; marker=$(dvw_version_marker_path)
  [ -f "$marker" ] && tr -d '[:space:]' < "$marker" || true
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `DVW_ROOT_TEST="$PWD" bats tests/bats/version.bats`
Expected: 3 PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/version.sh tests/bats/version.bats
git commit -m "feat(version): dvw-owned installed-version marker library"
```

### Task A2: record the marker at install

**Files:**
- Modify: `devpod/dvw/dvw-install.sh`

- [ ] **Step 1: Add the write step near the end of `dvw-install.sh`** (after the PATH symlink is created, before the final success message). `SCRIPT_DIR` is already defined at the top of the file.

```bash
# shellcheck source=lib/version.sh
. "$SCRIPT_DIR/lib/version.sh"
step "recording dvw version marker"
dvw_write_version_marker "$SCRIPT_DIR" \
  && echo "recorded dvw version $(dvw_installed_version)"
```

- [ ] **Step 2: Verify it runs without error in a git checkout**

Run (from `devpod/dvw`): `bash dvw-install.sh --check-only` then manually source+call:
`bash -c '. ./lib/version.sh; DVW_STATE_DIR=$(mktemp -d) bash -c ". ./lib/version.sh; dvw_write_version_marker \"$PWD\"; dvw_installed_version"'`
Expected: prints a 40-char SHA.

- [ ] **Step 3: Commit**

```bash
git add dvw-install.sh
git commit -m "feat(install): record dvw version marker at install time"
```

### Task A3: `cmd_update` — manual in-place update

**Files:**
- Modify: `devpod/dvw/lib/commands.sh`
- Modify: `devpod/dvw/dvw`

- [ ] **Step 1: Add `cmd_update` to `lib/commands.sh`** (place beside the other `cmd_*` functions).

```bash
# dvw update — manual, user-invoked in-place update. Pull latest main, re-run
# the installer, refresh the version marker. NEVER called automatically.
cmd_update() {
  . "$DVW_ROOT/lib/version.sh"
  ui_info "updating dvw in $DVW_ROOT"
  if ! git -C "$DVW_ROOT" pull --ff-only origin main; then
    ui_error "git pull failed — resolve manually in $DVW_ROOT"; return 1
  fi
  bash "$DVW_ROOT/dvw-install.sh" || { ui_error "dvw-install.sh failed"; return 1; }
  dvw_write_version_marker "$DVW_ROOT"
  ui_info "dvw now at $(dvw_installed_version)"
}
```

(`ui_info`/`ui_error` come from `lib/ui.sh`, already sourced by `dvw`. `DVW_ROOT` is exported by the `dvw` dispatcher.)

- [ ] **Step 2: Dispatch `update` in `dvw`** — add a case arm alongside the existing subcommands (e.g. after the `rm)` arm):

```bash
    update)
      shift; cmd_update "$@" ;;
```

- [ ] **Step 3: Smoke-test dispatch (no network) — verify the arm is wired**

Run (from `devpod/dvw`): `bash -c '. lib/ui.sh; . lib/commands.sh; type cmd_update >/dev/null && echo wired'`
Expected: `wired`.

- [ ] **Step 4: Commit**

```bash
git add lib/commands.sh dvw
git commit -m "feat(dvw): add 'dvw update' (manual in-place update + marker refresh)"
```

### Task A4: open the dvw PR

- [ ] **Step 1: Push + PR**

```bash
git push origin HEAD          # from a feature branch, e.g. feat/version-marker
gh pr create -R vossiman/dvw --base main --head feat/version-marker \
  --title "dvw version marker + 'dvw update'" \
  --body "Adds a dvw-owned installed-version marker (lib/version.sh, written by dvw-install.sh) and a manual 'dvw update' subcommand. Enables the aiCodingBaseSetup update notifier to detect dvw drift. No auto-update."
```

---

# Part B — aicoding: checker + shell-banner CTA

> Do Part A first: Task B2's dvw registry entry reads dvw's marker (`~/.local/state/dvw/version`).

### Task B1: `bin/update-status` — checker, cache, banner (core)

**Files:**
- Create: `devpod/aicoding/bin/update-status`
- Test: `devpod/aicoding/tests/bats/update-status.bats`

- [ ] **Step 1: Write the failing test (status compute + cache + banner + throttle + fail-open)**

```bash
# devpod/aicoding/tests/bats/update-status.bats
#!/usr/bin/env bats

setup() {
  : "${BLUEPRINT_ROOT:?unset — run via tests/bats/run.sh}"
  BIN="$BLUEPRINT_ROOT/bin/update-status"
  TMP=$(mktemp -d); export HOME="$TMP"
  export AICODING_UPDATE_STATE="$TMP/state/updates"
  export AICODING_UPDATE_TTL=3600
  # Stub `git`: only `ls-remote` is used; emit a controllable SHA.
  mkdir -p "$TMP/stubs"
  cat > "$TMP/stubs/git" <<STUB
#!/bin/sh
if [ "\$1" = "ls-remote" ]; then
  [ -n "\${FAKE_LSREMOTE_FAIL:-}" ] && exit 1
  printf '%s\t%s\n' "\${FAKE_LATEST:-1111111111111111111111111111111111111111}" refs/heads/main
  exit 0
fi
exec /usr/bin/git "\$@"
STUB
  chmod +x "$TMP/stubs/git"
  export PATH="$TMP/stubs:$PATH"
  # Single-tool registry for tests via override hooks (see implementation).
  export AICODING_UPDATE_TESTONLY_TOOL="demo"
  export AICODING_UPDATE_TESTONLY_REMOTE="https://example.invalid/demo"
  # installed SHA comes from a file we control:
  export AICODING_UPDATE_TESTONLY_INSTALLED_FILE="$TMP/installed"
}
teardown() { rm -rf "$TMP"; }

cache() { cat "$AICODING_UPDATE_STATE/demo.json"; }

@test "behind: installed != latest -> status behind, banner shows CTA" {
  echo 2222222222222222222222222222222222222222 > "$AICODING_UPDATE_TESTONLY_INSTALLED_FILE"
  FAKE_LATEST=1111111111111111111111111111111111111111 run "$BIN" --refresh
  [ "$status" -eq 0 ]
  [ "$(cache | jq -r .status)" = "behind" ]
  run "$BIN" --banner
  echo "$output" | grep -q "demo"
  echo "$output" | grep -q "behind"
}

@test "up_to_date: installed == latest -> banner silent" {
  echo 1111111111111111111111111111111111111111 > "$AICODING_UPDATE_TESTONLY_INSTALLED_FILE"
  FAKE_LATEST=1111111111111111111111111111111111111111 "$BIN" --refresh
  [ "$(cache | jq -r .status)" = "up_to_date" ]
  run "$BIN" --banner
  [ -z "$output" ]
}

@test "throttle: fresh cache means no network call on refresh" {
  echo 2222222222222222222222222222222222222222 > "$AICODING_UPDATE_TESTONLY_INSTALLED_FILE"
  FAKE_LATEST=1111111111111111111111111111111111111111 "$BIN" --refresh   # writes cache now
  # Break the stub so any network call would change latest; throttle must skip it.
  FAKE_LATEST=3333333333333333333333333333333333333333 "$BIN" --refresh
  [ "$(cache | jq -r .latest | cut -c1-7)" = "1111111" ]
}

@test "fail-open: ls-remote failure -> unknown, exit 0, prior cache kept" {
  echo 2222222222222222222222222222222222222222 > "$AICODING_UPDATE_TESTONLY_INSTALLED_FILE"
  AICODING_UPDATE_TTL=0 FAKE_LSREMOTE_FAIL=1 run "$BIN" --refresh
  [ "$status" -eq 0 ]
  [ "$(cache | jq -r .status)" = "unknown" ]
}

@test "stale-lock: a lock older than TTL is stolen and refresh proceeds" {
  echo 2222222222222222222222222222222222222222 > "$AICODING_UPDATE_TESTONLY_INSTALLED_FILE"
  mkdir -p "$AICODING_UPDATE_STATE/.lock"
  touch -d '2000-01-01' "$AICODING_UPDATE_STATE/.lock"
  AICODING_UPDATE_TTL=0 FAKE_LATEST=1111111111111111111111111111111111111111 run "$BIN" --refresh
  [ "$status" -eq 0 ]
  [ "$(cache | jq -r .status)" = "behind" ]
}
```

- [ ] **Step 2: Run it, verify it fails**

Run: `BLUEPRINT_ROOT="$PWD" bats tests/bats/update-status.bats` (from `devpod/aicoding`)
Expected: FAIL — `bin/update-status` does not exist.

- [ ] **Step 3: Write `bin/update-status`**

```bash
#!/usr/bin/env bash
# update-status — detect whether managed tools are behind their main branch and
# print a CTA. CTA-ONLY: never applies an update. Reads/writes a per-tool JSON
# cache; network checks are throttled, timeout-bounded, and fail-open.
set -uo pipefail

STATE="${AICODING_UPDATE_STATE:-$HOME/.aicodingsetup/state/updates}"
TTL="${AICODING_UPDATE_TTL:-21600}"             # 6h
NET_TIMEOUT="${AICODING_UPDATE_NET_TIMEOUT:-8}"
LOCK="$STATE/.lock"
: "${AICODING_MANIFEST:=$HOME/.aicodingsetup/manifest.json}"

# --- registry: name|remote|branch|installed_fn -----------------------------
_installed_aicoding() { jq -r '.blueprint_commit // empty' "$AICODING_MANIFEST" 2>/dev/null; }
_installed_dvw()      { local f="${DVW_STATE_DIR:-$HOME/.local/state/dvw}/version"; [ -f "$f" ] && tr -d '[:space:]' < "$f"; }
_registry() {
  if [ -n "${AICODING_UPDATE_TESTONLY_TOOL:-}" ]; then
    printf '%s|%s|main|_installed_testonly\n' "$AICODING_UPDATE_TESTONLY_TOOL" "$AICODING_UPDATE_TESTONLY_REMOTE"
    return
  fi
  cat <<EOF
aicoding|https://github.com/vossiman/aiCodingBaseSetup|main|_installed_aicoding|aicoding-update
dvw|https://github.com/vossiman/dvw|main|_installed_dvw|dvw update
EOF
}
_installed_testonly() { cat "$AICODING_UPDATE_TESTONLY_INSTALLED_FILE" 2>/dev/null | tr -d '[:space:]'; }
_apply_cmd() { case "$1" in aicoding) echo "aicoding-update";; dvw) echo "dvw update";; *) echo "update";; esac; }

_norm() { printf '%.12s' "${1:-}"; }     # compare a stable prefix (short vs full SHA)

_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Refresh ALL tools' caches (the network step). Caller handles throttle+lock.
_refresh_all() {
  mkdir -p "$STATE"
  local name remote branch ifn rest installed latest status tmp
  while IFS='|' read -r name remote branch ifn rest; do
    [ -z "$name" ] && continue
    installed=$("$ifn" 2>/dev/null || true)
    latest=$(timeout "$NET_TIMEOUT" git ls-remote "$remote" "$branch" 2>/dev/null | awk 'NR==1{print $1}')
    if [ -z "$installed" ] || [ -z "$latest" ]; then status=unknown
    elif [ "$(_norm "$installed")" = "$(_norm "$latest")" ]; then status=up_to_date
    else status=behind; fi
    tmp=$(mktemp)
    jq -n --arg t "$name" --arg i "${installed:-}" --arg l "${latest:-}" \
          --arg s "$status" --arg c "$(_now_iso)" --arg a "$(_apply_cmd "$name")" \
      '{tool:$t,installed:$i,latest:$l,status:$s,checked_at:$c,apply_cmd:$a}' > "$tmp"
    mv "$tmp" "$STATE/$name.json"
  done < <(_registry)
}

_cache_fresh() {   # 0 if newest cache file is younger than TTL
  local newest
  newest=$(find "$STATE" -maxdepth 1 -name '*.json' -newermt "-${TTL} seconds" 2>/dev/null | head -1)
  [ -n "$newest" ]
}

# Throttled, locked, stale-lock-aware refresh. Returns immediately if fresh.
_maybe_refresh() {
  mkdir -p "$STATE"
  _cache_fresh && return 0
  # steal a lock older than TTL (a crashed refresh must not wedge us)
  if [ -d "$LOCK" ] && [ -z "$(find "$LOCK" -maxdepth 0 -newermt "-${TTL} seconds" 2>/dev/null)" ]; then
    rmdir "$LOCK" 2>/dev/null || true
  fi
  mkdir "$LOCK" 2>/dev/null || return 0     # someone else holds a fresh lock
  _refresh_all
  rmdir "$LOCK" 2>/dev/null || true
}

# Detached, never blocks the caller.
_refresh_detached() { ( _maybe_refresh >/dev/null 2>&1 & ) ; }

_print_banner() {
  local f st tool apply
  for f in "$STATE"/*.json; do
    [ -f "$f" ] || continue
    st=$(jq -r '.status' "$f" 2>/dev/null)
    [ "$st" = "behind" ] || continue
    tool=$(jq -r '.tool' "$f"); apply=$(jq -r '.apply_cmd' "$f")
    printf '⬆ %s behind main — run: %s\n' "$tool" "$apply"
  done
}

case "${1:-}" in
  --refresh)  AICODING_UPDATE_TTL_OVERRIDE=1 _maybe_refresh ;;
  --banner)   _refresh_detached; _print_banner ;;
  --print)    _print_banner ;;
  -h|--help)  echo "usage: update-status [--refresh|--banner|--print]" ;;
  *)          echo "usage: update-status [--refresh|--banner|--print]" >&2; exit 2 ;;
esac
exit 0
```

> Note: `--refresh` must honor the throttle so the test "throttle: fresh cache → no network" passes; the stale-lock and fail-open tests set `AICODING_UPDATE_TTL=0` to force a refresh. `_maybe_refresh` already returns early when `_cache_fresh`, and `find -newermt "-0 seconds"` matches nothing, so TTL=0 always refreshes. Remove the unused `AICODING_UPDATE_TTL_OVERRIDE` marker — it documents intent only.

- [ ] **Step 4: Make executable, run tests, verify pass**

Run:
```bash
chmod +x bin/update-status
BLUEPRINT_ROOT="$PWD" bats tests/bats/update-status.bats
```
Expected: 5 PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/update-status tests/bats/update-status.bats
git commit -m "feat(update-status): clone-free behind-main checker + CTA banner"
```

### Task B2: bashrc snippet + deploy wiring

**Files:**
- Create: `devpod/aicoding/configs/bash/update-notify.sh`
- Modify: `devpod/aicoding/lib/blueprint-deploy.sh` (managed inventory)
- Modify: `devpod/aicoding/install.sh` (symlink the CLI)

- [ ] **Step 1: Create the bashrc snippet** (interactive-only; never blocks)

```bash
# devpod/aicoding/configs/bash/update-notify.sh
# Print a CTA banner for managed tools behind main. Reads a cached status
# (refreshed in the background, throttled); interactive shells only; fail-open.
case $- in
  *i*)
    command -v update-status >/dev/null 2>&1 && update-status --banner 2>/dev/null || true
    ;;
esac
```

- [ ] **Step 2: Add the snippet to `managed_inventory_overwrite`** in `lib/blueprint-deploy.sh`, beside the existing `ssh-auth-sock.sh` line:

```
$HOME/.bashrc.d/aicoding-update-notify.sh|overwrite|configs/bash/update-notify.sh
```

- [ ] **Step 3: Symlink the CLI in `install.sh`** — add a function mirroring `install_aicoding_update_symlink` and call it in `main` right after that call:

```bash
install_update_status_symlink() {
  header "update-status CLI"
  local src="$SCRIPT_DIR/bin/update-status" dest="$HOME/.local/bin/update-status"
  [[ -f "$src" ]] || { warn "bin/update-status not found — skipping"; return; }
  mkdir -p "$HOME/.local/bin"; chmod +x "$src"; ln -sf "$src" "$dest"
  ok "update-status installed at $dest -> $src"
}
```

In `main`, after `install_aicoding_update_symlink`:

```bash
  install_update_status_symlink
```

- [ ] **Step 4: Verify the snippet deploys + is tracked (extends the existing install flow)**

Add to `tests/bats/install.bats`:

```bash
@test "install.sh first-deploy: deploys update-notify snippet and update-status symlink" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ -f "$HOME/.bashrc.d/aicoding-update-notify.sh" ]
  grep -q "update-status --banner" "$HOME/.bashrc.d/aicoding-update-notify.sh"
  [ -x "$HOME/.local/bin/update-status" ]
  local h
  h=$(jq -r '.files["'"$HOME"'/.bashrc.d/aicoding-update-notify.sh"].deployed_hash' "$AICODING_MANIFEST")
  [ "$h" != "null" ] && [ -n "$h" ]
}
```

- [ ] **Step 5: Run the targeted test, verify pass**

Run: `BLUEPRINT_ROOT="$PWD" bats -f 'update-notify snippet' tests/bats/install.bats`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add configs/bash/update-notify.sh lib/blueprint-deploy.sh install.sh tests/bats/install.bats
git commit -m "feat(install): deploy update-notify bashrc snippet + update-status symlink"
```

### Task B3: full suite + aicoding PR

- [ ] **Step 1: Run the whole suite**

Run: `bash tests/bats/run.sh`
Expected: all green (existing 85 + new update-status tests + 1 new install test).

- [ ] **Step 2: Push + PR**

```bash
git push origin HEAD          # feature branch, e.g. feat/update-notifier
gh pr create -R vossiman/aiCodingBaseSetup --base main --head feat/update-notifier \
  --title "Update notifier (Phase 1): behind-main checker + shell CTA" \
  --body "CTA-only notifier: throttled clone-free 'git ls-remote' check writes a per-tool cache; an interactive bashrc snippet prints '⬆ <tool> behind main — run: <cmd>' until applied. Registry covers aicoding + dvw (reads dvw's version marker). No self-update, no daemon. Phase 2 (tmux badge) separate."
```

---

## Self-review

**Spec coverage:** registry ✔ (B1 `_registry`), latest via ls-remote+timeout ✔ (B1), installed markers ✔ (aicoding manifest / dvw A1), throttle ✔ (B1 `_cache_fresh`), stale-lock ✔ (B1 `_maybe_refresh` + test), detached/timeout ✔ (B1), banner ✔ (B1/B2), dvw `update` ✔ (A3), dvw marker dvw-owned ✔ (A1, path under dvw's own state dir; aicoding only reads it in `_installed_dvw`), fail-open ✔ (tests), CTA-only ✔ (no apply path invoked anywhere). Phase 2 (tmux) intentionally excluded.

**Placeholder scan:** none — every step has concrete code/commands.

**Type/name consistency:** `dvw_version_marker_path` / `dvw_write_version_marker` / `dvw_installed_version` used identically in A1–A3 and read by B1's `_installed_dvw` (same `~/.local/state/dvw/version` default + `DVW_STATE_DIR` override). Cache schema `{tool,installed,latest,status,checked_at,apply_cmd}` written in B1 and read by `_print_banner`/tests consistently. `update-status` modes `--refresh`/`--banner` match snippet (B2) and tests (B1).
