#!/usr/bin/env bats
# lib/update-opencode.sh: OpenCode v2 from GitHub release archives, checked
# against the release's SHA256SUMS. curl is a stub; nothing leaves the box.
setup() {
  : "${BLUEPRINT_ROOT:?run via run.sh}"
  export TMP; TMP=$(mktemp -d)
  export HOME="$TMP/home" AICODING_STATE_DIR="$TMP/state" AICODING_DATA_DIR="$TMP/data"
  mkdir -p "$HOME/.local/bin" "$TMP/stubs" "$TMP/pkg" "$TMP/dl"
  export PATH="$TMP/stubs:/usr/bin:/bin"
  export OPENCODE_TEST_VERSION=2.3.2
  export AICODING_OPENCODE_MUSL_GLOB="$TMP/no-musl-*"
  printf 'flags : fpu sse avx2\n' > "$TMP/cpuinfo"
  export AICODING_OPENCODE_CPUINFO="$TMP/cpuinfo"
  cat > "$TMP/releases.json" <<'JSON'
[
  {"tag_name": "v2.4.0-beta.1", "draft": false, "prerelease": true},
  {"tag_name": "v9.0.0", "draft": true, "prerelease": false},
  {"tag_name": "v2.3.2", "draft": false, "prerelease": false},
  {"tag_name": "v1.19.6", "draft": false, "prerelease": false},
  {"tag_name": "process-daemon-v0.6.0", "draft": false, "prerelease": false},
  {"tag_name": "v2.3.1", "draft": false, "prerelease": false}
]
JSON
  build_release
  cat > "$TMP/stubs/curl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$TMP/curl.log"
dest=; url=
while [ "$#" -gt 0 ]; do
  case "$1" in -o) dest=$2; shift 2 ;; https://*) url=$1; shift ;; *) shift ;; esac
done
case "$url" in
  https://api.github.com/repos/anomalyco/opencode/releases*) cat "$TMP/releases.json" ;;
  https://github.com/anomalyco/opencode/releases/download/v*/*)
    [ -n "$dest" ] || exit 9
    file=$TMP/dl/${url##*/}
    [ -f "$file" ] || exit 22
    cp "$file" "$dest" ;;
  *) exit 8 ;;
esac
STUB
  chmod +x "$TMP/stubs/curl"
  unset AICODINGSETUP_SKIP_NETWORK
  . "$BLUEPRINT_ROOT/lib/update-results.sh"
  . "$BLUEPRINT_ROOT/lib/update-components.sh"
}
teardown() { rm -rf "$TMP"; }

# Builds every Linux asset of the fake release plus its SHA256SUMS.
build_release() {
  local asset
  rm -rf "$TMP/pkg" && mkdir -p "$TMP/pkg"
  printf '#!/bin/sh\necho "opencode v%s"\n' "$OPENCODE_TEST_VERSION" > "$TMP/pkg/opencode"
  chmod +x "$TMP/pkg/opencode"
  : > "$TMP/dl/SHA256SUMS"
  for asset in opencode-linux-x64 opencode-linux-x64-baseline opencode-linux-x64-musl \
      opencode-linux-x64-baseline-musl opencode-linux-arm64 opencode-linux-arm64-musl; do
    tar -czf "$TMP/dl/$asset.tar.gz" -C "$TMP/pkg" opencode
    (cd "$TMP/dl" && sha256sum "$asset.tar.gz" >> SHA256SUMS)
  done
}

@test "OpenCode installs the newest plain v2 release, skipping v1, drafts and prereleases" {
  run aicoding_update_component opencode
  [ "$status" -eq 0 ]
  [ "$("$HOME/.local/bin/opencode" --version)" = "opencode v2.3.2" ]
  jq -e '.components.opencode.state == "updated" and .components.opencode.target_version == "2.3.2"' "$AICODING_RESULTS_FILE"
  grep -q 'releases/download/v2.3.2/SHA256SUMS' "$TMP/curl.log"
}

