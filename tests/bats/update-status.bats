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

@test "behind: installed != latest -> banner shows CTA" {
  echo 2222222222222222222222222222222222222222 > "$AICODING_UPDATE_TESTONLY_INSTALLED_FILE"
  FAKE_LATEST=1111111111111111111111111111111111111111 run "$BIN" --refresh
  [ "$status" -eq 0 ]
  [ "$(cache | jq -r .latest | cut -c1-7)" = "1111111" ]
  run "$BIN" --banner
  echo "$output" | grep -q "demo"
  echo "$output" | grep -q "behind"
}

@test "up_to_date: installed == latest -> banner silent" {
  echo 1111111111111111111111111111111111111111 > "$AICODING_UPDATE_TESTONLY_INSTALLED_FILE"
  FAKE_LATEST=1111111111111111111111111111111111111111 "$BIN" --refresh
  run "$BIN" --banner
  [ -z "$output" ]
}

@test "throttle: fresh cache means no network call on refresh" {
  echo 2222222222222222222222222222222222222222 > "$AICODING_UPDATE_TESTONLY_INSTALLED_FILE"
  FAKE_LATEST=1111111111111111111111111111111111111111 "$BIN" --refresh
  FAKE_LATEST=3333333333333333333333333333333333333333 "$BIN" --refresh
  [ "$(cache | jq -r .latest | cut -c1-7)" = "1111111" ]
}

@test "fail-open: ls-remote failure on cold cache -> no badge, throttled, exit 0" {
  echo 2222222222222222222222222222222222222222 > "$AICODING_UPDATE_TESTONLY_INSTALLED_FILE"
  AICODING_UPDATE_TTL=0 FAKE_LSREMOTE_FAIL=1 run "$BIN" --refresh
  [ "$status" -eq 0 ]
  # An entry with empty latest is still written: no badge without a known
  # latest, and the fresh file throttles retry attempts via _cache_fresh.
  [ -f "$AICODING_UPDATE_STATE/demo.json" ]
  [ -z "$(cache | jq -r '.latest // empty')" ]
  run "$BIN" --tmux
  [ -z "$output" ]
}

@test "fail-open: ls-remote failure preserves the prior known latest (no clobber)" {
  echo 2222222222222222222222222222222222222222 > "$AICODING_UPDATE_TESTONLY_INSTALLED_FILE"
  FAKE_LATEST=1111111111111111111111111111111111111111 "$BIN" --refresh
  AICODING_UPDATE_TTL=0 FAKE_LSREMOTE_FAIL=1 run "$BIN" --refresh
  [ "$status" -eq 0 ]
  [ "$(cache | jq -r .latest | cut -c1-7)" = "1111111" ]
  run "$BIN" --tmux
  [[ "$output" == *"⬆demo"* ]]
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

@test "tmux: multiple behind tools -> space-separated, registry order, no trailing space" {
  export AICODING_UPDATE_TESTONLY_TOOL="aicoding dvw"
  echo 2222222222222222222222222222222222222222 > "$AICODING_UPDATE_TESTONLY_INSTALLED_FILE.aicoding"
  echo 3333333333333333333333333333333333333333 > "$AICODING_UPDATE_TESTONLY_INSTALLED_FILE.dvw"
  FAKE_LATEST=1111111111111111111111111111111111111111 "$BIN" --refresh
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
  [ "$(cache | jq -r .latest | cut -c1-7)" = "1111111" ]
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

# --- print-time verdict (see: six stranded-cache fixes) ---------------------
# The cache used to freeze `installed` and the derived `status` alongside
# `latest`. That made every manifest writer responsible for invalidating the
# cache — an invariant that failed six times (44a9d42 25deb8f d6ee59b 43795ff
# 4f621bc 178f776), because new writers appear and self-updating sync executes
# the previous library. The verdict is now computed at print time from a FRESH
# installed read vs the cached latest, so there is no stored verdict left for
# any writer to strand.

@test "stale cache self-heals: a manifest stamp clears the badge at print time, no refresh" {
  echo 2222222222222222222222222222222222222222 > "$AICODING_UPDATE_TESTONLY_INSTALLED_FILE"
  FAKE_LATEST=1111111111111111111111111111111111111111 "$BIN" --refresh
  run "$BIN" --tmux
  [[ "$output" == *"⬆demo"* ]]
  # A writer stamps installed to latest but does NOT invalidate the cache —
  # the recurring bug class. The badge must clear anyway, within the TTL.
  echo 1111111111111111111111111111111111111111 > "$AICODING_UPDATE_TESTONLY_INSTALLED_FILE"
  run "$BIN" --tmux
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "banner self-heals the same way as the tmux badge" {
  echo 2222222222222222222222222222222222222222 > "$AICODING_UPDATE_TESTONLY_INSTALLED_FILE"
  FAKE_LATEST=1111111111111111111111111111111111111111 "$BIN" --refresh
  run "$BIN" --print
  echo "$output" | grep -q demo
  echo 1111111111111111111111111111111111111111 > "$AICODING_UPDATE_TESTONLY_INSTALLED_FILE"
  run "$BIN" --print
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "badge appears at print time when installed regresses against a fresh latest" {
  echo 1111111111111111111111111111111111111111 > "$AICODING_UPDATE_TESTONLY_INSTALLED_FILE"
  FAKE_LATEST=1111111111111111111111111111111111111111 "$BIN" --refresh
  run "$BIN" --tmux
  [ -z "$output" ]
  # e.g. a fresh container adopts an older shared-mount manifest after the
  # cache was already warm — behind must show without waiting out the TTL.
  echo 2222222222222222222222222222222222222222 > "$AICODING_UPDATE_TESTONLY_INSTALLED_FILE"
  run "$BIN" --tmux
  [[ "$output" == *"⬆demo"* ]]
}

@test "cache stores no frozen verdict: neither installed nor status fields" {
  # Structural guard for the six-times-fixed defect: if either field returns,
  # some future code can read a stale verdict again and the writer-invalidation
  # treadmill restarts.
  echo 2222222222222222222222222222222222222222 > "$AICODING_UPDATE_TESTONLY_INSTALLED_FILE"
  FAKE_LATEST=1111111111111111111111111111111111111111 "$BIN" --refresh
  [ "$(cache | jq 'has("installed") or has("status")')" = "false" ]
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
