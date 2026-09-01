# Custom Base Image Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the digest-pinnable `ghcr.io/vossiman/devbox-base` image (Dockerfile + GHA pipeline + static tests) specified in `docs/superpowers/specs/2026-08-06-custom-base-image-design.md`, on branch `feat/base-image-spec` (PR #48).

**Architecture:** An `image/` directory holds a build-time `devcontainer.json` (base Dockerfile + the official docker-in-docker feature) that `devcontainer build` turns into a single image carrying the same `devcontainer.metadata` label contract universal:6 has today (privileged, `/usr/local/share/docker-init.sh` entrypoint, per-workspace dind volumes, `remoteUser: codespace`). A GitHub Actions workflow builds weekly/on-change, smoke-tests, and pushes date + `latest` tags to GHCR. Bats tests statically pin the cross-file invariants (tmux commit, daemon.json caps, feature/user contract). The blueprint `devcontainer.json` is NOT switched in this PR — that is rollout step 2, a follow-up PR pinning the first published digest.

**Tech Stack:** Dockerfile (multi-stage), `@devcontainers/cli` (build), devcontainers `docker-in-docker` feature, GitHub Actions, GHCR, bats.

## Global Constraints

- Image name: `ghcr.io/vossiman/devbox-base`; tags: UTC date (`2026-08-06`) + `latest`; platform **amd64 only**; target size **2–3GB** (smoke test fails above 4GB compressed-ish threshold, see Task 3).
- User: **`codespace`, uid 1000** — every blueprint mount targets `/home/codespace/...`.
- tmux built from pinned commit `b07424224b88fcc02bcb9b58d8655f00b97909c6` — MUST equal the `tmux_commit` pin in `lib/provision-system.sh` (`ensure_tmux`), and MUST write that hash to `/usr/local/share/aicoding/tmux-commit` so `ensure_tmux` no-ops.
- `/etc/docker/daemon.json` baked with `{"log-driver":"json-file","log-opts":{"max-size":"20m","max-file":"3"}}` — same caps as `ensure_dind_log_rotation`.
- Playwright's Chromium is NOT baked (stays provision-time). Go is NOT baked (`ensure_go` stays provision-time — resolves the spec's open question conservatively).
- No nvm/nvs anywhere in the image — Node comes from NodeSource apt. (The nvs `BASH_FUNC` breakage is a universal-only disease; do not reintroduce it.)
- Agent CLI seeds (claude, opencode, codex, cursor-agent) live in **user-owned `/home/codespace/.local/bin`** (not a root-owned system path): `lib/sync.sh` `_sync_binaries` refreshes via each CLI's *self-updater*, which must be able to write its install location; `ensure_*` in `lib/provision-system.sh` short-circuits when the binary is present there. Nothing may be seeded into mount-shadowed paths: `~/.claude`, `~/.codex`, `~/.cursor`, `~/.local/share/opencode`, `~/.aicodingsetup` are ALL host binds at runtime — content baked there is invisible.
- Tests: ALWAYS run via `bash tests/bats/run.sh` (never bare bats). New tests must be purely static (file inspection with jq/grep) — no network, no docker, no daemon starts, no writes into `$BLUEPRINT_ROOT`.
- All work commits to `feat/base-image-spec` in `devpod/aicoding`; integration is via PR — the PR is #48.

---

### Task 1: Static contracts — `image/daemon.json` + build `devcontainer.json` + first bats tests

**Files:**
- Create: `image/daemon.json`
- Create: `image/devcontainer.json`
- Test: `tests/bats/image.bats`

