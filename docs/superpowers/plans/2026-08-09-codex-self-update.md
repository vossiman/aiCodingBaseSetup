# Codex Self-Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Version-gated codex refresh in `_sync_binaries` so the baked codex seed stops going stale, with loud (stderr) but non-fatal failure reporting.

**Architecture:** One new function `_update_codex` in `lib/sync.sh`, appended to `_sync_binaries` — inheriting the existing 6h boot throttle and manual-sync cadence. Version gate via the npm registry (`@openai/codex`), update via the official chatgpt.com installer, forced symlink over the baked seed, post-verify probe. Spec: `docs/superpowers/specs/2026-08-09-codex-self-update-design.md`.

**Tech Stack:** bash (`lib/sync.sh`), bats (`tests/bats/`), curl + jq.

## Global Constraints

- Repo: `devpod/aicoding` submodule (aiCodingBaseSetup), branch `feat/codex-self-update`. All paths below are relative to that repo root.
- ALWAYS run tests via `bash tests/bats/run.sh` (never bare `bats`); a single file via `bash tests/bats/run.sh tests/bats/codex-update.bats`.
- Never assert with bare `! cmd` — use `run` + status or `if cmd; then false; fi` (a regressions guard greps for offenders).
- Every network call must be gated behind `AICODINGSETUP_SKIP_NETWORK` (value `1`); every external binary a test can reach must be stubbed in the same commit.
- Tests must never write into `$BLUEPRINT_ROOT`; new test file writes only under its `$TMP`.
- `_update_codex` must ALWAYS return 0 — abnormal outcomes print `ERROR: …` to stderr, never break sync/boot.

---

### Task 1: `_update_codex` in `lib/sync.sh` (TDD)

**Files:**
- Create: `tests/bats/codex-update.bats`
- Modify: `lib/sync.sh` (insert `_update_codex` directly above `_sync_binaries`, which is at ~line 429)

**Interfaces:**
- Consumes: nothing from other tasks. Reads env: `AICODINGSETUP_SKIP_NETWORK`, `HOME`.
- Produces: function `_update_codex` (no args, always returns 0) — Task 2 calls it from `_sync_binaries`.

- [ ] **Step 1: Write the failing tests**

Create `tests/bats/codex-update.bats`:

```bash
#!/usr/bin/env bats
# _update_codex: version-gated codex refresh (spec:
# docs/superpowers/specs/2026-08-09-codex-self-update-design.md).
# codex is "installed" as a REAL file in $TMP/.local/bin (like the baked
# image seed); curl is stubbed to serve the npm registry JSON and the
# installer script; jq is the real binary.
setup() {
  : "${BLUEPRINT_ROOT:?run via run.sh}"
  export TMP; TMP=$(mktemp -d); export HOME="$TMP"
  mkdir -p "$TMP/stubs" "$TMP/.local/bin"

  # Baked-seed stand-in: real file (not a symlink), old version.
  printf '#!/bin/sh\necho "codex-cli 0.147.0"\n' > "$TMP/.local/bin/codex"
  chmod +x "$TMP/.local/bin/codex"

  # curl stub: registry URL -> JSON with $CODEX_LATEST; installer URL ->
  # a script (piped into sh by the code under test) that drops a new
  # codex into ~/.codex/bin and logs. Any other URL: log + fail.
  cat > "$TMP/stubs/curl" <<'EOF'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    *registry.npmjs.org*)
      echo "curl-registry" >> "$TMP/ran.log"
      [ "${CODEX_REGISTRY_FAIL:-}" = 1 ] && exit 22
      printf '{"version":"%s"}\n' "$CODEX_LATEST"; exit 0 ;;
    *chatgpt.com*)
      echo "curl-installer" >> "$TMP/ran.log"
      [ "${CODEX_INSTALLER_FAIL:-}" = 1 ] && exit 22
      cat <<INNER
mkdir -p "\$HOME/.codex/bin"
printf '#!/bin/sh\necho "codex-cli %s"\n' "${CODEX_INSTALLS:-$CODEX_LATEST}" > "\$HOME/.codex/bin/codex"
chmod +x "\$HOME/.codex/bin/codex"
INNER
      exit 0 ;;
  esac
done
echo "curl-other $*" >> "$TMP/ran.log"; exit 1
EOF
  chmod +x "$TMP/stubs/curl"

  export CODEX_LATEST="0.148.0"
  export PATH="$TMP/.local/bin:$TMP/stubs:$PATH"
  unset AICODINGSETUP_SKIP_NETWORK
  . "$BLUEPRINT_ROOT/lib/sync.sh"
}
teardown() { rm -rf "$TMP"; }

@test "codex update: equal versions -> silent no-op, no installer" {
  CODEX_LATEST="0.147.0" run _update_codex
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run grep -q "curl-installer" "$TMP/ran.log"
  [ "$status" -ne 0 ]
}

@test "codex update: newer version -> installer runs, seed force-linked" {
  run _update_codex
  [ "$status" -eq 0 ]
  grep -q "curl-installer" "$TMP/ran.log"
  [ -L "$TMP/.local/bin/codex" ]   # real file replaced by symlink
  [ "$(readlink "$TMP/.local/bin/codex")" = "$TMP/.codex/bin/codex" ]
  [ "$(codex --version)" = "codex-cli 0.148.0" ]
  run bash -c 'echo "$1" | grep ERROR' _ "$output"
  [ "$status" -ne 0 ]              # no ERROR emitted on success
}

@test "codex update: registry probe failure -> ERROR line, exit 0, no installer" {
  CODEX_REGISTRY_FAIL=1 run _update_codex
  [ "$status" -eq 0 ]
  [[ "$output" == *"ERROR: codex update check failed"* ]]
  run grep -q "curl-installer" "$TMP/ran.log"
  [ "$status" -ne 0 ]
}

@test "codex update: SKIP_NETWORK -> silent, zero network" {
  AICODINGSETUP_SKIP_NETWORK=1 run _update_codex
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$TMP/ran.log" ]          # curl never invoked
}

@test "codex update: codex absent -> silent no-op" {
  rm "$TMP/.local/bin/codex"
  # hash table may cache the removed path in this shell
  hash -r 2>/dev/null || true
  run _update_codex
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$TMP/ran.log" ]
}

@test "codex update: installer failure -> ERROR still-at line, exit 0" {
  CODEX_INSTALLER_FAIL=1 run _update_codex
  [ "$status" -eq 0 ]
  [[ "$output" == *"ERROR: codex update failed — still at 0.147.0"* ]]
  [ ! -L "$TMP/.local/bin/codex" ]   # seed untouched
}

@test "codex update: post-verify mismatch -> ERROR names both versions" {
  CODEX_INSTALLS="0.147.0" run _update_codex   # installer "succeeds" but drops old version
  [ "$status" -eq 0 ]
  [[ "$output" == *"ERROR: codex updated but version is still 0.147.0 (expected 0.148.0)"* ]]
}
```

