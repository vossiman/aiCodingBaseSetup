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

@test "Chrome for Testing branded output records its actual browser version" {
  cat > "$cache/chromium-123/chrome-linux64/chrome" <<'BROWSER'
#!/bin/sh
echo 'Google Chrome for Testing 143.0.7499.4'
BROWSER
  _aicoding_finish_npm_entry_release mcp-playwright "$target" "$release" playwright-mcp bin/playwright-mcp
  jq -e '.components["playwright-chromium"] | .state == "updated" and .successful_version == "143.0.7499.4" and .reason == "browser_ready"' "$AICODING_RESULTS_FILE"
  ensure_playwright_browsers
  jq -e '.components["playwright-chromium"] | .state == "current" and .successful_version == "143.0.7499.4" and .reason == "browser_ready"' "$AICODING_RESULTS_FILE"
}

_fixture_install_cli() {
  cat > "$release/node_modules/@playwright/mcp/cli.js"
  chmod +x "$release/node_modules/@playwright/mcp/cli.js"
}

@test "failed Chromium download records why on the browser and the package" {
  _fixture_install_cli <<'CLI'
#!/bin/sh
printf 'Downloading Chrome 1 (playwright chromium v1)\033[2m from https://cdn.example/a.zip\033[22m\n'
printf '|      |  50%% of 197.8 MiB\r\n'
echo 'Error: Request to https://user:secret@storage.example/a.zip timed out after 120000ms'
echo '    at TLSSocket.emit (node:events:530:35)'
printf 'Downloading Chrome 1 (playwright chromium v1)\033[2m from https://mirror.example/a.zip\033[22m\n'
exit 1
CLI
  run _aicoding_prepare_playwright_browser mcp-playwright "$target" "$release"
  [ "$status" -ne 0 ]
  jq -e '[.components["playwright-chromium"], .components["mcp-playwright"]] | all(
    .state == "failed" and .reason == "browser_install_failed"
    and (.detail | test("^exit 1 after [0-9]+s, 1 restarted transfers; Error: Request to https://storage.example/a.zip timed out after 120000ms$")))' "$AICODING_RESULTS_FILE"
  jq -e '.components["playwright-chromium"].download.restarts == 1
    and (.components["mcp-playwright"] | has("download") | not)' "$AICODING_RESULTS_FILE"
  if grep -q secret "$AICODING_RESULTS_FILE"; then false; fi
  [ "$(stat -c %a "$AICODING_STATE_DIR/playwright-install.log")" = 600 ]
}

@test "a restarted Chromium download stays visible after it succeeds" {
  _fixture_install_cli <<'CLI'
#!/bin/sh
echo 'Downloading Chrome 1 (playwright chromium v1) from https://cdn.example/a.zip'
echo 'Downloading Chrome 1 (playwright chromium v1) from https://cdn.example/a.zip'
echo 'Downloading Chrome Headless Shell 1 (playwright chromium-headless-shell v1) from https://cdn.example/b.zip'
CLI
  run _aicoding_finish_npm_entry_release mcp-playwright "$target" "$release" playwright-mcp bin/playwright-mcp
  [ "$status" -eq 0 ]
  [[ "$output" == *"Chromium download was slow"* ]]
  jq -e '.components["playwright-chromium"] | .state == "updated" and .download.restarts == 1
    and (.download.seconds | type == "number") and (.download.at | type == "string")' "$AICODING_RESULTS_FILE"
  printf '#!/bin/sh\nexit 0\n' | _fixture_install_cli
  ensure_playwright_browsers
  jq -e '.components["playwright-chromium"] | .state == "current" and .download.restarts == 1' "$AICODING_RESULTS_FILE"
}

@test "a browser that was already cached records no download" {
  _aicoding_finish_npm_entry_release mcp-playwright "$target" "$release" playwright-mcp bin/playwright-mcp
  jq -e '.components["playwright-chromium"] | .state == "updated" and (has("download") | not)' "$AICODING_RESULTS_FILE"
}

@test "Chromium download gets its own time limit and a longer idle limit than Playwright's default" {
  _fixture_install_cli <<'CLI'
#!/bin/sh
echo "$PLAYWRIGHT_DOWNLOAD_CONNECTION_TIMEOUT" > "$TMP/idle-limit"
sleep 2
CLI
  AICODING_VENDOR_TIMEOUT=1 AICODING_BROWSER_TIMEOUT=10 run _aicoding_prepare_playwright_browser mcp-playwright "$target" "$release"
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/idle-limit")" = 120000 ]
  AICODING_BROWSER_TIMEOUT=1 run _aicoding_prepare_playwright_browser mcp-playwright "$target" "$release"
  [ "$status" -ne 0 ]
  jq -e '.components["playwright-chromium"].detail | test("^timed out after [0-9]+s$")' "$AICODING_RESULTS_FILE"
}

@test "standalone Chromium install failure records why" {
  ln -s "../versions/mcp-playwright/$target" "$AICODING_DATA_DIR/current/mcp-playwright"
  _fixture_install_cli <<'CLI'
#!/bin/sh
echo 'Failed to install browsers'
exit 3
CLI
  run ensure_playwright_browsers
  [ "$status" -eq 0 ]
  jq -e '.components["playwright-chromium"] | .reason == "browser_install_failed"
    and (.detail | test("^exit 3 after [0-9]+s; Failed to install browsers$"))' "$AICODING_RESULTS_FILE"
}

@test "provisioning keeps a package's own blocker instead of reporting it as not staged" {
  export SCRIPT_DIR="$BLUEPRINT_ROOT"
  aicoding_result_record mcp-playwright failed "$target" browser_install_failed "" "timed out after 1800s"
  _AICODING_PREPARATION_DEFERRED=
  rc=0; _provision_reconcile_exact_mcp playwright mcp-playwright playwright-mcp --browser chromium || rc=$?
  [ "$rc" -eq 3 ]
  [ "$_AICODING_PREPARATION_DEFERRED" = 1 ]
  jq -e '.components["mcp-playwright"] | .state == "failed" and .reason == "browser_install_failed"
    and .detail == "timed out after 1800s"' "$AICODING_RESULTS_FILE"
}
