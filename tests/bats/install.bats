#!/usr/bin/env bats

setup() {
  : "${BLUEPRINT_ROOT:?unset — run via tests/bats/run.sh; refusing to default to / and copy the whole filesystem}"
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  export AICODING_MANIFEST="$TMPDIR/.aicodingsetup/manifest.json"
  export AICODINGSETUP_NONINTERACTIVE=1
  export BASHRC_BLOCK_START_LIT='# >>> aicoding managed block — do not edit between markers >>>'
  export BASHRC_BLOCK_END_LIT='# <<< aicoding managed block <<<'
  # Stub apt etc. so install.sh's prereq steps no-op.
  export PATH="$TMPDIR/stubs:$PATH"
  mkdir -p "$TMPDIR/stubs"
  for cmd in apt-get sudo curl npm bash-build-tmux; do
    cat > "$TMPDIR/stubs/$cmd" <<'STUB'
#!/bin/sh
exit 0
STUB
    chmod +x "$TMPDIR/stubs/$cmd"
  done
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "install.sh mode: first-deploy when no manifest and no managed files" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ -f "$AICODING_MANIFEST" ]
  [ -f "$HOME/.tmux.conf" ]
}

@test "install.sh mode: adopt when managed files exist but no manifest" {
  mkdir -p "$HOME"
  echo "user-customised tmux config" > "$HOME/.tmux.conf"
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  # File content must be untouched.
  grep -q "user-customised" "$HOME/.tmux.conf"
  # Manifest must record the user's hash.
  local user_hash blueprint_hash
  user_hash=$(sha256sum "$HOME/.tmux.conf" | awk '{print $1}')
  blueprint_hash=$(jq -r '.files["'"$HOME"'/.tmux.conf"].deployed_hash' "$AICODING_MANIFEST")
  [ "$user_hash" = "$blueprint_hash" ]
}

@test "install.sh mode: reconcile when manifest exists" {
  # First-deploy populates a real manifest, then a re-run hits reconcile.
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]
  # Output announces reconcile mode (replaces the old "Container already initialized" line).
  echo "$output" | grep -q "Mode: reconcile"
}

@test "install.sh --force-reinstall: deletes manifest and re-deploys" {
  mkdir -p "$HOME/.aicodingsetup"
  echo '{"schema_version":1,"files":{}}' > "$AICODING_MANIFEST"
  echo "user-edit-that-should-be-clobbered" > "$HOME/.tmux.conf"
  run bash "$BLUEPRINT_ROOT/install.sh" --force-reinstall </dev/null
  [ "$status" -eq 0 ]
  # File must be overwritten from blueprint.
  ! grep -q "user-edit-that-should-be-clobbered" "$HOME/.tmux.conf"
  # Manifest must record blueprint-hash, not user's hash.
  local blueprint_hash deployed_hash
  blueprint_hash=$(sha256sum "$BLUEPRINT_ROOT/configs/tmux/tmux.conf" | awk '{print $1}')
  deployed_hash=$(jq -r '.files["'"$HOME"'/.tmux.conf"].deployed_hash' "$AICODING_MANIFEST")
  [ "$blueprint_hash" = "$deployed_hash" ]
}

@test "install.sh adopt: strips standalone Go-PATH export from ~/.bashrc" {
  mkdir -p "$HOME"
  cat > "$HOME/.bashrc" <<'EOF'
export PATH="/usr/local/go/bin:$PATH"
echo hello
EOF
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  # Standalone line is gone; managed block contains it inside markers.
  local outside_block
  outside_block=$(awk -v s="$BASHRC_BLOCK_START_LIT" -v e="$BASHRC_BLOCK_END_LIT" '
    $0 == s { in_block = 1; next }
    $0 == e { in_block = 0; next }
    !in_block { print }
  ' "$HOME/.bashrc")
  if echo "$outside_block" | grep -qF 'export PATH="/usr/local/go/bin:$PATH"'; then
    echo "Go-PATH export still present outside managed block:"
    echo "$outside_block"
    return 1
  fi
  grep -qF 'export PATH="/usr/local/go/bin:$PATH"' "$HOME/.bashrc"
}

@test "install.sh: symlinks aicoding-update into ~/.local/bin" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ -L "$HOME/.local/bin/aicoding-update" ]
  [ -x "$HOME/.local/bin/aicoding-update" ]
  # Target points back to bin/aicoding-update in the blueprint.
  local target
  target=$(readlink "$HOME/.local/bin/aicoding-update")
  echo "$target" | grep -q "bin/aicoding-update"
}

