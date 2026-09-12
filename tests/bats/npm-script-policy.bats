#!/usr/bin/env bats
setup() {
  : "${BLUEPRINT_ROOT:?run via tests/bats/run.sh}"
  export TMP; TMP=$(mktemp -d)
  export HOME="$TMP/home"
  mkdir -p "$HOME" "$TMP/stage/node_modules"
  . "$BLUEPRINT_ROOT/lib/update-components.sh"
  cp -R "$BLUEPRINT_ROOT/tests/fixtures/tldjs-2.3.2" "$TMP/stage/node_modules/tldjs"
  cat > "$TMP/stage/package-lock.json" <<'LOCK'
{"packages":{"node_modules/tldjs":{"version":"2.3.2","hasInstallScript":true,"resolved":"https://registry.npmjs.org/tldjs/-/tldjs-2.3.2.tgz","integrity":"sha512-EORDwFMSZKrHPUVDhejCMDeAovRS5d8jZKiqALFiPp3cjKjEldPkxBY39ZSx3c45awz3RpKwJD1cCgGxEfy8/A=="}}}
LOCK
}
teardown() { rm -rf "$TMP"; }
@test "audited tldjs optional refresh is safe to skip with bundled rules" {
  run _aicoding_npm_tree_ignores_scripts_safely "$TMP/stage"
  [ "$status" -eq 0 ]
}
@test "tldjs exception rejects changed registry provenance" {
  sed -i 's/registry.npmjs.org/other.example/' "$TMP/stage/package-lock.json"
  run _aicoding_npm_tree_ignores_scripts_safely "$TMP/stage"
  [ "$status" -eq 1 ]
}
@test "tldjs exception rejects changed lifecycle script" {
  printf '\nprocess.exit(1);\n' >> "$TMP/stage/node_modules/tldjs/bin/postinstall.js"
  run _aicoding_npm_tree_ignores_scripts_safely "$TMP/stage"
  [ "$status" -eq 1 ]
}
@test "tldjs exception rejects missing or changed bundled rules" {
  printf '{}\n' > "$TMP/stage/node_modules/tldjs/rules.json"
  run _aicoding_npm_tree_ignores_scripts_safely "$TMP/stage"
  [ "$status" -eq 1 ]
}
@test "tldjs exception does not permit extra install hooks" {
  jq '.scripts.install="node malicious.js"' "$TMP/stage/node_modules/tldjs/package.json" > "$TMP/new.json"
  mv "$TMP/new.json" "$TMP/stage/node_modules/tldjs/package.json"
  run _aicoding_npm_tree_ignores_scripts_safely "$TMP/stage"
  [ "$status" -eq 1 ]
}
@test "tldjs exception does not permit unrecognized lifecycle dependencies" {
  mkdir -p "$TMP/stage/node_modules/other"
  printf '{"scripts":{"postinstall":"node build.js"}}\n' > "$TMP/stage/node_modules/other/package.json"
  run _aicoding_npm_tree_ignores_scripts_safely "$TMP/stage"
  [ "$status" -eq 1 ]
}
@test "tldjs exception rejects changed tarball integrity" {
  sed -i 's/sha512-EORD/sha512-AAAA/' "$TMP/stage/package-lock.json"
  run _aicoding_npm_tree_ignores_scripts_safely "$TMP/stage"
  [ "$status" -eq 1 ]
}
@test "tldjs exception still audits hooks when npm omits the lock script flag" {
  jq 'del(.packages["node_modules/tldjs"].hasInstallScript)' "$TMP/stage/package-lock.json" > "$TMP/new.json"
  mv "$TMP/new.json" "$TMP/stage/package-lock.json"
  run _aicoding_npm_tree_ignores_scripts_safely "$TMP/stage"
  [ "$status" -eq 0 ]
  printf '\nchanged\n' >> "$TMP/stage/node_modules/tldjs/bin/postinstall.js"
  run _aicoding_npm_tree_ignores_scripts_safely "$TMP/stage"
  [ "$status" -eq 1 ]
}
@test "lock lifecycle flag without an audited package stays blocked" {
  jq '.packages["node_modules/missing"]={"hasInstallScript":true}' "$TMP/stage/package-lock.json" > "$TMP/new.json"
  mv "$TMP/new.json" "$TMP/stage/package-lock.json"
  run _aicoding_npm_tree_ignores_scripts_safely "$TMP/stage"
  [ "$status" -eq 1 ]
}
