#!/usr/bin/env bats

setup() {
  : "${BLUEPRINT_ROOT:?run via tests/bats/run.sh}"
  TEST_ROOT=$(mktemp -d)
  export HOME="$TEST_ROOT/home" PATH="$TEST_ROOT/bin:$PATH"
  export BOOTSTRAP_CALLS="$TEST_ROOT/calls"
  export SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  mkdir -p "$HOME" "$TEST_ROOT/bin" "$TEST_ROOT/api" "$TEST_ROOT/source/repo/bin" "$TEST_ROOT/source/repo/lib"
  printf '1\n' > "$TEST_ROOT/source/repo/.aicoding-bootstrap-version"
  for file in aicoding-auto-update aicoding-sync aicoding-status aicoding-select; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_ROOT/source/repo/bin/$file"
  done
  for file in runtime.sh auto-update.sh ci-selector.sh; do
    printf 'true\n' > "$TEST_ROOT/source/repo/lib/$file"
  done
  cat > "$TEST_ROOT/source/repo/bin/aicoding-install" <<'EOF'
#!/usr/bin/env bash
if read -r unexpected; then exit 90; fi
printf '%s\n' "$*" > "$BOOTSTRAP_CALLS"
EOF
  chmod +x "$TEST_ROOT/source/repo/bin/"*
  tar -C "$TEST_ROOT/source" -czf "$TEST_ROOT/source.tar.gz" repo

  printf '%s\n' '{"id":330421083,"name":"tests","path":".github/workflows/tests.yml","state":"active"}' > "$TEST_ROOT/api/workflow"
  printf '[{"sha":"%s"}]\n' "$SHA" > "$TEST_ROOT/api/commits"
  printf '{"total_count":1,"workflow_runs":[{"id":10,"run_number":4,"run_attempt":1,"workflow_id":330421083,"head_sha":"%s","head_branch":"main","event":"push","status":"completed","conclusion":"success"}]}\n' "$SHA" > "$TEST_ROOT/api/runs"
  cat > "$TEST_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  cat > "$TEST_ROOT/bin/curl" <<'EOF'
#!/usr/bin/env bash
output= url= headers=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output=$2; shift 2 ;;
    -D) headers=$2; shift 2 ;;
    https://api.github.com/*) url=$1; shift ;;
    *) shift ;;
  esac
done
if [ "${BOOTSTRAP_RATE_LIMIT:-0}" = 1 ]; then
  [ -z "$headers" ] || printf 'HTTP/2 403\r\nx-ratelimit-remaining: 0\r\n\r\n' > "$headers"
  exit 22
fi
if [ -n "$output" ]; then cp "$TEST_ROOT/source.tar.gz" "$output"; exit $?; fi
case "${url#https://api.github.com/}" in
  repos/vossiman/aiCodingBaseSetup/actions/workflows/tests.yml) file=workflow ;;
  'repos/vossiman/aiCodingBaseSetup/commits?sha=main&per_page=30') file=commits ;;
  repos/vossiman/aiCodingBaseSetup/actions/workflows/tests.yml/runs*) file=runs ;;
  *) exit 91 ;;
esac
cat "$TEST_ROOT/api/$file"
EOF
  chmod +x "$TEST_ROOT/bin/gh" "$TEST_ROOT/bin/curl"
  export TEST_ROOT
}

teardown() { rm -rf "$TEST_ROOT"; }

@test "verified bootstrap executes only the exact selected capable source with closed stdin" {
  run "$BLUEPRINT_ROOT/bootstrap-aicoding.sh" --profile container </dev/null
  [ "$status" -eq 0 ]
  [[ "$(cat "$BOOTSTRAP_CALLS")" == "--unattended --source "* ]]
  [[ "$(cat "$BOOTSTRAP_CALLS")" == *" --version $SHA --profile container" ]]
  local source_path
  source_path=$(awk '{for (i=1;i<=NF;i++) if ($i=="--source") print $(i+1)}' "$BOOTSTRAP_CALLS")
  [ ! -e "$source_path" ]
}

@test "malformed CI response fails closed before source download or execution" {
  printf '{}\n' > "$TEST_ROOT/api/runs"
  rm "$TEST_ROOT/source.tar.gz"
  run "$BLUEPRINT_ROOT/bootstrap-aicoding.sh" --profile container </dev/null
  [ "$status" -ne 0 ]
  [ ! -e "$BOOTSTRAP_CALLS" ]
}

@test "bootstrap reports exhausted public API quota without executing a source" {
  BOOTSTRAP_RATE_LIMIT=1 run "$BLUEPRINT_ROOT/bootstrap-aicoding.sh" --profile container </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *'GitHub API rate limit exhausted'* ]]
  [ ! -e "$BOOTSTRAP_CALLS" ]
}

@test "bootstrap required workflow identity matches the runtime selector" {
  local boot_id selector_id
  boot_id=$(sed -n 's/^workflow_id=//p' "$BLUEPRINT_ROOT/bootstrap-aicoding.sh")
  selector_id=$(bash -c '. "$BLUEPRINT_ROOT/lib/ci-selector.sh"; _aicoding_ci_policy aicoding; printf "%s\n" "$_CI_ID"')
  [ -n "$boot_id" ]
  [ "$boot_id" = "$selector_id" ]
}