**Interfaces:**
- Produces: `image/daemon.json` (copied by Task 2's Dockerfile to `/etc/docker/daemon.json`); `image/devcontainer.json` (consumed by `devcontainer build` in Tasks 4/5).
- Note: the devcontainers `docker-in-docker` feature v4.0.0 `install.sh` never touches `/etc/docker/daemon.json` (verified 2026-08-06), so the Dockerfile-baked copy survives the feature layer, which is applied after the Dockerfile.

- [ ] **Step 1: Write the failing tests**

Create `tests/bats/image.bats`:

```bash
#!/usr/bin/env bats
#
# Static contracts for the custom base image (spec: 2026-08-06-custom-base-image-design).
# Everything here is file inspection — no docker, no network. The cross-file
# pins (tmux commit, daemon.json caps) exist so drifting one side breaks CI.

IMAGE_DIR="$BLUEPRINT_ROOT/image"

@test "image: daemon.json bakes the same log rotation caps as ensure_dind_log_rotation" {
  run jq -r '.["log-driver"] + " " + .["log-opts"]["max-size"] + " " + (.["log-opts"]["max-file"])' \
    "$IMAGE_DIR/daemon.json"
  [ "$status" -eq 0 ]
  [ "$output" = "json-file 20m 3" ]
}

@test "image: build devcontainer.json is valid JSON with dockerfile build" {
  run jq -r '.build.dockerfile' "$IMAGE_DIR/devcontainer.json"
  [ "$status" -eq 0 ]
  [ "$output" = "Dockerfile" ]
}

@test "image: build devcontainer.json uses the official docker-in-docker feature" {
  run jq -r '.features | keys[]' "$IMAGE_DIR/devcontainer.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ghcr.io/devcontainers/features/docker-in-docker"* ]]
}

@test "image: build devcontainer.json keeps user codespace (mount contract)" {
  run jq -r '.remoteUser + " " + .containerUser' "$IMAGE_DIR/devcontainer.json"
  [ "$status" -eq 0 ]
  [ "$output" = "codespace codespace" ]
}
```

Note on style: mirror `tests/bats/devcontainer.bats` — `$BLUEPRINT_ROOT` is exported by `tests/bats/run.sh`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/bats/run.sh tests/bats/image.bats`
Expected: 4 failures (missing files).

- [ ] **Step 3: Create `image/daemon.json`**

```json
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "20m", "max-file": "3" }
}
```

(Byte-for-byte the config `ensure_dind_log_rotation` writes at runtime — `lib/provision-system.sh:97-102`.)

- [ ] **Step 4: Create `image/devcontainer.json`**

```json
{
  "build": { "dockerfile": "Dockerfile" },
  "features": {
    "ghcr.io/devcontainers/features/docker-in-docker:2": {}
  },
  "remoteUser": "codespace",
  "containerUser": "codespace"
}
```

This is a *build config only* (input to `devcontainer build`), not the blueprint's runtime devcontainer.json. The feature contributes to the image's `devcontainer.metadata` label: `privileged: true`, `entrypoint: /usr/local/share/docker-init.sh`, and the `dind-var-lib-docker-${devcontainerId}` / `dind-var-lib-containerd-${devcontainerId}` volume mounts — byte-compatible with what universal:6's label carries today (verified via `docker buildx imagetools inspect` 2026-08-06), so the blueprint `devcontainer.json` will need only the image ref swapped in the rollout PR. The `:2` major-version range currently resolves to v4.x — the feature publishes only major tags 1/2 (2 is the moving latest).

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/bats/run.sh tests/bats/image.bats`
Expected: 4 passes.

- [ ] **Step 6: Commit**

```bash
git add tests/bats/image.bats image/daemon.json image/devcontainer.json
git commit -m "feat(image): daemon.json + build devcontainer config for devbox-base"
```

---

### Task 2: `image/Dockerfile`

**Files:**
- Create: `image/Dockerfile`
- Test: `tests/bats/image.bats` (append)

**Interfaces:**
- Consumes: `image/daemon.json` (Task 1).
- Produces: image filesystem contract relied on by smoke test (Task 3) and provisioning: binaries `git gh jq rg parallel bwrap tmux node npm python3 uv claude opencode codex` on PATH; `agent`+`cursor-agent` both resolvable; `/usr/local/share/aicoding/tmux-commit` containing the pin; `/etc/docker/daemon.json`; locales `de_AT.utf8` + `en_US.utf8`; user `codespace` uid 1000 with passwordless sudo.

- [ ] **Step 1: Append failing tests to `tests/bats/image.bats`**

