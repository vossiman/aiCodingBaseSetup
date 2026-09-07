#!/usr/bin/env bats
# lib/redact-literal.sh: the one place that turns the secrets file into sed
# rules. Both redact-transcript and redact-sessions source it.

bats_require_minimum_version 1.5.0

setup() {
  : "${BLUEPRINT_ROOT:?unset, run via tests/bats/run.sh}"
  LIB="$BLUEPRINT_ROOT/lib/redact-literal.sh"
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  mkdir -p "$HOME/.aicodingsetup"
  SECRETS="$HOME/.aicodingsetup/.secrets.env"
  . "$LIB"
}

teardown() { case "${TMPDIR:-}" in */tmp.*) rm -rf "$TMPDIR" ;; esac }

V="abcdefghijklmnopqrstuvwxyz"

@test "b64 core, offset 0: full encoding minus the mixed last char" {
  # 26 bytes, 26 % 3 == 2, so the last char carries padding bits.
  run redact_literal_b64_core "$V" 0
  [ "$output" = "YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eX" ]
}

@test "b64 core, offset 1: drops two leading chars, ends on a byte boundary" {
  run redact_literal_b64_core "$V" 1
  [ "$output" = "FiY2RlZmdoaWprbG1ub3BxcnN0dXZ3eHl6" ]
  [[ "$(printf 'X%sY' "$V" | base64 -w0)" == *"$output"* ]]
}

@test "b64 core, offset 2: drops three leading chars and the mixed last char" {
  run redact_literal_b64_core "$V" 2
  [[ "$(printf 'XX%sYZ' "$V" | base64 -w0)" == *"$output"* ]]
  [ "${#output}" -ge 12 ]
}

@test "transcript mode: raw and json variants, anonymous marker" {
  printf 'GH_TOKEN=abc"def\\ghijklmno\n' > "$SECRETS"
  run redact_literal_rules transcript "$SECRETS"
  [ "$status" -eq 0 ]
  [[ "$output" == *'[REDACTED]/g'* ]]
  [[ "$output" != *'[REDACTED:'* ]]
  [ "$(printf '%s\n' "$output" | grep -c '^s/')" -eq 2 ]
}

@test "sessions mode: named marker, raw, and six base64 rules" {
  printf 'GH_TOKEN=%s\n' "$V" > "$SECRETS"
  run redact_literal_rules sessions "$SECRETS"
  [ "$status" -eq 0 ]
  [[ "$output" == *'[REDACTED:GH_TOKEN]/g'* ]]
  # raw + 3 b64 + 3 urlsafe (json variant identical to raw, so omitted)
  [ "$(printf '%s\n' "$output" | grep -c '^s/')" -eq 7 ]
}

@test "sessions mode: a value of 8 to 11 chars gets literal rules but no base64" {
  printf 'SHORT=abcdefgh\n' > "$SECRETS"
  run redact_literal_rules sessions "$SECRETS"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^s/')" -eq 1 ]
}

@test "sessions rules redact a value planted at every base64 alignment" {
  printf 'GH_TOKEN=%s\n' "$V" > "$SECRETS"
  local script; script="$(redact_literal_rules sessions "$SECRETS")"
  local blob0 blob1 blob2
  blob0="$(printf '%s' "$V" | base64 -w0)"
  blob1="$(printf 'X%sYZ' "$V" | base64 -w0)"
  blob2="$(printf 'XX%sY' "$V" | base64 -w0)"
  run sed -E -f <(printf '%s' "$script") <<EOF
plain $V here
b0 $blob0
b1 $blob1
b2 $blob2
EOF
  [[ "$output" != *"$V"* ]]
  [[ "$output" != *"$blob0"* ]]
  [[ "$output" != *"$blob1"* ]]
  [[ "$output" != *"$blob2"* ]]
  [ "$(printf '%s\n' "$output" | grep -c 'REDACTED:GH_TOKEN')" -eq 4 ]
}

@test "urlsafe base64 of the value is redacted too" {
  printf 'GH_TOKEN=%s\n' "$V" > "$SECRETS"
  local script; script="$(redact_literal_rules sessions "$SECRETS")"
  local blob; blob="$(printf '~~%s??' "$V" | base64 -w0 | tr '+/' '-_')"
  run sed -E -f <(printf '%s' "$script") <<< "u $blob"
  [[ "$output" != *"$blob"* ]]
}

@test "an unrelated base64 blob survives" {
  printf 'GH_TOKEN=%s\n' "$V" > "$SECRETS"
  local script; script="$(redact_literal_rules sessions "$SECRETS")"
  local other; other="$(printf 'the quick brown fox jumps over the lazy dog' | base64 -w0)"
  run sed -E -f <(printf '%s' "$script") <<< "keep $other"
  [ "$output" = "keep $other" ]
}

@test "absent file: exit 0, empty script" {
  run redact_literal_rules sessions "$SECRETS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "unreadable file: exit 1, empty script" {
  if [ "$(id -u)" -eq 0 ]; then skip "root can read a chmod 000 file"; fi
  printf 'GH_TOKEN=%s\n' "$V" > "$SECRETS"; chmod 000 "$SECRETS"
  run redact_literal_rules sessions "$SECRETS"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "unknown mode: exit 1" {
  printf 'GH_TOKEN=%s\n' "$V" > "$SECRETS"
  run redact_literal_rules bogus "$SECRETS"
  [ "$status" -eq 1 ]
}

@test "comments, blanks, export prefix and quotes are handled" {
  cat > "$SECRETS" <<'EOF'
# comment

export A="abcdefghijkl"
B='mnopqrstuvwx'
C=
EOF
  run redact_literal_rules sessions "$SECRETS"
  [ "$status" -eq 0 ]
  [[ "$output" == *'[REDACTED:A]'* ]]
  [[ "$output" == *'[REDACTED:B]'* ]]
  [[ "$output" != *'"'* ]]
}
