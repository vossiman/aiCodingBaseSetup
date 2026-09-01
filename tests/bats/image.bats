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
  run jq -e '.features["ghcr.io/devcontainers/features/docker-in-docker:2"]' "$IMAGE_DIR/devcontainer.json"
  [ "$status" -eq 0 ]
}

@test "image: build devcontainer.json keeps user codespace (mount contract)" {
  run jq -r '.remoteUser + " " + .containerUser' "$IMAGE_DIR/devcontainer.json"
  [ "$status" -eq 0 ]
  [ "$output" = "codespace codespace" ]
}

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

@test "image: codex seed carries its code-mode sidecar" {
  # Flattening the codex symlink drops the release layout, so the sidecar
  # `codex-code-mode-host` must be copied next to the binary and asserted.
  # Seeding `codex` alone ships a codex whose Code Mode fails closed
  # ("host executable was not found", 2026-08-12).
  grep -qF 'cp "$codex_host" ~/.local/bin/codex-code-mode-host' "$IMAGE_DIR/Dockerfile"
  grep -qF '[ -x ~/.local/bin/codex-code-mode-host ]' "$IMAGE_DIR/Dockerfile"
  grep -qF 'codex-code-mode-host' "$IMAGE_DIR/smoke-test.sh"
}

@test "image: smoke-test.sh exists, is executable, and checks the core contract" {
  [ -x "$IMAGE_DIR/smoke-test.sh" ]
  run grep -c -E 'tmux-commit|daemon\.json|docker-init\.sh|codespace' "$IMAGE_DIR/smoke-test.sh"
  [ "$status" -eq 0 ]
}

@test "image: smoke-test.sh proves the DEVBOX_BASE_SHA build arg reached the image" {
  # Nothing else catches a silently-empty build arg: the image would ship
  # {"sha":""}, aicoding-status' _image_sha returns empty, _behind_paths fails
  # open, and the ⬆rebuild badge is dead forever with no signal.
  grep -q '/etc/devbox-base-release' "$IMAGE_DIR/smoke-test.sh"
  # …and it must assert the sha is non-empty, not merely that the file exists.
  grep -qE '\.sha.*length > 0' "$IMAGE_DIR/smoke-test.sh"
}

@test "image workflow: on-change + manual dispatch triggers, no schedule" {
  WORKFLOW="$BLUEPRINT_ROOT/.github/workflows/build-base-image.yml"
  [ -f "$WORKFLOW" ]
  # No scheduled builds: seeds self-update at boot, so a cron only churns
  # tags (decision 2026-08-09, see workflow header).
  run grep -qE '^[[:space:]]*(- )?(schedule|cron):' "$WORKFLOW"
  [ "$status" -ne 0 ]
  grep -q 'workflow_dispatch' "$WORKFLOW"
  grep -q 'image/' "$WORKFLOW"
}

@test "image workflow: pushes ghcr.io/vossiman/devbox-base and runs the smoke test" {
  WORKFLOW="$BLUEPRINT_ROOT/.github/workflows/build-base-image.yml"
  grep -q 'ghcr.io/vossiman/devbox-base' "$WORKFLOW"
  grep -q 'smoke-test.sh' "$WORKFLOW"
  grep -q 'packages: write' "$WORKFLOW"
}

@test "image workflow: PR builds never push" {
  WORKFLOW="$BLUEPRINT_ROOT/.github/workflows/build-base-image.yml"
  grep -qE "github.event_name != 'pull_request'" "$WORKFLOW"
}

@test "image workflow: build step passes --config image/devcontainer.json" {
  WORKFLOW="$BLUEPRINT_ROOT/.github/workflows/build-base-image.yml"
  grep -qF -- '--config image/devcontainer.json' "$WORKFLOW"
}

@test "image workflow: auto-pins the blueprint after publish (non-PR only)" {
  WORKFLOW="$BLUEPRINT_ROOT/.github/workflows/build-base-image.yml"
  # Push permission for the pin commit
  grep -q 'contents: write' "$WORKFLOW"
  # The pin step: sed rewrite of the digest + the commit message contract
  grep -qF 'sha256:[0-9a-f]{64}' "$WORKFLOW"
  grep -qF 'chore(image): pin devbox-base' "$WORKFLOW"
  # Loud failure is the contract — no silent fallback wording
  run grep -qiE 'continue-on-error: *true' "$WORKFLOW"
  [ "$status" -ne 0 ]
  # Gate appears on login, push, AND pin steps
  [ "$(grep -c "github.event_name != 'pull_request'" "$WORKFLOW")" -ge 3 ]
}

