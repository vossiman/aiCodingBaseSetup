#!/usr/bin/env bats
#
# The canonical devcontainer.json (spec #2: devcontainer dedup). aicoding owns
# the one true devcontainer.json — verified bootstrap provisioning + generic mounts.
# Host state lives under ~/devpod/<name>; DevPod resolves ${localEnv:HOME} on
# the host at provision time, so the same file is portable across hosts.

DEVCONTAINER="$BLUEPRINT_ROOT/devcontainer.json"

@test "devcontainer.json: exists" {
  [ -f "$DEVCONTAINER" ]
}

@test "devcontainer.json: is valid JSON (jsonc comments tolerated)" {
  # jq is strict JSON; the canonical file must parse as plain JSON so any
  # consumer (jq, devpod, a raw fetch) reads it without a jsonc preprocessor.
  run jq empty "$DEVCONTAINER"
  [ "$status" -eq 0 ]
}

@test "devcontainer.json: carries all six generic \${localEnv:HOME}/devpod bind mounts" {
  local mounts
  mounts=$(jq -r '.mounts[]' "$DEVCONTAINER")

  for spec in \
    'source=${localEnv:HOME}/devpod/aicodingsetup,target=/home/codespace/.aicodingsetup,type=bind' \
    'source=${localEnv:HOME}/devpod/claude,target=/home/codespace/.claude,type=bind' \
    'source=${localEnv:HOME}/devpod/opencode,target=/home/codespace/.local/share/opencode,type=bind' \
    'source=${localEnv:HOME}/devpod/codex,target=/home/codespace/.codex,type=bind' \
    'source=${localEnv:HOME}/devpod/cursor,target=/home/codespace/.cursor,type=bind' \
    'source=${localEnv:HOME}/devpod/uv,target=/home/codespace/.local/share/uv,type=bind'
  do
    [[ "$mounts" == *"$spec"* ]] || {
      echo "missing mount: $spec"
      echo "actual mounts:"
      echo "$mounts"
      return 1
    }
  done
}

@test "devcontainer.json: overlays .secrets.env read-only on top of the rw dir mount" {
  local mounts
  mounts=$(jq -r '.mounts[]' "$DEVCONTAINER")
  local overlay='source=${localEnv:HOME}/devpod/aicodingsetup/.secrets.env,target=/home/codespace/.aicodingsetup/.secrets.env,type=bind,readonly'
  [[ "$mounts" == *"$overlay"* ]] || {
    echo "missing read-only overlay mount for .secrets.env"
    echo "actual mounts:"
    echo "$mounts"
    return 1
  }

  # Docker applies mounts in order: the single-file readonly bind must come
  # AFTER the directory bind to stack on top of it.
  local dir_idx overlay_idx
  dir_idx=$(jq -r '.mounts | to_entries[] | select(.value | contains("/devpod/aicodingsetup,")) | .key' "$DEVCONTAINER")
  overlay_idx=$(jq -r '.mounts | to_entries[] | select(.value | contains(".secrets.env")) | .key' "$DEVCONTAINER")
  [ -n "$dir_idx" ] && [ -n "$overlay_idx" ] && [ "$overlay_idx" -gt "$dir_idx" ]
}

@test "devcontainer.json: mounts use generic HOME, not a hardcoded host path" {
  run grep -q "/home/vossi/devpod" "$DEVCONTAINER"
  [ "$status" -ne 0 ]
}

@test "devcontainer.json: pins devbox-base by digest (not a floating tag, not universal)" {
  local image
  image=$(jq -r '.image' "$DEVCONTAINER")
  [[ "$image" == ghcr.io/vossiman/devbox-base@sha256:* ]] || {
    echo "image is not a digest-pinned devbox-base ref: $image"
    return 1
  }
  # 64 hex chars after sha256: — a truncated digest would fail the pull.
  [[ "$image" =~ @sha256:[0-9a-f]{64}$ ]]
}

@test "devcontainer.json: provisions through the embedded reviewed verifier" {
  local post_create
  post_create=$(jq -r '.postCreateCommand' "$DEVCONTAINER")
  [[ "$post_create" == *"mktemp -d"* ]]
  [[ "$post_create" == *"base64 -d"* ]]
  [[ "$post_create" == *"--profile container"* ]]
  [[ "$post_create" != *"raw.githubusercontent.com"* ]]
  [[ "$post_create" != *"git clone"* ]]
}

@test "devcontainer.json: sets the workspace-name hostname via runArgs" {
  run jq -r '.runArgs | join(" ")' "$DEVCONTAINER"
  [ "$status" -eq 0 ]
  [ "$output" = '--hostname ${containerWorkspaceFolderBasename}' ]
}

@test "devcontainer startup calls the physical runtime hook and tolerates missing enrollment" {
  local scratch command
  scratch=$(mktemp -d)
  command=$(jq -r '.postStartCommand' "$DEVCONTAINER")
  run env HOME="$scratch" AICODING_DATA_DIR="$scratch/data" bash -c "$command"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not enrolled"* ]]
  mkdir -p "$scratch/data/versions/aicoding/fixture" "$scratch/data/current"
  printf 'printf "%%s\\n" "$0" > "$HOME/startup-path"\n' \
    > "$scratch/data/versions/aicoding/fixture/on-start.sh"
  ln -s ../versions/aicoding/fixture "$scratch/data/current/aicoding"
  run env HOME="$scratch" AICODING_DATA_DIR="$scratch/data" bash -c "$command"
  [ "$status" -eq 0 ]
  [ "$(cat "$scratch/startup-path")" = "$scratch/data/versions/aicoding/fixture/on-start.sh" ]
  rm -rf "$scratch"
}
