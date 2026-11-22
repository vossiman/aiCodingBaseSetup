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
dest=; url=; headers=/dev/null
while [ "$#" -gt 0 ]; do
  case "$1" in -o) dest=$2; shift 2 ;; -D) headers=$2; shift 2 ;; https://*) url=$1; shift ;; *) shift ;; esac
done
case "$url" in
  https://api.github.com/*)
    page=1; case "$url" in *page=2*) page=2 ;; esac
    body=$TMP/releases.json; [ "$page" = 2 ] && body=$TMP/releases-2.json
    { printf 'HTTP/2 200\r\n'
      if [ "$page" = 1 ] && [ -f "$TMP/releases-2.json" ]; then
        printf 'link: <https://api.github.com/repositories/1/releases?per_page=100&page=2>; rel="next", <https://api.github.com/repositories/1/releases?per_page=100&page=2>; rel="last"\r\n'
      fi
      printf '\r\n'; } > "$headers"
    cp "$body" "$dest" ;;
  https://github.com/anomalyco/opencode/releases/download/v*/*)
    [ -n "$dest" ] || exit 9
    file=$TMP/dl/${url##*/}
    if [ ! -f "$file" ]; then echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; fi
    cp "$file" "$dest" ;;
  *) exit 8 ;;
esac
STUB
  printf '#!/bin/sh\ncase "$1" in -s) echo Linux ;; -m) echo x86_64 ;; *) /bin/uname "$@" ;; esac\n' > "$TMP/stubs/uname"
  chmod +x "$TMP/stubs/curl" "$TMP/stubs/uname"
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
  printf '\n# tamper\n' >> "$AICODING_DATA_DIR/versions/opencode/2.3.2/node_modules/.bin/opencode"
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

@test "OpenCode follows the Link header to a later page of releases" {
  echo '[{"tag_name":"v1.19.6","draft":false,"prerelease":false}]' > "$TMP/releases.json"
  echo '[{"tag_name":"v2.3.2","draft":false,"prerelease":false}]' > "$TMP/releases-2.json"
  run aicoding_update_component opencode
  [ "$status" -eq 0 ]
  grep -q 'page=2' "$TMP/curl.log"
  jq -e '.components.opencode.target_version == "2.3.2"' "$AICODING_RESULTS_FILE"
}

@test "OpenCode keeps curl's error for a failed download where the reason text points" {
  rm "$TMP/dl/opencode-linux-x64.tar.gz"
  run aicoding_update_component opencode
  [ "$status" -ne 0 ]
  jq -e '.components.opencode.reason == "archive_download_failed"' "$AICODING_RESULTS_FILE"
  grep -q 'returned error: 404' "$AICODING_STATE_DIR/diagnostics/opencode-download.log"
  grep -q 'opencode-download.log' "$BLUEPRINT_ROOT/lib/status-reasons.json"
}

@test "OpenCode moves an active npm v1 release to v2 and keeps the launcher path" {
  local v1="$AICODING_DATA_DIR/versions/opencode/1.19.6"
  mkdir -p "$v1/node_modules/opencode-ai/bin" "$v1/node_modules/.bin"
  printf '#!/bin/sh\necho 1.19.6\n' > "$v1/node_modules/opencode-ai/bin/opencode"
  chmod +x "$v1/node_modules/opencode-ai/bin/opencode"
  ln -s ../opencode-ai/bin/opencode "$v1/node_modules/.bin/opencode"
  aicoding_activate_version opencode 1.19.6 opencode node_modules/.bin/opencode
  [ "$("$HOME/.local/bin/opencode" --version)" = 1.19.6 ]
  run aicoding_update_component opencode
  [ "$status" -eq 0 ]
  [ "$("$HOME/.local/bin/opencode" --version)" = "opencode v2.3.2" ]
  [ "$(readlink "$AICODING_DATA_DIR/current/opencode")" = ../versions/opencode/2.3.2 ]
  grep -qx 'relative=node_modules/.bin/opencode' "$HOME/.local/bin/opencode"
  grep -qF 'OPENCODE_DISABLE_AUTOUPDATE' "$HOME/.local/bin/opencode"
  jq -e '.components.opencode.state == "updated"' "$AICODING_RESULTS_FILE"
}

