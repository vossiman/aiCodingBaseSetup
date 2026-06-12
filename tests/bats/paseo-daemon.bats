#!/usr/bin/env bats

setup() {
  : "${BLUEPRINT_ROOT:?unset — run via tests/bats/run.sh}"
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "paseo config template exists in blueprint and disables voice" {
  [ -f "$BLUEPRINT_ROOT/configs/paseo/config.json" ]
  run jq -r '.features.dictation.enabled, .features.voiceMode.enabled' \
    "$BLUEPRINT_ROOT/configs/paseo/config.json"
  [ "$status" -eq 0 ]
  [ "$output" = "false
false" ]
}

@test "paseo config template registers cursor ACP provider" {
  run jq -r '.agents.providers.cursor.command | join(" ")' \
    "$BLUEPRINT_ROOT/configs/paseo/config.json"
  [ "$status" -eq 0 ]
  [ "$output" = "cursor-agent acp" ]
}

@test "managed inventory deploys paseo template to fixed path" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run managed_inventory_overwrite
  [[ "$output" == *"$HOME/.aicodingsetup/templates/paseo-config.json|overwrite|configs/paseo/config.json"* ]]
}
