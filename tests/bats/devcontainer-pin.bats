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
