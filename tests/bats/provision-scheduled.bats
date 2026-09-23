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
  _ORIG_PATH=$PATH
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

teardown() { PATH=$_ORIG_PATH; rm -rf "$TMP"; }

# Only the tools the code under test needs, so "missing" packages are really missing.
_curated_path() {
  local t
  for t in bash sh env cat mkdir rm mv chmod cp ln sed awk grep head tail tr cut sort \
           date mktemp dirname basename readlink sha256sum tar gzip jq flock install \
           id true false nproc tee ls find sleep uname wc stat; do
    ln -sf "$(type -P "$t")" "$TMP/bin/$t"
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

_run_orchestrator() {
  export AICODINGSETUP_SKIP_NETWORK=1 AICODING_SYSTEM_PROVISION_RUN_OFFLINE=1
  run aicoding_run_system_provision
}

_record() { jq -r --arg k "$1" '.components["provision-system"][$k] // empty' "$AICODING_RESULTS_FILE"; }

@test "skip-network without the test seam does nothing and records nothing" {
  _load_scheduled
  export AICODINGSETUP_SKIP_NETWORK=1
  run aicoding_run_system_provision
  [ "$status" -eq 0 ]
  [ ! -e "$AICODING_RESULTS_FILE" ]
  [ ! -s "$CALLS" ]
}

@test "nothing pending records current with the digest and makes no privileged call" {
  _load_scheduled
  _all_present
  _run_orchestrator
  [ "$status" -eq 0 ]
  [ "$(_record state)" = current ]
  [ "$(_record successful_version)" = "$(aicoding_system_provision_digest)" ]
  if grep -qE '^(sudo|apt-get|curl)' "$CALLS"; then false; fi
}

@test "a recorded matching digest runs nothing at all" {
  _load_scheduled
  aicoding_result_record provision-system current "$(aicoding_system_provision_digest)" verified "$(aicoding_system_provision_digest)"
  rm -f "$TMP/stubs/rg"
  _run_orchestrator
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
}

@test "missing apt packages install through sudo -n with lock wait and a bounded timeout" {
  _load_scheduled
  _all_present
  rm "$TMP/stubs/rg"
  _stub apt-get 'printf "apt-get %s\n" "$*" >> "$CALLS"
case "$*" in *install*ripgrep*) printf "#!/bin/sh\nexit 0\n" > "$TMP/stubs/rg"; chmod +x "$TMP/stubs/rg" ;; esac'
  _run_orchestrator
  [ "$status" -eq 0 ]
  [ "$(_record state)" = updated ]
  grep -q '^timeout --kill-after=30 900 sudo -n env DEBIAN_FRONTEND=noninteractive apt-get .*-o DPkg::Lock::Timeout=120 .*install -y --no-install-recommends ripgrep$' "$CALLS"
  if grep -q '^sudo [^-]' "$CALLS"; then false; fi
  if grep -q 'sources.list' "$CALLS"; then false; fi
}

@test "a held apt lock is blocked/apt_lock_busy and nothing is killed" {
  _load_scheduled
  _all_present
  rm "$TMP/stubs/rg"
  _stub apt-get 'printf "apt-get %s\n" "$*" >> "$CALLS"
case "$*" in *install*) echo "E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 4242 (apt)" >&2; exit 100 ;; esac'
  _run_orchestrator
  [ "$status" -eq 3 ]
  [ "$(_record state)" = blocked ]
  [ "$(_record reason)" = apt_lock_busy ]
  if grep -qE '(^|[[:space:]])(kill|pkill|killall)([[:space:]]|$)' "$CALLS"; then false; fi
}

@test "a busy archives directory lock during install is blocked/apt_lock_busy" {
  _load_scheduled
  _all_present
  rm "$TMP/stubs/rg"
  _stub apt-get 'printf "apt-get %s\n" "$*" >> "$CALLS"
case "$*" in *install*) echo "E: Unable to lock directory /var/cache/apt/archives/" >&2; exit 100 ;; esac'
  _run_orchestrator
  [ "$status" -eq 3 ]
  [ "$(_record state)" = blocked ]
  [ "$(_record reason)" = apt_lock_busy ]
}

@test "an apt-get update timeout is failed/apt_timeout and install never runs" {
  _load_scheduled
  _all_present
  rm "$TMP/stubs/rg"
  _stub timeout 'printf "timeout %s\n" "$*" >> "$CALLS"
while [ $# -gt 0 ]; do case "$1" in -*|[0-9]*) shift ;; *) break ;; esac; done
case "$*" in *"update -qq"*) exit 124 ;; esac
exec "$@"'
  _run_orchestrator
  [ "$status" -eq 1 ]
  [ "$(_record state)" = failed ]
  [ "$(_record reason)" = apt_timeout ]
  if grep -q 'install.*ripgrep' "$CALLS"; then false; fi
}