- [ ] **Step 2: Run the new file to verify it fails**

Run: `bash tests/bats/run.sh tests/bats/codex-update.bats`
Expected: FAIL — `_update_codex: command not found` (or equivalent) in every test.

- [ ] **Step 3: Implement `_update_codex`**

In `lib/sync.sh`, directly above `_sync_binaries() {`:

```bash
# Codex has no self-update subcommand; a refresh means re-running the
# official installer. Version-gate against the npm registry (same release
# channel as the installer) so the ~258MB download only happens on a real
# version change. Abnormal outcomes print ERROR to stderr but return 0 —
# sync/boot must never break on a stale codex.
# Spec: docs/superpowers/specs/2026-08-09-codex-self-update-design.md
_update_codex() {
  command -v codex >/dev/null 2>&1 || return 0
  [ "${AICODINGSETUP_SKIP_NETWORK:-}" = 1 ] && return 0
  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: codex update check failed (curl/jq missing) — codex may be stale" >&2
    return 0
  fi
  local installed latest
  installed=$(codex --version 2>/dev/null | awk '{print $NF}') || true
  latest=$(curl -fsSL --max-time 10 \
    https://registry.npmjs.org/@openai/codex/latest 2>/dev/null \
    | jq -r '.version // empty' 2>/dev/null) || true
  if [ -z "$installed" ] || [ -z "$latest" ]; then
    echo "ERROR: codex update check failed (installed='${installed:-?}' latest='${latest:-?}') — codex may be stale" >&2
    return 0
  fi
  [ "$installed" = "$latest" ] && return 0
  # CODEX_NON_INTERACTIVE=1: upstream grew y/N prompts that read /dev/tty.
  # Subshell with pipefail so a failed curl doesn't vanish behind sh
  # succeeding on empty stdin.
  if ! (set -o pipefail; curl -fsSL https://chatgpt.com/codex/install.sh \
      | CODEX_NON_INTERACTIVE=1 sh >/dev/null 2>&1); then
    echo "ERROR: codex update failed — still at $installed" >&2
    return 0
  fi
  # Force-link over the baked seed. ensure_codex's probe links only when
  # ~/.local/bin/codex is absent, which would leave the stale image seed
  # shadowing the update. ~/.codex is the shared host mount, so the new
  # binary reaches every container and survives recreates.
  if [ -x "$HOME/.codex/bin/codex" ]; then
    mkdir -p "$HOME/.local/bin"
    ln -sf "$HOME/.codex/bin/codex" "$HOME/.local/bin/codex"
  fi
  local now
  now=$(codex --version 2>/dev/null | awk '{print $NF}') || true
  if [ "$now" != "$latest" ]; then
    echo "ERROR: codex updated but version is still ${now:-unknown} (expected $latest)" >&2
  fi
  return 0
}
```

