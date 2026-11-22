#!/usr/bin/env bats
# load_or_prompt_secrets: an existing store is appended to, never rebuilt.

setup() {
  : "${BLUEPRINT_ROOT:?unset — run via tests/bats/run.sh}"
  T=$(mktemp -d)
  STORE_DIR="$T/store"
  STORE="$STORE_DIR/.secrets.env"
  mkdir -p "$STORE_DIR" "$T/repo"
  printf '# example\nAAA_TOKEN=\n\n# comment\nBBB_TOKEN=\n' > "$T/repo/.secrets.env.example"
  cat > "$T/driver.sh" <<EOF
set -euo pipefail
SCRIPT_DIR='$T/repo'; SECRETS_DIR='$STORE_DIR'; SECRETS_FILE='$STORE'
ENV_TYPE=linux
info() { echo "INFO: \$*"; }; ok() { echo "OK: \$*"; }
warn() { echo "WARN: \$*"; }; err() { echo "ERROR: \$*"; }; header() { :; }
. '$BLUEPRINT_ROOT/lib/provision-secrets.sh'
load_or_prompt_secrets
echo "EXPORT AAA=\${AAA_TOKEN-unset} BBB=\${BBB_TOKEN-unset} EXTRA=\${EXTRA_KEY-unset}"
EOF
}

teardown() { rm -rf "$T"; }

# Drive the function on a pty, answering its prompts from $1.
interactive() {
  unset AICODINGSETUP_NONINTERACTIVE
  run bash -c "printf '$1' | script -qec 'bash $T/driver.sh' /dev/null"
}

noninteractive() {
  AICODINGSETUP_NONINTERACTIVE=1 run bash "$T/driver.sh" </dev/null
}

@test "interactive: unknown keys, comments and order survive; only the missing key is appended in place" {
  printf '# mine\nEXTRA_KEY=keep=me=\nBBB_TOKEN=b\n' > "$STORE"
  local inode; inode=$(stat -c %i "$STORE")
  interactive 'a1\n'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cat "$STORE")" = "$(printf '# mine\nEXTRA_KEY=keep=me=\nBBB_TOKEN=b\n\nAAA_TOKEN=a1')" ]
  [ "$(stat -c %i "$STORE")" = "$inode" ]
  echo "$output" | grep -q "EXPORT AAA=a1 BBB=b EXTRA=unset"
}

@test "interactive: a store without a trailing newline gets one before the append" {
  printf 'BBB_TOKEN=b' > "$STORE"
  interactive 'a1\n'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cat "$STORE")" = "$(printf 'BBB_TOKEN=b\n\nAAA_TOKEN=a1')" ]
}

@test "interactive: a skipped key is written empty and the next run asks nothing" {
  printf 'BBB_TOKEN=b\n' > "$STORE"
  interactive '\n'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qx 'AAA_TOKEN=' "$STORE"
  local before; before=$(sha256sum "$STORE")
  interactive ''
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(sha256sum "$STORE")" = "$before" ]
  if echo "$output" | grep -q "Enter "; then false; fi
}

@test "interactive: a value the sync-time shell source could misread is refused" {
  printf 'BBB_TOKEN=b\n' > "$STORE"
  interactive 'bad value\ngood\n'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  echo "$output" | grep -q "WARN: AAA_TOKEN: value contains"
  grep -qx 'AAA_TOKEN=good' "$STORE"
}

@test "interactive: a read-only store fails loudly instead of claiming success" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores file modes"
  printf 'BBB_TOKEN=b\n' > "$STORE"
  chmod 400 "$STORE"
  interactive 'a1\n'
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  echo "$output" | grep -q "ERROR: Could not append AAA_TOKEN"
  if echo "$output" | grep -q "OK: Added"; then false; fi
}

@test "reader: CRLF, export prefix, '=' in values and an unterminated last line parse; bad keys are skipped" {
  printf 'export AAA_TOKEN=x=\r\nBAD-KEY=1\nBBB_TOKEN=y' > "$STORE"
  local before; before=$(sha256sum "$STORE")
  noninteractive
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  echo "$output" | grep -q "EXPORT AAA=x= BBB=y EXTRA=unset"
  echo "$output" | grep -q "WARN: .* line 2 is not KEY=value"
  if echo "$output" | grep -q "BAD-KEY=1\|=1$"; then false; fi
  [ "$(sha256sum "$STORE")" = "$before" ]
}

@test "fresh machine: the store is created with exactly the example's keys, mode 600" {
  noninteractive
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(stat -c %a "$STORE")" = 600 ]
  [ "$(grep -v '^#' "$STORE" | grep -v '^$')" = "$(printf 'AAA_TOKEN=\nBBB_TOKEN=')" ]
}
