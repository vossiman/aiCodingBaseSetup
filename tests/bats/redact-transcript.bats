#!/usr/bin/env bats
# bin/redact-transcript: the one redactor for anything that leaves a machine
# as transcript material. stdin -> stdout. The distiller hook's slice tee and
# the memory-lanes transcript harvester both call it, so there is a single
# implementation of the literal / pattern / entropy layers and of the
# fail-closed rule for an unreadable secrets file.

bats_require_minimum_version 1.5.0

setup() {
  : "${BLUEPRINT_ROOT:?unset — run via tests/bats/run.sh}"
  RT="$BLUEPRINT_ROOT/bin/redact-transcript"
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  mkdir -p "$HOME/.aicodingsetup"
}

teardown() { case "${TMPDIR:-}" in */tmp.*) rm -rf "$TMPDIR" ;; esac }

# Literal-only fixture: 32 lowercase hex, below the 48-hex rule, no uppercase
# (entropy layer blind), planted as bare prose (keyword rule blind). Only the
# literal layer can catch it, which is what makes the assertion meaningful.
LITERAL="deadbeefcafebabefeedface12345678"

@test "redacts a literal value from the secrets file and a pattern-shaped token" {
  printf 'MEMORY_ROUTER_TOKEN=%s\n' "$LITERAL" > "$HOME/.aicodingsetup/.secrets.env"
  run --separate-stderr bash "$RT" <<EOF
ordinary prose that must survive
router token $LITERAL inline
gh token ghp_abcdefghijklmnopqrstuvwxyz012345 in a log line
EOF
  [ "$status" -eq 0 ]
  [[ "$output" == *"ordinary prose that must survive"* ]]
  [[ "$output" != *"$LITERAL"* ]]
  [[ "$output" != *"ghp_abcdefghijklmnopqrstuvwxyz012345"* ]]
  [[ "$output" == *"REDACTED"* ]]
  [ -z "$stderr" ]
}

@test "clean text passes through byte for byte" {
  printf 'OTHER=%s\n' "$LITERAL" > "$HOME/.aicodingsetup/.secrets.env"
  printf 'line one\n{"role":"user","text":"nothing secret here 1234"}\n' > "$TMPDIR/in"
  bash "$RT" < "$TMPDIR/in" > "$TMPDIR/out"
  cmp "$TMPDIR/in" "$TMPDIR/out"
}

@test "absent secrets file: patterns still redact, exit 0" {
  rm -f "$HOME/.aicodingsetup/.secrets.env"
  run bash "$RT" <<< "key sk-abcdefghijklmnopqrstuvwx here"
  [ "$status" -eq 0 ]
  [[ "$output" != *"sk-abcdefghijklmnopqrstuvwx"* ]]
}

@test "unreadable secrets file: refuses, writes nothing, names no value" {
  if [ "$(id -u)" -eq 0 ]; then
    skip "running as root: chmod 000 does not make a file unreadable"
  fi
  printf 'MEMORY_ROUTER_TOKEN=%s\n' "$LITERAL" > "$HOME/.aicodingsetup/.secrets.env"
  chmod 000 "$HOME/.aicodingsetup/.secrets.env"
  run --separate-stderr bash "$RT" <<< "router token $LITERAL inline"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [[ "$stderr" == *"secrets file"* ]]
  [[ "$stderr" != *"$LITERAL"* ]]
}

@test "short and empty values get no literal rule and do not break parsing" {
  printf 'A=%s\nB=\nC=short\n' "$LITERAL" > "$HOME/.aicodingsetup/.secrets.env"
  run bash "$RT" <<< "router token $LITERAL inline"
  [ "$status" -eq 0 ]
  [[ "$output" != *"$LITERAL"* ]]
}
