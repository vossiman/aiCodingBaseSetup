#!/usr/bin/env bats

setup() {
  : "${BLUEPRINT_ROOT:?run via tests/bats/run.sh}"
  TEST_ROOT=$(mktemp -d)
  export HOME="$TEST_ROOT/home"
  export AICODING_DATA_DIR="$TEST_ROOT/data"
  export AICODING_STATE_DIR="$TEST_ROOT/state"
  export PATH="$TEST_ROOT/bin:$PATH"
  unset AICODINGSETUP_SKIP_NETWORK
  export VERSION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  export SOURCE="$TEST_ROOT/source"
  mkdir -p "$HOME/.local/bin" "$TEST_ROOT/bin" "$SOURCE/bin" "$SOURCE/lib" "$SOURCE/configs/systemd"
  printf '1\n' > "$SOURCE/.aicoding-bootstrap-version"
  printf '%s\n' "$VERSION" > "$SOURCE/.aicoding-version"
  cp "$BLUEPRINT_ROOT/bin/aicoding-install" "$SOURCE/bin/"
  cp "$BLUEPRINT_ROOT/bin/aicoding-auto-update" "$SOURCE/bin/"
  cp "$BLUEPRINT_ROOT/lib/runtime.sh" "$SOURCE/lib/"
  cp "$BLUEPRINT_ROOT/lib/auto-update.sh" "$SOURCE/lib/"
  cp "$BLUEPRINT_ROOT/lib/ci-selector.sh" "$SOURCE/lib/"
  cp "$BLUEPRINT_ROOT/configs/systemd/"* "$SOURCE/configs/systemd/"
  for name in aicoding-sync aicoding-status aicoding-select; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$SOURCE/bin/$name"
    chmod +x "$SOURCE/bin/$name"
  done
  cat > "$SOURCE/install.sh" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$AICODING_TEST_INSTALL_MARKER"
if ! mkdir "$AICODING_TEST_INSTALL_MARKER/running" 2>/dev/null; then
  : > "$AICODING_TEST_INSTALL_MARKER/overlap"
fi
printf '%s\n' "$*" >> "$AICODING_TEST_INSTALL_MARKER/calls"
sleep "${AICODING_TEST_INSTALL_SLEEP:-0}"
rmdir "$AICODING_TEST_INSTALL_MARKER/running"
EOF
  chmod +x "$SOURCE/install.sh" "$SOURCE/bin/"*
  export AICODING_TEST_INSTALL_MARKER="$TEST_ROOT/installed"
  export GH_CALLS="$TEST_ROOT/gh.calls"

  cat > "$TEST_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = api ] || exit 90
printf '%s\n' "$2" >> "$GH_CALLS"
case "$2" in
  repos/vossiman/aiCodingBaseSetup/commits\?sha=main\&per_page=30) printf '[{"sha":"%s"}]\n' "$VERSION" ;;
  repos/vossiman/aiCodingBaseSetup/compare/*) printf '{"status":"ahead","merge_base_commit":{"sha":"%s"}}\n' "$VERSION" ;;
  repos/vossiman/aiCodingBaseSetup/actions/workflows/tests.yml) printf '{"id":330421083,"name":"tests","path":".github/workflows/tests.yml","state":"active"}\n' ;;
  repos/vossiman/aiCodingBaseSetup/actions/workflows/tests.yml/runs*)
    [ "${AICODING_TEST_CI_FAIL:-0}" = 0 ] || exit 22
    printf '{"total_count":1,"workflow_runs":[{"id":9,"run_number":3,"run_attempt":1,"workflow_id":330421083,"head_sha":"%s","head_branch":"main","event":"push","status":"completed","conclusion":"success"}]}\n' "$VERSION"
    ;;
  *) exit 91 ;;
esac
EOF
  chmod +x "$TEST_ROOT/bin/gh"
}

teardown() { rm -rf "$TEST_ROOT"; }

run_enroll() {
  "$BLUEPRINT_ROOT/bin/aicoding-install" --unattended --source "$SOURCE" --version "$VERSION" --profile container </dev/null
}

make_selected_dispatch_repo() {
  local repo="$TEST_ROOT/selected-repo"
  rsync -a --exclude=.git "$BLUEPRINT_ROOT/" "$repo/"
  cat > "$repo/bin/aicoding-install" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$AICODING_TEST_DISPATCH"
EOF
  chmod +x "$repo/bin/aicoding-install"
  git -C "$repo" init -q -b main
  git -C "$repo" add -A
  git -C "$repo" -c user.email=test@example.invalid -c user.name=test commit -qm selected
  VERSION=$(git -C "$repo" rev-parse HEAD)
  export VERSION AICODING_BLUEPRINT_REMOTE="$repo"
  export AICODING_TEST_DISPATCH="$TEST_ROOT/dispatched"
}

@test "an arbitrary matching source marker cannot bypass CI qualification" {
  export AICODING_TEST_CI_FAIL=1
  run run_enroll
  [ "$status" -ne 0 ]
  [ ! -e "$AICODING_DATA_DIR/versions/aicoding/$VERSION" ]
  [ ! -e "$AICODING_TEST_INSTALL_MARKER/calls" ]
}

@test "verified enrollment publishes durable launchers before running the selected installer" {
  run run_enroll
  [ "$status" -eq 0 ] || { echo "$output"; cat "$GH_CALLS"; false; }
  [ -x "$HOME/.local/bin/aicoding-auto-update" ]
  [ -x "$HOME/.local/bin/aicoding-sync" ]
  [ "$(readlink "$AICODING_DATA_DIR/current/aicoding")" = "../versions/aicoding/$VERSION" ]
  [[ "$(cat "$AICODING_TEST_INSTALL_MARKER/calls")" == *'--unattended'* ]]
}

@test "source and requested version must match before any activation" {
  printf '%s\n' bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb > "$SOURCE/.aicoding-version"
  run run_enroll
  [ "$status" -ne 0 ]
  [ ! -e "$AICODING_DATA_DIR/current/aicoding" ]
}

@test "manual enrollment commands share the whole-run lock" {
  export AICODING_TEST_INSTALL_SLEEP=1
  run_enroll & local first=$!
  sleep 0.1
  run_enroll & local second=$!
  wait "$first"; wait "$second"
  [ "$(wc -l < "$AICODING_TEST_INSTALL_MARKER/calls")" -eq 2 ]
  [ ! -e "$AICODING_TEST_INSTALL_MARKER/overlap" ]
}

@test "normal install preserves the persisted host profile when dispatching selected source" {
  make_selected_dispatch_repo
  mkdir -p "$AICODING_STATE_DIR"
  printf '{"schema_version":1,"profile":"host","files":{}}\n' > "$AICODING_STATE_DIR/manifest.json"

  run "$BLUEPRINT_ROOT/bin/aicoding-install" </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$(cat "$AICODING_TEST_DISPATCH")" == *"--profile host"* ]]
}

@test "normal install preserves the persisted minimal-pi component selection" {
  make_selected_dispatch_repo
  mkdir -p "$AICODING_STATE_DIR"
  printf '{"schema":1,"profile":"minimal-pi","components":["aicoding","dvw"]}\n' \
    > "$AICODING_STATE_DIR/component-selection.json"

  run "$BLUEPRINT_ROOT/bin/aicoding-install" </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$(cat "$AICODING_TEST_DISPATCH")" == *"--profile minimal-pi"* ]]
}
