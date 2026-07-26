#!/usr/bin/env bats

setup() {
  : "${BLUEPRINT_ROOT:?unset — run via tests/bats/run.sh}"
  BIN="$BLUEPRINT_ROOT/bin/aicoding-status"
  TMP=$(mktemp -d); export HOME="$TMP"
  export AICODING_UPDATE_STATE="$TMP/state/updates"
  export AICODING_UPDATE_TTL=3600
  mkdir -p "$TMP/stubs"
  cat > "$TMP/stubs/git" <<STUB
#!/bin/sh
if [ "\$1" = "ls-remote" ]; then
  [ -n "\${FAKE_LSREMOTE_FAIL:-}" ] && exit 1
  printf '%s\t%s\n' "\${FAKE_LATEST:-1111111111111111111111111111111111111111}" refs/heads/main
  exit 0
fi
exec /usr/bin/git "\$@"
STUB
  chmod +x "$TMP/stubs/git"
  export PATH="$TMP/stubs:$PATH"
  export AICODING_UPDATE_TESTONLY_TOOL="demo"
  export AICODING_UPDATE_TESTONLY_REMOTE="https://example.invalid/demo"
  export AICODING_UPDATE_TESTONLY_INSTALLED_FILE="$TMP/installed"
}
teardown() { rm -rf "$TMP"; }

cache() { cat "$AICODING_UPDATE_STATE/demo.json"; }

@test "behind: installed != latest -> status behind, banner shows CTA" {
  echo 2222222222222222222222222222222222222222 > "$AICODING_UPDATE_TESTONLY_INSTALLED_FILE"
  FAKE_LATEST=1111111111111111111111111111111111111111 run "$BIN" --refresh
  [ "$status" -eq 0 ]
  [ "$(cache | jq -r .status)" = "behind" ]
  run "$BIN" --banner
  echo "$output" | grep -q "demo"
  echo "$output" | grep -q "behind"
}

@test "up_to_date: installed == latest -> banner silent" {
  echo 1111111111111111111111111111111111111111 > "$AICODING_UPDATE_TESTONLY_INSTALLED_FILE"
  FAKE_LATEST=1111111111111111111111111111111111111111 "$BIN" --refresh
  [ "$(cache | jq -r .status)" = "up_to_date" ]
  run "$BIN" --banner
  [ -z "$output" ]
}

@test "throttle: fresh cache means no network call on refresh" {
  echo 2222222222222222222222222222222222222222 > "$AICODING_UPDATE_TESTONLY_INSTALLED_FILE"
  FAKE_LATEST=1111111111111111111111111111111111111111 "$BIN" --refresh
  FAKE_LATEST=3333333333333333333333333333333333333333 "$BIN" --refresh
  [ "$(cache | jq -r .latest | cut -c1-7)" = "1111111" ]
}

@test "fail-open: ls-remote failure on cold cache -> unknown, exit 0" {
  echo 2222222222222222222222222222222222222222 > "$AICODING_UPDATE_TESTONLY_INSTALLED_FILE"
  AICODING_UPDATE_TTL=0 FAKE_LSREMOTE_FAIL=1 run "$BIN" --refresh
  [ "$status" -eq 0 ]
  [ "$(cache | jq -r .status)" = "unknown" ]
}

@test "fail-open: ls-remote failure preserves a prior good status (no clobber)" {
  echo 2222222222222222222222222222222222222222 > "$AICODING_UPDATE_TESTONLY_INSTALLED_FILE"
  FAKE_LATEST=1111111111111111111111111111111111111111 "$BIN" --refresh
  [ "$(cache | jq -r .status)" = "behind" ]
  AICODING_UPDATE_TTL=0 FAKE_LSREMOTE_FAIL=1 run "$BIN" --refresh
  [ "$status" -eq 0 ]
  [ "$(cache | jq -r .status)" = "behind" ]
}

# The segment is APPENDED to status-right, straight after the clock, so it must
# carry its own leading gap and divider — the config can't add them, since a
# static separator would leave a dangling "│" on every up-to-date container.
# Divider styled in the bar's blue, badge in CTA yellow; the config no longer
# colours the segment.
@test "tmux: a behind tool renders a compact badge behind a styled divider" {
  echo 2222222222222222222222222222222222222222 > "$AICODING_UPDATE_TESTONLY_INSTALLED_FILE"
  FAKE_LATEST=1111111111111111111111111111111111111111 "$BIN" --refresh
  run "$BIN" --tmux
  [ "$status" -eq 0 ]
  [ "$output" = " #[fg=#89b4fa]│ #[fg=#f9e2af]⬆demo" ]
}