@test "install.sh reconcile mode: restores missing files without touching edited ones" {
  # First-deploy populates the manifest and all managed files.
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ -f "$AICODING_MANIFEST" ]
  [ -f "$HOME/.tmux.conf" ]
  [ -f "$HOME/.bashrc.d/aicoding-env.sh" ]

  # Simulate a rebuild: manifest persists (bind-mount), one file is wiped,
  # another is locally edited.
  rm -f "$HOME/.tmux.conf"
  echo "user edit" >> "$HOME/.bashrc.d/aicoding-env.sh"
  local edited_hash
  edited_hash=$(sha256sum "$HOME/.bashrc.d/aicoding-env.sh" | awk '{print $1}')

  # Re-run install.sh — should enter reconcile mode.
  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]

  # Missing file restored.
  [ -f "$HOME/.tmux.conf" ]
  # Edited file untouched.
  local after_hash
  after_hash=$(sha256sum "$HOME/.bashrc.d/aicoding-env.sh" | awk '{print $1}')
  [ "$after_hash" = "$edited_hash" ]
  # Output mentions reconcile mode and restored count.
  echo "$output" | grep -q "Mode: reconcile"
  echo "$output" | grep -qE "restored [1-9]"
}

@test "install.sh reconcile mode: applies will_update for unedited file" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  # Snapshot the deployed tmux.conf hash and overwrite the blueprint source
  # to simulate a blueprint update (test-only — does not commit upstream).
  local deployed_hash
  deployed_hash=$(jq -r '.files["'"$HOME"'/.tmux.conf"].deployed_hash' "$AICODING_MANIFEST")
  local blueprint_src="$BLUEPRINT_ROOT/configs/tmux/tmux.conf"
  local original_blueprint
  original_blueprint=$(cat "$blueprint_src")
  echo "${original_blueprint}
# new blueprint addition" > "$blueprint_src"

  # Re-run; should auto-update since user hasn't touched ~/.tmux.conf.
  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]

  # File now matches new blueprint, not old deployed_hash.
  grep -q "# new blueprint addition" "$HOME/.tmux.conf"
  local new_hash
  new_hash=$(sha256sum "$HOME/.tmux.conf" | awk '{print $1}')
  [ "$new_hash" != "$deployed_hash" ]
  # Manifest deployed_hash refreshed.
  local manifest_hash
  manifest_hash=$(jq -r '.files["'"$HOME"'/.tmux.conf"].deployed_hash' "$AICODING_MANIFEST")
  [ "$manifest_hash" = "$new_hash" ]

  # Restore blueprint source so other tests don't see the modified file.
  printf '%s' "$original_blueprint" > "$blueprint_src"
}

@test "install.sh reconcile mode: does not auto-resolve drifted_and_updating" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  # Edit the deployed file (user drift).
  echo "user local change" >> "$HOME/.tmux.conf"
  local edited_hash
  edited_hash=$(sha256sum "$HOME/.tmux.conf" | awk '{print $1}')

  # Also change the blueprint so the bucket is drifted_and_updating, not drifted_but_aligned.
  local blueprint_src="$BLUEPRINT_ROOT/configs/tmux/tmux.conf"
  local original_blueprint
  original_blueprint=$(cat "$blueprint_src")
  echo "${original_blueprint}
