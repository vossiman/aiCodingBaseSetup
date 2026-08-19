#!/usr/bin/env bats

setup() {
  : "${BLUEPRINT_ROOT:?unset — run via tests/bats/run.sh; refusing to default to / and copy the whole filesystem}"
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  export AICODING_MANIFEST="$TMPDIR/.local/state/aicoding/manifest.json"
  export AICODINGSETUP_NONINTERACTIVE=1
  # install-host.sh's nvs-strip prelude (copied from install.sh) unconditionally
  # `exec`s into `bash "$0"` unless this is already set. Under bats, sourcing
  # via `_source_host_lib` runs in a subshell whose $0 is bats' own test
  # runner, not install-host.sh — letting that exec fire re-execs the wrong
  # file. install.bats's `_run_install_fn` dodges the same landmine by
  # pre-setting this before sourcing install.sh; mirror that here.
  export _AICODINGSETUP_NVS_STRIPPED=1
  export PATH="$TMPDIR/stubs:$PATH"
  mkdir -p "$TMPDIR/stubs" "$TMPDIR/.local/bin"
  # Prereq stubs present by default; individual tests remove them.
  for t in git curl node npm bwrap claude; do
    printf '#!/bin/bash\nexit 0\n' > "$TMPDIR/stubs/$t"; chmod +x "$TMPDIR/stubs/$t"
  done
  # dirname and jq are real passthroughs, not no-op stubs. install-host.sh's
  # SCRIPT_DIR resolution (`dirname "${BASH_SOURCE[0]}"`) needs dirname's
  # actual output at source-time, and the deploy engine's manifest read/write
  # (manifest_set_profile, manifest_stamp_provision, detect_install_mode)
  # needs real jq behavior — a no-op stub would silently truncate
  # $AICODING_MANIFEST to empty on every write. Some tests set
  # PATH="$TMPDIR/stubs" (no system dirs) to hide real jq/npm from
  # `command -v`; without a stub-dir dirname/jq passthrough, that same
  # restriction also hides coreutils' dirname and breaks sourcing before
  # check_prerequisites_host is even defined. `command -v jq`'s presence
  # check for check_prerequisites_host tests still works via this passthrough
  # (present) or via the plain `rm` some tests do (absent).
  for t in dirname jq; do
    printf '#!/bin/bash\nexec /usr/bin/%s "$@"\n' "$t" > "$TMPDIR/stubs/$t"
    chmod +x "$TMPDIR/stubs/$t"
  done
}

teardown() { rm -rf "$TMPDIR"; }

_source_host_lib() {
  ( cd "$BLUEPRINT_ROOT" && source ./install-host.sh >/dev/null 2>&1; "$@" )
}

@test "check_prerequisites_host: all present -> success" {
  run _source_host_lib check_prerequisites_host
  [ "$status" -eq 0 ]
}

@test "check_prerequisites_host: missing tools abort with one apt hint line" {
  rm "$TMPDIR/stubs/jq" "$TMPDIR/stubs/npm"
  # Restrict to the stub dir only for this call: the devcontainer itself has
  # real jq/npm installed, and command -v would otherwise fall through to
  # those via the inherited system PATH, masking the "missing" case we're
  # simulating by deleting the stubs.
  PATH="$TMPDIR/stubs" run _source_host_lib check_prerequisites_host
  [ "$status" -eq 1 ]
  [[ "$output" == *"sudo apt install"*"jq"* ]]
  [[ "$output" == *"npm"* ]]
}

@test "ensure_homelab_wiki: no-op when clone exists, no git call" {
  mkdir -p "$HOME/homelab-wiki/.git"
  printf '#!/bin/bash\necho GIT-CALLED; exit 1\n' > "$TMPDIR/stubs/git"; chmod +x "$TMPDIR/stubs/git"
  run _source_host_lib ensure_homelab_wiki
  [ "$status" -eq 0 ]
  [[ "$output" != *"GIT-CALLED"* ]]
}

