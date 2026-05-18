#!/usr/bin/env bats

# Regression coverage for three bugs the final review of blueprint-sync
# surfaced:
#   1. aicoding-update was sweeping ~/.bashrc into to_remove and deleting it.
#   2. aicoding-update wrote raw {{HOME}}/{{*_API_KEY}} placeholders into
#      ~/.claude/settings.json and skill SKILL.md files (no substitution).
#   3. aicoding-update didn't refuse manifests with a newer schema_version.

setup() {
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  export AICODING_MANIFEST="$TMPDIR/.aicodingsetup/manifest.json"
  export AICODING_BLUEPRINT_CLONE="$TMPDIR/aicoding"
  export AICODINGSETUP_NONINTERACTIVE=1
  # Stub apt/curl/etc.
  export PATH="$TMPDIR/stubs:$PATH"
  mkdir -p "$TMPDIR/stubs"
  for cmd in apt-get sudo curl npm; do
    cat > "$TMPDIR/stubs/$cmd" <<'STUB'
#!/bin/sh
exit 0
STUB
    chmod +x "$TMPDIR/stubs/$cmd"
  done
  mkdir -p "$AICODING_BLUEPRINT_CLONE"
  rsync -a --exclude=.git "$BLUEPRINT_ROOT/" "$AICODING_BLUEPRINT_CLONE/"
  (cd "$AICODING_BLUEPRINT_CLONE" && git init -q && git add -A && \
    git -c user.email=t@t -c user.name=t commit -q -m initial)
}

teardown() {
  rm -rf "$TMPDIR"
}

