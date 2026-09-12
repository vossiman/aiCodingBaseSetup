#!/usr/bin/env bats
setup() {
  : "${BLUEPRINT_ROOT:?run via tests/bats/run.sh}"
  export TMP; TMP=$(mktemp -d)
  export HOME="$TMP/home" AICODING_STATE_DIR="$TMP/state" AICODING_DATA_DIR="$TMP/data"
  export AICODING_VENDOR_TIMEOUT=2 AICODING_PROBE_TIMEOUT=1
  mkdir -p "$HOME" "$TMP/stubs" "$AICODING_DATA_DIR/current"
  export PATH="$TMP/stubs:/usr/bin:/bin"
  . "$BLUEPRINT_ROOT/lib/update-results.sh"
  . "$BLUEPRINT_ROOT/lib/update-components.sh"
  . "$BLUEPRINT_ROOT/lib/provision.sh"
  . "$BLUEPRINT_ROOT/lib/provision-system.sh"
  export AICODINGSETUP_SKIP_NETWORK=
  target=0.0.80
  release="$AICODING_DATA_DIR/versions/mcp-playwright/$target"
  cache="$AICODING_DATA_DIR/browser-cache/mcp-playwright/$target"
  mkdir -p "$release/node_modules/@playwright/mcp" "$cache/chromium-123/chrome-linux64"
  cat > "$release/node_modules/@playwright/mcp/cli.js" <<'CLI'
#!/bin/sh
[ "${INSTALL_FAIL:-0}" = 0 ]
CLI
  cat > "$cache/chromium-123/chrome-linux64/chrome" <<'BROWSER'
#!/bin/sh
[ "${BROWSER_FAIL:-0}" = 0 ] || exit 1
[ "${BROWSER_HANG:-0}" = 0 ] || exec sleep 5
[ "${NO_VERSION:-0}" = 0 ] && echo 'Chromium 132.0.6834.83'
exit 0
BROWSER
  cat > "$TMP/stubs/ldd" <<'LDD'
#!/bin/sh
[ "${MISSING_LIBS:-0}" = 0 ] || echo 'libfixture.so => not found'
exit 0
LDD
  chmod +x "$release/node_modules/@playwright/mcp/cli.js" "$cache/chromium-123/chrome-linux64/chrome" "$TMP/stubs/ldd"
  _aicoding_activate_vendor_release() {
    [ "${ACTIVATE_FAIL:-0}" = 0 ] || return 1
    ln -sfn "../versions/mcp-playwright/$2" "$AICODING_DATA_DIR/current/mcp-playwright"
  }
  _aicoding_reconcile_claude_mcp_registration() { :; }
}
teardown() { rm -rf "$TMP"; }

@test "Chromium staging failure records its own receipt and preserves its previous success" {
  aicoding_result_record playwright-chromium current mcp-playwright@old browser_ready 131.0.0.1
  export INSTALL_FAIL=1
  run _aicoding_prepare_playwright_browser mcp-playwright "$target" "$release"
  [ "$status" -ne 0 ]
  jq -e '.components["playwright-chromium"] | .state == "failed" and .reason == "browser_install_failed" and .target_version == "mcp-playwright@0.0.80" and .successful_version == "131.0.0.1"' "$AICODING_RESULTS_FILE"
}

@test "staged Chromium is not recorded as active before package activation" {
  aicoding_result_record playwright-chromium current mcp-playwright@old browser_ready 131.0.0.1
  _aicoding_prepare_playwright_browser mcp-playwright "$target" "$release"
  jq -e '.components["playwright-chromium"].successful_version == "131.0.0.1"' "$AICODING_RESULTS_FILE"
  export ACTIVATE_FAIL=1
  run _aicoding_finish_npm_entry_release mcp-playwright "$target" "$release" playwright-mcp bin/playwright-mcp
  [ "$status" -ne 0 ]
  jq -e '.components["playwright-chromium"] | .state == "failed" and .reason == "activation_failed" and .successful_version == "131.0.0.1"' "$AICODING_RESULTS_FILE"
}

@test "active Chromium success records actual browser version and associated MCP target" {
  _aicoding_finish_npm_entry_release mcp-playwright "$target" "$release" playwright-mcp bin/playwright-mcp
  jq -e '.components["playwright-chromium"] | .state == "updated" and .successful_version == "132.0.6834.83" and .target_version == "mcp-playwright@0.0.80" and .succeeded_at != null' "$AICODING_RESULTS_FILE"
  [ "$AICODING_COMPONENT_LAST_RESULT" = mcp-playwright ]
}

@test "standalone Chromium deferrals are recorded despite fail-open return zero" {
  ln -s "../versions/mcp-playwright/$target" "$AICODING_DATA_DIR/current/mcp-playwright"
  export MISSING_LIBS=1
  run ensure_playwright_browsers
  [ "$status" -eq 0 ]
  jq -e '.components["playwright-chromium"] | .state == "blocked" and .reason == "playwright_system_libs_unavailable"' "$AICODING_RESULTS_FILE"
}

@test "standalone Chromium install failure is recorded despite fail-open return zero" {
  ln -s "../versions/mcp-playwright/$target" "$AICODING_DATA_DIR/current/mcp-playwright"
  export INSTALL_FAIL=1
  run ensure_playwright_browsers
  [ "$status" -eq 0 ]
  jq -e '.components["playwright-chromium"] | .state == "failed" and .reason == "browser_install_failed"' "$AICODING_RESULTS_FILE"
}

