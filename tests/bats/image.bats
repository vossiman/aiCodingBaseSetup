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

@test "image: smoke-test.sh exists, is executable, and checks the core contract" {
  [ -x "$IMAGE_DIR/smoke-test.sh" ]
  run grep -c -E 'tmux-commit|daemon\.json|docker-init\.sh|codespace' "$IMAGE_DIR/smoke-test.sh"
  [ "$status" -eq 0 ]
}
