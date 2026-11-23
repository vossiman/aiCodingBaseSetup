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

teardown() { chmod -R u+rwx "$T" 2>/dev/null || true; rm -rf "$T"; }

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
  interactive 'bad value\na&b\n~home\n  padded  \ngh_pat/+=@%%,-.:9\n'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(echo "$output" | grep -c "WARN: AAA_TOKEN: only letters")" -eq 4 ]
  grep -qx 'AAA_TOKEN=gh_pat/+=@%,-.:9' "$STORE"
}

@test "interactive: end of input (Ctrl-D) at a prompt writes nothing" {
  printf 'BBB_TOKEN=b' > "$STORE"
  local before; before=$(sha256sum "$STORE")
  unset AICODINGSETUP_NONINTERACTIVE
  run bash -c "printf '\004' | script -qec 'bash $T/driver.sh' /dev/null"
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  echo "$output" | grep -q "ERROR: Input ended at the AAA_TOKEN prompt"
  [ "$(sha256sum "$STORE")" = "$before" ]
}

@test "an unreadable store fails before prompting or exporting" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores file modes"
  printf 'AAA_TOKEN=a\nBBB_TOKEN=b\n' > "$STORE"
  chmod 200 "$STORE"
  interactive 'x\nx\n'
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  echo "$output" | grep -q "ERROR: Cannot read"
  if echo "$output" | grep -q "Enter \|EXPORT"; then false; fi
}

@test "interactive: a missing key is not appended when the lock cannot be taken" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores file modes"
  printf 'BBB_TOKEN=b\n' > "$STORE"
  chmod 555 "$STORE_DIR"
  interactive 'a1\n'
  chmod 755 "$STORE_DIR"
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  echo "$output" | grep -q "ERROR: Could not lock"
  [ "$(cat "$STORE")" = "BBB_TOKEN=b" ]
}

@test "non-interactive: an existing complete store in a read-only directory needs no lock" {
  printf 'AAA_TOKEN=a\nBBB_TOKEN=b\n' > "$STORE"
  chmod 555 "$STORE_DIR"
  noninteractive
  chmod 755 "$STORE_DIR"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  echo "$output" | grep -q "EXPORT AAA=a BBB=b"
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

@test "reader: space-indented, tab-indented and multi-space export keys count as set" {
  printf '  AAA_TOKEN=a\n\tBBB_TOKEN=b\n' > "$STORE"
  local before; before=$(sha256sum "$STORE")
  interactive ''
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  echo "$output" | grep -q "EXPORT AAA=a BBB=b"
  if echo "$output" | grep -q "Enter "; then false; fi
  [ "$(sha256sum "$STORE")" = "$before" ]
  printf 'export   AAA_TOKEN=a\nexport\tBBB_TOKEN=b\n' > "$STORE"
  before=$(sha256sum "$STORE")
  interactive ''
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  echo "$output" | grep -q "EXPORT AAA=a BBB=b"
  if echo "$output" | grep -q "Enter "; then false; fi
  [ "$(sha256sum "$STORE")" = "$before" ]
}

@test "interactive: a read-only store with a missing key fails before any prompt" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores file modes"
  printf 'BBB_TOKEN=b\n' > "$STORE"
  chmod 400 "$STORE"
  interactive 'a1\n'
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  echo "$output" | grep -q "ERROR: Could not append AAA_TOKEN"
  if echo "$output" | grep -q "Enter "; then false; fi
}

@test "non-interactive: a read-only store with a missing key still succeeds" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores file modes"
  printf 'BBB_TOKEN=b\n' > "$STORE"
  chmod 400 "$STORE"
  noninteractive
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  echo "$output" | grep -q "EXPORT AAA= BBB=b"
}

@test "host: a 0644 store is tightened to 0600 in place" {
  printf 'AAA_TOKEN=a\nBBB_TOKEN=b\n' > "$STORE"
  chmod 644 "$STORE"
  local inode; inode=$(stat -c %i "$STORE")
  noninteractive
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(stat -c %a "$STORE")" = 600 ]
  [ "$(stat -c %i "$STORE")" = "$inode" ]
}

@test "host: a 0400 store stays 0400 and keeps its inode" {
  printf 'AAA_TOKEN=a\nBBB_TOKEN=b\n' > "$STORE"
  chmod 400 "$STORE"
  local inode; inode=$(stat -c %i "$STORE")
  noninteractive
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(stat -c %a "$STORE")" = 400 ]
  [ "$(stat -c %i "$STORE")" = "$inode" ]
}

@test "0400 with group read is tightened to 0400, not given owner write" {
  printf 'AAA_TOKEN=a\nBBB_TOKEN=b\n' > "$STORE"
  chmod 440 "$STORE"
  noninteractive
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(stat -c %a "$STORE")" = 400 ]
}

@test "container: a 0644 store is left alone" {
  printf 'AAA_TOKEN=a\nBBB_TOKEN=b\n' > "$STORE"
  chmod 644 "$STORE"
  sed -i 's/^ENV_TYPE=linux/ENV_TYPE=container/' "$T/driver.sh"
  noninteractive
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(stat -c %a "$STORE")" = 644 ]
}
