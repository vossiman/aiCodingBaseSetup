#!/usr/bin/env bats
setup() {
  : "${BLUEPRINT_ROOT:?run via run.sh}"
  export TMP; TMP=$(mktemp -d)
  export HOME="$TMP/home" AICODING_STATE_DIR="$TMP/state" AICODING_DATA_DIR="$TMP/data"
  mkdir -p "$HOME/.local/bin" "$TMP/stubs" "$TMP/package/dist-package"
  export PATH="$TMP/stubs:/usr/bin:/bin"
  export CURSOR_TEST_VERSION=2026.09.10-fd3934a
  printf '#!/bin/sh\necho %s\n' "$CURSOR_TEST_VERSION" > "$TMP/package/dist-package/cursor-agent"
  chmod +x "$TMP/package/dist-package/cursor-agent"
  tar -czf "$TMP/package.tar.gz" -C "$TMP/package" dist-package
  cat > "$TMP/stubs/curl" <<'STUB'
#!/bin/bash
case "$*" in
  *https://cursor.com/install*) printf 'DOWNLOAD_URL="https://downloads.cursor.com/lab/%s/${OS}/${ARCH}/agent-cli-package.tar.gz"\n' "$CURSOR_TEST_VERSION" ;;
  *https://downloads.cursor.com/lab/*) cat "$TMP/package.tar.gz" ;;
  *) exit 8 ;;
esac
STUB
  chmod +x "$TMP/stubs/curl"
  unset AICODINGSETUP_SKIP_NETWORK
  . "$BLUEPRINT_ROOT/lib/update-results.sh"
  . "$BLUEPRINT_ROOT/lib/update-components.sh"
}
teardown() { rm -rf "$TMP"; }
@test "Cursor stages exact vendor archive and activates both Linux aliases" {
  run aicoding_update_component cursor
  [ "$status" -eq 0 ]
  [ "$("$HOME/.local/bin/agent" --version)" = "$CURSOR_TEST_VERSION" ]
  [ "$("$HOME/.local/bin/cursor-agent" --version)" = "$CURSOR_TEST_VERSION" ]
  jq -e '.components.cursor.state == "updated"' "$AICODING_RESULTS_FILE"
}
@test "Cursor version mismatch preserves existing launcher" {
  printf '#!/bin/sh\necho old\n' > "$HOME/.local/bin/agent"
  chmod +x "$HOME/.local/bin/agent"
  export CURSOR_TEST_VERSION=2026.09.11-abcdef0
  run aicoding_update_component cursor
  [ "$status" -ne 0 ]
  [ "$("$HOME/.local/bin/agent")" = old ]
  jq -e '.components.cursor.reason == "staged_version_mismatch"' "$AICODING_RESULTS_FILE"
}
@test "Cursor rejects archive links without touching their destination" {
  ln -s "$TMP/escaped" "$TMP/package/dist-package/escape"
  tar -czf "$TMP/package.tar.gz" -C "$TMP/package" dist-package
  run aicoding_update_component cursor
  [ "$status" -ne 0 ]
  [ ! -e "$TMP/escaped" ]
  jq -e '.components.cursor.reason == "archive_invalid"' "$AICODING_RESULTS_FILE"
}
@test "Cursor does no download under network guard" {
  export AICODINGSETUP_SKIP_NETWORK=1
  run aicoding_update_component cursor
  [ "$status" -ne 0 ]
  jq -e '.components.cursor.reason == "network_disabled"' "$AICODING_RESULTS_FILE"
}
@test "Cursor reuses verified release and rejects later tampering" {
  aicoding_update_component cursor
  aicoding_update_component cursor
  jq -e '.components.cursor.state == "current"' "$AICODING_RESULTS_FILE"
  printf '\n# tamper\n' >> "$AICODING_DATA_DIR/versions/cursor/$CURSOR_TEST_VERSION/cursor-agent"
  run aicoding_update_component cursor
  [ "$status" -ne 0 ]
  jq -e '.components.cursor.reason == "existing_release_invalid"' "$AICODING_RESULTS_FILE"
}
@test "Cursor refuses malformed vendor metadata without executing it" {
  cat > "$TMP/stubs/curl" <<'STUB'
#!/bin/sh
echo 'touch "$HOME/installer-executed"'
echo 'https://downloads.cursor.com/lab/../../escape/linux/x64/agent-cli-package.tar.gz'
STUB
  run aicoding_update_component cursor
  [ "$status" -ne 0 ]
  [ ! -e "$HOME/installer-executed" ]
  jq -e '.components.cursor.reason == "target_version_unavailable"' "$AICODING_RESULTS_FILE"
}
@test "host preparation includes installed Cursor runtime" {
  . "$BLUEPRINT_ROOT/lib/provision.sh"
  _provision_ensure_update_components() { return 0; }
  aicoding_installed_components() { echo cursor; }
  run aicoding_prepare_installed_config_tools
  [ "$status" -eq 0 ]
  [ -x "$HOME/.local/bin/agent" ]
  jq -e '.components.cursor.state == "updated"' "$AICODING_RESULTS_FILE"
}
