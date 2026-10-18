#!/usr/bin/env bats
# Legacy `curl .../on-start.sh | bash` invocations hand off to the enrolled
# runtime release, or do nothing. Piped runs use `bash -s` so $0 is "bash".
bats_require_minimum_version 1.5.0

setup() {
  : "${BLUEPRINT_ROOT:?run via tests/bats/run.sh}"
  export HOME="$BATS_TEST_TMPDIR/home"
  export AICODING_DATA_DIR="$HOME/.local/share/aicoding"
  WS="$BATS_TEST_TMPDIR/workspace"
  mkdir -p "$HOME/.local/bin" "$WS"
  unset AICODINGSETUP_SKIP_NETWORK
}

# fixture_release VERSION: a release whose hook records how it was started.
fixture_release() {
  local release="$AICODING_DATA_DIR/versions/aicoding/$1"
  mkdir -p "$release"
  cat > "$release/on-start.sh" <<'SH'
printf '%s\n' "$0" > "$HOME/hook-path"
pwd > "$HOME/hook-cwd"
printf '[%s]' "$@" > "$HOME/hook-args"
readlink "/proc/$$/fd/0" > "$HOME/hook-stdin"
echo ran >> "$HOME/hook-runs"
SH
  printf '%s\n' "$release"
}

link_current() {
  mkdir -p "$AICODING_DATA_DIR/current"
  ln -sfn "$1" "$AICODING_DATA_DIR/current/aicoding"
}

piped() {
  local marker=$1; shift
  cd "$WS"
  if [ "$marker" = unset ]; then
    run env -u _NVS_STRIPPED bash -s -- "$@" < "$BLUEPRINT_ROOT/on-start.sh"
  else
    run env _NVS_STRIPPED="$marker" bash -s -- "$@" < "$BLUEPRINT_ROOT/on-start.sh"
  fi
}

@test "legacy piped hook without enrollment warns and runs nothing, whatever the marker" {
  for marker in unset 0 1; do
    piped "$marker"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no verified runtime enrolled"* ]]
    [[ "$output" != *"Transcript redaction"* ]]
    [ ! -e "$HOME/hook-runs" ]
  done
}

@test "legacy piped hook delegates to the enrolled release, whatever the marker" {
  local release real
  release=$(fixture_release abc123)
  link_current ../versions/aicoding/abc123
  real=$(readlink -f "$release/on-start.sh")
  for marker in unset 0 1; do
    rm -f "$HOME"/hook-*
    piped "$marker" one "two words"
    [ "$status" -eq 0 ]
    [[ "$output" == *"running verified runtime abc123"* ]]
    [ "$(cat "$HOME/hook-path")" = "$real" ]
    [ "$(cat "$HOME/hook-cwd")" = "$WS" ]
    [ "$(cat "$HOME/hook-args")" = "[one][two words]" ]
    [ "$(cat "$HOME/hook-stdin")" = /dev/null ]
    [ "$(wc -l < "$HOME/hook-runs")" -eq 1 ]
  done
}

