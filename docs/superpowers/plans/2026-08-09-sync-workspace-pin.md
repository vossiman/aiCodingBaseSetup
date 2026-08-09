# Sync Workspace Pin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `aicoding-sync` reconciles the workspace's `.devcontainer/devcontainer.json` image pin from the blueprint on every sync (working-tree edit, never commits), killing the manual digest-edit step.

**Architecture:** One new function `_sync_devcontainer_pin` in `lib/sync.sh`, called from `aicoding_sync` in every mode (dry-run reports, other modes write). Spec: `docs/superpowers/specs/2026-08-09-sync-workspace-pin-design.md`.

**Tech Stack:** bash (`lib/sync.sh`), bats, jq/sed.

## Global Constraints

- Work ONLY in `/var/tmp/aicoding-wt-wspin` (worktree, branch `feat/sync-workspace-pin`).
- Tests ALWAYS via `bash tests/bats/run.sh [file]` from the worktree root; run the FULL suite before finishing.
- Never assert with bare `! cmd`; `[ ! -e f ]` flags fine. Tests write only under `$TMP`, never `$BLUEPRINT_ROOT`.
- `_sync_devcontainer_pin` must ALWAYS return 0 (fail-open; warn on stderr for abnormal cases), no network calls, and must NEVER run git commit/push.
- A non-devbox-base `image` value must never be modified.
- Commit trailer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

---

### Task 1: `_sync_devcontainer_pin` + wiring + tests (TDD)

**Files:**
- Create: `tests/bats/devcontainer-pin.bats`
- Modify: `lib/sync.sh` (new function above `aicoding_sync`; one call inside `aicoding_sync` after the `_sync_reconcile` step)

**Interfaces:**
- Consumes: `$AICODING_BLUEPRINT_CLONE/devcontainer.json` (blueprint pin source), `$PWD` (workspace discovery), mode string from `aicoding_sync` (`dry-run|yes|boot|first|interactive`).
- Produces: `_sync_devcontainer_pin <mode>` — always returns 0.

- [ ] **Step 1: Write the failing tests**

Create `tests/bats/devcontainer-pin.bats`:

```bash
#!/usr/bin/env bats
# _sync_devcontainer_pin: workspace pin reconcile (spec:
# docs/superpowers/specs/2026-08-09-sync-workspace-pin-design.md).
# Fixtures: a fake blueprint clone dir and a git-init'd workspace under $TMP.

OLD_PIN="ghcr.io/vossiman/devbox-base@sha256:0000000000000000000000000000000000000000000000000000000000000000"
NEW_PIN="ghcr.io/vossiman/devbox-base@sha256:1111111111111111111111111111111111111111111111111111111111111111"

setup() {
  : "${BLUEPRINT_ROOT:?run via run.sh}"
  export TMP; TMP=$(mktemp -d); export HOME="$TMP"
  export AICODING_BLUEPRINT_CLONE="$TMP/bp"
  mkdir -p "$TMP/bp" "$TMP/ws/.devcontainer"
  printf '{\n  "image": "%s",\n  "remoteUser": "codespace"\n}\n' "$NEW_PIN" > "$TMP/bp/devcontainer.json"
  printf '{\n  "image": "%s",\n  "remoteUser": "codespace",\n  "mounts": ["keepme"]\n}\n' "$OLD_PIN" > "$TMP/ws/.devcontainer/devcontainer.json"
  git -C "$TMP/ws" init -q
  cd "$TMP/ws"
  . "$BLUEPRINT_ROOT/lib/sync.sh"
}
teardown() { cd /; rm -rf "$TMP"; }

@test "pin sync: stale devbox pin is reconciled from the blueprint, reported" {
  run _sync_devcontainer_pin boot
  [ "$status" -eq 0 ]
  [[ "$output" == *"devcontainer pin: 000000000000 -> 111111111111"* ]]
  [ "$(jq -r .image "$TMP/ws/.devcontainer/devcontainer.json")" = "$NEW_PIN" ]
  grep -q '"mounts": \["keepme"\]' "$TMP/ws/.devcontainer/devcontainer.json"  # formatting preserved
}

@test "pin sync: custom (non-devbox) image is never touched" {
  printf '{\n  "image": "docker.io/library/ubuntu:24.04"\n}\n' > "$TMP/ws/.devcontainer/devcontainer.json"
  run _sync_devcontainer_pin boot
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(jq -r .image "$TMP/ws/.devcontainer/devcontainer.json")" = "docker.io/library/ubuntu:24.04" ]
}

@test "pin sync: equal pins -> silent no-op" {
  printf '{\n  "image": "%s"\n}\n' "$NEW_PIN" > "$TMP/ws/.devcontainer/devcontainer.json"
  run _sync_devcontainer_pin boot
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pin sync: no .devcontainer/devcontainer.json -> silent skip" {
  rm "$TMP/ws/.devcontainer/devcontainer.json"
  run _sync_devcontainer_pin boot
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pin sync: not a git repo -> silent skip, file untouched" {
  mkdir -p "$TMP/plain/.devcontainer"
  cp "$TMP/ws/.devcontainer/devcontainer.json" "$TMP/plain/.devcontainer/"
  cd "$TMP/plain"
  run _sync_devcontainer_pin boot
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(jq -r .image "$TMP/plain/.devcontainer/devcontainer.json")" = "$OLD_PIN" ]
}

@test "pin sync: dry-run reports but does not write" {
  run _sync_devcontainer_pin dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"devcontainer pin: 000000000000 -> 111111111111"* ]]
  [[ "$output" == *"dry run"* ]]
  [ "$(jq -r .image "$TMP/ws/.devcontainer/devcontainer.json")" = "$OLD_PIN" ]
}

@test "pin sync: blueprint copy missing image -> WARN, target untouched" {
  printf '{}\n' > "$TMP/bp/devcontainer.json"
  run _sync_devcontainer_pin boot
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN"* ]]
  [ "$(jq -r .image "$TMP/ws/.devcontainer/devcontainer.json")" = "$OLD_PIN" ]
}

@test "pin sync: aicoding_sync wires it in (call present in every non-return path)" {
  grep -q '_sync_devcontainer_pin "\$mode"' "$BLUEPRINT_ROOT/lib/sync.sh"
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /var/tmp/aicoding-wt-wspin && bash tests/bats/run.sh tests/bats/devcontainer-pin.bats`
Expected: all 8 FAIL (`_sync_devcontainer_pin: command not found`; wiring grep fails).

