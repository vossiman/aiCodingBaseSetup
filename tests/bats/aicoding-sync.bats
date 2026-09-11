#!/usr/bin/env bats
#
# CLI smoke for bin/aicoding-sync. Classify/apply logic lives in
# blueprint-deploy.bats + sync.bats (lib/sync.sh) — keep this file thin.

setup() {
  : "${BLUEPRINT_ROOT:?unset — run via tests/bats/run.sh; refusing to default to / and copy the whole filesystem}"
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  export AICODING_MANIFEST="$TMPDIR/.aicodingsetup/manifest.json"
  export AICODING_BLUEPRINT_CLONE="$TMPDIR/aicoding"
  export CODEX_MANAGED_DIR="$TMPDIR/etc-codex"
  # Build a stand-in "blueprint" by copying the real one (skipping .git).
  mkdir -p "$AICODING_BLUEPRINT_CLONE"
  rsync -a --exclude=.git "$BLUEPRINT_ROOT/" "$AICODING_BLUEPRINT_CLONE/"
  # Initialize a real Git provenance fixture. The offline runner skips fetch,
  # so tests still use this cached checkout without reset.
  (cd "$AICODING_BLUEPRINT_CLONE" && git init -q && git add -A && \
     git -c user.email=test@local -c user.name=test commit -q -m init)
  git -C "$AICODING_BLUEPRINT_CLONE" remote add origin "$BLUEPRINT_ROOT"
  git -C "$AICODING_BLUEPRINT_CLONE" update-ref refs/remotes/origin/main HEAD
  # aicoding_sync now runs the throttled binary refresh for non-dry-run modes
  # (--yes here). Stub the real CLIs so they no-op instead of hitting the
  # network; assertions check file/manifest state, not this output.
  export AICODING_UPDATE_STATE="$TMPDIR/state/updates"
  mkdir -p "$TMPDIR/stubs"
  cat > "$TMPDIR/stubs/claude" <<'EOF'
#!/bin/sh
case "$*" in
  --version) printf '2.1.0\n' ;;
  "mcp get logfire") printf '  URL: https://logfire-eu.pydantic.dev/mcp\n' ;;
esac
exit 0
EOF
  chmod +x "$TMPDIR/stubs/claude"
  for c in opencode agent cursor-agent npx npm; do
    printf '#!/bin/sh\nexit 0\n' > "$TMPDIR/stubs/$c"
    chmod +x "$TMPDIR/stubs/$c"
  done
  cat > "$TMPDIR/stubs/sudo" <<'EOF'
#!/bin/sh
[ "${1:-}" != -n ] || shift
exec "$@"
EOF
  chmod +x "$TMPDIR/stubs/sudo"
  export PATH="$TMPDIR/stubs:$PATH"
  # cwd must leave the real checkout: _sync_devcontainer_pin targets the
  # cwd's repo, and tests must never write into $BLUEPRINT_ROOT.
  cd "$TMPDIR"
}

# Refuse to remove anything but a mktemp sandbox: if setup ever aborts before
# assigning TMPDIR, the inherited value is /tmp itself (bats exports it).
teardown() { cd /; case "${TMPDIR:-}" in */tmp.*) rm -rf "$TMPDIR" ;; esac }

# These tests assert the result of a fully completed config pass. Seed the
# successful dependency receipts and local probes that the production
# compatibility gate now requires before it can advance the blueprint stamp.
seed_verified_config_dependencies() {
  export AICODING_STATE_DIR="$HOME/.local/state/aicoding"
  export AICODING_RESULTS_FILE="$AICODING_STATE_DIR/update-results.json"
  mkdir -p "$AICODING_STATE_DIR"

  cat > "$TMPDIR/stubs/codex" <<'EOF'
#!/bin/sh
printf 'codex-cli 0.200.0\n'
EOF
  cat > "$TMPDIR/stubs/pi" <<'EOF'
#!/bin/sh
printf 'pi 1.0.0\n'
EOF
  chmod +x "$TMPDIR/stubs/codex" "$TMPDIR/stubs/pi"

  # Use the real receipt writer so the fixture follows the persisted schema.
  source "$AICODING_BLUEPRINT_CLONE/lib/update-results.sh"
  local component
  for component in codex opencode cursor pi claude mcp-context7 mcp-playwright \
      mcp-registration-claude-context7 mcp-registration-claude-playwright; do
    aicoding_result_record "$component" current 1.0.0 verified 1.0.0
  done
}

commit_blueprint_fixture() {
  git -C "$AICODING_BLUEPRINT_CLONE" add -A
  git -C "$AICODING_BLUEPRINT_CLONE" \
    -c user.email=test@local -c user.name=test commit -q -m fixture-change
}

@test "aicoding-sync: exits with error when no manifest" {
  local maintenance_log="$TMPDIR/maintenance.log" command
  for command in claude opencode agent cursor-agent npx npm; do
    printf '#!/bin/sh\necho "%s $*" >> "%s"\n' "$command" "$maintenance_log" \
      > "$TMPDIR/stubs/$command"
    chmod +x "$TMPDIR/stubs/$command"
  done

  run "$BLUEPRINT_ROOT/bin/aicoding-sync"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "no manifest"
  [ ! -s "$maintenance_log" ]
}

