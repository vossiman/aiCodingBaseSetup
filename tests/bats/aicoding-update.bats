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

@test "aicoding-update: shows inline diff for drifted_and_updating" {
  mkdir -p "$HOME/.aicodingsetup"
  echo "user-line" > "$HOME/.tmux.conf"
  # Mutate blueprint so the new version differs from the user's content.
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
  run bash -c "echo n | $BLUEPRINT_ROOT/bin/aicoding-update"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "user-line"
  echo "$output" | grep -q "blueprint-line"
  echo "$output" | grep -q "Apply?"
}

@test "aicoding-update: 'n' answer aborts without writing" {
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
  run bash -c "echo n | $BLUEPRINT_ROOT/bin/aicoding-update"
  [ "$status" -eq 0 ]
  grep -q "^user-line$" "$HOME/.tmux.conf"
}

@test "aicoding-update --yes: applies will_update files" {
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
  run "$BLUEPRINT_ROOT/bin/aicoding-update" --yes
  [ "$status" -eq 0 ]
  grep -q "^new-blueprint$" "$HOME/.tmux.conf"
  # Manifest hash advanced.
  local new_h
  new_h=$(jq -r '.files["'"$HOME"'/.tmux.conf"].deployed_hash' "$AICODING_MANIFEST")
  [ "$new_h" = "$(sha256sum "$HOME/.tmux.conf" | awk '{print $1}')" ]
}

@test "aicoding-update --yes: saves .bak for drifted_and_updating before overwrite" {
  mkdir -p "$HOME/.aicodingsetup"
  echo "user-edit" > "$HOME/.tmux.conf"
  echo "blueprint-version" > "$AICODING_BLUEPRINT_CLONE/configs/tmux/tmux.conf"
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
  run "$BLUEPRINT_ROOT/bin/aicoding-update" --yes
  [ "$status" -eq 0 ]
  grep -q "^blueprint-version$" "$HOME/.tmux.conf"
  # A .bak.* file exists with the user's original content.
  ls "$HOME/.tmux.conf.bak."*
  cat "$HOME"/.tmux.conf.bak.* | grep -q "user-edit"
}

@test "aicoding-update --yes: removes to_remove files and manifest entries" {
  mkdir -p "$HOME/.aicodingsetup" "$HOME/.bashrc.d"
  echo "orphan content" > "$HOME/.bashrc.d/aicoding-old-thing.sh"
  cat > "$AICODING_MANIFEST" <<EOF
{
  "schema_version": 1,
  "blueprint_commit": "old",
  "files": {
    "$HOME/.bashrc.d/aicoding-old-thing.sh": {
      "mode": "overwrite",
      "source": "configs/bash/old-thing.sh",
      "deployed_hash": "$(sha256sum "$HOME/.bashrc.d/aicoding-old-thing.sh" | awk '{print $1}')"
    }
  }
}
EOF
  run "$BLUEPRINT_ROOT/bin/aicoding-update" --yes
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.bashrc.d/aicoding-old-thing.sh" ]
  jq -e '.files | has("'"$HOME"'/.bashrc.d/aicoding-old-thing.sh") | not' "$AICODING_MANIFEST"
}
