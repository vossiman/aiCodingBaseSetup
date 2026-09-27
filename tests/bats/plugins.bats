#!/usr/bin/env bats
setup() {
  export TMP; TMP=$(mktemp -d)
  export HOME="$TMP/home"
  mkdir -p "$HOME/.claude/plugins" "$TMP/bin"
  cat >"$TMP/bin/claude" <<EOF
#!/bin/sh
echo "\$*" >>"$TMP/calls"
EOF
  chmod +x "$TMP/bin/claude"
  cat >"$HOME/.claude/plugins/installed_plugins.json" <<'EOF'
{"version": 2, "plugins": {
  "present@x": [{"scope": "user", "version": "1.2.3"}],
  "project-only@x": [{"scope": "project", "version": "9.9.9"}]
}}
EOF
  cat >"$TMP/plugins.sh" <<EOF
export PATH="$TMP/bin:\$PATH" AICODING_SYNC_MODE=interactive
. "$BLUEPRINT_ROOT/lib/provision.sh"
_provision_tool_ready() { return 0; }
MANAGED_PLUGINS=(present@x missing@x project-only@x)
RETIRED_PLUGINS=(gone@x)
install_claude_plugins
EOF
}
teardown() { rm -rf "$TMP"; }

@test "installed plugins are confirmed from Claude's registry without running the CLI" {
  run bash "$TMP/plugins.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"✔ present"*"installed (1.2.3)"* ]]
  if grep -q "present@x" "$TMP/calls"; then false; fi
  grep -qx "plugin install missing@x" "$TMP/calls"
  # A project-scoped copy does not count as the managed user install.
  grep -qx "plugin install project-only@x" "$TMP/calls"
  # A retired plugin absent from the registry needs no uninstall call.
  if grep -q "uninstall" "$TMP/calls"; then false; fi
}

@test "--full refreshes installed plugins through the CLI" {
  run env AICODING_SYNC_FULL=1 bash "$TMP/plugins.sh"
  [ "$status" -eq 0 ]
  grep -qx "plugin update present@x" "$TMP/calls"
  grep -qx "plugin install missing@x" "$TMP/calls"
}

@test "a missing registry falls back to the CLI for every plugin" {
  rm "$HOME/.claude/plugins/installed_plugins.json"
  run bash "$TMP/plugins.sh"
  [ "$status" -eq 0 ]
  grep -qx "plugin install present@x" "$TMP/calls"
  grep -qx "plugin uninstall gone@x" "$TMP/calls"
}

@test "a retired plugin still in the registry is uninstalled" {
  jq '.plugins["gone@x"] = [{"scope": "user", "version": "0.1"}]' \
    "$HOME/.claude/plugins/installed_plugins.json" >"$TMP/r.json"
  mv "$TMP/r.json" "$HOME/.claude/plugins/installed_plugins.json"
  run bash "$TMP/plugins.sh"
  [ "$status" -eq 0 ]
  grep -qx "plugin uninstall gone@x" "$TMP/calls"
}

@test "aicoding-sync --help documents --full" {
  run grep -q -- "--full" "$BLUEPRINT_ROOT/bin/aicoding-sync"
  [ "$status" -eq 0 ]
}
