#!/usr/bin/env bats

# End-to-end: install on a tmp HOME, modify a managed file by hand,
# bump the "blueprint" version of that file, run aicoding-update --yes,
# verify the user's change is backed up and the blueprint version is live.

setup() {
  : "${BLUEPRINT_ROOT:?unset — run via tests/bats/run.sh; refusing to default to / and copy the whole filesystem}"
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
  # Build a writable blueprint clone.
  mkdir -p "$AICODING_BLUEPRINT_CLONE"
  rsync -a --exclude=.git "$BLUEPRINT_ROOT/" "$AICODING_BLUEPRINT_CLONE/"
  (cd "$AICODING_BLUEPRINT_CLONE" && git init -q && git add -A && \
    git -c user.email=t@t -c user.name=t commit -q -m initial)
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "e2e: first install -> modify -> blueprint changes -> aicoding-update applies" {
  # First install (use the cloned blueprint as the install source).
  bash "$AICODING_BLUEPRINT_CLONE/install.sh" </dev/null
  [ -f "$AICODING_MANIFEST" ]
  [ -f "$HOME/.tmux.conf" ]
  [ -L "$HOME/.local/bin/aicoding-update" ]

  # User modifies a managed file by hand.
  echo "user-customisation" > "$HOME/.tmux.conf"

  # Blueprint advances: change the tmux.conf in the clone and commit.
  echo "next-version-of-tmux-conf" > "$AICODING_BLUEPRINT_CLONE/configs/tmux/tmux.conf"
  (cd "$AICODING_BLUEPRINT_CLONE" && git add -A && \
    git -c user.email=t@t -c user.name=t commit -q -m advance)

  # Run aicoding-update --yes.
  run "$HOME/.local/bin/aicoding-update" --yes
  [ "$status" -eq 0 ]

  # User's edit is in a .bak.* file; blueprint content is now live.
  ls "$HOME/.tmux.conf.bak."* | head -1
  cat "$HOME"/.tmux.conf.bak.* | grep -q "user-customisation"
  grep -q "^next-version-of-tmux-conf$" "$HOME/.tmux.conf"

  # Manifest's deployed_hash matches the new blueprint content.
  local h_disk h_manifest
  h_disk=$(sha256sum "$HOME/.tmux.conf" | awk '{print $1}')
  h_manifest=$(jq -r '.files["'"$HOME"'/.tmux.conf"].deployed_hash' "$AICODING_MANIFEST")
  [ "$h_disk" = "$h_manifest" ]
}
