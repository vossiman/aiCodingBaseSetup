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