@test "aicoding-sync: reads existing manifest and prints blueprint commit" {
  mkdir -p "$HOME/.aicodingsetup"
  echo '{"schema_version":1,"blueprint_commit":"old123","files":{}}' > "$AICODING_MANIFEST"
  run "$AICODING_BLUEPRINT_CLONE/bin/aicoding-sync" --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  echo "$output" | grep -q "old123"
}

@test "aicoding-sync --blueprint uses a dirty local checkout without fetch or reset" {
  mkdir -p "$HOME/.aicodingsetup"
  echo '{"schema_version":1,"blueprint_commit":"old123","files":{}}' > "$AICODING_MANIFEST"
  echo "uncommitted local blueprint edit" >> "$AICODING_BLUEPRINT_CLONE/README.md"

  local real_git git_log git_stubs
  real_git=$(command -v git)
  git_log="$TMPDIR/git-mutations.log"
  git_stubs="$TMPDIR/git-stubs"
  mkdir -p "$git_stubs"
  cat > "$git_stubs/git" <<EOF
#!/bin/sh
if [ "\${1:-}" = -C ] && { [ "\${3:-}" = fetch ] || [ "\${3:-}" = reset ]; }; then
  echo "\${3}" >> "$git_log"
  exit 97
fi
exec "$real_git" "\$@"
EOF
  chmod +x "$git_stubs/git"

  run env PATH="$git_stubs:$PATH" \
      "$AICODING_BLUEPRINT_CLONE/bin/aicoding-sync" --blueprint "$AICODING_BLUEPRINT_CLONE" --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  echo "$output" | grep -Fq "Blueprint source: local $AICODING_BLUEPRINT_CLONE"
  echo "$output" | grep -q "dirty"
  [ ! -e "$git_log" ]
  grep -q "uncommitted local blueprint edit" "$AICODING_BLUEPRINT_CLONE/README.md"
}

@test "aicoding-sync --blueprint rejects a missing checkout" {
  run "$AICODING_BLUEPRINT_CLONE/bin/aicoding-sync" --blueprint "$TMPDIR/absent" --dry-run
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "local blueprint is not a directory"
}

@test "aicoding-sync help documents the local blueprint option" {
  run "$AICODING_BLUEPRINT_CLONE/bin/aicoding-sync" --help
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  echo "$output" | grep -q -- "--blueprint PATH"
  echo "$output" | grep -q "never fetch or reset"
  echo "$output" | grep -q "return to origin/main tracking"
}

@test "aicoding-sync: 'n' answer preserves the existing managed config" {
  mkdir -p "$HOME/.aicodingsetup"
  echo "user-line" > "$HOME/.tmux.conf"
  echo "blueprint-line" > "$AICODING_BLUEPRINT_CLONE/configs/tmux/tmux.conf"
  commit_blueprint_fixture
  cat > "$AICODING_MANIFEST" <<EOF
{
  "schema_version": 1,
  "blueprint_commit": "old",
  "files": {
    "$HOME/.tmux.conf": {
      "mode": "overwrite",
      "source": "configs/tmux/tmux.conf",
      "deployed_hash": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
    }
  }
}
EOF
  run bash -c "echo n | $AICODING_BLUEPRINT_CLONE/bin/aicoding-sync"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q "^user-line$" "$HOME/.tmux.conf"
}

@test "aicoding-sync --yes: busts stale aicoding-status cache when commit advances" {
  seed_verified_config_dependencies
  mkdir -p "$HOME/.aicodingsetup"
  echo "old-blueprint" > "$HOME/.tmux.conf"
  echo "new-blueprint" > "$AICODING_BLUEPRINT_CLONE/configs/tmux/tmux.conf"
  commit_blueprint_fixture
  cat > "$AICODING_MANIFEST" <<EOF
{
  "schema_version": 1,
  "blueprint_commit": "old",
  "files": {
    "$HOME/.tmux.conf": {
      "mode": "overwrite",
      "source": "configs/tmux/tmux.conf",
      "deployed_hash": "$(sha256sum "$HOME/.tmux.conf" | awk '{print $1}')"
    }
  }
}
EOF
  # Seed a stale "behind" verdict, as aicoding-status would have cached it.
  mkdir -p "$AICODING_UPDATE_STATE"
  echo '{"tool":"aicoding","status":"behind"}' > "$AICODING_UPDATE_STATE/aicoding.json"
  run "$AICODING_BLUEPRINT_CLONE/bin/aicoding-sync" --yes
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # Commit advanced (old -> real HEAD), so the stale cache is dropped.
  [ ! -e "$AICODING_UPDATE_STATE/aicoding.json" ]
}