```bash
@test "image: Dockerfile exists and builds from devcontainers/base:ubuntu" {
  run grep -E '^FROM mcr\.microsoft\.com/devcontainers/base:ubuntu' "$IMAGE_DIR/Dockerfile"
  [ "$status" -eq 0 ]
}

@test "image: Dockerfile tmux pin matches ensure_tmux's commit" {
  # Same commit in both places or artifact regressions return on one path.
  local df_commit lib_commit
  df_commit=$(grep -oE 'TMUX_COMMIT=[0-9a-f]{40}' "$IMAGE_DIR/Dockerfile" | head -1 | cut -d= -f2)
  lib_commit=$(grep -oE 'tmux_commit="[0-9a-f]{40}"' "$BLUEPRINT_ROOT/lib/provision-system.sh" | cut -d'"' -f2)
  [ -n "$df_commit" ]
  [ "$df_commit" = "$lib_commit" ]
}

@test "image: Dockerfile writes the tmux commit marker ensure_tmux checks" {
  run grep -F '/usr/local/share/aicoding/tmux-commit' "$IMAGE_DIR/Dockerfile"
  [ "$status" -eq 0 ]
}

@test "image: Dockerfile bakes daemon.json" {
  run grep -E 'COPY +daemon\.json +/etc/docker/daemon\.json' "$IMAGE_DIR/Dockerfile"
  [ "$status" -eq 0 ]
}

@test "image: Dockerfile renames uid-1000 user to codespace" {
  run grep -F 'usermod -l codespace vscode' "$IMAGE_DIR/Dockerfile"
  [ "$status" -eq 0 ]
}

@test "image: Dockerfile does not bake Playwright browsers or nvm" {
  run grep -iE 'playwright|nvm|nvs' "$IMAGE_DIR/Dockerfile"
  [ "$status" -ne 0 ]
}

@test "image: Dockerfile seeds no mount-shadowed path" {
  # ~/.codex, ~/.claude, ~/.cursor, ~/.local/share/opencode, ~/.aicodingsetup are
  # host binds at runtime; a seed left ONLY there would vanish. ~/.codex may be
  # used as an installer scratch dir but must be removed afterwards (rm -rf).
  if grep -qE '\.codex' "$IMAGE_DIR/Dockerfile"; then
    grep -qE 'rm -rf .*\.codex' "$IMAGE_DIR/Dockerfile"
  fi
}
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `bash tests/bats/run.sh tests/bats/image.bats`
Expected: Task 1 tests pass, new ones fail (no Dockerfile).

- [ ] **Step 3: Verify base image's uid-1000 username before writing the Dockerfile**

Run: `docker buildx imagetools inspect mcr.microsoft.com/devcontainers/base:ubuntu --format '{{json .Image.Config.Labels}}' | jq -r '.["devcontainer.metadata"]' | jq .`
Expected: metadata mentioning `common-utils` with user `vscode`. If the user is NOT `vscode`, adjust the `usermod` lines below to the actual name.

- [ ] **Step 4: Write `image/Dockerfile`**

```dockerfile
# devbox-base — purpose-built replacement for devcontainers/universal:6.
# Built by .github/workflows/build-base-image.yml via `devcontainer build`
# (see image/devcontainer.json: docker-in-docker feature layers on top of this).
# Spec: docs/superpowers/specs/2026-08-06-custom-base-image-design.md
#
# Invariant: image = stable substrate; agent CLIs baked here are SEED copies
# in user-owned ~/.local/bin — aicoding-sync --boot self-updates them in place.

# --- Stage 1: build tmux from the pinned commit -----------------------------
# Pin MUST match tmux_commit in lib/provision-system.sh (ensure_tmux);
# tests/bats/image.bats enforces it.
FROM mcr.microsoft.com/devcontainers/base:ubuntu AS tmux-build
ARG TMUX_COMMIT=b07424224b88fcc02bcb9b58d8655f00b97909c6
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential libevent-dev libncurses-dev pkg-config bison autoconf automake \
 && mkdir /tmp/tmux-src \
 && curl -fsSL "https://github.com/tmux/tmux/archive/${TMUX_COMMIT}.tar.gz" \
      | tar xz --strip-components=1 -C /tmp/tmux-src \
 && cd /tmp/tmux-src \
 && sh autogen.sh && ./configure --prefix=/usr/local \
 && make -j"$(nproc)" && make install DESTDIR=/tmp/tmux-out

# --- Stage 2: the image -----------------------------------------------------
FROM mcr.microsoft.com/devcontainers/base:ubuntu
ARG TMUX_COMMIT=b07424224b88fcc02bcb9b58d8655f00b97909c6

# Keep uid 1000 named codespace: every blueprint mount targets /home/codespace.
RUN usermod -l codespace vscode \
 && groupmod -n codespace vscode \
 && usermod -d /home/codespace -m codespace \
 && printf 'codespace ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/codespace \
 && chmod 0440 /etc/sudoers.d/codespace \
 && rm -f /etc/sudoers.d/vscode

# CLI staples auto_install_prereqs otherwise apt-installs per-container, plus
# gh (universal shipped it via feature) and tmux runtime libs.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      git jq ripgrep parallel bubblewrap kitty-terminfo locales \
      python3 python3-venv libevent-core-2.1-7t64 libncurses6 \
 && mkdir -p /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && printf 'deb [arch=amd64 signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# Node LTS via NodeSource apt — deliberately NOT nvm/nvs (universal's nvs
