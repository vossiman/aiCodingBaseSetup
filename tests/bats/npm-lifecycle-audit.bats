#!/usr/bin/env bats

setup() {
  export AUDIT_TMP; AUDIT_TMP=$(mktemp -d)
  export HOME="$AUDIT_TMP/home"
  export AUDIT_ROOT="$AUDIT_TMP/package"
  mkdir -p "$HOME" "$AUDIT_ROOT/node_modules/published"
  printf '{"packages":{"node_modules/published":{"resolved":"https://registry.npmjs.org/published/-/published-1.0.0.tgz","integrity":"sha512-fixture"}}}\n' > "$AUDIT_ROOT/package-lock.json"
  source "$BLUEPRINT_ROOT/lib/update-components.sh"
}

teardown() { rm -rf "$AUDIT_TMP"; }

@test "MCP preparation reports the component and deferral reason directly" {
  source "$BLUEPRINT_ROOT/lib/update-results.sh"
  source "$BLUEPRINT_ROOT/lib/provision.sh"
  export AICODINGSETUP_SKIP_NETWORK= AICODING_PERSISTENT_ENROLLMENT=1
  aicoding_update_component() {
    [ "$1" = mcp-firecrawl ] || return 0
    _aicoding_record_deferred "$1" blocked 3.24.0 lifecycle_scripts_required
    return 1
  }
  run install_mcp_packages
  [ "$status" -eq 0 ]
  [[ "$output" == *'mcp-firecrawl'*'lifecycle_scripts_required'* ]]
}

@test "published registry build hooks do not block installing prebuilt package bytes" {
  printf '{"scripts":{"prepare":"build","prepublish":"build","preprepare":"build","postprepare":"build"}}\n' > "$AUDIT_ROOT/node_modules/published/package.json"
  run _aicoding_npm_tree_ignores_scripts_safely "$AUDIT_ROOT"
  [ "$status" -eq 0 ]
}

@test "git dependencies still require preparation even with a packaged entrypoint" {
  printf '{"scripts":{"prepare":"build"}}\n' > "$AUDIT_ROOT/node_modules/published/package.json"
  printf '{"packages":{"node_modules/published":{"resolved":"git+https://example.invalid/pkg.git","integrity":"sha512-fixture"}}}\n' > "$AUDIT_ROOT/package-lock.json"
  run _aicoding_npm_tree_ignores_scripts_safely "$AUDIT_ROOT"
  [ "$status" -ne 0 ]
}

@test "real install hooks remain blocked even if the lock omits its script flag" {
  printf '{"scripts":{"postinstall":"build"}}\n' > "$AUDIT_ROOT/node_modules/published/package.json"
  run _aicoding_npm_tree_ignores_scripts_safely "$AUDIT_ROOT"
  [ "$status" -ne 0 ]
}

@test "unreadable package inventory cannot pass lifecycle inspection" {
  printf '{}\n' > "$AUDIT_ROOT/node_modules/published/package.json"
  find() { return 1; }
  run _aicoding_npm_tree_ignores_scripts_safely "$AUDIT_ROOT"
  [ "$status" -eq 2 ]
}

@test "early lifecycle deferral does not trigger installer ERR through a broken pipe" {
  python3 - <<'PY'
import os
from pathlib import Path
root=Path(os.environ['AUDIT_ROOT'])/'node_modules'
for i in range(1000):
    path=root/(str(i)+'x'*180)
    path.mkdir()
    (path/'package.json').write_text('{"scripts":{"install":"build"}}')
PY
  printf '{"scripts":{"install":"build"}}\n' > "$AUDIT_ROOT/node_modules/published/package.json"
  run bash -c '
    set -Eeuo pipefail
    trap '\''printf "unexpected installer failure\n" >> "$AUDIT_TMP/trap"; exit 1'\'' ERR
    source "$BLUEPRINT_ROOT/lib/update-components.sh"
    rc=0
    _aicoding_npm_tree_ignores_scripts_safely "$AUDIT_ROOT" || rc=$?
    wait
    [ "$rc" -ne 0 ]
  '
  [ "$status" -eq 0 ]
  [ ! -s "$AUDIT_TMP/trap" ]
}

@test "failed MCP registration reports its fresh registration reason" {
  source "$BLUEPRINT_ROOT/lib/update-results.sh"
  source "$BLUEPRINT_ROOT/lib/provision.sh"
  export AICODINGSETUP_SKIP_NETWORK= AICODING_PERSISTENT_ENROLLMENT=1
  aicoding_update_component() {
    [ "$1" = mcp-context7 ] || return 0
    aicoding_result_record "$1" updated 4.1.0 installed 4.1.0
    aicoding_result_record mcp-registration-claude-context7 failed 4.1.0 registration_migration_failed
    return 1
  }
  run install_mcp_packages
  [ "$status" -ne 0 ]
  [[ "$output" == *'mcp-context7: registration_migration_failed'* ]]
  [[ "$output" != *'mcp-context7: installed'* ]]
}

@test "unrecorded MCP failure never prints a prior attempt reason" {
  source "$BLUEPRINT_ROOT/lib/update-results.sh"
  source "$BLUEPRINT_ROOT/lib/provision.sh"
  export AICODINGSETUP_SKIP_NETWORK= AICODING_PERSISTENT_ENROLLMENT=1
  aicoding_result_record mcp-firecrawl failed 3.24.0 old_failure
  aicoding_update_component() { [ "$1" != mcp-firecrawl ]; }
  run install_mcp_packages
  [ "$status" -ne 0 ]
  [[ "$output" == *'mcp-firecrawl: update_not_verified'* ]]
  [[ "$output" != *old_failure* ]]
}