- [ ] **Step 3: Implement**

In `lib/sync.sh`, directly above `aicoding_sync() {`:

```bash
# Reconcile the workspace's .devcontainer/devcontainer.json image pin from
# the blueprint copy. The blueprint self-pins after every image publish
# (2026-08-09-auto-pin-image-digest-design.md); without this, the snapshot
# `dvw new` committed into the workspace repo goes stale and the ⬆rebuild
# badge's CTA recreates from the old pin. Working-tree edit ONLY — never
# commits or pushes; `devpod up --recreate` reads on-disk config, so the
# next dvw rebuild already uses the new pin and the commit rides the
# project's normal flow. Fail-open: warn + return 0, never break sync.
# Spec: docs/superpowers/specs/2026-08-09-sync-workspace-pin-design.md
_sync_devcontainer_pin() {
  local mode="${1:-}" top target bp_image cur_image old_d new_d
  top=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null) || return 0
  target="$top/.devcontainer/devcontainer.json"
  [ -f "$target" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  bp_image=$(jq -r '.image // empty' "$AICODING_BLUEPRINT_CLONE/devcontainer.json" 2>/dev/null) || true
  if [ -z "$bp_image" ]; then
    echo "WARN: blueprint devcontainer.json has no image — skipping pin sync" >&2
    return 0
  fi
  cur_image=$(jq -r '.image // empty' "$target" 2>/dev/null) || true
  case "$cur_image" in
    ghcr.io/vossiman/devbox-base@*) : ;;
    *) return 0 ;;   # custom or missing image — never stomp
  esac
  [ "$cur_image" = "$bp_image" ] && return 0
  old_d=$(printf '%s' "$cur_image" | sed -E 's/.*@sha256:([0-9a-f]{12}).*/\1/')
  new_d=$(printf '%s' "$bp_image"  | sed -E 's/.*@sha256:([0-9a-f]{12}).*/\1/')
  if [ "$mode" = dry-run ]; then
    echo "devcontainer pin: $old_d -> $new_d (dry run, not written)"
    return 0
  fi
  if ! sed -i -E "s|\"image\": \"[^\"]+\"|\"image\": \"${bp_image}\"|" "$target"; then
    echo "WARN: devcontainer pin sync failed for $target" >&2
    return 0
  fi
  echo "devcontainer pin: $old_d -> $new_d (commit at your convenience)"
  return 0
}
```

In `aicoding_sync`, after the `_sync_reconcile "$mode" || return $?` line, insert:

```bash
  # 2b. Workspace devcontainer pin — dry-run reports, other modes edit the
  #     working tree (never commits). Local file ops only, no throttle.
  _sync_devcontainer_pin "$mode" || true
```

- [ ] **Step 4: Verify green, then the full suite**

Run: `bash tests/bats/run.sh tests/bats/devcontainer-pin.bats` → 8/8 PASS.
Run: `bash tests/bats/run.sh` → full suite PASS (241 + 8 = 249). Watch `sync.bats`/`e2e.bats`: they invoke `aicoding_sync` with cwd inside `$TMP` fixtures — if any fixture cwd is inside a real git repo with a `.devcontainer/`, the new step could fire; their `$TMP` roots are `mktemp -d` dirs (not git repos), so expect silent skips. If a test fails from the new output line, report it — do not weaken existing assertions.

- [ ] **Step 5: Commit**

```bash
cd /var/tmp/aicoding-wt-wspin
git add lib/sync.sh tests/bats/devcontainer-pin.bats
git commit -m "feat(sync): reconcile workspace devcontainer pin from blueprint on every sync

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
