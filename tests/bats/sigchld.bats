#!/usr/bin/env bats

setup() {
  : "${BLUEPRINT_ROOT:?run via tests/bats/run.sh}"
  TEST_ROOT=$(mktemp -d)
  export TEST_ROOT
  # Reports the SIGCHLD and SIGPIPE dispositions its own children inherit.
  cat > "$TEST_ROOT/probe" <<'EOF'
#!/usr/bin/env bash
. "$BLUEPRINT_ROOT/lib/sigchld.sh"
aicoding_reset_inherited_sigchld "$0" "$@"
mask=$(sed -n 's/^SigIgn:[[:space:]]*//p' /proc/self/status)
mask=${mask: -8}
printf 'chld=%s pipe=%s args=%s reset=%s\n' "$(( (16#$mask >> 16) & 1 ))" \
  "$(( (16#$mask >> 12) & 1 ))" "$*" "${AICODING_SIGCHLD_RESET:-unset}"
EOF
  chmod +x "$TEST_ROOT/probe"
  git init -q --bare "$TEST_ROOT/repo.git"
}

teardown() { rm -rf "$TEST_ROOT"; }

# Starts $@ with SIGCHLD ignored, the way WSL's /init starts sessions.
with_ignored_sigchld() {
  python3 -c 'import os, signal, sys
signal.signal(signal.SIGCHLD, signal.SIG_IGN)
signal.signal(signal.SIGPIPE, signal.SIG_DFL)
os.execvp(sys.argv[1], sys.argv[1:])' "$@"
}

@test "inherited ignored SIGCHLD breaks git fsck (the failure being fixed)" {
  git -C "$TEST_ROOT/repo.git" commit-graph write --reachable 2>/dev/null || true
  run with_ignored_sigchld bash -c 'git --git-dir="$1" fsck --full --no-reflogs 2>&1' _ "$TEST_ROOT/repo.git"
  [ "$status" -ne 0 ] || skip "this git does not spawn fsck helpers"
  [[ "$output" == *"No child processes"* ]]
}

@test "reset re-executes once with SIGCHLD restored for children" {
  run with_ignored_sigchld "$TEST_ROOT/probe" one 'two words'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "chld=0 pipe=0 args=one two words reset=unset" ] || { echo "$output"; false; }
}

@test "reset keeps an inherited SIGPIPE ignore" {
  run python3 -c 'import os, signal, sys
signal.signal(signal.SIGCHLD, signal.SIG_IGN)
signal.signal(signal.SIGPIPE, signal.SIG_IGN)
os.execv(sys.argv[1], sys.argv[1:])' "$TEST_ROOT/probe"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == "chld=0 pipe=1 "* ]]
}

@test "reset is a no-op when SIGCHLD is not ignored" {
  run "$TEST_ROOT/probe" x
  [ "$status" -eq 0 ]
  [[ "$output" == "chld=0 pipe="?" args=x reset=unset" ]] || { echo "$output"; false; }
}

@test "git fsck passes under the reset" {
  cat > "$TEST_ROOT/fsck" <<'EOF'
#!/usr/bin/env bash
. "$BLUEPRINT_ROOT/lib/sigchld.sh"
aicoding_reset_inherited_sigchld "$0" "$@"
git --git-dir="$1" fsck --full --no-reflogs
EOF
  chmod +x "$TEST_ROOT/fsck"
  run with_ignored_sigchld "$TEST_ROOT/fsck" "$TEST_ROOT/repo.git"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "entrypoints that run update passes reset SIGCHLD first" {
  for entry in aicoding-auto-update aicoding-sync aicoding-install; do
    grep -q '^aicoding_reset_inherited_sigchld "\$SCRIPT_REAL" "\$@"' "$BLUEPRINT_ROOT/bin/$entry" \
      || { echo "missing in $entry"; false; }
  done
}
