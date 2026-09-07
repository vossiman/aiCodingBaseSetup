#!/usr/bin/env bats
# bin/measure-remote: drives memory-lanes measurement runs on vossisrv over a
# command=-restricted SSH key, so an agent can start, watch and cancel a run
# without a shell on the box and without the key path in any command it
# writes (the secrets deny hook refuses that path, correctly).
#
# These tests never open a connection: a fake `ssh` on PATH records what it
# would have run. What is under test is that the client sends exactly the
# verb it was given, uses the key non-interactively, and refuses malformed
# requests before any round trip.

bats_require_minimum_version 1.5.0

setup() {
  TMPDIR=$(mktemp -d)
  export TMPDIR
  export HOME="$TMPDIR"
  MR="$BLUEPRINT_ROOT/bin/measure-remote"
  mkdir -p "$HOME/.aicodingsetup" "$TMPDIR/bin"
  printf 'not-a-real-key\n' > "$HOME/.aicodingsetup/memory-lanes-measure"
  cat > "$TMPDIR/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TMPDIR/ssh.argv"
echo "fake-ssh-ok"
exit 0
EOF
  chmod +x "$TMPDIR/bin/ssh"
  export PATH="$TMPDIR/bin:$PATH"
}

teardown() { rm -rf "$TMPDIR"; }

@test "status is sent verbatim with the key, batch mode and no shell" {
  run "$MR" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"fake-ssh-ok"* ]]
  argv=$(cat "$TMPDIR/ssh.argv")
  [[ "$argv" == *"$HOME/.aicodingsetup/memory-lanes-measure"* ]]
  [[ "$argv" == *"BatchMode=yes"* ]]
  [[ "$argv" == *"IdentitiesOnly=yes"* ]]
  [[ "$argv" == *"vossi@10.0.0.249"* ]]
  [ "$(tail -n 1 "$TMPDIR/ssh.argv")" = "status" ]
}

@test "start forwards every argument in order" {
  run "$MR" start c2-vector vector,cognee 12.5 full unit
  [ "$status" -eq 0 ]
  [ "$(tail -n 6 "$TMPDIR/ssh.argv" | tr '\n' ' ')" = "start c2-vector vector,cognee 12.5 full unit " ]
}

@test "start with a malformed label is refused before any connection" {
  run "$MR" start 'c2;rm' vector 5 delta
  [ "$status" -eq 2 ]
  [[ "$output" == *"label"* ]]
  [ ! -f "$TMPDIR/ssh.argv" ]
}

@test "start with an unknown lane or mode is refused" {
  run "$MR" start c2 vector,postgres 5 delta
  [ "$status" -eq 2 ]
  run "$MR" start c2 vector 5 wipe
  [ "$status" -eq 2 ]
  [ ! -f "$TMPDIR/ssh.argv" ]
}

@test "an unknown verb is refused" {
  run "$MR" bash
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown verb"* ]]
  [ ! -f "$TMPDIR/ssh.argv" ]
}

@test "verbs that take no arguments refuse extras" {
  run "$MR" cancel now
  [ "$status" -eq 2 ]
  [ ! -f "$TMPDIR/ssh.argv" ]
}

@test "a missing key is a clear refusal, not an ssh error" {
  rm "$HOME/.aicodingsetup/memory-lanes-measure"
  run "$MR" status
  [ "$status" -eq 2 ]
  [[ "$output" == *"no key at"* ]]
  [ ! -f "$TMPDIR/ssh.argv" ]
}

@test "MEASURE_REMOTE_TARGET overrides the host" {
  MEASURE_REMOTE_TARGET="tester@127.0.0.1" run "$MR" status
  [ "$status" -eq 0 ]
  [[ "$(cat "$TMPDIR/ssh.argv")" == *"tester@127.0.0.1"* ]]
}

@test "ssh's exit code is passed through" {
  cat > "$TMPDIR/bin/ssh" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
  run "$MR" status
  [ "$status" -eq 7 ]
}
