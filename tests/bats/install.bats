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
  # another (user-editable, non-owned) is locally edited.
  rm -f "$HOME/.bashrc.d/aicoding-env.sh"
  echo "user edit" >> "$HOME/.tmux.conf"
  local edited_hash
  edited_hash=$(sha256sum "$HOME/.tmux.conf" | awk '{print $1}')

  # Re-run install.sh — should enter reconcile mode.
  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]

  # Missing file restored.
  [ -f "$HOME/.bashrc.d/aicoding-env.sh" ]
  # Edited non-owned file untouched.
  local after_hash
  after_hash=$(sha256sum "$HOME/.tmux.conf" | awk '{print $1}')
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

@test "reconcile force-restores a drifted owned bashrc.d snippet (with backup)" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  echo "# STALE old version" > "$HOME/.bashrc.d/aicoding-env.sh"
  printf '\n# blueprint moved\n' >> "$BLUEPRINT_ROOT/configs/bash/env.sh"
  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]
  ! grep -q "STALE old version" "$HOME/.bashrc.d/aicoding-env.sh"
  grep -q "blueprint moved" "$HOME/.bashrc.d/aicoding-env.sh"
  ls "$HOME"/.bashrc.d/aicoding-env.sh.bak.* >/dev/null 2>&1
  git -C "$BLUEPRINT_ROOT" checkout -- configs/bash/env.sh
}

@test "reconcile still preserves an edited non-owned overwrite file" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  echo "# user tweak" >> "$HOME/.tmux.conf"
  local edited; edited=$(sha256sum "$HOME/.tmux.conf" | awk '{print $1}')
  printf '\n# blueprint moved\n' >> "$BLUEPRINT_ROOT/configs/tmux/tmux.conf"
  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]
  [ "$(sha256sum "$HOME/.tmux.conf" | awk '{print $1}')" = "$edited" ]
  git -C "$BLUEPRINT_ROOT" checkout -- configs/tmux/tmux.conf
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

# ---------------------------------------------------------------------------
# ensure_codex / ensure_cursor_agent — function-level unit tests.
#
# These source install.sh and call the two functions directly instead of
# booting the whole installer. That makes them fast and — crucially — hermetic.
# Both functions start with `command -v codex` / `command -v agent` existence
# checks, so the only way to test their "tool missing" paths is to control PATH
# so those binaries don't resolve. You cannot stub a command into *non-existence*
# (a stub file only makes it look present); the previous `bash install.sh` tests
# left the host's real codex/cursor-agent on PATH, so every "missing" assertion
# silently exercised the "already installed" short-circuit instead.
# ---------------------------------------------------------------------------

# Invoke one install.sh function in an isolated subshell with a pinned PATH.
#   - _AICODINGSETUP_NVS_STRIPPED=1 skips install.sh's nvs self-reexec.
#   - sourcing defines the functions; the `BASH_SOURCE != $0` guards keep
#     check_prerequisites()/main() from running as a side effect.
#   - we disarm install.sh's global `set -eEuo`/ERR-trap after sourcing so a
#     function's exit status is reported to `run` instead of killing the test.
# HOME and any per-test stubs are inherited from the test environment.
_run_install_fn() {
  local fn_path="$1"; shift
  run env _AICODINGSETUP_NVS_STRIPPED=1 PATH="$fn_path" \
    bash -c 'source "$1"; trap - ERR; set +eEu +o pipefail; shift; "$@"' \
    _ "$BLUEPRINT_ROOT/install.sh" "$@"
}

# A PATH with only the tools install.sh touches before the curl check — and
# deliberately NO curl — so `command -v curl` genuinely fails. (curl shares
# /usr/bin with coreutils, so we curate a dir rather than drop one.) It also
# omits the host bin dirs, so codex/cursor-agent/agent don't resolve either.
_curl_less_path() {
  local d="$TMPDIR/nocurl"
  mkdir -p "$d"
  local t
  for t in bash sh dirname uname id; do ln -sf "$(command -v "$t")" "$d/$t"; done
  printf '%s' "$d"
}