@test "aicoding-sync --dry-run: leaves aicoding-status cache untouched" {
  mkdir -p "$HOME/.aicodingsetup"
  echo '{"schema_version":1,"blueprint_commit":"old123","files":{}}' > "$AICODING_MANIFEST"
  mkdir -p "$AICODING_UPDATE_STATE"
  echo '{"tool":"aicoding","status":"behind"}' > "$AICODING_UPDATE_STATE/aicoding.json"
  run "$AICODING_BLUEPRINT_CLONE/bin/aicoding-sync" --dry-run
  [ "$status" -eq 0 ]
  # Dry-run applies nothing, so the cache must survive.
  [ -e "$AICODING_UPDATE_STATE/aicoding.json" ]
}

@test "aicoding-sync --yes: records the FULL blueprint SHA (badge comparison needs >=12 chars)" {
  seed_verified_config_dependencies
  mkdir -p "$HOME/.aicodingsetup"
  echo "old-blueprint" > "$HOME/.tmux.conf"
  echo "new-blueprint" > "$AICODING_BLUEPRINT_CLONE/configs/tmux/tmux.conf"
  commit_blueprint_fixture
  cat > "$AICODING_MANIFEST" <<EOF
{
  "schema_version": 1,
  "blueprint_commit": "old",
  "files": {
    "$HOME/.tmux.conf": {
      "mode": "overwrite",
      "source": "configs/tmux/tmux.conf",
      "deployed_hash": "$(sha256sum "$HOME/.tmux.conf" | awk '{print $1}')"
    }
  }
}
EOF
  run "$AICODING_BLUEPRINT_CLONE/bin/aicoding-sync" --yes
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  local recorded full
  recorded=$(jq -r '.blueprint_commit' "$AICODING_MANIFEST")
  full=$(git -C "$AICODING_BLUEPRINT_CLONE" rev-parse HEAD)
  [ "$recorded" = "$full" ]
  [ "${#recorded}" -eq 40 ]
}

@test "normal sync ignores an inherited legacy tracking clone" {
  local legacy="$TMPDIR/legacy-tracking-clone"
  rsync -a --exclude=.git "$AICODING_BLUEPRINT_CLONE/" "$legacy/"
  printf '\nprintf "LEGACY_SOURCE_EXECUTED\\n"\n' >> "$legacy/lib/sync.sh"
  mkdir -p "$HOME/.aicodingsetup"
  echo '{"schema_version":1,"blueprint_commit":"old123","files":{}}' > "$AICODING_MANIFEST"

  run env AICODING_BLUEPRINT_CLONE="$legacy" \
    "$AICODING_BLUEPRINT_CLONE/bin/aicoding-sync" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *LEGACY_SOURCE_EXECUTED* ]]
}

@test "normal dry-run leaves the immutable physical release untouched" {
  mkdir -p "$HOME/.aicodingsetup"
  echo '{"schema_version":1,"blueprint_commit":"old123","files":{}}' > "$AICODING_MANIFEST"
  local before
  before=$(git -C "$AICODING_BLUEPRINT_CLONE" status --porcelain)
  run "$AICODING_BLUEPRINT_CLONE/bin/aicoding-sync" --dry-run
  [ "$status" -eq 0 ]
  [ "$(git -C "$AICODING_BLUEPRINT_CLONE" status --porcelain)" = "$before" ]
}

@test "aicoding-sync serializes manual and boot runs before blueprint refresh" {
  mkdir -p "$HOME/.local/state/aicoding"
  exec 8>"$HOME/.local/state/aicoding/sync.lock"
  flock -n 8

  run "$AICODING_BLUEPRINT_CLONE/bin/aicoding-sync" --boot </dev/null
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "already running"
  [ ! -e "$AICODING_STATE_DIR/update-results.json" ]
}

@test "selected blueprint refresh advances to the exact CI-qualified SHA, not newer main" {
  local first newer
  (cd "$AICODING_BLUEPRINT_CLONE" && git checkout -q -B main)
  first=$(git -C "$AICODING_BLUEPRINT_CLONE" rev-parse HEAD)
  git clone -q --bare "$AICODING_BLUEPRINT_CLONE" "$TMPDIR/exact-origin.git"
  git -C "$AICODING_BLUEPRINT_CLONE" remote add origin "$TMPDIR/exact-origin.git"
  local work="$TMPDIR/exact-work"
  git clone -q "$TMPDIR/exact-origin.git" "$work"
  echo newer >> "$work/README.md"
  git -C "$work" -c user.email=t@t -c user.name=t commit -qam newer
  git -C "$work" push -q origin HEAD:main
  newer=$(git -C "$work" rev-parse HEAD)
  [ "$first" != "$newer" ]

  . "$BLUEPRINT_ROOT/lib/sync.sh"
  export AICODING_DATA_DIR="$TMPDIR/data"
  export AICODING_BLUEPRINT_REMOTE="$TMPDIR/exact-origin.git"
  local staged
  staged=$(_sync_stage_selected_blueprint "$first")
  [ "$(git -C "$AICODING_BLUEPRINT_CLONE" rev-parse HEAD)" = "$first" ]
  [ "$staged" = "$AICODING_DATA_DIR/versions/aicoding/$first" ]
  [ "$(cat "$staged/.aicoding-version")" = "$first" ]
}