# BASH_FUNC exports are the single worst bug this image exists to bury).
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

# Locales ensure_locales otherwise generates per-container.
RUN sed -i 's/^# *de_AT.UTF-8/de_AT.UTF-8/; s/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen \
 && locale-gen

# tmux from the pinned build; commit marker makes ensure_tmux a no-op.
COPY --from=tmux-build /tmp/tmux-out/usr/local/ /usr/local/
RUN mkdir -p /usr/local/share/aicoding \
 && printf '%s\n' "${TMUX_COMMIT}" > /usr/local/share/aicoding/tmux-commit

# dind log rotation baked (supersedes ensure_dind_log_rotation's runtime write
# on this image; PR #47). The docker-in-docker feature layers after this
# Dockerfile and does not touch daemon.json (verified against feature v4.0.0).
COPY daemon.json /etc/docker/daemon.json

# --- Agent CLI seeds --------------------------------------------------------
# Seeds live in user-owned ~/.local/bin so `aicoding-sync --boot` can
# self-update them in place, and ensure_* provisioning short-circuits.
# NEVER seed into ~/.claude ~/.codex ~/.cursor ~/.local/share/opencode —
# those are host bind mounts at runtime; baked content there is invisible.
USER codespace
ENV HOME=/home/codespace
WORKDIR /home/codespace

RUN curl -fsSL https://claude.ai/install.sh | bash
RUN curl -fsSL https://opencode.ai/install | bash \
 && mkdir -p ~/.local/bin \
 && cp "$(readlink -f ~/.opencode/bin/opencode)" ~/.local/bin/opencode
RUN curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh \
 && mkdir -p ~/.local/bin \
 && { [ -x ~/.local/bin/codex ] || cp "$(readlink -f ~/.codex/bin/codex)" ~/.local/bin/codex; } \
 && rm -rf ~/.codex
RUN curl -fsSL https://cursor.com/install | bash \
 && cd ~/.local/bin \
 && { [ -e agent ] || ln -s cursor-agent agent; } \
 && { [ -e cursor-agent ] || ln -s agent cursor-agent; }

# uv (Python package manager) — installs to ~/.local/bin.
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