# A PATH that keeps real coreutils + curl but excludes the host's user-bin dirs
# (~/.local/bin et al.), so only the *injected* stubs decide whether
# codex/cursor-agent/agent exist.
_isolated_path() { printf '%s' "$TMPDIR/stubs:/usr/bin:/bin"; }

@test "ensure_codex: warns and skips (non-fatal) when curl is unavailable" {
  _run_install_fn "$(_curl_less_path)" ensure_codex
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "WARN.*codex|skipping codex install"
}

@test "ensure_codex: runs the installer and keeps codex when curl works and codex is absent" {
  cat > "$TMPDIR/stubs/curl" <<EOF
#!/bin/sh
echo "(stub) curl-pipe-sh for codex installer ran" > "$TMPDIR/codex-install-attempted"
# Mimic the upstream installer dropping the binary in ~/.local/bin.
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/codex" <<'BIN'
#!/bin/sh
echo "codex 0.0.0-stub"
BIN
chmod +x "$HOME/.local/bin/codex"
EOF
  chmod +x "$TMPDIR/stubs/curl"

  _run_install_fn "$(_isolated_path)" ensure_codex
  [ -f "$TMPDIR/codex-install-attempted" ]
  [ -x "$HOME/.local/bin/codex" ]
}

@test "ensure_cursor_agent: warns and skips (non-fatal) when curl is unavailable" {
  _run_install_fn "$(_curl_less_path)" ensure_cursor_agent
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "WARN.*cursor|skipping cursor-agent install"
}

@test "ensure_cursor_agent: symlinks agent -> cursor-agent when only cursor-agent is dropped" {
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

  _run_install_fn "$(_isolated_path)" ensure_cursor_agent
  # Both names must resolve so downstream tooling (update.sh) can call either.
  [ -x "$HOME/.local/bin/cursor-agent" ]
  [ -L "$HOME/.local/bin/agent" ] || [ -x "$HOME/.local/bin/agent" ]
}

@test "ensure_cursor_agent: skips the installer when 'agent' is already on PATH" {
  # Inject an 'agent' stub so the function's existence check trips.
  cat > "$TMPDIR/stubs/agent" <<'STUB'
#!/bin/sh
echo "agent 0.0.0-stub"
STUB
  chmod +x "$TMPDIR/stubs/agent"

  _run_install_fn "$(_isolated_path)" ensure_cursor_agent
  echo "$output" | grep -qE "cursor-agent already installed"
  # The install attempt must be short-circuited before it starts.
  ! echo "$output" | grep -qE "Installing Cursor CLI"
}