@test "without passwordless sudo it is blocked/sudo_unavailable before any apt call" {
  _load_scheduled
  _all_present
  rm "$TMP/stubs/rg"
  _stub sudo 'printf "sudo %s\n" "$*" >> "$CALLS"; exit 1'
  _run_orchestrator
  [ "$status" -eq 3 ]
  [ "$(_record reason)" = sudo_unavailable ]
  if grep -q '^apt-get' "$CALLS"; then false; fi
}

@test "tmux drift rebuilds with limits under a 1800s bound and records updated" {
  _load_scheduled
  _all_present
  printf '%s\n' 5356c62eadf8650ad1ffc95f52755d6f66029a20 > "$AICODING_TMUX_COMMIT_FILE"
  _run_orchestrator
  [ "$status" -eq 0 ]
  [ "$(_record state)" = updated ]
  grep -q '^timeout --kill-after=30 1800 bash -c ensure_tmux$' "$CALLS"
  grep -q '^nice -n 19 ionice -c3 make -j2$' "$CALLS"
  [ "$(cat "$AICODING_TMUX_COMMIT_FILE")" = "$AICODING_TMUX_COMMIT_PIN" ]
}

@test "a tmux build failure is failed/tmux_build_failed and keeps the old digest" {
  _load_scheduled
  _all_present
  aicoding_result_record provision-system current olddigest verified olddigest
  printf '%s\n' 5356c62eadf8650ad1ffc95f52755d6f66029a20 > "$AICODING_TMUX_COMMIT_FILE"
  export FAKE_MAKE_FAIL=1
  _run_orchestrator
  [ "$status" -eq 1 ]
  [ "$(_record state)" = failed ]
  [ "$(_record reason)" = tmux_build_failed ]
  [ "$(_record successful_version)" = olddigest ]
  [ "$("$TMP/prefix/bin/tmux")" = "old-tmux" ]
}

@test "missing frogmouth installs as a uv tool into the system prefix" {
  _load_scheduled
  _all_present
  rm "$TMP/prefix/bin/frogmouth"
  cat > "$HOME/.local/bin/uv" <<'EOF'
#!/bin/bash
printf 'uv %s\n' "$*" >> "$CALLS"
printf '#!/bin/sh\nexit 0\n' > "$UV_TOOL_BIN_DIR/frogmouth"; chmod +x "$UV_TOOL_BIN_DIR/frogmouth"
EOF
  _run_orchestrator
  [ "$status" -eq 0 ]
  grep -q "^sudo -n env UV_PYTHON_INSTALL_DIR=$TMP/opt-uv/python UV_TOOL_DIR=$TMP/opt-uv/tools UV_TOOL_BIN_DIR=$TMP/prefix/bin $HOME/.local/bin/uv tool install --python 3.12 frogmouth$" "$CALLS"
  [ "$(_record state)" = updated ]
}

@test "an item that still fails verification after a clean run is failed/verification_failed" {
  _load_scheduled
  _all_present
  rm "$TMP/stubs/gh"
  _run_orchestrator
  [ "$status" -eq 1 ]
  [ "$(_record state)" = failed ]
  [[ "$(_record reason)" == verification_failed:apt:gh* ]]
}

@test "the scheduled library contains no kill, pkill or killall" {
  if grep -nE '(^|[^_[:alnum:]-])(kill|pkill|killall)([[:space:]]|$)' "$BLUEPRINT_ROOT/lib/provision-scheduled.sh"; then false; fi
  _load_provision_system
  if declare -f ensure_tmux | grep -nE '(^|[^_[:alnum:]-])(kill|pkill|killall)([[:space:]]|$)'; then false; fi
}

@test "the bounded child shell has every helper, the strict seams and no rc-file edits" {
  _load_scheduled
  probe() {
    local f
    for f in info ok warn err _sched_apt_install _sched_note_reason _sched_uv_bin "$AICODING_TMUX_APT_FN"; do
      declare -F "$f" >/dev/null || { echo "missing $f"; return 9; }
    done
    printf '%s|%s|%s|%s|%s\n' "$AICODING_TMUX_STRICT" "$AICODING_TMUX_BUILD_JOBS" \
      "$AICODING_TMUX_LOW_PRIORITY" "$UV_NO_MODIFY_PATH" "$SUDO"
  }
  SUDO="sudo -n"
  run _sched_bounded 10 probe
  [ "$status" -eq 0 ]
  [ "$output" = "1|2|1|1|sudo -n" ]
  grep -q '^timeout --kill-after=30 10 bash -c probe$' "$CALLS"
}
