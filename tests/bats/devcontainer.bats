#!/usr/bin/env bats
#
# The canonical devcontainer.json (spec #2: devcontainer dedup). aicoding owns
# the one true devcontainer.json — clone-based provisioning + generic mounts.
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

@test "devcontainer.json: carries all five generic \${localEnv:HOME}/devpod bind mounts" {
  local mounts
  mounts=$(jq -r '.mounts[]' "$DEVCONTAINER")

  for spec in \
    'source=${localEnv:HOME}/devpod/aicodingsetup,target=/home/codespace/.aicodingsetup,type=bind' \
    'source=${localEnv:HOME}/devpod/claude,target=/home/codespace/.claude,type=bind' \
    'source=${localEnv:HOME}/devpod/opencode,target=/home/codespace/.local/share/opencode,type=bind' \
    'source=${localEnv:HOME}/devpod/codex,target=/home/codespace/.codex,type=bind' \
    'source=${localEnv:HOME}/devpod/cursor,target=/home/codespace/.cursor,type=bind'
  do
    [[ "$mounts" == *"$spec"* ]] || {
      echo "missing mount: $spec"
      echo "actual mounts:"
      echo "$mounts"
      return 1
    }
  done
}

@test "devcontainer.json: mounts use generic HOME, not a hardcoded host path" {
  run grep -q "/home/vossi/devpod" "$DEVCONTAINER"
  [ "$status" -ne 0 ]
}

@test "devcontainer.json: provisions by cloning aiCodingBaseSetup (clone-based, not submodule)" {
  local post_create
  post_create=$(jq -r '.postCreateCommand' "$DEVCONTAINER")
  [[ "$post_create" == *"git clone"* ]]
  [[ "$post_create" == *"aiCodingBaseSetup"* ]]
  [[ "$post_create" == *"install.sh"* ]]
}

@test "devcontainer.json: sets the workspace-name hostname via runArgs (paseo host labels)" {
  run jq -r '.runArgs | join(" ")' "$DEVCONTAINER"
  [ "$status" -eq 0 ]
  [ "$output" = '--hostname ${containerWorkspaceFolderBasename}' ]
}