@test "ensure_homelab_wiki: skipped under AICODINGSETUP_SKIP_NETWORK" {
  export AICODINGSETUP_SKIP_NETWORK=1
  printf '#!/bin/bash\necho GIT-CALLED; exit 1\n' > "$TMPDIR/stubs/git"; chmod +x "$TMPDIR/stubs/git"
  run _source_host_lib ensure_homelab_wiki
  [ "$status" -eq 0 ]
  [[ "$output" != *"GIT-CALLED"* ]]
}

@test "ensure_homelab_wiki: failed clone warns but exits 0" {
  # tests/bats/run.sh exports AICODINGSETUP_SKIP_NETWORK=1 suite-wide so the
  # rest of the suite stays offline; unset it here so this test actually
  # reaches the git-clone branch it means to exercise.
  unset AICODINGSETUP_SKIP_NETWORK
  printf '#!/bin/bash\nexit 128\n' > "$TMPDIR/stubs/git"; chmod +x "$TMPDIR/stubs/git"
  run _source_host_lib ensure_homelab_wiki
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN"* ]]
}

@test "install-host.sh: sourcing defines functions without executing main" {
  run _source_host_lib true
  [ "$status" -eq 0 ]
  [ ! -f "$AICODING_MANIFEST" ]
}

@test "install-host.sh: main writes profile=host and provision stamp to manifest" {
  export AICODINGSETUP_SKIP_NETWORK=1
  run bash -c "cd '$BLUEPRINT_ROOT' && bash install-host.sh"
  [ "$status" -eq 0 ]
  run jq -r '.profile' "$AICODING_MANIFEST"
  [ "$output" = "host" ]
}

@test "install-host.sh: deploys host-shaped managed set (boot-sync + agent CLIs yes, tmux no)" {
  export AICODINGSETUP_SKIP_NETWORK=1
  bash -c "cd '$BLUEPRINT_ROOT' && bash install-host.sh"
  [ -f "$HOME/.bashrc.d/aicoding-boot-sync.sh" ]
  [ -f "$HOME/.claude/CLAUDE.md" ]
  # Agent CLI configs are managed on hosts too (user decision 2026-08-19:
  # all machines behave the same; repo-level files still override globals).
  [ -f "$HOME/.codex/config.toml" ]
  [ -f "$HOME/.codex/AGENTS.md" ]
  [ -f "$HOME/.config/opencode/opencode.json" ]
  [ -f "$HOME/.cursor/mcp.json" ]
  [ -f "$HOME/.cursor/cli-config.json" ]
  # tmux/ssh-agent wiring stays container-only.
  [ ! -f "$HOME/.tmux.conf" ]
  [ ! -f "$HOME/.bashrc.d/aicoding-ssh-auth-sock.sh" ]
  grep -q 'aicoding managed block' "$HOME/.bashrc"
}

@test "install-host.sh: host merge preserves personal cursor MCP entries" {
  export AICODINGSETUP_SKIP_NETWORK=1
  mkdir -p "$HOME/.cursor"
  cat > "$HOME/.cursor/mcp.json" <<'EOF'
{
  "mcpServers": {
    "postgres": { "command": "docker", "args": ["run", "-i", "--rm", "pg-mcp"] }
  }
}
EOF
  # A managed file on disk with no manifest flips detect_install_mode to
  # 'adopt' (review, don't merge) — force first-deploy, same as the
  # container-side cursor merge test.
  bash -c "cd '$BLUEPRINT_ROOT' && bash install-host.sh --force-reinstall"
  jq -e '.mcpServers.postgres'         "$HOME/.cursor/mcp.json"
  jq -e '.mcpServers["memory-router"]' "$HOME/.cursor/mcp.json"
}

@test "install-host.sh: second run is reconcile mode, still exits 0" {
  export AICODINGSETUP_SKIP_NETWORK=1
  bash -c "cd '$BLUEPRINT_ROOT' && bash install-host.sh"
  run bash -c "cd '$BLUEPRINT_ROOT' && bash install-host.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"reconcile"* ]]
}