USER root
# Surface the seeds for non-interactive shells (postCreate/postStart run
# before the managed ~/.bashrc exists).
ENV PATH=/home/codespace/.local/bin:$PATH
USER codespace
```

Installer-layout caveats the implementer must know (each RUN must fail loudly, so verify during Task 5's real build):
- claude native installer → real install under `~/.local/`, entry point `~/.local/bin/claude` (matches `ensure_claude_code`'s check at `lib/provision-system.sh:151`).
- opencode installer → `~/.opencode/bin/opencode`; we COPY (not symlink) the resolved binary into `~/.local/bin` because `ensure_opencode` only symlinks, but a copy keeps working if the installer's directory layout changes. `~/.opencode` is NOT mount-shadowed, but the copy makes `~/.local/bin` self-contained.
- codex installer drop path is empirically uncertain (`~/.local/bin/codex` or `~/.codex/bin/codex` — see `ensure_codex`); handle both, then `rm -rf ~/.codex` because `~/.codex` IS mount-shadowed at runtime.
- cursor installer drops `agent` or `cursor-agent` in `~/.local/bin` (see `ensure_cursor_agent`); normalize so both names resolve. If the cursor installer errors in docker build (no tty), add `bash -s -- --quiet` style flags per its docs — resolve during Task 5's build, not by guessing.

- [ ] **Step 5: Run the static tests**

Run: `bash tests/bats/run.sh tests/bats/image.bats`
Expected: all pass. (The Dockerfile is only statically validated here; the real build happens in Tasks 4/5.)

- [ ] **Step 6: Commit**

```bash
git add image/Dockerfile tests/bats/image.bats
git commit -m "feat(image): Dockerfile for devbox-base (staples, tmux pin, node, CLI seeds)"
```

---

### Task 3: `image/smoke-test.sh`

**Files:**
- Create: `image/smoke-test.sh`
- Test: `tests/bats/image.bats` (append)

**Interfaces:**
- Consumes: a built image name as `$1`.
- Produces: `smoke-test.sh <image-ref>` exits 0 iff the image honors the filesystem contract; called by the workflow (Task 4) and the local build (Task 5).

- [ ] **Step 1: Append failing test**

```bash
@test "image: smoke-test.sh exists, is executable, and checks the core contract" {
  [ -x "$IMAGE_DIR/smoke-test.sh" ]
  run grep -c -E 'tmux-commit|daemon\.json|docker-init\.sh|codespace' "$IMAGE_DIR/smoke-test.sh"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/bats/run.sh tests/bats/image.bats`

- [ ] **Step 3: Write `image/smoke-test.sh`**

```bash
#!/usr/bin/env bash
# smoke-test.sh <image-ref> — assert the built devbox-base image honors the
# contract provisioning and the blueprint devcontainer.json rely on.
# Runs plain `docker run` checks first, then a privileged dind boot.
set -euo pipefail

IMG="${1:?usage: smoke-test.sh <image-ref>}"

fail=0
check() { # <desc> <cmd...>
  local desc="$1"; shift
  if docker run --rm --user codespace "$IMG" bash -lc "$*" >/dev/null 2>&1; then
    echo "ok:   $desc"
  else
    echo "FAIL: $desc  ($*)" >&2; fail=1
  fi
}

check "user codespace uid 1000"        '[ "$(id -un):$(id -u)" = codespace:1000 ]'
check "passwordless sudo"              'sudo -n true'
check "home is /home/codespace"        '[ "$HOME" = /home/codespace ]'
check "git"                            'command -v git'
check "gh"                             'command -v gh'
check "jq"                             'command -v jq'
check "ripgrep"                        'command -v rg'
check "GNU parallel (not moreutils)"   'parallel --version | head -1 | grep -q "GNU parallel"'
check "bubblewrap"                     'command -v bwrap'
check "kitty terminfo"                 'ls /usr/share/terminfo/x/xterm-kitty /etc/terminfo/x/xterm-kitty 2>/dev/null | grep -q .'
check "node + npm"                     'command -v node && command -v npm'
check "python3"                        'command -v python3'
check "uv seed"                        '[ -x ~/.local/bin/uv ]'
check "tmux runs (deps resolved)"      'tmux -V'
check "tmux commit marker matches"     '[ "$(cat /usr/local/share/aicoding/tmux-commit)" = b07424224b88fcc02bcb9b58d8655f00b97909c6 ]'
check "daemon.json log rotation baked" 'jq -e ".\"log-opts\".\"max-size\" == \"20m\"" /etc/docker/daemon.json'
check "docker-init.sh present"         '[ -x /usr/local/share/docker-init.sh ]'
check "claude seed"                    '[ -x ~/.local/bin/claude ]'
check "opencode seed"                  '[ -x ~/.local/bin/opencode ]'
check "codex seed"                     '[ -x ~/.local/bin/codex ]'
check "cursor-agent seed (both names)" '[ -x ~/.local/bin/agent ] && [ -x ~/.local/bin/cursor-agent ]'
check "no mount-shadowed codex seed"   '[ ! -e ~/.codex ]'
check "locales de_AT + en_US"          'locale -a | grep -qi de_AT.utf8 && locale -a | grep -qi en_US.utf8'
check "no nvs/nvm land mines"          '! ls /usr/local/nvs 2>/dev/null && ! ls /usr/local/share/nvs 2>/dev/null'

echo "-- dind boot (privileged) --"
if docker run --rm --privileged "$IMG" \
     /usr/local/share/docker-init.sh bash -c 'timeout 90 docker info >/dev/null && docker run --rm hello-world >/dev/null' \
     >/dev/null 2>&1; then
  echo "ok:   nested dockerd boots and runs a container"
else
  echo "FAIL: nested dockerd" >&2; fail=1
fi

size_bytes=$(docker image inspect "$IMG" --format '{{.Size}}')
echo "image size: $((size_bytes / 1024 / 1024)) MB"
if [ "$size_bytes" -gt $((4 * 1024 * 1024 * 1024)) ]; then
  echo "FAIL: image exceeds 4GB hard cap (spec target 2-3GB)" >&2; fail=1
fi

exit "$fail"
```

Then: `chmod +x image/smoke-test.sh`.

- [ ] **Step 4: Run static tests**

Run: `bash tests/bats/run.sh tests/bats/image.bats`
Expected: all pass. (`smoke-test.sh` itself is exercised for real in Tasks 4/5 — it is a build-pipeline tool, deliberately NOT run by bats: it needs docker + network, which the suite forbids.)

- [ ] **Step 5: Shellcheck it**

Run: `shellcheck image/smoke-test.sh` (if shellcheck is absent, skip — do not install anything for this).
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add image/smoke-test.sh tests/bats/image.bats
git commit -m "feat(image): smoke test asserting the image contract incl. dind boot"
```

---

### Task 4: GitHub Actions workflow

**Files:**
- Create: `.github/workflows/build-base-image.yml` (repo has no `.github/` yet — first workflow)
- Test: `tests/bats/image.bats` (append)

**Interfaces:**
- Consumes: `image/devcontainer.json` build config (Task 1), `image/smoke-test.sh` (Task 3).
- Produces: `ghcr.io/vossiman/devbox-base:{YYYY-MM-DD,latest}` on GHCR; the pushed digest printed in the job summary (input for the follow-up digest-pin PR).

- [ ] **Step 1: Append failing tests**

```bash
WORKFLOW="$BLUEPRINT_ROOT/.github/workflows/build-base-image.yml"

@test "image workflow: weekly cron + manual dispatch + image-path triggers" {
  [ -f "$WORKFLOW" ]
  grep -qE 'cron:' "$WORKFLOW"
  grep -q 'workflow_dispatch' "$WORKFLOW"
  grep -q 'image/' "$WORKFLOW"
}

@test "image workflow: pushes ghcr.io/vossiman/devbox-base and runs the smoke test" {
  grep -q 'ghcr.io/vossiman/devbox-base' "$WORKFLOW"
  grep -q 'smoke-test.sh' "$WORKFLOW"
  grep -q 'packages: write' "$WORKFLOW"
}

@test "image workflow: PR builds never push" {
  # push is gated so pull_request builds only validate
  grep -qE "github.event_name != 'pull_request'" "$WORKFLOW"
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/bats/run.sh tests/bats/image.bats`

- [ ] **Step 3: Write `.github/workflows/build-base-image.yml`**

```yaml
# Build & publish ghcr.io/vossiman/devbox-base — the custom devcontainer base
# image (spec: docs/superpowers/specs/2026-08-06-custom-base-image-design.md).
# Weekly so the baked CLI seeds stay <=7 days stale; on-change for image/ PRs
# (build+smoke only, no push); manual dispatch for out-of-band rebuilds.
name: build-base-image

on:
  schedule:
    - cron: "17 5 * * 1" # Mondays 05:17 UTC
  workflow_dispatch:
  push:
    branches: [main]
    paths:
      - "image/**"
      - ".github/workflows/build-base-image.yml"
  pull_request:
    paths:
      - "image/**"
      - ".github/workflows/build-base-image.yml"

permissions:
  contents: read
  packages: write

env:
  IMAGE: ghcr.io/vossiman/devbox-base

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Log in to GHCR
        if: github.event_name != 'pull_request'
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build image (Dockerfile + devcontainer features)
        run: |
          DATE_TAG="$(date -u +%Y-%m-%d)"
          echo "DATE_TAG=$DATE_TAG" >> "$GITHUB_ENV"
          npx -y @devcontainers/cli@0.80.0 build \
            --workspace-folder image \
            --platform linux/amd64 \
            --image-name "$IMAGE:$DATE_TAG" \
            --image-name "$IMAGE:latest"

      - name: Smoke test
        run: bash image/smoke-test.sh "$IMAGE:$DATE_TAG"

      - name: Push
        if: github.event_name != 'pull_request'
        run: |
          docker push "$IMAGE:$DATE_TAG"
          docker push "$IMAGE:latest"
          DIGEST="$(docker buildx imagetools inspect "$IMAGE:$DATE_TAG" --format '{{json .Manifest}}' | jq -r .digest)"
          {
            echo "## devbox-base published"
            echo '```'
            echo "$IMAGE:$DATE_TAG"
            echo "$IMAGE@$DIGEST"
            echo '```'
            echo "Pin the blueprint with the digest ref above (rollout step 2)."
          } >> "$GITHUB_STEP_SUMMARY"