@test "image: Dockerfile points npm's global prefix at user space" {
  # NodeSource npm defaults to root-owned /usr/lib; without this,
  # install_mcp_packages' unprivileged npm -g fails on every container.
  run grep -E '^ENV NPM_CONFIG_PREFIX=/home/codespace/\.local$' "$IMAGE_DIR/Dockerfile"
  [ "$status" -eq 0 ]
}

@test "image: Dockerfile sets Vienna timezone" {
  grep -qE '^ENV TZ=Europe/Vienna$' "$IMAGE_DIR/Dockerfile"
  grep -qF '/usr/share/zoneinfo/Europe/Vienna /etc/localtime' "$IMAGE_DIR/Dockerfile"
}

@test "image bakes /etc/devbox-base-release and CI wires the sha build-arg" {
  grep -q 'ARG DEVBOX_BASE_SHA' "$BLUEPRINT_ROOT/image/Dockerfile"
  grep -q '/etc/devbox-base-release' "$BLUEPRINT_ROOT/image/Dockerfile"
  grep -q 'DEVBOX_BASE_SHA.*localEnv:DEVBOX_BASE_SHA' "$BLUEPRINT_ROOT/image/devcontainer.json"
  grep -q 'DEVBOX_BASE_SHA:.*github.sha' "$BLUEPRINT_ROOT/.github/workflows/build-base-image.yml"
}

@test "every workflow action is pinned to a full commit SHA" {
  local bad
  bad=$(grep -rhoE '^\s*(- )?uses:\s*\S+' "$BLUEPRINT_ROOT/.github/workflows" \
        | grep -vE 'uses:\s*\S+@[0-9a-f]{40}$' || true)
  [ -z "$bad" ]
}

@test "no workflow grants write permission at workflow scope" {
  # Workflow-scope writes apply to every job, including ones that only build.
  # Writes belong on the single job that needs them.
  local f
  for f in "$BLUEPRINT_ROOT"/.github/workflows/*.yml; do
    run awk '/^jobs:/{exit} /^permissions:/{p=1;next} p&&/^[^ ]/{p=0} p&&/write/{print FILENAME": "$0}' "$f"
    [ -z "$output" ]
  done
}

@test "renovate config raises no scheduled PRs" {
  run jq -e '.extends | index("config:best-practices")' "$BLUEPRINT_ROOT/renovate.json"
  [ "$status" -eq 0 ]
  # The closed PR #94 was rejected for weekly PR noise. A schedule key or an
  # enabled non-security update set brings that back.
  run jq -e 'has("schedule")' "$BLUEPRINT_ROOT/renovate.json"
  [ "$status" -ne 0 ]
  run jq -e '.vulnerabilityAlerts.enabled == true' "$BLUEPRINT_ROOT/renovate.json"
  [ "$status" -eq 0 ]
}

@test "renovate never automerges: no rule may set automerge true" {
  # This repo has no branch protection (verified 2026-08-31), so an
  # automerged digest bump lands a compromised upstream tag on main with no
  # human in the loop — which undoes the SHA pinning in .github/workflows.
  run jq -e '[.packageRules[] | select(.automerge == true)] | length == 0' \
    "$BLUEPRINT_ROOT/renovate.json"
  echo "$output"
  [ "$status" -eq 0 ]
  run jq -e 'has("automerge") and .automerge == true' "$BLUEPRINT_ROOT/renovate.json"
  [ "$status" -ne 0 ]
}

@test "renovate config uses matchPackageNames, not the deprecated patterns key" {
  # renovate-config-validator only accepted matchPackagePatterns because
  # Renovate auto-migrates it; the migration prints matchPackageNames.
  run grep -c 'matchPackagePatterns' "$BLUEPRINT_ROOT/renovate.json"
  [ "$status" -eq 1 ]
}

@test "renovate workflow has no cron trigger" {
  run grep -c 'schedule:' "$BLUEPRINT_ROOT/.github/workflows/renovate.yml"
  [ "$status" -eq 1 ]
}