@test "install-host.sh: main flow survives a failed homelab-wiki clone (errexit-safe)" {
  # Regression test for C1: a plain `git clone ... | tail -1` +
  # `PIPESTATUS[0]` check is NOT errexit-safe — under install-host.sh's
  # `set -euo pipefail` + ERR trap, git's non-zero exit on the left of the
  # pipe aborts the whole installer before the PIPESTATUS check ever runs.
  # This must run the real `main` flow (not `_source_host_lib`, which
  # sources into a subshell and doesn't reproduce the abort) so the failure
  # is exercised exactly the way production hits it.
  #
  # Keep run.sh's suite-wide network guard enabled for the entire real main
  # flow. In particular, install_bubblewrap must not run an ignored checkout's
  # real vendor/bw-AICode installer. Wrap only ensure_homelab_wiki so its
  # production implementation sees the guard disabled for this fake-git call.
  export AICODINGSETUP_SKIP_NETWORK=1
  cat > "$TMPDIR/stubs/git" <<'EOF'
#!/bin/bash
if [[ "$1" == "clone" ]]; then
  for a in "$@"; do
    if [[ "$a" == *homelab-wiki* ]]; then
      echo "fatal: unable to access homelab-wiki (fake failure)" >&2
      exit 128
    fi
  done
fi
exit 0
EOF
  chmod +x "$TMPDIR/stubs/git"

  run bash -c '
    cd "$BLUEPRINT_ROOT"
    source ./install-host.sh
    definition=$(declare -f ensure_homelab_wiki)
    eval "_real_$definition"
    ensure_homelab_wiki() {
      AICODINGSETUP_SKIP_NETWORK= _real_ensure_homelab_wiki
    }
    main
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping bw-AICode (AICODINGSETUP_SKIP_NETWORK)"* ]]
  [[ "$output" == *"WARN"*"homelab-wiki clone failed"* ]]
  run jq -r '.profile' "$AICODING_MANIFEST"
  [ "$output" = "host" ]
}

@test "install-host.sh: main registers the git-credential-aicoding fallback helper" {
  # Root cause of the 2026-08-12 Mint field failure: helper registration
  # lived only in _sync_plumbing (sync-time), so the installer's own HTTPS
  # wiki clone found no credential helper and prompted interactively.
  # The git stub passes `config` through to real git (writes to this test's
  # fake $HOME/.gitconfig) and no-ops everything else.
  export AICODINGSETUP_SKIP_NETWORK=1
  cat > "$TMPDIR/stubs/git" <<'EOF'
#!/bin/bash
if [[ "$1" == "config" ]]; then exec /usr/bin/git "$@"; fi
exit 0
EOF
  chmod +x "$TMPDIR/stubs/git"
  run bash -c "cd '$BLUEPRINT_ROOT' && bash install-host.sh"
  [ "$status" -eq 0 ]
  grep -q 'git-credential-aicoding' "$HOME/.gitconfig"
}

@test "ensure_homelab_wiki: clone runs with GIT_TERMINAL_PROMPT=0 (never prompts)" {
  unset AICODINGSETUP_SKIP_NETWORK
  # run.sh exports GIT_TERMINAL_PROMPT=0 suite-wide as an offline guard —
  # unset it so this test proves ensure_homelab_wiki sets it ITSELF (the
  # production shell on a real host has no such export).
  unset GIT_TERMINAL_PROMPT
  cat > "$TMPDIR/stubs/git" <<'EOF'
#!/bin/bash
echo "GTP=${GIT_TERMINAL_PROMPT:-unset}"
exit 128
EOF
  chmod +x "$TMPDIR/stubs/git"
  run _source_host_lib ensure_homelab_wiki
  [ "$status" -eq 0 ]
  [[ "$output" == *"GTP=0"* ]]
}