@test "standalone Chromium verified recovery supersedes previous dependency block" {
  ln -s "../versions/mcp-playwright/$target" "$AICODING_DATA_DIR/current/mcp-playwright"
  aicoding_result_record playwright-chromium blocked mcp-playwright@old playwright_system_libs_unavailable
  ensure_playwright_browsers
  jq -e '.components["playwright-chromium"] | .state == "current" and .successful_version == "132.0.6834.83"' "$AICODING_RESULTS_FILE"
}

@test "Chromium receipt never substitutes MCP version for an unavailable browser version" {
  ln -s "../versions/mcp-playwright/$target" "$AICODING_DATA_DIR/current/mcp-playwright"
  export NO_VERSION=1
  ensure_playwright_browsers
  jq -e '.components["playwright-chromium"] | .state == "current" and .successful_version == "unknown" and .reason == "browser_ready_version_unavailable"' "$AICODING_RESULTS_FILE"
}

@test "staged Chromium dependency deferral records browser and package blocks" {
  export MISSING_LIBS=1
  run _aicoding_finish_npm_entry_release mcp-playwright "$target" "$release" playwright-mcp bin/playwright-mcp
  [ "$status" -ne 0 ]
  jq -e '.components["playwright-chromium"].state == "blocked" and .components["mcp-playwright"].state == "blocked"' "$AICODING_RESULTS_FILE"
  [ ! -e "$AICODING_DATA_DIR/current/mcp-playwright" ]
}

@test "standalone Chromium marker failure cannot overwrite its failure with a ready receipt" {
  ln -s "../versions/mcp-playwright/$target" "$AICODING_DATA_DIR/current/mcp-playwright"
  mv() { [[ "${*: -1}" != */.browser-bin ]] || return 1; command mv "$@"; }
  run ensure_playwright_browsers
  [ "$status" -eq 0 ]
  jq -e '.components["playwright-chromium"] | .state == "failed" and .reason == "browser_marker_commit_failed"' "$AICODING_RESULTS_FILE"
}

@test "offline browser provisioning preserves its last attempt instead of claiming a fresh check" {
  aicoding_result_record playwright-chromium failed mcp-playwright@old browser_install_failed
  before=$(cat "$AICODING_RESULTS_FILE")
  export AICODINGSETUP_SKIP_NETWORK=1
  ensure_playwright_browsers
  [ "$(cat "$AICODING_RESULTS_FILE")" = "$before" ]
}

@test "failed or timed-out Chromium probes prevent staged activation and record genuine failure" {
  local mode
  for mode in fail timeout; do
    export BROWSER_FAIL=0 BROWSER_HANG=0
    if [ "$mode" = fail ]; then export BROWSER_FAIL=1; else export BROWSER_HANG=1; fi
    aicoding_result_record playwright-chromium current mcp-playwright@old browser_ready 131.0.0.1
    run _aicoding_finish_npm_entry_release mcp-playwright "$target" "$release" playwright-mcp bin/playwright-mcp
    [ "$status" -ne 0 ]
    jq -e '.components["playwright-chromium"] | .state == "failed" and .reason == "browser_version_probe_failed" and .successful_version == "131.0.0.1"' "$AICODING_RESULTS_FILE"
    jq -e '.components["mcp-playwright"].state == "failed"' "$AICODING_RESULTS_FILE"
    [ ! -e "$AICODING_DATA_DIR/current/mcp-playwright" ]
  done
}

@test "standalone failed Chromium version probe cannot report browser ready" {
  ln -s "../versions/mcp-playwright/$target" "$AICODING_DATA_DIR/current/mcp-playwright"
  export BROWSER_FAIL=1
  run ensure_playwright_browsers
  [ "$status" -eq 0 ]
  jq -e '.components["playwright-chromium"] | .state == "failed" and .reason == "browser_version_probe_failed" and .successful_version == null' "$AICODING_RESULTS_FILE"
}

@test "Chromium activates with its staged version evidence and probes the executable only once" {
  cat > "$cache/chromium-123/chrome-linux64/chrome" <<'BROWSER'
#!/bin/sh
printf 'probe\n' >> "$HOME/browser-probes"
[ ! -e "$HOME/after-browser-activation" ] || exit 1
echo 'Chromium 132.0.6834.83'
BROWSER
  _aicoding_activate_vendor_release() {
    touch "$HOME/after-browser-activation"
    ln -sfn "../versions/mcp-playwright/$2" "$AICODING_DATA_DIR/current/mcp-playwright"
  }
  _aicoding_finish_npm_entry_release mcp-playwright "$target" "$release" playwright-mcp bin/playwright-mcp
  [ "$(wc -l < "$HOME/browser-probes")" -eq 1 ]
  jq -e '.components["mcp-playwright"].state == "updated" and .components["playwright-chromium"].state == "updated" and .components["playwright-chromium"].successful_version == "132.0.6834.83"' "$AICODING_RESULTS_FILE"
}

@test "browser receipt persistence failure does not misreport an activated MCP package as failed" {
  eval "$(declare -f aicoding_result_record | sed '1s/aicoding_result_record/_fixture_result_record/')"
  aicoding_result_record() {
    [[ "$1" != playwright-chromium ]] || return 1
    _fixture_result_record "$@"
  }
  _aicoding_finish_npm_entry_release mcp-playwright "$target" "$release" playwright-mcp bin/playwright-mcp
  jq -e '.components["mcp-playwright"].state == "updated"' "$AICODING_RESULTS_FILE"
  [ -L "$AICODING_DATA_DIR/current/mcp-playwright" ]
}