@test "legacy piped hook rejects anything that is not an activated release" {
  local data=$AICODING_DATA_DIR case
  for case in directory dangling outside unsafe escaping-hook hook-not-file release-symlink; do
    rm -rf "$data" "$HOME"/hook-* "$BATS_TEST_TMPDIR/elsewhere"
    mkdir -p "$data/current"
    case "$case" in
      directory)
        fixture_release abc123 >/dev/null
        cp -r "$data/versions/aicoding/abc123" "$data/current/aicoding" ;;
      dangling)
        link_current ../versions/aicoding/missing ;;
      outside)
        mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
        cp "$(fixture_release abc123)/on-start.sh" "$BATS_TEST_TMPDIR/elsewhere/"
        link_current "$BATS_TEST_TMPDIR/elsewhere" ;;
      unsafe)
        fixture_release abc123 >/dev/null
        link_current ../versions/aicoding/abc123/../abc123 ;;
      escaping-hook)
        mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
        mv "$(fixture_release abc123)/on-start.sh" "$BATS_TEST_TMPDIR/elsewhere/on-start.sh"
        ln -s "$BATS_TEST_TMPDIR/elsewhere/on-start.sh" "$data/versions/aicoding/abc123/on-start.sh"
        link_current ../versions/aicoding/abc123 ;;
      hook-not-file)
        mkdir -p "$data/versions/aicoding/abc123/on-start.sh"
        link_current ../versions/aicoding/abc123 ;;
      release-symlink)
        mkdir -p "$BATS_TEST_TMPDIR/elsewhere" "$data/versions/aicoding"
        cp "$(fixture_release tmp)/on-start.sh" "$BATS_TEST_TMPDIR/elsewhere/"
        rm -rf "$data/versions/aicoding/tmp"
        ln -s "$BATS_TEST_TMPDIR/elsewhere" "$data/versions/aicoding/abc123"
        link_current ../versions/aicoding/abc123 ;;
    esac
    for marker in unset 1; do
      piped "$marker"
      [ "$status" -eq 0 ] || { echo "case $case marker $marker: status $status"; false; }
      [[ "$output" == *"no verified runtime enrolled"* ]] || { echo "case $case: $output"; false; }
      [ ! -e "$HOME/hook-runs" ] || { echo "case $case ran the hook"; false; }
    done
  done
}

@test "legacy piped hook runs the real runtime hook once, stripped and detached" {
  local release="$AICODING_DATA_DIR/versions/aicoding/real"
  mkdir -p "$release"
  cp "$BLUEPRINT_ROOT/on-start.sh" "$release/on-start.sh"
  link_current ../versions/aicoding/real
  cat > "$HOME/.local/bin/aicoding-auto-update" <<'SH'
#!/bin/bash
echo "$*" >> "$HOME/ensure-calls"
env | grep "^BASH_FUNC_" | cut -d= -f1 > "$HOME/ensure-bash-funcs" || true
readlink "/proc/$$/fd/0" > "$HOME/ensure-stdin"
SH
  cat > "$HOME/.local/bin/redact-sessions" <<'SH'
#!/bin/bash
sleep 2
touch "$HOME/sweep-finished"
SH
  printf '#!/bin/sh\necho "$@" >> "$HOME/t3-calls"\n' > "$HOME/.local/bin/t3-start"
  chmod +x "$HOME/.local/bin/"*
  export DEVPOD_WORKSPACE_ID=demo
  mkdir -p "$HOME/.t3-envs/demo/aicoding"
  cd "$WS"
  local start=$SECONDS
  run --separate-stderr timeout 10 env -u _NVS_STRIPPED \
    'BASH_FUNC_nvs%%=() {  :' 'BASH_FUNC_nvsudo%%=() {  :' 'BASH_FUNC_nvm%%=() {  :' \
    PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" \
    bash -s < "$BLUEPRINT_ROOT/on-start.sh"
  [ "$status" -eq 0 ]
  [ $((SECONDS - start)) -lt 2 ]
  [[ "$stderr" == *"running verified runtime real"* ]]
  [ "$(cat "$HOME/ensure-calls")" = --ensure ]
  if grep -E '^BASH_FUNC_(nvs|nvsudo|nvm)%%' "$HOME/ensure-bash-funcs"; then false; fi
  [ "$(cat "$HOME/ensure-stdin")" = /dev/null ]
  [ ! -e "$HOME/t3-calls" ]
  [ ! -e "$HOME/sweep-finished" ]
  for _ in $(seq 1 30); do [ -e "$HOME/sweep-finished" ] && break; sleep 0.2; done
  [ -e "$HOME/sweep-finished" ]

  : > "$HOME/.t3-envs/demo/aicoding/enabled"
  rm -f "$HOME/sweep-finished"
  run --separate-stderr timeout 10 env -u _NVS_STRIPPED \
    PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" \
    bash -s < "$BLUEPRINT_ROOT/on-start.sh"
  [ "$status" -eq 0 ]
  for _ in $(seq 1 30); do [ -e "$HOME/t3-calls" ] && [ -e "$HOME/sweep-finished" ] && break; sleep 0.2; done
  [ "$(cat "$HOME/t3-calls")" = --boot ]
  [ "$(wc -l < "$HOME/ensure-calls")" -eq 2 ]
}