@test "boot-sync snippet: falls back to ~/.local/bin when aicoding-sync is not on PATH" {
  # A fresh machine's first login shell may predate ~/.local/bin appearing
  # on PATH (Debian/Mint add it only when the dir existed at login), which
  # would silently defer the first sync forever. PATH below deliberately
  # excludes both the fake $HOME/.local/bin and the devcontainer's real
  # aicoding-sync.
  unset AICODINGSETUP_SKIP_NETWORK
  printf '#!/bin/bash\necho "RAN $*" > "$HOME/sync-ran"\n' > "$HOME/.local/bin/aicoding-sync"
  chmod +x "$HOME/.local/bin/aicoding-sync"
  run bash -c "PATH='$TMPDIR/stubs:/usr/bin:/bin'; source '$BLUEPRINT_ROOT/configs/bash/boot-sync.sh'; for i in \$(seq 50); do [ -f \"\$HOME/sync-ran\" ] && break; sleep 0.1; done; cat \"\$HOME/sync-ran\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN --boot"* ]]
}

@test "boot-sync snippet: concurrent shells launch only one sync" {
  unset AICODINGSETUP_SKIP_NETWORK
  cat > "$HOME/.local/bin/aicoding-sync" <<'EOF'
#!/bin/bash
echo start >> "$HOME/sync-ran"
sleep 0.2
echo done >> "$HOME/sync-ran"
EOF
  chmod +x "$HOME/.local/bin/aicoding-sync"

  run bash -c '
    for _ in $(seq 20); do
      PATH="$TMPDIR/stubs:/usr/bin:/bin" bash -c ". \"$BLUEPRINT_ROOT/configs/bash/boot-sync.sh\"" &
    done
    wait
    for _ in $(seq 100); do
      [ "$(grep -c "^done$" "$HOME/sync-ran" 2>/dev/null || true)" -eq 1 ] && break
      sleep 0.05
    done
    cat "$HOME/sync-ran"
  '
  [ "$status" -eq 0 ]
  [ "$(grep -c '^start$' <<<"$output")" -eq 1 ]
  [ "$(grep -c '^done$' <<<"$output")" -eq 1 ]
  [ ! -e "$HOME/.local/state/aicoding/updates/.boot-sync.lock" ]
}

@test "boot-sync snippet: recovers an abandoned stale lock" {
  unset AICODINGSETUP_SKIP_NETWORK
  printf '#!/bin/bash\necho done > "$HOME/sync-ran"\n' > "$HOME/.local/bin/aicoding-sync"
  chmod +x "$HOME/.local/bin/aicoding-sync"
  mkdir -p "$HOME/.local/state/aicoding/updates/.boot-sync.lock"
  touch -d '2000-01-01' "$HOME/.local/state/aicoding/updates/.boot-sync.lock"

  run bash -c '
    PATH="$TMPDIR/stubs:/usr/bin:/bin" source "$BLUEPRINT_ROOT/configs/bash/boot-sync.sh"
    for _ in $(seq 100); do
      [ -f "$HOME/sync-ran" ] && break
      sleep 0.05
    done
    cat "$HOME/sync-ran"
  '
  [ "$status" -eq 0 ]
  [ "$output" = done ]
  [ ! -e "$HOME/.local/state/aicoding/updates/.boot-sync.lock" ]
  # The steal renames the stale lock to .boot-sync.lock.stale.<pid> before
  # removing it — recovery must not leave that private copy behind either.
  [ -z "$(find "$HOME/.local/state/aicoding/updates" -maxdepth 1 -name '.boot-sync.lock.stale.*' -print 2>/dev/null)" ]
}

@test "aicoding-install: dispatches to install-host.sh when profile=host" {
  mkdir -p "$HOME/.local/state/aicoding"
  echo '{"profile":"host"}' > "$HOME/.local/state/aicoding/manifest.json"
  # Fake blueprint clone with sentinel installers; no network.
  CLONE="$TMPDIR/clone"; mkdir -p "$CLONE/lib"
  printf '#!/bin/bash\necho HOST-INSTALLER-RAN\n' > "$CLONE/install-host.sh"
  printf '#!/bin/bash\necho CONTAINER-INSTALLER-RAN\n' > "$CLONE/install.sh"
  run env AICODING_BLUEPRINT_CLONE="$CLONE" bash "$BLUEPRINT_ROOT/bin/aicoding-install"
  [[ "$output" == *"HOST-INSTALLER-RAN"* ]]
  [[ "$output" != *"CONTAINER-INSTALLER-RAN"* ]]
}