@test "install.sh non-interactive: never rewrites an existing .secrets.env (no host-secret clobber)" {
  # ~/.aicodingsetup/.secrets.env is a host bind mount — the single source of
  # truth across containers. A non-interactive container install must NOT
  # regenerate it; doing so blanks keys it can't prompt for and destroys the
  # user's real tokens on the host. The file must come out byte-identical.
  mkdir -p "$HOME/.aicodingsetup"
  cat > "$HOME/.aicodingsetup/.secrets.env" <<'EOF'
# my host secrets — hand maintained, do not let a container touch this
GH_TOKEN=github_pat_REALTOKENVALUE
FIRECRAWL_API_KEY=fc-abc
MY_CUSTOM_KEY=keepme
EOF
  chmod 600 "$HOME/.aicodingsetup/.secrets.env"
  local before after
  before=$(sha256sum "$HOME/.aicodingsetup/.secrets.env" | awk '{print $1}')

  bash "$BLUEPRINT_ROOT/install.sh" </dev/null

  after=$(sha256sum "$HOME/.aicodingsetup/.secrets.env" | awk '{print $1}')
  [ "$before" = "$after" ]
  # The real token and a non-blueprint custom key must both survive verbatim.
  grep -qx 'GH_TOKEN=github_pat_REALTOKENVALUE' "$HOME/.aicodingsetup/.secrets.env"
  grep -qx 'MY_CUSTOM_KEY=keepme' "$HOME/.aicodingsetup/.secrets.env"
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

@test "install.sh first-deploy: installs slash commands and tracks them in the manifest" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  # Every blueprint command lands in ~/.claude/commands and is manifest-tracked.
  local cmd_file cmd_name
  for cmd_file in "$BLUEPRINT_ROOT/commands"/*.md; do
    cmd_name=$(basename "$cmd_file")
    [ -f "$HOME/.claude/commands/$cmd_name" ]
    local h
    h=$(jq -r '.files["'"$HOME"'/.claude/commands/'"$cmd_name"'"].deployed_hash' "$AICODING_MANIFEST")
    [ "$h" != "null" ] && [ -n "$h" ]
  done
}

@test "install.sh first-deploy: installs check-archived-docs hook so settings.json reference is not dangling" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  # The SessionStart hook wired in settings.json must actually exist on disk.
  [ -f "$HOME/.claude/hooks/check-archived-docs.sh" ]
  [ -x "$HOME/.claude/hooks/check-archived-docs.sh" ]
  grep -q "check-archived-docs.sh" "$HOME/.claude/settings.json"
  # Manifest tracks it as a managed overwrite file.
  local h
  h=$(jq -r '.files["'"$HOME"'/.claude/hooks/check-archived-docs.sh"].deployed_hash' "$AICODING_MANIFEST")
  [ "$h" != "null" ] && [ -n "$h" ]
}

@test "install.sh first-deploy: mirrors project templates into ~/.aicodingsetup" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  local dest="$HOME/.aicodingsetup/templates/project"
  [ -d "$dest" ]
  [ -f "$dest/CLAUDE.md.tpl" ]
  [ -f "$dest/AGENTS.md.tpl" ]
  [ -f "$dest/dot-claude/settings.json.tpl" ]
  # The docs scaffold dirs (carried by .gitkeep) must survive the mirror so
  # /scaffold-project can walk them.
  [ -f "$dest/docs/specs/active/.gitkeep" ]
  # AGENTS.md is the canonical, agent-agnostic conventions file; CLAUDE.md
  # imports it via `@AGENTS.md` so Claude Code and the other CLIs share one
  # source of truth.
  grep -q "@AGENTS.md" "$dest/CLAUDE.md.tpl"
  # Scaffold-time placeholders must NOT be expanded at install time.
  grep -q "{{PROJECT_NAME}}" "$dest/AGENTS.md.tpl"
}

@test "install.sh reconcile mode: restores a deleted slash command" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  local one
  one=$(basename "$(ls "$BLUEPRINT_ROOT/commands"/*.md | head -1)")
  [ -f "$HOME/.claude/commands/$one" ]
  rm -f "$HOME/.claude/commands/$one"

  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Mode: reconcile"
  # The deleted command is restored by reconcile (classify → restore bucket).
  [ -f "$HOME/.claude/commands/$one" ]
}

@test "install.sh first-deploy: deploys update-notify snippet and update-status symlink" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ -f "$HOME/.bashrc.d/aicoding-update-notify.sh" ]
  grep -q "update-status --banner" "$HOME/.bashrc.d/aicoding-update-notify.sh"
  [ -x "$HOME/.local/bin/update-status" ]
  local h
  h=$(jq -r '.files["'"$HOME"'/.bashrc.d/aicoding-update-notify.sh"].deployed_hash' "$AICODING_MANIFEST")
  [ "$h" != "null" ] && [ -n "$h" ]
}

@test "install.sh reconcile: stamps blueprint_commit to the current blueprint HEAD" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null            # first-deploy stamps it
  # Simulate a stale recorded commit (as if installed from an older blueprint).
  local tmp; tmp=$(mktemp)
  jq '.blueprint_commit = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"' "$AICODING_MANIFEST" > "$tmp"
  mv "$tmp" "$AICODING_MANIFEST"

  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null        # reconcile
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Mode: reconcile"
  # Manifest must now record the actual deployed blueprint HEAD, not the stale one.
  local head stamped
  head=$(git -C "$BLUEPRINT_ROOT" rev-parse HEAD)
  stamped=$(jq -r '.blueprint_commit' "$AICODING_MANIFEST")
  [ "$stamped" = "$head" ]
}
