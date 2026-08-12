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

@test "install-host.sh: deploys host-shaped managed set (boot-sync yes, tmux/codex no)" {
  export AICODINGSETUP_SKIP_NETWORK=1
  bash -c "cd '$BLUEPRINT_ROOT' && bash install-host.sh"
  [ -f "$HOME/.bashrc.d/aicoding-boot-sync.sh" ]
  [ -f "$HOME/.claude/CLAUDE.md" ]
  [ ! -f "$HOME/.tmux.conf" ]
  [ ! -f "$HOME/.codex/config.toml" ]
  grep -q 'aicoding managed block' "$HOME/.bashrc"
}

@test "install-host.sh: second run is reconcile mode, still exits 0" {
  export AICODINGSETUP_SKIP_NETWORK=1
  bash -c "cd '$BLUEPRINT_ROOT' && bash install-host.sh"
  run bash -c "cd '$BLUEPRINT_ROOT' && bash install-host.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"reconcile"* ]]
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
