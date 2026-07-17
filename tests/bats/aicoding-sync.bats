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
  # Build a stand-in "blueprint" by copying the real one (skipping .git).
  mkdir -p "$AICODING_BLUEPRINT_CLONE"
  rsync -a --exclude=.git "$BLUEPRINT_ROOT/" "$AICODING_BLUEPRINT_CLONE/"
  # Initialize a git repo there so commit lookup works. No `origin` remote is
  # added, so refresh_blueprint's fetch fails and it falls back to the cached
  # clone WITHOUT hard-resetting — exactly the behaviour these tests rely on.
  (cd "$AICODING_BLUEPRINT_CLONE" && git init -q && git add -A && \
     git -c user.email=test@local -c user.name=test commit -q -m init)
  # aicoding_sync now runs the throttled binary refresh for non-dry-run modes
  # (--yes here). Stub the real CLIs so they no-op instead of hitting the
  # network; assertions check file/manifest state, not this output.
  export AICODING_UPDATE_STATE="$TMPDIR/state/updates"
  mkdir -p "$TMPDIR/stubs"
  for c in claude opencode agent cursor-agent npx npm; do
    printf '#!/bin/sh\nexit 0\n' > "$TMPDIR/stubs/$c"
    chmod +x "$TMPDIR/stubs/$c"
  done
  export PATH="$TMPDIR/stubs:$PATH"
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "aicoding-sync: exits with error when no manifest" {
  run "$BLUEPRINT_ROOT/bin/aicoding-sync"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "no manifest"
}

@test "aicoding-sync: reads existing manifest and prints blueprint commit" {
  mkdir -p "$HOME/.aicodingsetup"
  echo '{"schema_version":1,"blueprint_commit":"old123","files":{}}' > "$AICODING_MANIFEST"
  run "$BLUEPRINT_ROOT/bin/aicoding-sync" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "old123"
}

@test "aicoding-sync: 'n' answer aborts without writing" {
  mkdir -p "$HOME/.aicodingsetup"
  echo "user-line" > "$HOME/.tmux.conf"
  echo "blueprint-line" > "$AICODING_BLUEPRINT_CLONE/configs/tmux/tmux.conf"
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
  run bash -c "echo n | $BLUEPRINT_ROOT/bin/aicoding-sync"
  [ "$status" -eq 0 ]
  grep -q "^user-line$" "$HOME/.tmux.conf"
}

@test "aicoding-sync --yes: busts stale aicoding-status cache when commit advances" {
  mkdir -p "$HOME/.aicodingsetup"
  echo "old-blueprint" > "$HOME/.tmux.conf"
  echo "new-blueprint" > "$AICODING_BLUEPRINT_CLONE/configs/tmux/tmux.conf"
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
  run "$BLUEPRINT_ROOT/bin/aicoding-sync" --yes
  [ "$status" -eq 0 ]
  # Commit advanced (old -> real HEAD), so the stale cache is dropped.
  [ ! -e "$AICODING_UPDATE_STATE/aicoding.json" ]
}

@test "aicoding-sync --dry-run: leaves aicoding-status cache untouched" {
  mkdir -p "$HOME/.aicodingsetup"
  echo '{"schema_version":1,"blueprint_commit":"old123","files":{}}' > "$AICODING_MANIFEST"
  mkdir -p "$AICODING_UPDATE_STATE"
  echo '{"tool":"aicoding","status":"behind"}' > "$AICODING_UPDATE_STATE/aicoding.json"
  run "$BLUEPRINT_ROOT/bin/aicoding-sync" --dry-run
  [ "$status" -eq 0 ]
  # Dry-run applies nothing, so the cache must survive.
  [ -e "$AICODING_UPDATE_STATE/aicoding.json" ]
}

@test "aicoding-sync --yes: records the FULL blueprint SHA (badge comparison needs >=12 chars)" {
  mkdir -p "$HOME/.aicodingsetup"
  echo "old-blueprint" > "$HOME/.tmux.conf"
  echo "new-blueprint" > "$AICODING_BLUEPRINT_CLONE/configs/tmux/tmux.conf"
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
  run "$BLUEPRINT_ROOT/bin/aicoding-sync" --yes
  [ "$status" -eq 0 ]
  local recorded full
  recorded=$(jq -r '.blueprint_commit' "$AICODING_MANIFEST")
  full=$(git -C "$AICODING_BLUEPRINT_CLONE" rev-parse HEAD)
  [ "$recorded" = "$full" ]
  [ "${#recorded}" -eq 40 ]
}
