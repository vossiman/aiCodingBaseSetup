#!/usr/bin/env bats
# _update_codex: version-gated codex refresh (spec:
# docs/superpowers/specs/2026-08-09-codex-self-update-design.md).
# codex is "installed" as a REAL file in $TMP/.local/bin (like the baked
# image seed); curl is stubbed to serve the npm registry JSON and the
# installer script; jq is the real binary.
setup() {
  : "${BLUEPRINT_ROOT:?run via run.sh}"
  export TMP; TMP=$(mktemp -d); export HOME="$TMP"
  mkdir -p "$TMP/stubs" "$TMP/.local/bin"

  # Baked-seed stand-in: real file (not a symlink), old version.
  printf '#!/bin/sh\necho "codex-cli 0.147.0"\n' > "$TMP/.local/bin/codex"
  chmod +x "$TMP/.local/bin/codex"

  # curl stub: registry URL -> JSON with $CODEX_LATEST; installer URL ->
  # a script (piped into sh by the code under test) that drops a new
  # codex into ~/.codex/bin and logs. Any other URL: log + fail.
  cat > "$TMP/stubs/curl" <<'EOF'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    *registry.npmjs.org*)
      echo "curl-registry" >> "$TMP/ran.log"
      [ "${CODEX_REGISTRY_FAIL:-}" = 1 ] && exit 22
      printf '{"version":"%s"}\n' "$CODEX_LATEST"; exit 0 ;;
    *chatgpt.com*)
      echo "curl-installer" >> "$TMP/ran.log"
      [ "${CODEX_INSTALLER_FAIL:-}" = 1 ] && exit 22
      cat <<INNER
mkdir -p "\$HOME/.codex/bin"
printf '#!/bin/sh\necho "codex-cli %s"\n' "${CODEX_INSTALLS:-$CODEX_LATEST}" > "\$HOME/.codex/bin/codex"
chmod +x "\$HOME/.codex/bin/codex"
INNER
      exit 0 ;;
  esac
done
echo "curl-other $*" >> "$TMP/ran.log"; exit 1
EOF
  chmod +x "$TMP/stubs/curl"

  export CODEX_LATEST="0.148.0"
  export PATH="$TMP/.local/bin:$TMP/stubs:$PATH"
  unset AICODINGSETUP_SKIP_NETWORK
  . "$BLUEPRINT_ROOT/lib/sync.sh"
}
teardown() { rm -rf "$TMP"; }

@test "codex update: equal versions -> silent no-op, no installer" {
  CODEX_LATEST="0.147.0" run _update_codex
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run grep -q "curl-installer" "$TMP/ran.log"
  [ "$status" -ne 0 ]
}

@test "codex update: newer version -> installer runs, seed force-linked" {
  run _update_codex
  [ "$status" -eq 0 ]
  grep -q "curl-installer" "$TMP/ran.log"
  [ -L "$TMP/.local/bin/codex" ]   # real file replaced by symlink
  [ "$(readlink "$TMP/.local/bin/codex")" = "$TMP/.codex/bin/codex" ]
  [ "$(codex --version)" = "codex-cli 0.148.0" ]
  run bash -c 'echo "$1" | grep ERROR' _ "$output"
  [ "$status" -ne 0 ]              # no ERROR emitted on success
}

@test "codex update: registry probe failure -> ERROR line, exit 0, no installer" {
  CODEX_REGISTRY_FAIL=1 run _update_codex
  [ "$status" -eq 0 ]
  [[ "$output" == *"ERROR: codex update check failed"* ]]
  run grep -q "curl-installer" "$TMP/ran.log"
  [ "$status" -ne 0 ]
}

@test "codex update: SKIP_NETWORK -> silent, zero network" {
  AICODINGSETUP_SKIP_NETWORK=1 run _update_codex
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$TMP/ran.log" ]          # curl never invoked
}

@test "codex update: codex absent -> silent no-op" {
  rm "$TMP/.local/bin/codex"
  run env PATH="$TMP/stubs:/usr/bin:/bin" bash -c '. "$BLUEPRINT_ROOT/lib/sync.sh"; _update_codex'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$TMP/ran.log" ]
}

@test "codex update: installer failure -> ERROR still-at line, exit 0" {
  CODEX_INSTALLER_FAIL=1 run _update_codex
  [ "$status" -eq 0 ]
  [[ "$output" == *"ERROR: codex update failed — still at 0.147.0"* ]]
  [ ! -L "$TMP/.local/bin/codex" ]   # seed untouched
}

@test "codex update: post-verify mismatch -> ERROR names both versions" {
  CODEX_INSTALLS="0.147.0" run _update_codex   # installer "succeeds" but drops old version
  [ "$status" -eq 0 ]
  [[ "$output" == *"ERROR: codex updated but version is still 0.147.0 (expected 0.148.0)"* ]]
}

@test "_sync_binaries invokes the codex updater" {
  # claude/opencode/agent logging stubs so _sync_binaries' other calls
  # stay off the network (standing rule: agent CLIs are external binaries).
  for c in claude opencode agent; do
    printf '#!/bin/sh\necho "%s $*" >> "$TMP/ran.log"\n' "$c" > "$TMP/stubs/$c"
    chmod +x "$TMP/stubs/$c"
  done
  run _sync_binaries
  [ "$status" -eq 0 ]
  grep -q "curl-installer" "$TMP/ran.log"   # codex path reached via _sync_binaries
}

@test "_sync_binaries labels each pass-through updater, codex stays self-labeled" {
  # Cursor's binary is named `agent`, so unlabeled output is unattributable
  # (2026-08-12: its "[unauthenticated]" error was mistaken for codex).
  for c in claude opencode agent; do
    printf '#!/bin/sh\necho "%s $*" >> "$TMP/ran.log"\n' "$c" > "$TMP/stubs/$c"
    chmod +x "$TMP/stubs/$c"
  done
  CODEX_LATEST="0.147.0" run _sync_binaries   # codex up to date -> silent
  [ "$status" -eq 0 ]
  [[ "$output" == *"--- claude update ---"* ]]
  [[ "$output" == *"--- opencode upgrade ---"* ]]
  [[ "$output" == *"--- cursor (agent update) ---"* ]]
  [[ "$output" != *"--- codex"* ]]   # _update_codex self-labels its errors
}

@test "_sync_binaries: cursor-agent fallback gets its own label" {
  # Restricted PATH (line-85 pattern) hides the dev box's real `agent` so
  # the elif fallback is actually exercised; codex absent -> silent no-op.
  for c in claude opencode cursor-agent; do
    printf '#!/bin/sh\necho "%s $*" >> "$TMP/ran.log"\n' "$c" > "$TMP/stubs/$c"
    chmod +x "$TMP/stubs/$c"
  done
  run env PATH="$TMP/stubs:/usr/bin:/bin" bash -c '. "$BLUEPRINT_ROOT/lib/sync.sh"; _sync_binaries'
  [ "$status" -eq 0 ]
  [[ "$output" == *"--- cursor (cursor-agent update) ---"* ]]
  [[ "$output" != *"--- cursor (agent update) ---"* ]]
}