@test "OpenCode reuses a verified release and rejects later tampering" {
  aicoding_update_component opencode
  aicoding_update_component opencode
  jq -e '.components.opencode.state == "current"' "$AICODING_RESULTS_FILE"
  printf '\n# tamper\n' >> "$AICODING_DATA_DIR/versions/opencode/2.3.2/opencode"
  run aicoding_update_component opencode
  [ "$status" -ne 0 ]
  jq -e '.components.opencode.reason == "existing_release_invalid"' "$AICODING_RESULTS_FILE"
}

@test "OpenCode refuses an archive whose checksum does not match" {
  printf '0%.0s' {1..64} > "$TMP/sum"
  sed -i "s/^[0-9a-f]\{64\}  opencode-linux-x64.tar.gz$/$(cat "$TMP/sum")  opencode-linux-x64.tar.gz/" "$TMP/dl/SHA256SUMS"
  printf '#!/bin/sh\necho old\n' > "$HOME/.local/bin/opencode"; chmod +x "$HOME/.local/bin/opencode"
  run aicoding_update_component opencode
  [ "$status" -ne 0 ]
  [ "$("$HOME/.local/bin/opencode")" = old ]
  jq -e '.components.opencode.reason == "archive_checksum_mismatch"' "$AICODING_RESULTS_FILE"
}

@test "OpenCode refuses an archive with a link or extra files" {
  ln -s "$TMP/escaped" "$TMP/pkg/evil"
  tar -czf "$TMP/dl/opencode-linux-x64.tar.gz" -C "$TMP/pkg" opencode evil
  (cd "$TMP/dl" && sha256sum opencode-linux-x64.tar.gz > SHA256SUMS)
  run aicoding_update_component opencode
  [ "$status" -ne 0 ]
  [ ! -e "$TMP/escaped" ]
  jq -e '.components.opencode.reason == "archive_invalid"' "$AICODING_RESULTS_FILE"
}

@test "OpenCode refuses a binary that reports another version" {
  OPENCODE_TEST_VERSION=2.3.1 build_release
  run aicoding_update_component opencode
  [ "$status" -ne 0 ]
  jq -e '.components.opencode.reason == "staged_version_mismatch"' "$AICODING_RESULTS_FILE"
}

@test "OpenCode with no v2 release records an unavailable target" {
  echo '[{"tag_name":"v1.19.6","draft":false,"prerelease":false}]' > "$TMP/releases.json"
  run aicoding_update_component opencode
  [ "$status" -ne 0 ]
  jq -e '.components.opencode.reason == "target_version_unavailable"' "$AICODING_RESULTS_FILE"
}

@test "OpenCode does no download under the network guard" {
  export AICODINGSETUP_SKIP_NETWORK=1
  run aicoding_update_component opencode
  [ "$status" -ne 0 ]
  [ ! -e "$TMP/curl.log" ]
  jq -e '.components.opencode.reason == "network_disabled"' "$AICODING_RESULTS_FILE"
}

@test "OpenCode picks the asset for arch, CPU and libc" {
  . "$BLUEPRINT_ROOT/lib/update-opencode.sh"
  uname() { case "$1" in -s) echo Linux ;; -m) echo "$FAKE_ARCH" ;; esac; }
  FAKE_ARCH=x86_64
  [ "$(_aicoding_opencode_asset)" = opencode-linux-x64.tar.gz ]
  printf 'flags : fpu sse\n' > "$TMP/cpuinfo"
  [ "$(_aicoding_opencode_asset)" = opencode-linux-x64-baseline.tar.gz ]
  touch "$TMP/no-musl-x86_64.so.1"
  [ "$(_aicoding_opencode_asset)" = opencode-linux-x64-baseline-musl.tar.gz ]
  FAKE_ARCH=aarch64
  [ "$(_aicoding_opencode_asset)" = opencode-linux-arm64-musl.tar.gz ]
  rm "$TMP/no-musl-x86_64.so.1"
  [ "$(_aicoding_opencode_asset)" = opencode-linux-arm64.tar.gz ]
  FAKE_ARCH=riscv64
  if _aicoding_opencode_asset; then false; fi
}