# blueprint also changed" > "$blueprint_src"

  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]

  # User's edit must be preserved byte-for-byte.
  local after_hash
  after_hash=$(sha256sum "$HOME/.tmux.conf" | awk '{print $1}')
  [ "$after_hash" = "$edited_hash" ]
  # No .bak.* file created (reconcile didn't back up + overwrite).
  [ -z "$(ls "$HOME"/.tmux.conf.bak.* 2>/dev/null)" ]

  # Cleanup.
  printf '%s' "$original_blueprint" > "$blueprint_src"
}

@test "install.sh reconcile mode: does not delete to_remove entries" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  # Inject a manifest entry not present in the blueprint inventory.
  local fake_hash
  fake_hash=$(echo "junk" | sha256sum | awk '{print $1}')
  echo "obsolete content" > "$HOME/.obsolete"
  jq --arg p "$HOME/.obsolete" --arg h "$fake_hash" \
     '.files[$p] = {mode:"overwrite",source:"configs/obsolete",deployed_hash:$h}' \
     "$AICODING_MANIFEST" > "$AICODING_MANIFEST.tmp" && mv "$AICODING_MANIFEST.tmp" "$AICODING_MANIFEST"

  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]

  # File must still exist (to_remove is report-only in reconcile).
  [ -f "$HOME/.obsolete" ]
  # Manifest entry should still be there too — removal is aicoding-update's job.
  jq -e '.files["'"$HOME"'/.obsolete"]' "$AICODING_MANIFEST"
}

@test "install.sh: prints summary line in expected format" {
  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^INSTALL OK  blueprint [0-9a-f]+  new [0-9]+  restored [0-9]+  updated [0-9]+  merged [0-9]+  drifted [0-9]+  to_review [0-9]+$'
}

@test "install.sh: prints NOTE follow-up when drifted or to_review > 0" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  # Force a drifted_and_updating bucket.
  echo "user local change" >> "$HOME/.tmux.conf"
  local blueprint_src="$BLUEPRINT_ROOT/configs/tmux/tmux.conf"
  local original_blueprint
  original_blueprint=$(cat "$blueprint_src")
  echo "${original_blueprint}
# blueprint also changed" > "$blueprint_src"

  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^NOTE: [0-9]+ drifted file\(s\), [0-9]+ file\(s\) to review'

  printf '%s' "$original_blueprint" > "$blueprint_src"
}

@test "install.sh: ERR trap announces step name on failure" {
  # Force a failure by stubbing jq to exit nonzero. install.sh uses jq heavily.
  cat > "$TMPDIR/stubs/jq" <<'STUB'
#!/bin/sh
exit 1
STUB
  chmod +x "$TMPDIR/stubs/jq"

  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -ne 0 ]
  echo "$output" | grep -qE '^INSTALL FAILED  step=.*  line=[0-9]+$'
}

@test "ensure_codex: install.sh warns and returns 0 when curl missing" {
  # Stub curl to exit 127 (not installed); install.sh's ensure_codex
  # should detect this, emit a WARN line, and continue (return 0).
  cat > "$TMPDIR/stubs/curl" <<'STUB'
#!/bin/sh
exit 127
STUB
  chmod +x "$TMPDIR/stubs/curl"

  # Force container detection so auto_install_prereqs runs.
  export DEVCONTAINER=1
  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]
  # Expect a WARN line referencing codex install.
  echo "$output" | grep -qE "WARN.*codex|skipping codex install"
}

@test "ensure_codex: install.sh runs codex installer when curl available and codex missing" {
  # Stub curl to write a marker file so we can assert the installer ran.
  cat > "$TMPDIR/stubs/curl" <<EOF
#!/bin/sh
echo "(stub) curl-pipe-sh for codex installer would run" > "$TMPDIR/codex-install-attempted"
# Mimic the upstream installer dropping the binary in ~/.local/bin.
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/codex" <<'BIN'
#!/bin/sh
echo "codex 0.0.0-stub"
BIN
chmod +x "$HOME/.local/bin/codex"
EOF
  chmod +x "$TMPDIR/stubs/curl"

  export DEVCONTAINER=1
  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]
  [ -f "$TMPDIR/codex-install-attempted" ]
  [ -x "$HOME/.local/bin/codex" ]
}

