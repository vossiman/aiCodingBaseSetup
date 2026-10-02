#!/usr/bin/env bats

# End-to-end: install on a tmp HOME, modify a managed file by hand,
# bump the "blueprint" version of that file, run aicoding-sync --yes,
# verify the blueprint version is live with no backup or manifest.

setup() {
  : "${BLUEPRINT_ROOT:?unset — run via tests/bats/run.sh; refusing to default to / and copy the whole filesystem}"
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  export AICODING_BLUEPRINT_CLONE="$TMPDIR/aicoding"
  export AICODINGSETUP_NONINTERACTIVE=1
  export CODEX_MANAGED_DIR="$TMPDIR/etc-codex"
  # Stub apt/curl/etc.
  export PATH="$TMPDIR/stubs:$PATH"
  mkdir -p "$TMPDIR/stubs"
  for cmd in apt-get sudo curl npm npx bash-build-tmux opencode codex cursor-agent; do
    cat > "$TMPDIR/stubs/$cmd" <<'STUB'
#!/bin/sh
exit 0
STUB
    chmod +x "$TMPDIR/stubs/$cmd"
  done
  cat > "$TMPDIR/stubs/sudo" <<'STUB'
#!/bin/sh
[ "${1:-}" != -n ] || shift
exec "$@"
STUB
  chmod +x "$TMPDIR/stubs/sudo"
  cat > "$TMPDIR/stubs/claude" <<'STUB'
#!/bin/sh
case "$*" in
  '--version') echo '2.1.50 (Claude Code)' ;;
  'mcp get logfire')
    [ -f "$HOME/.fixture-logfire-added" ] || exit 1
    echo 'URL: https://logfire-eu.pydantic.dev/mcp'
    ;;
  'mcp add --transport http -s user logfire https://logfire-eu.pydantic.dev/mcp')
    : > "$HOME/.fixture-logfire-added"
    ;;
  'mcp get context7'|'mcp get playwright') exit 1 ;;
esac
STUB
  chmod +x "$TMPDIR/stubs/claude"
  # Build a writable blueprint clone.
  mkdir -p "$AICODING_BLUEPRINT_CLONE"
  rsync -a --exclude=.git "$BLUEPRINT_ROOT/" "$AICODING_BLUEPRINT_CLONE/"
  (cd "$AICODING_BLUEPRINT_CLONE" && git init -q && git add -A && \
    git -c user.email=t@t -c user.name=t commit -q -m initial)
  git -C "$AICODING_BLUEPRINT_CLONE" remote add origin "$BLUEPRINT_ROOT"
  git -C "$AICODING_BLUEPRINT_CLONE" update-ref refs/remotes/origin/main HEAD
  # cwd must leave the real checkout: _sync_devcontainer_pin targets the
  # cwd's repo, and tests must never write into $BLUEPRINT_ROOT.
  cd "$TMPDIR"
}

teardown() {
  cd /
  rm -rf "$TMPDIR"
}

@test "e2e: first install -> modify -> blueprint changes -> aicoding-sync applies" {
  # First install (use the cloned blueprint as the install source).
  bash "$AICODING_BLUEPRINT_CLONE/install.sh" </dev/null
  [ "$(cat "$HOME/.local/state/aicoding/profile")" = container ]
  [ -f "$HOME/.tmux.conf" ]
  [ -L "$HOME/.local/bin/aicoding-sync" ]

  # User modifies a managed file by hand.
  echo "user-customisation" > "$HOME/.tmux.conf"

  # Blueprint advances: change the tmux.conf in the clone and commit.
  echo "next-version-of-tmux-conf" > "$AICODING_BLUEPRINT_CLONE/configs/tmux/tmux.conf"
  (cd "$AICODING_BLUEPRINT_CLONE" && git add -A && \
    git -c user.email=t@t -c user.name=t commit -q -m advance)

  # An explicit --blueprint is the supported local-development source. The
  # scheduler never uses this path; this fixture intentionally exercises it.
  run "$HOME/.local/bin/aicoding-sync" --yes --blueprint "$AICODING_BLUEPRINT_CLONE"
  [ "$status" -eq 0 ]

  grep -q "^next-version-of-tmux-conf$" "$HOME/.tmux.conf"
  [ -z "$(find "$HOME" -maxdepth 1 -name '.tmux.conf.bak.*')" ]
  [ ! -e "$HOME/.local/state/aicoding/manifest.json" ]
  [ "$(cat "$HOME/.local/state/aicoding/blueprint_commit")" = "$(git -C "$AICODING_BLUEPRINT_CLONE" rev-parse HEAD)" ]
}