@test "tmux: all up-to-date -> nothing at all, not a bare divider" {
  echo 1111111111111111111111111111111111111111 > "$AICODING_UPDATE_TESTONLY_INSTALLED_FILE"
  FAKE_LATEST=1111111111111111111111111111111111111111 "$BIN" --refresh
  run "$BIN" --tmux
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "tmux: multiple behind tools -> space-separated, alphabetical, no trailing space" {
  mkdir -p "$AICODING_UPDATE_STATE"
  printf '{"tool":"aicoding","status":"behind"}' > "$AICODING_UPDATE_STATE/aicoding.json"
  printf '{"tool":"dvw","status":"behind"}'      > "$AICODING_UPDATE_STATE/dvw.json"
  run "$BIN" --tmux
  [ "$status" -eq 0 ]
  [ "$output" = " #[fg=#89b4fa]│ #[fg=#f9e2af]⬆aicoding ⬆dvw" ]
}

@test "stale-lock: a lock older than TTL is stolen and refresh proceeds" {
  echo 2222222222222222222222222222222222222222 > "$AICODING_UPDATE_TESTONLY_INSTALLED_FILE"
  mkdir -p "$AICODING_UPDATE_STATE/.lock"
  touch -d '2000-01-01' "$AICODING_UPDATE_STATE/.lock"
  AICODING_UPDATE_TTL=0 FAKE_LATEST=1111111111111111111111111111111111111111 run "$BIN" --refresh
  [ "$status" -eq 0 ]
  [ "$(cache | jq -r .status)" = "behind" ]
}

@test "registry is aicoding-only (no dvw entry) in-container" {
  # Unset the TESTONLY override so the real in-container registry is used.
  unset AICODING_UPDATE_TESTONLY_TOOL AICODING_UPDATE_TESTONLY_REMOTE AICODING_UPDATE_TESTONLY_INSTALLED_FILE
  run "$BIN" --print
  ! echo "$output" | grep -qi dvw
}

# --- container-local state (see: shared-manifest defect) ------------------
# Both the status cache and the manifest used to live under ~/.aicodingsetup,
# a host bind mount shared by every container. One container syncing stamped
# the global manifest to the new commit, so every OTHER container computed
# installed == latest and went quiet while still running stale files.

@test "status cache default is container-local, not the shared aicodingsetup mount" {
  unset AICODING_UPDATE_STATE
  echo 1111111111111111111111111111111111111111 > "$AICODING_UPDATE_TESTONLY_INSTALLED_FILE"
  run "$BIN" --refresh
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.aicodingsetup/state/updates/demo.json" ]
  [ -f "$HOME/.local/state/aicoding/updates/demo.json" ]
}

@test "manifest: adopts a shared-mount manifest once, leaving the shared copy intact" {
  unset AICODING_MANIFEST
  mkdir -p "$HOME/.aicodingsetup"
  echo '{"schema_version":1,"blueprint_commit":"abc123","files":{}}' \
    > "$HOME/.aicodingsetup/manifest.json"

  # Sourcing alone must NOT migrate — the library documents "no top-level side
  # effects". Adoption happens on the first manifest read.
  run bash -c ". '$BLUEPRINT_ROOT/lib/blueprint-deploy.sh'; printf '%s' \"\$AICODING_MANIFEST\""
  [ "$status" -eq 0 ]
  local local_manifest="$HOME/.local/state/aicoding/manifest.json"
  [ "$output" = "$local_manifest" ]
  [ ! -e "$local_manifest" ]

  run bash -c ". '$BLUEPRINT_ROOT/lib/blueprint-deploy.sh'; read_manifest >/dev/null"
  [ "$status" -eq 0 ]

  # migrated into the container, and the shared original is NOT removed:
  # other containers still need it for their own one-time adoption.
  [ -f "$local_manifest" ]
  [ "$(jq -r .blueprint_commit "$local_manifest")" = "abc123" ]
  [ -f "$HOME/.aicodingsetup/manifest.json" ]
}

@test "no writer stamps blueprint_commit outside manifest_stage_set_blueprint" {
  # Stamping the commit and invalidating this cache must never drift apart: a
  # site that does the first without the second leaves the badge asserting the
  # pre-run commit, and _cache_fresh then suppresses re-checks for the whole
  # TTL. install.sh's three provision sites did exactly that (2026-07-26).
  # manifest_stage_set_blueprint does both, so it is the only legal writer —
  # the helper's own set_top call in blueprint-deploy.sh is the sole exception.
  local hits
  hits=$(grep -rn 'manifest_stage_set_top blueprint_commit' \
    "$BLUEPRINT_ROOT/bin" "$BLUEPRINT_ROOT/lib" "$BLUEPRINT_ROOT/install.sh" 2>/dev/null \
    | grep -v '/lib/blueprint-deploy.sh:' || true)
  if [ -n "$hits" ]; then
    echo "blueprint_commit stamped without cache invalidation:"
    echo "$hits"
    return 1
  fi
}

@test "no shipped entrypoint re-defaults manifest/update-state to the shared mount" {
  # Files in bin/ have NO extension, so a `--include='*.sh'` grep misses them —
  # exactly how bin/aicoding-sync kept the old shared default while everything
  # else moved container-local. An entrypoint that pre-sets the var silently
  # wins, because `:=` in the library is then a no-op: sync wrote the shared
  # manifest, aicoding-status read the container-local one, and the update
  # badge could never clear. Scan by path, never by extension.
  local hits
  hits=$(grep -rn \
    -e 'AICODING_MANIFEST:=' -e 'AICODING_MANIFEST:-' \
    -e 'AICODING_UPDATE_STATE:=' -e 'AICODING_UPDATE_STATE:-' \
    "$BLUEPRINT_ROOT/bin" "$BLUEPRINT_ROOT/lib" 2>/dev/null \
    | grep 'aicodingsetup' || true)
  if [ -n "$hits" ]; then
    echo "shared-mount default(s) still shipped:"
    echo "$hits"
    return 1
  fi
}