@test "ensure_cursor_agent: install.sh warns and returns 0 when curl missing" {
  cat > "$TMPDIR/stubs/curl" <<'STUB'
#!/bin/sh
exit 127
STUB
  chmod +x "$TMPDIR/stubs/curl"

  export DEVCONTAINER=1
  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "WARN.*cursor|skipping cursor-agent install"
}

@test "ensure_cursor_agent: symlinks cursor-agent -> agent when only cursor-agent is dropped" {
  # Stub curl to drop the binary as 'cursor-agent' (the older-release name).
  cat > "$TMPDIR/stubs/curl" <<EOF
#!/bin/sh
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/cursor-agent" <<'BIN'
#!/bin/sh
echo "cursor-agent 0.0.0-stub"
BIN
chmod +x "$HOME/.local/bin/cursor-agent"
EOF
  chmod +x "$TMPDIR/stubs/curl"

  export DEVCONTAINER=1
  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]
  # Expect the symlink to exist so downstream code (update.sh) can call either name.
  [ -x "$HOME/.local/bin/cursor-agent" ]
  [ -L "$HOME/.local/bin/agent" ] || [ -x "$HOME/.local/bin/agent" ]
}

@test "ensure_cursor_agent: skips install when 'agent' is already on PATH" {
  # Pre-stub 'agent' so the function's existence check trips.
  cat > "$TMPDIR/stubs/agent" <<'STUB'
#!/bin/sh
echo "agent 0.0.0-stub"
STUB
  chmod +x "$TMPDIR/stubs/agent"
  # If curl gets called by ensure_cursor_agent (only), we'd see this marker.
  # NOTE: curl is also called by other ensure_* steps (claude, opencode,
  # codex, go, uv); the marker name distinguishes cursor's invocation by
  # checking install.sh output instead — see test below.
  export DEVCONTAINER=1
  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]
  # The "Installing Cursor CLI" info line must NOT appear because the
  # binary check short-circuits before the install attempt.
  ! echo "$output" | grep -qE "Installing Cursor CLI"
  echo "$output" | grep -qE "cursor-agent already installed"
}

@test "first-deploy: codex config.toml deploys with substituted FIRECRAWL_API_KEY" {
  # Seed a secrets file so substitution has a value to inject.
  mkdir -p "$HOME/.aicodingsetup"
  cat > "$HOME/.aicodingsetup/.secrets.env" <<EOF
FIRECRAWL_API_KEY=fake-firecrawl-123
BRAVE_API_KEY=fake-brave-456
CLOUDFLARE_API_TOKEN=
CLOUDFLARE_ACCOUNT_ID=
EOF
  chmod 600 "$HOME/.aicodingsetup/.secrets.env"

  bash "$BLUEPRINT_ROOT/install.sh" </dev/null

  # File deployed under bind-mount target ~/.codex/.
  [ -f "$HOME/.codex/config.toml" ]
  # Secret substituted (no {{...}} placeholder survives).
  grep -qF 'FIRECRAWL_API_KEY = "fake-firecrawl-123"' "$HOME/.codex/config.toml"
  ! grep -qF '{{FIRECRAWL_API_KEY}}' "$HOME/.codex/config.toml"
  # Manifest records overwrite mode + deployed_hash.
  local mode
  mode=$(jq -r '.files["'"$HOME"'/.codex/config.toml"].mode' "$AICODING_MANIFEST")
  [ "$mode" = "overwrite" ]
  local hash
  hash=$(jq -r '.files["'"$HOME"'/.codex/config.toml"].deployed_hash' "$AICODING_MANIFEST")
  [ -n "$hash" ]
  [ "$hash" != "null" ]
}