- [ ] **Step 4: Run the new file to verify it passes**

Run: `bash tests/bats/run.sh tests/bats/codex-update.bats`
Expected: 7 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add tests/bats/codex-update.bats lib/sync.sh
git commit -m "feat(sync): _update_codex — version-gated codex refresh, loud failures"
```

---

### Task 2: Wire into `_sync_binaries`, docs, full suite

**Files:**
- Modify: `lib/sync.sh:429-434` (`_sync_binaries`)
- Modify: `tests/bats/codex-update.bats` (one integration test)
- Modify: `docs/superpowers/specs/2026-08-06-custom-base-image-design.md:39` (lifecycle table row) and `:73-82` (seed-CLI caveat)

**Interfaces:**
- Consumes: `_update_codex` from Task 1 (no args, always returns 0).
- Produces: nothing downstream.

- [ ] **Step 1: Add the failing integration test**

Append to `tests/bats/codex-update.bats`:

```bash
@test "_sync_binaries invokes the codex updater" {
  # claude/opencode/agent logging stubs so _sync_binaries' other calls
  # stay off the network (standing rule: agent CLIs are external binaries).
  for c in claude opencode agent; do
    printf '#!/bin/sh\necho "%s $*" >> "$TMP/ran.log"\n' "$c" > "$TMP/stubs/$c"
    chmod +x "$TMP/stubs/$c"
  done
  run _sync_binaries
  [ "$status" -eq 0 ]
  grep -q "curl-installer" "$TMP/ran.log"   # codex path reached via _sync_binaries
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/bats/run.sh tests/bats/codex-update.bats`
Expected: the new test FAILS (`curl-installer` never logged); the six Task 1 tests still pass.

- [ ] **Step 3: Wire the call**

In `lib/sync.sh`, `_sync_binaries` becomes:

```bash
_sync_binaries() {            # throttled network refresh
  command -v claude   >/dev/null 2>&1 && { claude update    || true; }
  command -v opencode >/dev/null 2>&1 && { opencode upgrade || true; }
  if command -v agent >/dev/null 2>&1; then agent update || true
  elif command -v cursor-agent >/dev/null 2>&1; then cursor-agent update || true; fi
  _update_codex || true
}
```

- [ ] **Step 4: Run the file, then the full suite**

Run: `bash tests/bats/run.sh tests/bats/codex-update.bats`
Expected: 7 tests PASS.

Run: `bash tests/bats/run.sh`
Expected: full suite PASS. Watch `sync.bats` in particular — its setup stubs
`curl` as bare `exit 0` and leaves the host's real codex reachable on PATH,
so `_update_codex` there takes the probe-failure path: an ERROR line on
stderr (harmless to its assertions) and no network. If any sync.bats test
asserts on combined output and now fails, fix by adding a no-op `codex` stub
(`printf '#!/bin/sh\nexit 127\n'`) to its setup stub loop — do NOT weaken
the assertion.

- [ ] **Step 5: Update the base-image spec**

In `docs/superpowers/specs/2026-08-06-custom-base-image-design.md`:

Lifecycle table row (line ~39) — replace the parenthetical codex exception:

```markdown
| **Daily CLI updates** (claude, codex, cursor-agent, opencode) | image staleness is irrelevant | CLIs live/self-update in user-writable `~/.local/bin`; `aicoding-sync --boot` does the throttled refresh on every start; `~/.local/bin` precedes any image path in PATH (codex: no native updater, so `_update_codex` in `lib/sync.sh` version-gates against the npm registry and re-runs the official installer — see `docs/superpowers/specs/2026-08-09-codex-self-update-design.md`) |
```

Seed-CLI caveat (lines ~78-82) — replace from "Caveat:" to "(see Rollout)." with:

```markdown
  `~/.local/share/opencode`). Codex has no self-update subcommand;
  `_update_codex` (in `_sync_binaries`) closes that gap — version-gated
  installer re-run, forced link over the baked seed (spec:
  `2026-08-09-codex-self-update-design.md`).
```

- [ ] **Step 6: Commit**

```bash
git add lib/sync.sh tests/bats/codex-update.bats docs/superpowers/specs/2026-08-06-custom-base-image-design.md
git commit -m "feat(sync): wire codex updater into _sync_binaries; docs follow"
```