```

Notes for the implementer:
- `@devcontainers/cli` is pinned (`0.80.0` — verify it is the current release with `npm view @devcontainers/cli version` and pin whatever that returns; do not float `latest` in CI).
- `GITHUB_TOKEN` can create/push the `devbox-base` package because it lives in the same `vossiman` namespace; the first push creates the package (private by default — after the first publish, link it to the repo/make visibility decisions in the GHCR UI; note this in image/README.md).
- GHA `ubuntu-latest` runners allow `--privileged` docker, so the dind smoke check runs for real.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/bats/run.sh tests/bats/image.bats`
Expected: all pass.

- [ ] **Step 5: Validate workflow YAML parses**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/build-base-image.yml'))"`
Expected: exit 0. (If PyYAML is missing: `python3 -c "import json"`-style fallback is NOT acceptable — instead run `npx -y yaml-lint .github/workflows/build-base-image.yml` or skip with a note; do not apt-install anything.)

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/build-base-image.yml tests/bats/image.bats
git commit -m "ci(image): weekly GHCR build+smoke+push workflow for devbox-base"
```

---

### Task 5: Real local build + smoke test (validation gate)

The static tests cannot catch a wrong installer URL or a broken feature layer. Build the image for real with the nested docker daemon of this devbox before pushing the branch. This is the step that empirically resolves every "verify during real build" note from Task 2.

**Files:** none created (build only; fix-forward edits to `image/*` as needed).

- [ ] **Step 1: Check disk headroom first (2026-08-05 incident: host hit 0 bytes free)**

Run: `df -h /var/lib/docker /`
Proceed only with ≥15GB free. If short, stop and report — do not prune anything without asking.

- [ ] **Step 2: Build**

Run: `cd devpod/aicoding && npx -y @devcontainers/cli@<pinned-version> build --workspace-folder image --image-name devbox-base:local 2>&1 | tail -40`
Expected: successful build. Iterate on `image/Dockerfile` for any installer that behaves differently under docker build (no tty) than documented — each fix is a normal edit+rebuild loop; docker layer cache makes retries cheap.

- [ ] **Step 3: Smoke test**

Run: `bash image/smoke-test.sh devbox-base:local`
Expected: every `ok:` line, dind boot ok, size ≤ 4GB (target 2–3GB — if over target but under cap, note the number; if over 4GB, investigate the biggest layers via `docker history devbox-base:local`).

- [ ] **Step 4: Commit any fixes**

```bash
git add image/
git commit -m "fix(image): adjust for real-build findings (installer flags/paths)"
```

(Skip the commit if the build passed unchanged.)

- [ ] **Step 5: Clean up local build artifacts**

Run: `docker rmi devbox-base:local && docker builder prune -f --filter until=1h`
(Only these — never `docker system prune` on the devbox.)

---

### Task 6: Spec amendment + `image/README.md` runbook

**Files:**
- Modify: `docs/superpowers/specs/2026-08-06-custom-base-image-design.md`
- Create: `image/README.md`

- [ ] **Step 1: Amend the spec**

In `docs/superpowers/specs/2026-08-06-custom-base-image-design.md`:

1. `**Status:** design — draft, for review.` → `**Status:** accepted — implementation on this branch (see docs/superpowers/plans/2026-08-06-custom-base-image.md).`
2. In **Decisions**, replace the dind bullet's mechanism wording: `docker-in-docker: docker-ce + the moby dind init script` → `docker-in-docker: the official devcontainers docker-in-docker feature (the exact mechanism universal:6 uses), applied at build time via devcontainer build — same /usr/local/share/docker-init.sh entrypoint, privileged flag, and per-workspace /var/lib/docker volumes via the image's devcontainer.metadata label` (keep the daemon.json sentence).
3. Replace the seed-CLI bullet: `preinstalled to a system path as seed copies; first aicoding-sync --boot refresh shadows them in ~/.local/bin` → `preinstalled as seed copies directly in user-owned ~/.local/bin — the CLIs' self-updaters (driven by aicoding-sync --boot's _sync_binaries) update them in place, and ensure_* provisioning short-circuits on their presence; nothing is seeded into mount-shadowed paths (~/.claude, ~/.codex, ~/.cursor, ~/.local/share/opencode)`.
4. Resolve **Open questions** in place (change the section title to `## Resolved questions (2026-08-06)`):
   - Go: not baked; `ensure_go` stays provision-time (~30s curl+tar). Revisit only if a workspace's inner loop compiles Go.
   - Cadence: weekly (Mon 05:17 UTC) + on-change + manual dispatch; seeds ≤7 days stale.
   - Repo: this repo, `image/` + `.github/workflows/build-base-image.yml`.

- [ ] **Step 2: Write `image/README.md`**

```markdown
# devbox-base image

Purpose-built base image replacing `devcontainers/universal:6`
(spec: `../docs/superpowers/specs/2026-08-06-custom-base-image-design.md`).

- `Dockerfile` — staples, tmux pin, Node, locales, agent-CLI seeds.
- `devcontainer.json` — build config only; adds the docker-in-docker feature
  so the image carries universal-compatible `devcontainer.metadata`.
- `daemon.json` — baked dind log rotation (20m × 3).
- `smoke-test.sh <ref>` — contract assertions incl. a privileged dind boot.

## Build & release

CI (`.github/workflows/build-base-image.yml`) builds weekly (Mon 05:17 UTC),
on any `image/**` change (PRs: build+smoke only), and on manual dispatch;
pushes `ghcr.io/vossiman/devbox-base:{YYYY-MM-DD,latest}` and prints the
digest in the job summary.

Local build (needs ~15GB free docker disk):

    npx -y @devcontainers/cli@<pinned> build --workspace-folder image --image-name devbox-base:local
    bash image/smoke-test.sh devbox-base:local

## Rollout (per spec)

1. First publish happens when this lands on `main` (or via dispatch).
   One-time: make the GHCR package public / link it to this repo in the UI.
2. Follow-up PR: point the blueprint `devcontainer.json` at
   `ghcr.io/vossiman/devbox-base@sha256:…` (digest from the job summary)
   and update `tests/bats/devcontainer.bats` accordingly.
3. Recreate rides: dataenv first, then financepdfs. Verify dind, CLI boot
   refresh, and surviving logins per the spec's acceptance criteria.
4. Digest bumps = ordinary PRs editing the ref.

## Cross-file pins (enforced by tests/bats/image.bats)

- `TMUX_COMMIT` here == `tmux_commit` in `lib/provision-system.sh`.
- `daemon.json` == what `ensure_dind_log_rotation` would write.
```

- [ ] **Step 3: Run the full suite**

Run: `bash tests/bats/run.sh`
Expected: everything green (~70s). Fix anything the new files broke before committing.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-08-06-custom-base-image-design.md image/README.md docs/superpowers/plans/2026-08-06-custom-base-image.md
git commit -m "docs(image): resolve spec open questions, add build/rollout runbook + plan"
```

---

### Task 7: Push and update PR #48

- [ ] **Step 1: Push the branch**

Run: `git push origin feat/base-image-spec`

- [ ] **Step 2: Retitle + re-describe the PR (it was docs-only; now it implements)**

```bash
gh pr edit 48 --repo vossiman/aiCodingBaseSetup \
  --title "feat: custom devcontainer base image (spec + implementation)" \
  --body "$(cat <<'EOF'
Spec + implementation for replacing `universal:6` (~15GB) with the purpose-built,
digest-pinned `ghcr.io/vossiman/devbox-base` (~2–3GB).

**Spec:** `docs/superpowers/specs/2026-08-06-custom-base-image-design.md` (open questions resolved in-place)
**Plan:** `docs/superpowers/plans/2026-08-06-custom-base-image.md`

**Implementation:**
- `image/Dockerfile` — base:ubuntu + user `codespace` (uid 1000), apt staples, Node LTS (NodeSource, no nvm), locales, tmux from the `ensure_tmux` pinned commit (+ commit marker so provisioning no-ops), baked dind `daemon.json` log rotation (supersedes #47 on this image), agent-CLI seeds in user-owned `~/.local/bin`
- `image/devcontainer.json` — build config adding the official docker-in-docker feature, so the image carries the same `devcontainer.metadata` contract universal:6 has (privileged, docker-init entrypoint, per-workspace dind volumes, remoteUser codespace)
- `image/smoke-test.sh` — contract assertions incl. privileged dind boot + 4GB size cap
- `.github/workflows/build-base-image.yml` — weekly + on-change + dispatch; PR builds don't push; digest in job summary
- `tests/bats/image.bats` — static cross-file pins (tmux commit ↔ ensure_tmux, daemon.json ↔ ensure_dind_log_rotation, mount-shadow guard)

**Not in this PR (rollout step 2, needs the first published digest):** switching the blueprint `devcontainer.json` image ref.

Verified: full bats suite green; local `devcontainer build` + smoke test pass (incl. nested dockerd boot).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Report back** — suite results, local build/smoke outcome, image size number, and the PR link. Ask before merging (protected `main`).

---

## Self-review notes

- Spec coverage: contents ✔ (Task 2), pipeline ✔ (Task 4), blueprint digest pin — explicitly out of scope per rollout ordering (documented in README + PR body), provisioning simplification — explicitly a follow-up per spec ("gated on image adoption"), rollout runbook ✔ (Task 6).
- The `:2` feature tag in Task 1 vs "v4.0.0" note: the feature repo publishes major tag `2` as its moving pointer; the resolved version observed 2026-08-06 was 4.0.0 via raw main. Implementer: if `devcontainer build` logs show the feature resolving < 4.x, bump the tag spec accordingly.
- Type consistency: image name `ghcr.io/vossiman/devbox-base`, marker path `/usr/local/share/aicoding/tmux-commit`, and the tmux commit hash are identical across Tasks 1–6.