@test "a CI-qualified legacy source without enrollment capability is never executed" {
  rm "$TEST_ROOT/source/repo/.aicoding-bootstrap-version"
  tar -C "$TEST_ROOT/source" -czf "$TEST_ROOT/source.tar.gz" repo
  run "$BLUEPRINT_ROOT/bootstrap-aicoding.sh" --profile container </dev/null
  [ "$status" -ne 0 ]
  [ ! -e "$BOOTSTRAP_CALLS" ]
  [[ "$output" == *'lacks persistent enrollment capability'* ]]
}

@test "devcontainer postCreate embeds the reviewed bootstrap source byte for byte" {
  local command encoded decoded="$TEST_ROOT/decoded"
  command=$(jq -r '.postCreateCommand' "$BLUEPRINT_ROOT/devcontainer.json")
  encoded=$(sed -n "s/.*printf '%s' '\([^']*\)'.*/\1/p" <<<"$command")
  [ -n "$encoded" ]
  printf '%s' "$encoded" | base64 -d > "$decoded"
  cmp "$BLUEPRINT_ROOT/bootstrap-aicoding.sh" "$decoded"
}

@test "host bootstrap defers cleanly when noninteractive prerequisite elevation is denied" {
  local minimal="$TEST_ROOT/minimal-path" command
  mkdir -p "$minimal"
  for command in bash curl tar timeout git gh flock; do
    ln -s "$(command -v "$command")" "$minimal/$command"
  done
  ln -s "$(command -v apt-get)" "$minimal/apt-get"
  cat > "$minimal/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' > "$TEST_ROOT/sudo-called"
exit 1
EOF
  chmod +x "$minimal/sudo"

  run env PATH="$minimal" "$minimal/bash" "$BLUEPRINT_ROOT/bootstrap-aicoding.sh" --profile host </dev/null
  [ "$status" -ne 0 ]
  [ -s "$TEST_ROOT/sudo-called" ]
  [[ "$output" == *'minimal prerequisite install deferred'* ]]
  [ ! -e "$BOOTSTRAP_CALLS" ]
}

@test "host prerequisite install works with sudo restricted to apt-get" {
  local minimal="$TEST_ROOT/restricted-path" command definitions="$TEST_ROOT/prerequisite-functions"
  mkdir -p "$minimal"
  for command in bash curl tar timeout git gh flock setsid apt-get ln; do
    ln -s "$(command -v "$command")" "$minimal/$command"
  done
  sed '/^bootstrap_prerequisites || exit/,$d' "$BLUEPRINT_ROOT/bootstrap-aicoding.sh" > "$definitions"
  cat > "$minimal/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/restricted-sudo-calls"
case "$*" in
  '-n apt-get --version'|'-n apt-get update') exit 0 ;;
  '-n apt-get install '*) ln -s /usr/bin/jq "$RESTRICTED_BIN/jq"; exit 0 ;;
  '-n true') exit 77 ;;
  *) exit 91 ;;
esac
EOF
  chmod +x "$minimal/sudo"

  run env PATH="$minimal" RESTRICTED_BIN="$minimal" DEFINITIONS="$definitions" \
    "$minimal/bash" -c 'set --; source "$DEFINITIONS"; profile=host; bootstrap_prerequisites'

  [ "$status" -eq 0 ]
  grep -qx -- '-n apt-get --version' "$TEST_ROOT/restricted-sudo-calls"
  grep -qx -- '-n apt-get update' "$TEST_ROOT/restricted-sudo-calls"
  grep -q -- '^-n apt-get install ' "$TEST_ROOT/restricted-sudo-calls"
  if grep -qx -- '-n true' "$TEST_ROOT/restricted-sudo-calls"; then false; fi
}

@test "container bootstrap requests a rebuild when its image lacks prerequisites" {
  local minimal="$TEST_ROOT/container-path" command
  mkdir -p "$minimal"
  for command in bash curl tar timeout git gh flock; do
    ln -s "$(command -v "$command")" "$minimal/$command"
  done

  run env PATH="$minimal" "$minimal/bash" "$BLUEPRINT_ROOT/bootstrap-aicoding.sh" --profile container </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *'manual rebuild required'* ]]
  [ ! -e "$BOOTSTRAP_CALLS" ]
}

@test "host bootstrap distinguishes package index and package installation failures from denied privilege" {
  local minimal="$TEST_ROOT/package-path" command phase
  mkdir -p "$minimal"
  for command in bash curl tar timeout git gh flock apt-get; do
    ln -s "$(command -v "$command")" "$minimal/$command"
  done
  cat > "$minimal/sudo" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  '-n apt-get --version') exit 0 ;;
  '-n apt-get update') [ "$FAIL_PHASE" != update ] ;;
  '-n apt-get install '*) exit 1 ;;
  *) exit 91 ;;
esac
EOF
  chmod +x "$minimal/sudo"
  for phase in update install; do
    run env PATH="$minimal" FAIL_PHASE="$phase" "$minimal/bash" "$BLUEPRINT_ROOT/bootstrap-aicoding.sh" --profile host </dev/null
    [ "$status" -ne 0 ]
    [[ "$output" != *'privilege unavailable'* ]]
    if [ "$phase" = update ]; then
      [[ "$output" == *'package index update failed'* ]]
    else
      [[ "$output" == *'required package installation failed'* ]]
    fi
    [ ! -e "$BOOTSTRAP_CALLS" ]
  done
}
