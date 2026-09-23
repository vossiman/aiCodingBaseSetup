#!/usr/bin/env bats

setup() {
  : "${BLUEPRINT_ROOT:?run via tests/bats/run.sh}"
  unset AICODINGSETUP_SKIP_NETWORK
  export TMP; TMP=$(mktemp -d)
  export HOME="$TMP/home" TMPDIR="$TMP/tmp"
  export AICODING_STATE_DIR="$TMP/state"
  export AICODING_RESULTS_FILE="$TMP/state/update-results.json"
  export AICODING_SYSTEM_PREFIX="$TMP/prefix" AICODING_TMUX_PREFIX="$TMP/prefix"
  export AICODING_TMUX_COMMIT_FILE="$TMP/prefix/share/aicoding/tmux-commit"
  export AICODING_UV_OPT_DIR="$TMP/opt-uv"
  export AICODING_TERMINFO_DIRS="$TMP/terminfo"
  export AICODING_GO_ROOT="$TMP/go"
  export CALLS="$TMP/calls"
  mkdir -p "$HOME/.local/bin" "$TMPDIR" "$TMP/stubs" "$TMP/bin" "$TMP/prefix/bin" \
    "$TMP/prefix/share/aicoding" "$AICODING_STATE_DIR" "$TMP/terminfo/x"
  : > "$CALLS"
  _curated_path
  export PATH="$TMP/stubs:$HOME/.local/bin:$TMP/bin"
  _stub sudo 'printf "sudo %s\n" "$*" >> "$CALLS"; [ "${1:-}" != -n ] || shift; exec "$@"'
  _stub timeout 'printf "timeout %s\n" "$*" >> "$CALLS"
while [ $# -gt 0 ]; do case "$1" in -*|[0-9]*) shift ;; *) break ;; esac; done
exec "$@"'
  _stub nice 'printf "nice %s\n" "$*" >> "$CALLS"; shift 2; exec "$@"'
  _stub ionice 'printf "ionice %s\n" "$*" >> "$CALLS"; shift 1; exec "$@"'
  _stub apt-get 'printf "apt-get %s\n" "$*" >> "$CALLS"; exit 0'
  _stub tmux 'if [ "${1:-}" = -V ]; then echo "tmux next-3.8"; exit 0; fi
printf "tmux %s\n" "$*" >> "$CALLS"; exit 0'
  _stub make 'printf "make %s\n" "$*" >> "$CALLS"
[ -z "${FAKE_MAKE_FAIL:-}" ] || exit 2
printf "#!/bin/sh\necho tmux next-3.9\n" > tmux; chmod +x tmux; : > tmux.1'
  _fake_tmux_tarball
  _stub curl 'printf "curl %s\n" "$*" >> "$CALLS"
case "$*" in *tmux/tmux/archive/*) cat "$TMP/tmux.tgz" ;; *) exit 22 ;; esac'
  printf '#!/bin/sh\necho old-tmux\n' > "$TMP/prefix/bin/tmux"
  chmod +x "$TMP/prefix/bin/tmux"
  printf '%s\n' 5356c62eadf8650ad1ffc95f52755d6f66029a20 > "$AICODING_TMUX_COMMIT_FILE"
}

teardown() { rm -rf "$TMP"; }

# Only the tools the code under test needs, so "missing" packages are really missing.
_curated_path() {
  local t
  for t in bash sh env cat mkdir rm mv chmod cp ln sed awk grep head tail tr cut sort \
           date mktemp dirname basename readlink sha256sum tar gzip jq flock install \
           id true false nproc tee ls find sleep uname wc stat; do
    ln -sf "$(command -v "$t")" "$TMP/bin/$t"
  done
}

_stub() {
  printf '#!/bin/bash\n%s\n' "$2" > "$TMP/stubs/$1"
  chmod +x "$TMP/stubs/$1"
}

_fake_tmux_tarball() {
  mkdir -p "$TMP/src/tmux-x"
  printf '#!/bin/sh\nexit 0\n' > "$TMP/src/tmux-x/autogen.sh"
  printf '#!/bin/sh\nexit 0\n' > "$TMP/src/tmux-x/configure"
  chmod +x "$TMP/src/tmux-x/configure"
  tar -czf "$TMP/tmux.tgz" -C "$TMP/src" tmux-x
}

_load_provision_system() {
  info() { printf 'INFO: %s\n' "$*"; }
  ok() { printf 'OK: %s\n' "$*"; }
  warn() { printf 'WARN: %s\n' "$*"; }
  err() { printf 'ERROR: %s\n' "$*"; }
  . "$BLUEPRINT_ROOT/lib/provision-system.sh" >/dev/null
  SUDO="sudo -n"
}

@test "tmux pin is a single 40-hex constant" {
  _load_provision_system
  [[ "$AICODING_TMUX_COMMIT_PIN" =~ ^[0-9a-f]{40}$ ]]
}

@test "strict tmux build installs beside the old binary, renames, writes the marker, never kills" {
  _load_provision_system
  export AICODING_TMUX_STRICT=1 AICODING_TMUX_BUILD_JOBS=2 AICODING_TMUX_LOW_PRIORITY=1
  export AICODING_TMUX_APT_FN=true
  run ensure_tmux
  [ "$status" -eq 0 ]
  [ "$("$TMP/prefix/bin/tmux")" = "tmux next-3.9" ]
  [ "$(cat "$AICODING_TMUX_COMMIT_FILE")" = "$AICODING_TMUX_COMMIT_PIN" ]
  grep -q "^make -j2$" "$CALLS"
  grep -q "^nice -n 19 ionice -c3 make -j2$" "$CALLS"
  grep -q "^sudo -n mv -f $TMP/prefix/bin/.tmux-" "$CALLS"
  if grep -q "kill" "$CALLS"; then false; fi
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "strict tmux build failure returns 1, keeps the old binary, no apt tmux fallback" {
  _load_provision_system
  export AICODING_TMUX_STRICT=1 AICODING_TMUX_APT_FN=true FAKE_MAKE_FAIL=1
  run ensure_tmux
  [ "$status" -eq 1 ]
  [ "$("$TMP/prefix/bin/tmux")" = "old-tmux" ]
  if grep -q "apt-get.* tmux$" "$CALLS"; then false; fi
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "strict tmux propagates a blocked build-dependency install as 3" {
  _load_provision_system
  deps_blocked() { return 3; }
  export AICODING_TMUX_STRICT=1 AICODING_TMUX_APT_FN=deps_blocked
  run ensure_tmux
  [ "$status" -eq 3 ]
  if grep -q "^make" "$CALLS"; then false; fi
}

@test "non-strict tmux keeps the installer's skip-network behavior" {
  _load_provision_system
  export AICODINGSETUP_SKIP_NETWORK=1
  run ensure_tmux
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping tmux rebuild while network operations are disabled"* ]]
}

@test "strict tmux under skip-network is blocked, not success" {
  _load_provision_system
  export AICODINGSETUP_SKIP_NETWORK=1 AICODING_TMUX_STRICT=1
  run ensure_tmux
  [ "$status" -eq 3 ]
}

_load_scheduled() {
  info() { printf 'INFO: %s\n' "$*"; }
  ok() { printf 'OK: %s\n' "$*"; }
  warn() { printf 'WARN: %s\n' "$*"; }
  err() { printf 'ERROR: %s\n' "$*"; }
  . "$BLUEPRINT_ROOT/lib/update-results.sh"
  . "$BLUEPRINT_ROOT/lib/provision-scheduled.sh" >/dev/null
}

# Everything the descriptor wants is present in the test prefix.
_all_present() {
  local c
  for c in git git-lfs bwrap rg gh; do _stub "$c" 'exit 0'; done
  _stub parallel 'echo "GNU parallel 20240222"'
  : > "$TMP/terminfo/x/xterm-kitty"
  printf '%s\n' "$AICODING_TMUX_COMMIT_PIN" > "$AICODING_TMUX_COMMIT_FILE"
  _stub tmux 'echo "tmux next-3.9"'
  printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/uv"; chmod +x "$HOME/.local/bin/uv"
  printf '#!/bin/sh\nexit 0\n' > "$TMP/prefix/bin/frogmouth"; chmod +x "$TMP/prefix/bin/frogmouth"
  mkdir -p "$AICODING_GO_ROOT/bin"
  printf '#!/bin/sh\nexit 0\n' > "$AICODING_GO_ROOT/bin/go"; chmod +x "$AICODING_GO_ROOT/bin/go"
}

@test "descriptor names the fixed apt list, the tmux pin, frogmouth, go and uv" {
  _load_scheduled
  run aicoding_system_provision_descriptor
  [ "$status" -eq 0 ]
  [[ "$output" == *"apt=git git-lfs jq bubblewrap ripgrep parallel kitty-terminfo gh"* ]]
  [[ "$output" == *"tmux=$AICODING_TMUX_COMMIT_PIN"* ]]
  [[ "$output" == *"frogmouth=uv-tool python3.12"* ]]
  [[ "$output" == *"go=if-missing"* ]]
  [[ "$output" == *"uv=if-missing"* ]]
}

@test "digest is 64 hex and changes with the tmux pin" {
  _load_scheduled
  local a b
  a=$(aicoding_system_provision_digest)
  [[ "$a" =~ ^[0-9a-f]{64}$ ]]
  AICODING_TMUX_COMMIT_PIN=0000000000000000000000000000000000000000
  b=$(aicoding_system_provision_digest)
  [ "$a" != "$b" ]
}

@test "no pending actions when every item is present" {
  _load_scheduled
  _all_present
  run _sched_pending_actions
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pending actions list missing items in execution order" {
  _load_scheduled
  _all_present
  rm "$TMP/stubs/rg" "$TMP/stubs/gh" "$TMP/terminfo/x/xterm-kitty" "$TMP/prefix/bin/frogmouth"
  printf '%s\n' 5356c62eadf8650ad1ffc95f52755d6f66029a20 > "$AICODING_TMUX_COMMIT_FILE"
  run _sched_pending_actions
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'apt:ripgrep\napt:kitty-terminfo\napt:gh\ntmux\nfrogmouth')" ]
}

@test "GNU parallel check rejects moreutils parallel" {
  _load_scheduled
  _stub parallel 'echo "parallel: moreutils"'
  run _sched_package_present parallel
  [ "$status" -ne 0 ]
}
