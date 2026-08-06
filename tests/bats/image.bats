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
