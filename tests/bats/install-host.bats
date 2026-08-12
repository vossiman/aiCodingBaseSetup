#!/usr/bin/env bats

setup() {
  : "${BLUEPRINT_ROOT:?unset — run via tests/bats/run.sh; refusing to default to / and copy the whole filesystem}"
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  export AICODING_MANIFEST="$TMPDIR/.local/state/aicoding/manifest.json"
  export AICODINGSETUP_NONINTERACTIVE=1
  export PATH="$TMPDIR/stubs:$PATH"
  mkdir -p "$TMPDIR/stubs" "$TMPDIR/.local/bin"
  # Prereq stubs present by default; individual tests remove them.
  for t in git curl jq node npm bwrap claude; do
    printf '#!/bin/bash\nexit 0\n' > "$TMPDIR/stubs/$t"; chmod +x "$TMPDIR/stubs/$t"
  done
}

teardown() { rm -rf "$TMPDIR"; }

_source_host_lib() {
  ( cd "$BLUEPRINT_ROOT" \
    && source lib/provision.sh >/dev/null 2>&1 \
    && source lib/provision-system.sh >/dev/null 2>&1 \
    && source lib/provision-integrations.sh >/dev/null 2>&1; "$@" )
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