@test "first-deploy: cursor mcp.json merges 4 blueprint servers without dropping user adds" {
  # Pre-create ~/.cursor/mcp.json with one user-added server. The merge
  # pipeline must preserve it while adding the blueprint's 4 servers.
  mkdir -p "$HOME/.cursor"
  cat > "$HOME/.cursor/mcp.json" <<'EOF'
{
  "mcpServers": {
    "user-custom": {
      "command": "my-custom-mcp",
      "args": ["--flag"]
    }
  }
}
EOF
  # Make sure first-deploy fires (no manifest yet); Plan 1's detect_install_mode
  # picks 'adopt' when a managed file exists but no manifest is present, so
  # cursor mcp.json on disk -> mode=adopt. Use --force-reinstall to force first.
  mkdir -p "$HOME/.aicodingsetup"
  cat > "$HOME/.aicodingsetup/.secrets.env" <<EOF
FIRECRAWL_API_KEY=fake-firecrawl-123
BRAVE_API_KEY=fake-brave-456
CLOUDFLARE_API_TOKEN=
CLOUDFLARE_ACCOUNT_ID=
EOF

  bash "$BLUEPRINT_ROOT/install.sh" --force-reinstall </dev/null

  [ -f "$HOME/.cursor/mcp.json" ]
  # All 4 blueprint servers present.
  jq -e '.mcpServers.firecrawl'    "$HOME/.cursor/mcp.json"
  jq -e '.mcpServers["brave-search"]' "$HOME/.cursor/mcp.json"
  jq -e '.mcpServers.context7'     "$HOME/.cursor/mcp.json"
  jq -e '.mcpServers.playwright'   "$HOME/.cursor/mcp.json"
  # User's custom server preserved.
  jq -e '.mcpServers["user-custom"]' "$HOME/.cursor/mcp.json"
  # Substitution applied.
  jq -r '.mcpServers.firecrawl.env.FIRECRAWL_API_KEY' "$HOME/.cursor/mcp.json" | grep -qF 'fake-firecrawl-123'
}

@test "first-deploy: opencode.json mcp field populated with 4 servers and substituted secrets" {
  mkdir -p "$HOME/.aicodingsetup"
  cat > "$HOME/.aicodingsetup/.secrets.env" <<EOF
FIRECRAWL_API_KEY=fake-firecrawl-123
BRAVE_API_KEY=fake-brave-456
CLOUDFLARE_API_TOKEN=
CLOUDFLARE_ACCOUNT_ID=
EOF

  bash "$BLUEPRINT_ROOT/install.sh" </dev/null

  [ -f "$HOME/.config/opencode/opencode.json" ]
  # All 4 servers present under the 'mcp' (not 'mcpServers') top-level key.
  jq -e '.mcp.firecrawl.type == "local"'                  "$HOME/.config/opencode/opencode.json"
  jq -e '.mcp["brave-search"].type == "local"'            "$HOME/.config/opencode/opencode.json"
  jq -e '.mcp.context7.type == "local"'                   "$HOME/.config/opencode/opencode.json"
  jq -e '.mcp.playwright.type == "local"'                 "$HOME/.config/opencode/opencode.json"
  # opencode schema uses 'environment' not 'env' and 'command' is an array.
  jq -e '.mcp.firecrawl.environment.FIRECRAWL_API_KEY == "fake-firecrawl-123"' "$HOME/.config/opencode/opencode.json"
  jq -e '.mcp.firecrawl.command | type == "array"'        "$HOME/.config/opencode/opencode.json"
}

@test "merge: opencode.json mcp field preserves user-added server" {
  # Pre-populate opencode.json with an existing user-added mcp entry.
  mkdir -p "$HOME/.config/opencode"
  cat > "$HOME/.config/opencode/opencode.json" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "anthropic/claude-opus-4-6",
  "mcp": {
    "user-server": {
      "type": "local",
      "command": ["my-custom"],
      "enabled": true
    }
  }
}
EOF
  mkdir -p "$HOME/.aicodingsetup"
  cat > "$HOME/.aicodingsetup/.secrets.env" <<EOF