@test "the OpenCode launcher: bare update/upgrade runs aicoding, help passes through, anything else is refused" {
  aicoding_update_component opencode
  printf '#!/bin/sh\necho "UPDATER $*" > "$TMP/updater.ran"\n' > "$HOME/.local/bin/aicoding-auto-update"
  chmod +x "$HOME/.local/bin/aicoding-auto-update"
  printf '#!/bin/sh\necho "REAL $* disable=$OPENCODE_DISABLE_AUTOUPDATE"\n' \
    > "$AICODING_DATA_DIR/versions/opencode/2.3.2/node_modules/.bin/opencode"
  for sub in update upgrade; do
    rm -f "$TMP/updater.ran"
    run "$HOME/.local/bin/opencode" "$sub"
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP/updater.ran")" = "UPDATER --once" ]
    for help in --help -h; do
      rm -f "$TMP/updater.ran"
      run "$HOME/.local/bin/opencode" "$sub" "$help"
      [ "$status" -eq 0 ]
      [ "$output" = "REAL $sub $help disable=1" ]
      [ ! -e "$TMP/updater.ran" ]
    done
    for extra in "2.3.1" "--method npm" "--help 2.3.1"; do
      rm -f "$TMP/updater.ran"
      # shellcheck disable=SC2086
      run "$HOME/.local/bin/opencode" "$sub" $extra
      [ "$status" -eq 2 ]
      [[ "$output" == *"takes no version or flags"* ]]
      [[ "$output" != *REAL* ]]
      [ ! -e "$TMP/updater.ran" ]
    done
  done
  OPENCODE_DISABLE_AUTOUPDATE=0 run "$HOME/.local/bin/opencode" run x
  [ "$output" = "REAL run x disable=1" ]
}

@test "the Claude launcher text is unchanged: any update/upgrade goes to aicoding" {
  . "$BLUEPRINT_ROOT/lib/runtime.sh"
  _aicoding_runtime_write_wrapper "$TMP/claude" "$AICODING_DATA_DIR/current/claude" bin/claude
  grep -qx '  update|upgrade)' "$TMP/claude"
  grep -qx '    exec "$updater" --once' "$TMP/claude"
  grep -qx 'export DISABLE_AUTOUPDATER="${DISABLE_AUTOUPDATER:-1}"' "$TMP/claude"
  grep -qx 'export FORCE_AUTOUPDATE_PLUGINS="${FORCE_AUTOUPDATE_PLUGINS:-1}"' "$TMP/claude"
  if grep -qE 'OPENCODE|\$#:' "$TMP/claude"; then false; fi
  [ "$(sed -n '/^case/,/^esac/p' "$TMP/claude" | wc -l)" -eq 12 ]
}

@test "the v2 config probe never opens an inherited live OpenCode database" {
  mkdir -p "$HOME/live"
  echo live > "$HOME/live/opencode.db"
  cat > "$TMP/stubs/opencode" <<'STUB'
#!/bin/sh
[ "$1" = --version ] && { echo "opencode v2.3.2"; exit 0; }
printf 'args=%s\ndb=%s\nhome=%s\npty=%s\n' "$*" "$OPENCODE_DB" "${OPENCODE_TEST_HOME:-unset}" "$OPENCODE_PTY_SOCKET_DIR" > "$TMP/probe.env"
STUB
  chmod +x "$TMP/stubs/opencode"
  export OPENCODE_DB="$HOME/live/opencode.db" OPENCODE_TEST_HOME="$HOME/live"
  _aicoding_opencode_config_probe
  grep -qx 'args=debug config --standalone' "$TMP/probe.env"
  db=$(sed -n 's/^db=//p' "$TMP/probe.env")
  [ "$db" != "$HOME/live/opencode.db" ]
  case "$db" in /*/data/opencode.db) ;; *) false ;; esac
  grep -qx 'home=unset' "$TMP/probe.env"
  [ -n "$(sed -n 's/^pty=//p' "$TMP/probe.env")" ]
  [ "$(cat "$HOME/live/opencode.db")" = live ]
}

@test "OpenCode extraction allows only a real root directory marker besides the binary" {
  . "$BLUEPRINT_ROOT/lib/update-opencode.sh"
  python3 - "$TMP" <<'EOF'
import io, sys, tarfile
tmp = sys.argv[1]
def build(name, entries):
    with tarfile.open(f"{tmp}/{name}.tgz", "w:gz") as t:
        for n, kind in entries:
            i = tarfile.TarInfo(n)
            if kind == "dir": i.type = tarfile.DIRTYPE; t.addfile(i)
            elif kind == "link": i.type = tarfile.SYMTYPE; i.linkname = "/etc/passwd"; t.addfile(i)
            else:
                data = b"#!/bin/sh\necho opencode v2.3.2\n"; i.size = len(data); i.mode = 0o755
                t.addfile(i, io.BytesIO(data))
build("dirmarker", [("./", "dir"), ("./opencode", "file")])
build("filemarker", [(".", "file"), ("opencode", "file")])
build("linkmarker", [("./", "link"), ("opencode", "file")])
build("twocopies", [("opencode", "file"), ("./opencode", "file")])
build("subdir", [("bin", "dir"), ("opencode", "file")])
EOF
  for good in dirmarker; do
    mkdir "$TMP/x-$good"; _aicoding_opencode_extract "$TMP/$good.tgz" "$TMP/x-$good"
    [ -x "$TMP/x-$good/node_modules/.bin/opencode" ]
  done
  for bad in filemarker linkmarker twocopies subdir; do
    mkdir "$TMP/x-$bad"
    if _aicoding_opencode_extract "$TMP/$bad.tgz" "$TMP/x-$bad"; then echo "accepted $bad"; false; fi
    [ ! -e "$TMP/x-$bad/node_modules/.bin/opencode" ]
  done
}
