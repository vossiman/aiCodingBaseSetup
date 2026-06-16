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
  "daemon start")    exit 0 ;;
  "daemon pair")     echo "QR-CODE-HERE"; echo "https://app.paseo.sh/#offer=test"; exit 0 ;;
  "terminal ls")     printf '%s' "${PASEO_STUB_TERMINALS:-[]}"; exit 0 ;;
  "terminal create") exit 0 ;;
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



@test "install.sh gates the provision-time ensure behind AICODINGSETUP_SKIP_NETWORK (incident regression)" {
  # The --ensure call must sit inside the skip-network gate: an ungated call
  # spawns a REAL daemon per install.sh-running test (incident 2026-06-12).
  # Behavioral coverage lives in e2e.bats ("no paseo daemon start under test").
  grep -A2 'AICODINGSETUP_SKIP_NETWORK:-}" != "1" ]]' "$BLUEPRINT_ROOT/install.sh" \
    | grep -q 'aicoding-paseo-daemon" --ensure'
}

@test "sync plumbing ensures the paseo daemon on every boot" {
  grep -q 'aicoding-paseo-daemon --ensure' "$BLUEPRINT_ROOT/lib/sync.sh"
}

@test "sync binary refresh updates @getpaseo/cli" {
  grep -q '@getpaseo/cli' "$BLUEPRINT_ROOT/lib/sync.sh"
}

@test "env.sh exports PASEO_HOME via the helper" {
  grep -q 'PASEO_HOME' "$BLUEPRINT_ROOT/configs/bash/env.sh"
  grep -q 'aicoding-paseo-daemon --print-home' "$BLUEPRINT_ROOT/configs/bash/env.sh"
}

@test "install.sh persists cursor-agent auth dir into the shared mount" {
  grep -q 'aicodingsetup/cursor-config' "$BLUEPRINT_ROOT/install.sh"
}

@test "run.sh injects a global paseo no-op stub so the suite never starts a real daemon" {
  grep -q '_PASEO_STUB_DIR' "$BLUEPRINT_ROOT/tests/bats/run.sh"
  grep -q 'exit 0' "$BLUEPRINT_ROOT/tests/bats/run.sh"
}

@test "ensure wires project registration via the openProject helper" {
  grep -q '_register_project' "$BLUEPRINT_ROOT/bin/aicoding-paseo-daemon"
  grep -q 'aicoding-paseo-open-project.mjs' "$BLUEPRINT_ROOT/bin/aicoding-paseo-daemon"
}

@test "open-project helper calls the daemon openProject primitive" {
  grep -q 'openProject' "$BLUEPRINT_ROOT/bin/aicoding-paseo-open-project.mjs"
  grep -q 'connectToDaemon' "$BLUEPRINT_ROOT/bin/aicoding-paseo-open-project.mjs"
}

@test "open-project helper is fail-open with no args" {
  run node "$BLUEPRINT_ROOT/bin/aicoding-paseo-open-project.mjs"
  [ "$status" -eq 0 ]
}

@test "open-project helper is fail-open when the bundled CLI client is absent" {
  # Point npm root at an empty dir so the client path doesn't resolve.
  mkdir -p "$TMPDIR/fakeroot/bin"
  printf '#!/bin/sh\necho %s\n' "$TMPDIR/fakeroot" > "$TMPDIR/fakeroot/bin/npm"
  chmod +x "$TMPDIR/fakeroot/bin/npm"
  PATH="$TMPDIR/fakeroot/bin:$PATH" run node "$BLUEPRINT_ROOT/bin/aicoding-paseo-open-project.mjs" "$TMPDIR"
  [ "$status" -eq 0 ]
}

@test "scaffold ships a starter paseo.json with a dev service" {
  [ -f "$BLUEPRINT_ROOT/templates/project/paseo.json" ]
  run jq -e '.scripts.dev.type == "service" and (.scripts.dev.command|length>0) and (.scripts.dev.port|type=="number")' \
    "$BLUEPRINT_ROOT/templates/project/paseo.json"
  [ "$status" -eq 0 ]
}

@test "scaffold-project lists paseo.json in its created files" {
  grep -q 'paseo.json' "$BLUEPRINT_ROOT/commands/scaffold-project.md"
}
