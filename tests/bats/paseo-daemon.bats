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
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "$HOME/.aicodingsetup/templates/paseo-config.json|overwrite|configs/paseo/config.json"
}

_install_paseo_stub() {        # records daemon-start calls, fakes pair output
  mkdir -p "$TMPDIR/stubs"
  cat > "$TMPDIR/stubs/paseo" <<'EOS'
#!/bin/sh
echo "$@" >> "${PASEO_STUB_LOG:?}"
case "$1 $2" in
  "daemon start")  exit 0 ;;
  "daemon pair")   echo "QR-CODE-HERE"; echo "https://app.paseo.sh/#offer=test"; exit 0 ;;
esac
exit 0
EOS
  chmod +x "$TMPDIR/stubs/paseo"
  export PATH="$TMPDIR/stubs:$PATH"
  export PASEO_STUB_LOG="$TMPDIR/paseo-calls.log"
  : > "$PASEO_STUB_LOG"
}

@test "print-home uses DEVPOD_WORKSPACE_ID when set" {
  export DEVPOD_WORKSPACE_ID=myws
  run "$BLUEPRINT_ROOT/bin/aicoding-paseo-daemon" --print-home
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/.aicodingsetup/paseo/myws" ]
}

@test "print-home falls back to /workspaces basename" {
  unset DEVPOD_WORKSPACE_ID
  mkdir -p "$TMPDIR/workspaces/fallbackws"
  AICODING_WORKSPACES_DIR="$TMPDIR/workspaces" \
    run "$BLUEPRINT_ROOT/bin/aicoding-paseo-daemon" --print-home
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/.aicodingsetup/paseo/fallbackws" ]
}

@test "print-home fails closed when workspace cannot be derived" {
  unset DEVPOD_WORKSPACE_ID
  AICODING_WORKSPACES_DIR="$TMPDIR/empty-nonexistent" \
    run "$BLUEPRINT_ROOT/bin/aicoding-paseo-daemon" --print-home
  [ "$status" -ne 0 ]
}

@test "ensure seeds config from template and starts daemon" {
  _install_paseo_stub
  export DEVPOD_WORKSPACE_ID=myws
  mkdir -p "$HOME/.aicodingsetup/templates"
  cp "$BLUEPRINT_ROOT/configs/paseo/config.json" "$HOME/.aicodingsetup/templates/paseo-config.json"
  run "$BLUEPRINT_ROOT/bin/aicoding-paseo-daemon" --ensure
  [ "$status" -eq 0 ]
  [ -f "$HOME/.aicodingsetup/paseo/myws/config.json" ]
  diff "$HOME/.aicodingsetup/paseo/myws/config.json" "$HOME/.aicodingsetup/templates/paseo-config.json"
  grep -q "daemon start" "$PASEO_STUB_LOG"
}

@test "ensure is a no-op start when daemon already running" {
  _install_paseo_stub
  export DEVPOD_WORKSPACE_ID=myws
  mkdir -p "$HOME/.aicodingsetup/templates" "$HOME/.aicodingsetup/paseo/myws"
  cp "$BLUEPRINT_ROOT/configs/paseo/config.json" "$HOME/.aicodingsetup/templates/paseo-config.json"
  printf '{"pid":%s,"startedAt":"x"}' "$$" > "$HOME/.aicodingsetup/paseo/myws/paseo.pid"
  run "$BLUEPRINT_ROOT/bin/aicoding-paseo-daemon" --ensure
  [ "$status" -eq 0 ]
  run grep -q "daemon start" "$PASEO_STUB_LOG"
  [ "$status" -ne 0 ]
}

@test "ensure overwrites config when template changed" {
  _install_paseo_stub
  export DEVPOD_WORKSPACE_ID=myws
  mkdir -p "$HOME/.aicodingsetup/templates"
  cp "$BLUEPRINT_ROOT/configs/paseo/config.json" "$HOME/.aicodingsetup/templates/paseo-config.json"
  "$BLUEPRINT_ROOT/bin/aicoding-paseo-daemon" --ensure
  echo '{"version":1,"changed":true}' > "$HOME/.aicodingsetup/templates/paseo-config.json"
  "$BLUEPRINT_ROOT/bin/aicoding-paseo-daemon" --ensure
  grep -q changed "$HOME/.aicodingsetup/paseo/myws/config.json"
}

@test "ensure fails open when paseo binary is absent" {
  export DEVPOD_WORKSPACE_ID=myws
  PATH="/usr/bin:/bin" run "$BLUEPRINT_ROOT/bin/aicoding-paseo-daemon" --ensure
  [ "$status" -eq 0 ]
}

@test "pair subcommand passes through to paseo daemon pair" {
  _install_paseo_stub
  export DEVPOD_WORKSPACE_ID=myws
  run "$BLUEPRINT_ROOT/bin/aicoding-paseo-daemon" pair
  [ "$status" -eq 0 ]
  [[ "$output" == *"QR-CODE-HERE"* ]]
  grep -q "daemon pair" "$PASEO_STUB_LOG"
}

@test "ensure detects a live daemon via pidfile and does not start" {
  _install_paseo_stub
  export DEVPOD_WORKSPACE_ID=myws
  mkdir -p "$HOME/.aicodingsetup/templates" "$HOME/.aicodingsetup/paseo/myws"
  cp "$BLUEPRINT_ROOT/configs/paseo/config.json" "$HOME/.aicodingsetup/templates/paseo-config.json"
  printf '{"pid":%s,"startedAt":"x"}' "$$" > "$HOME/.aicodingsetup/paseo/myws/paseo.pid"
  run "$BLUEPRINT_ROOT/bin/aicoding-paseo-daemon" --ensure
  [ "$status" -eq 0 ]
  run grep -q "daemon start" "$PASEO_STUB_LOG"
  [ "$status" -ne 0 ]
}