FIRECRAWL_API_KEY=fake-firecrawl-123
BRAVE_API_KEY=fake-brave-456
CLOUDFLARE_API_TOKEN=
CLOUDFLARE_ACCOUNT_ID=
EOF

  bash "$BLUEPRINT_ROOT/install.sh" --force-reinstall </dev/null

  # User server + all 4 blueprint servers both present.
  jq -e '.mcp["user-server"]'   "$HOME/.config/opencode/opencode.json"
  jq -e '.mcp.firecrawl'        "$HOME/.config/opencode/opencode.json"
  jq -e '.mcp["brave-search"]'  "$HOME/.config/opencode/opencode.json"
  jq -e '.mcp.context7'         "$HOME/.config/opencode/opencode.json"
  jq -e '.mcp.playwright'       "$HOME/.config/opencode/opencode.json"
}

@test "reconcile: restores deleted ~/.codex/config.toml on rebuild" {
  mkdir -p "$HOME/.aicodingsetup"
  cat > "$HOME/.aicodingsetup/.secrets.env" <<EOF
FIRECRAWL_API_KEY=fake-firecrawl-123
BRAVE_API_KEY=fake-brave-456
CLOUDFLARE_API_TOKEN=
CLOUDFLARE_ACCOUNT_ID=
EOF
  # First-deploy seeds the manifest.
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ -f "$HOME/.codex/config.toml" ]
  local first_hash
  first_hash=$(sha256sum "$HOME/.codex/config.toml" | awk '{print $1}')

  # Simulate a rebuild: manifest persists (bind-mount), file is wiped.
  rm -f "$HOME/.codex/config.toml"
  [ ! -f "$HOME/.codex/config.toml" ]

  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]
  # File restored, content byte-identical to pre-wipe.
  [ -f "$HOME/.codex/config.toml" ]
  local restored_hash
  restored_hash=$(sha256sum "$HOME/.codex/config.toml" | awk '{print $1}')
  [ "$restored_hash" = "$first_hash" ]
  # Plan 1's summary line shows restored count >= 1.
  echo "$output" | grep -qE 'restored [1-9][0-9]* '
  # Mode line announces reconcile.
  echo "$output" | grep -q "Mode: reconcile"
}

@test "reconcile: leaves edited ~/.codex/config.toml byte-unchanged" {
  mkdir -p "$HOME/.aicodingsetup"
  cat > "$HOME/.aicodingsetup/.secrets.env" <<EOF
FIRECRAWL_API_KEY=fake-firecrawl-123
BRAVE_API_KEY=fake-brave-456
CLOUDFLARE_API_TOKEN=
CLOUDFLARE_ACCOUNT_ID=
EOF
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null

  # User edits the file (drift).
  echo "# user-added line" >> "$HOME/.codex/config.toml"
  local edited_hash
  edited_hash=$(sha256sum "$HOME/.codex/config.toml" | awk '{print $1}')

  # Also change the blueprint source so the bucket is drifted_and_updating
  # (not drifted_but_aligned), which is the conservatism case we care about.
  local original_blueprint
  original_blueprint=$(cat "$BLUEPRINT_ROOT/configs/codex/config.toml")
  echo "# blueprint also changed" >> "$BLUEPRINT_ROOT/configs/codex/config.toml"

  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]
  # User's edit preserved byte-for-byte (reconcile excludes drifted_and_updating).
  local after_hash
  after_hash=$(sha256sum "$HOME/.codex/config.toml" | awk '{print $1}')
  [ "$after_hash" = "$edited_hash" ]
  # Summary shows drifted >= 1.
  echo "$output" | grep -qE 'drifted [1-9][0-9]* '
  # NOTE line surfaces.
  echo "$output" | grep -qE '^NOTE: [0-9]+ drifted file'

  # Restore blueprint so other tests don't see the modification. The
  # source codex/config.toml ends with a trailing newline; preserve it
  # with `printf '%s\n'` (a bare `printf '%s'` would silently strip it).
  printf '%s\n' "$original_blueprint" > "$BLUEPRINT_ROOT/configs/codex/config.toml"
}