# Bug 1 regression: ~/.bashrc must survive aicoding-update --yes.
@test "regression: aicoding-update does not delete ~/.bashrc" {
  # Bootstrap via install.sh.
  bash "$AICODING_BLUEPRINT_CLONE/install.sh" </dev/null
  [ -f "$HOME/.bashrc" ]
  local start_marker='# >>> aicoding managed block — do not edit between markers >>>'
  local end_marker='# <<< aicoding managed block <<<'
  grep -qxF "$start_marker" "$HOME/.bashrc"

  # Capture the block body that install.sh deployed.
  local body_before
  body_before=$(awk -v s="$start_marker" -v e="$end_marker" '
    $0 == s { in_block = 1; next }
    $0 == e { in_block = 0; next }
    in_block { print }
  ' "$HOME/.bashrc")
  [ -n "$body_before" ]

  # Add some user content so we can sanity-check it survives too.
  echo "# user-added line below the managed block" >> "$HOME/.bashrc"

  # Run aicoding-update --yes twice (idempotency check).
  run "$HOME/.local/bin/aicoding-update" --yes
  [ "$status" -eq 0 ]
  run "$HOME/.local/bin/aicoding-update" --yes
  [ "$status" -eq 0 ]

  # File must still exist with the marker block intact.
  [ -f "$HOME/.bashrc" ]
  grep -qxF "$start_marker" "$HOME/.bashrc"
  grep -qxF "$end_marker"   "$HOME/.bashrc"

  # Block content unchanged (blueprint didn't advance).
  local body_after
  body_after=$(awk -v s="$start_marker" -v e="$end_marker" '
    $0 == s { in_block = 1; next }
    $0 == e { in_block = 0; next }
    in_block { print }
  ' "$HOME/.bashrc")
  [ "$body_before" = "$body_after" ]

  # User's hand-edits outside the block also survived.
  grep -qF "user-added line below the managed block" "$HOME/.bashrc"

  # Manifest still records ~/.bashrc as marker_block (not removed).
  jq -e '.files["'"$HOME"'/.bashrc"].mode == "marker_block"' "$AICODING_MANIFEST"
}

# Bug 2 regression: substitute_secrets must apply on aicoding-update too.
# After install.sh, ~/.claude/settings.json contains the actual $HOME path
# (no literal {{HOME}}). Running aicoding-update against an advanced
# blueprint must NOT regress this — the deployed file must still be free
# of {{HOME}}.
@test "regression: aicoding-update preserves placeholder substitutions" {
  bash "$AICODING_BLUEPRINT_CLONE/install.sh" </dev/null
  [ -f "$HOME/.claude/settings.json" ]

  # install.sh's deploy substituted {{HOME}} -> $HOME — settings.json on
  # disk has no literal placeholders.
  ! grep -q "{{HOME}}" "$HOME/.claude/settings.json"
  # And the resulting hooks-command path contains the expanded $HOME.
  jq -e --arg h "$HOME" '
    .hooks.PreToolUse[0].hooks[0].command | contains($h)
  ' "$HOME/.claude/settings.json"

  # Advance the blueprint: add a benign field via the blueprint's source
  # JSON, commit, then run aicoding-update.
  jq '. + {"_blueprintAdvance":"v2"}' \
    "$AICODING_BLUEPRINT_CLONE/configs/claude/settings.json" \
    > "$AICODING_BLUEPRINT_CLONE/configs/claude/settings.json.tmp"
  mv "$AICODING_BLUEPRINT_CLONE/configs/claude/settings.json.tmp" \
     "$AICODING_BLUEPRINT_CLONE/configs/claude/settings.json"
  (cd "$AICODING_BLUEPRINT_CLONE" && git add -A && \
    git -c user.email=t@t -c user.name=t commit -q -m advance)

  run "$HOME/.local/bin/aicoding-update" --yes
  [ "$status" -eq 0 ]

  # settings.json must still have substituted values — NO literal {{HOME}}.
  ! grep -q "{{HOME}}" "$HOME/.claude/settings.json"
  jq -e --arg h "$HOME" '
    .hooks.PreToolUse[0].hooks[0].command | contains($h)
  ' "$HOME/.claude/settings.json"

  # The blueprint's new field merged in.
  jq -e '._blueprintAdvance == "v2"' "$HOME/.claude/settings.json"

  # Skill SKILL.md files also stay substituted (no {{*}} placeholders),
  # if any are present in the blueprint.
  if [ -d "$HOME/.claude/skills" ]; then
    if ls "$HOME/.claude/skills"/*/SKILL.md 1>/dev/null 2>&1; then
      ! grep -q "{{HOME}}" "$HOME/.claude/skills"/*/SKILL.md
    fi
  fi
}

# Bug 1 + to_remove safety: an actually-orphaned file (in manifest but not
# in blueprint inventory) is removed, AND ~/.bashrc is left alone.
@test "regression: to_remove removes orphan but not ~/.bashrc" {
  bash "$AICODING_BLUEPRINT_CLONE/install.sh" </dev/null

  # Inject an orphan: a file in manifest with no corresponding blueprint source.
  echo "orphan content" > "$HOME/.bashrc.d/aicoding-orphan.sh"
  local h
  h=$(sha256sum "$HOME/.bashrc.d/aicoding-orphan.sh" | awk '{print $1}')
  local updated
  updated=$(jq --arg p "$HOME/.bashrc.d/aicoding-orphan.sh" --arg h "$h" \
    '.files[$p] = {mode:"overwrite",source:"configs/bash/nonexistent.sh",deployed_hash:$h}' \
    "$AICODING_MANIFEST")
  printf '%s\n' "$updated" > "$AICODING_MANIFEST"

  # Sanity: ~/.bashrc is present and marker block is intact pre-update.
  [ -f "$HOME/.bashrc" ]

  run "$HOME/.local/bin/aicoding-update" --yes
  [ "$status" -eq 0 ]

  # Orphan removed, manifest entry gone.
  [ ! -e "$HOME/.bashrc.d/aicoding-orphan.sh" ]
  jq -e '.files | has("'"$HOME"'/.bashrc.d/aicoding-orphan.sh") | not' "$AICODING_MANIFEST"

  # ~/.bashrc untouched (still exists, still has the managed block).
  [ -f "$HOME/.bashrc" ]
  grep -qxF '# >>> aicoding managed block — do not edit between markers >>>' "$HOME/.bashrc"
  # Manifest still tracks it as marker_block.
  jq -e '.files["'"$HOME"'/.bashrc"].mode == "marker_block"' "$AICODING_MANIFEST"
}

# Cosmetic regression: a managed file in the manifest but absent from disk
# must be cleanly restored — no `diff: ... No such file` stderr, no
# "updated (with backup)" misleading line, no silent cp failures inside
# backup_drifted. Should classify as `restore` and re-deploy.
@test "regression: aicoding-update restores missing managed file cleanly" {
  bash "$AICODING_BLUEPRINT_CLONE/install.sh" </dev/null
  rm -f "$HOME/.bashrc.d/aicoding-env.sh"
  [ ! -e "$HOME/.bashrc.d/aicoding-env.sh" ]

  # aicoding-update should classify as restore, deploy without trying to diff.
  run "$HOME/.local/bin/aicoding-update" --yes
  [ "$status" -eq 0 ]

  # File is restored.
  [ -f "$HOME/.bashrc.d/aicoding-env.sh" ]

  # No "diff: ... No such file" error in output.
  ! echo "$output" | grep -q "diff:.*No such file"

  # Output mentions "restored:" not "updated (with backup): <env.sh>".
  echo "$output" | grep -q "restored:"
  ! echo "$output" | grep -q "updated (with backup): $HOME/.bashrc.d/aicoding-env.sh"

  # Summary section labeled "restore" not "needs your decision".
  echo "$output" | grep -q "restore"
}

# Bug 3 regression: manifest schema_version higher than supported aborts.
@test "regression: aicoding-update refuses newer manifest schema_version" {
  mkdir -p "$HOME/.aicodingsetup"
  cat > "$AICODING_MANIFEST" <<'EOF'
{"schema_version":99,"blueprint_commit":"old","files":{}}
EOF
  run "$BLUEPRINT_ROOT/bin/aicoding-update" --dry-run
  [ "$status" -ne 0 ]
  # The error must mention schema_version so the user knows what to fix.
  echo "$output" | grep -q "schema_version"
}
