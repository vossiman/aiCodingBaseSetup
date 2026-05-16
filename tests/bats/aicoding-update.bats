#!/usr/bin/env bats

setup() {
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  export AICODING_MANIFEST="$TMPDIR/.aicodingsetup/manifest.json"
  export AICODING_BLUEPRINT_CLONE="$TMPDIR/aicoding"
  # Build a stand-in "blueprint" by copying the real one (skipping .git).
  mkdir -p "$AICODING_BLUEPRINT_CLONE"
  rsync -a --exclude=.git "$BLUEPRINT_ROOT/" "$AICODING_BLUEPRINT_CLONE/"
  # Initialize a git repo there so commit lookup works.
  (cd "$AICODING_BLUEPRINT_CLONE" && git init -q && git add -A && \
     git -c user.email=test@local -c user.name=test commit -q -m init)
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "aicoding-update: exits with error when no manifest" {
  run "$BLUEPRINT_ROOT/bin/aicoding-update"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "no manifest"
}

@test "aicoding-update: reads existing manifest and prints blueprint commit" {
  mkdir -p "$HOME/.aicodingsetup"
  echo '{"schema_version":1,"blueprint_commit":"old123","files":{}}' > "$AICODING_MANIFEST"
  run "$BLUEPRINT_ROOT/bin/aicoding-update" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "old123"
}

@test "aicoding-update --dry-run: bucket counts reflect classifications" {
  mkdir -p "$HOME/.aicodingsetup"
  # Two managed files: one matches blueprint exactly, one is drifted.
  mkdir -p "$HOME/.bashrc.d"
  cp "$AICODING_BLUEPRINT_CLONE/configs/bash/env.sh" "$HOME/.bashrc.d/aicoding-env.sh"
  echo "user-edit" > "$HOME/.tmux.conf"
  # Build a matching manifest.
  cat > "$AICODING_MANIFEST" <<EOF
{
  "schema_version": 1,
  "blueprint_commit": "old",
  "files": {
    "$HOME/.bashrc.d/aicoding-env.sh": {
      "mode": "overwrite",
      "source": "configs/bash/env.sh",
      "deployed_hash": "$(sha256sum "$HOME/.bashrc.d/aicoding-env.sh" | awk '{print $1}')"
    },
    "$HOME/.tmux.conf": {
      "mode": "overwrite",
      "source": "configs/tmux/tmux.conf",
      "deployed_hash": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
    }
  }
}
EOF
  run "$BLUEPRINT_ROOT/bin/aicoding-update" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "up_to_date" || echo "$output" | grep -q "up to date"
  echo "$output" | grep -qE "(drifted|needs your decision)"
}
