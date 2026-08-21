#!/usr/bin/env bats
# ensure_codex_managed_hooks: deploy the secrets deny hook as a codex MANAGED
# hook (/etc/codex/requirements.toml), which is trusted by policy. A hook in
# ~/.codex/hooks.json would be silently skipped until a human runs /hooks —
# installed-but-inert, the exact bug this whole change fixes.

setup() {
  : "${BLUEPRINT_ROOT:?unset — run via tests/bats/run.sh}"
  TMPDIR_T=$(mktemp -d)
  export HOME="$TMPDIR_T"
  export SCRIPT_DIR="$BLUEPRINT_ROOT"
  export CODEX_MANAGED_DIR="$TMPDIR_T/etc-codex"

  # Loggers normally come from install.sh, which sources this library.
  header(){ :; }; info(){ echo "INFO: $*"; }; ok(){ echo "OK: $*"; }
  warn(){ echo "WARN: $*"; }; err(){ echo "ERROR: $*"; }
  export -f header info ok warn err 2>/dev/null || true

  # A codex on PATH, and no sudo: the function must write directly.
  mkdir -p "$TMPDIR_T/bin"
  printf '#!/bin/sh\nexit 0\n' > "$TMPDIR_T/bin/codex"; chmod +x "$TMPDIR_T/bin/codex"
  # A MINIMAL PATH: the real codex lives in ~/.local/bin, so leaving the
  # inherited PATH in place would defeat the "codex not installed" case.
  export PATH="$TMPDIR_T/bin:/usr/bin:/bin"

  . "$BLUEPRINT_ROOT/lib/provision-system.sh" >/dev/null 2>&1
  SUDO=""   # after sourcing: the library sets it from `id -u`
  REQ="$CODEX_MANAGED_DIR/requirements.toml"
  HOOK="$CODEX_MANAGED_DIR/hooks/bw-deny-files.sh"
}

teardown() { rm -rf "$TMPDIR_T"; }

@test "installs the hook script and requirements.toml" {
  run ensure_codex_managed_hooks
  [ "$status" -eq 0 ]
  [ -f "$REQ" ]
  [ -x "$HOOK" ]
}

@test "the deployed hook is the same script Claude Code uses" {
  ensure_codex_managed_hooks
  cmp "$BLUEPRINT_ROOT/configs/claude/hooks/bw-deny-files.sh" "$HOOK"
}

@test "registers a PreToolUse hook with the managed dir substituted" {
  ensure_codex_managed_hooks
  grep -q '^\[\[hooks.PreToolUse\]\]' "$REQ"
  grep -q "command = \"$CODEX_MANAGED_DIR/hooks/bw-deny-files.sh\"" "$REQ"
  # the placeholder must not survive into the deployed file. `! grep` at
  # command level can never fail a bats test (see regressions.bats).
  if grep -q '{{MANAGED_DIR}}' "$REQ"; then false; fi
}

@test "the deployed requirements.toml is valid TOML codex can parse" {
  ensure_codex_managed_hooks
  run python3 -c "
import sys
try: import tomllib
except ModuleNotFoundError: sys.exit(0)
d=tomllib.load(open('$REQ','rb'))
h=d['hooks']['PreToolUse'][0]
assert h['matcher'], 'no matcher'
assert h['hooks'][0]['type']=='command', h
assert h['hooks'][0]['command'].endswith('bw-deny-files.sh'), h
print('ok')
"
  [ "$status" -eq 0 ]
}

@test "second run is idempotent and rewrites nothing" {
  ensure_codex_managed_hooks
  local before; before=$(stat -c %Y "$REQ")
  run ensure_codex_managed_hooks
  [ "$status" -eq 0 ]
  [[ "$output" == *"up to date"* ]]
  [ "$(stat -c %Y "$REQ")" = "$before" ]
}

@test "a changed hook script is redeployed" {
  ensure_codex_managed_hooks
  echo "# tampered" >> "$HOOK"
  run ensure_codex_managed_hooks
  [ "$status" -eq 0 ]
  [[ "$output" != *"up to date"* ]]
  cmp "$BLUEPRINT_ROOT/configs/claude/hooks/bw-deny-files.sh" "$HOOK"
}

@test "refuses to clobber a requirements.toml the blueprint did not write" {
  mkdir -p "$CODEX_MANAGED_DIR"
  printf '# an admin policy file\nallow_managed_hooks_only = true\n' > "$REQ"
  run ensure_codex_managed_hooks
  [ "$status" -eq 0 ]
  [[ "$output" == *"not blueprint-managed"* ]]
  grep -q "an admin policy file" "$REQ"
}

@test "skips cleanly when codex is not installed" {
  rm "$TMPDIR_T/bin/codex"
  run ensure_codex_managed_hooks
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex not installed"* ]]
  [ ! -e "$REQ" ]
}

@test "warns instead of failing when root is unavailable" {
  SUDO="$TMPDIR_T/bin/false-sudo"
  printf '#!/bin/sh\nexit 1\n' > "$SUDO"; chmod +x "$SUDO"
  run ensure_codex_managed_hooks
  [ "$status" -eq 0 ]
  [[ "$output" == *"needs root"* ]]
}

# --- root escalation: only for the /etc writes, never the whole installer ----
# A sudo stub that can be told to refuse `-n` (i.e. "a password is required")
# while still executing the command when actually invoked.
_stub_sudo() {
  cat > "$TMPDIR_T/bin/sudo" <<EOF
#!/bin/bash
echo "sudo \$*" >> "$TMPDIR_T/sudo.log"
if [ "\$1" = "-n" ]; then exit ${1:-0}; fi
exec "\$@"
EOF
  chmod +x "$TMPDIR_T/bin/sudo"
  SUDO="$TMPDIR_T/bin/sudo"
}

@test "passwordless sudo: escalates silently, no explanation noise" {
  _stub_sudo 0
  run ensure_codex_managed_hooks
  [ "$status" -eq 0 ]
  [ -f "$REQ" ]
  [[ "$output" != *"Escalating"* ]]
  grep -q '^sudo -n true' "$TMPDIR_T/sudo.log"
}

@test "password needed + interactive: explains, then escalates for the writes" {
  _stub_sudo 1
  _codex_hook_can_prompt() { return 0; }   # pretend a human is watching
  run ensure_codex_managed_hooks
  [ "$status" -eq 0 ]
  [ -f "$REQ" ]
  [[ "$output" == *"One step needs root"* ]]
  [[ "$output" == *"rest of the install stays unprivileged"* ]]
}

@test "password needed + non-interactive: warns, and never says 'sudo aicoding-install'" {
  _stub_sudo 1
  export AICODINGSETUP_NONINTERACTIVE=1
  run ensure_codex_managed_hooks
  [ "$status" -eq 0 ]
  [ ! -e "$REQ" ]
  [[ "$output" == *"cannot prompt"* ]]
  [[ "$output" == *"run 'aicoding-install' from a terminal"* ]]
  # the whole point of this change: never tell the user to sudo the installer
  if [[ "$output" == *"sudo aicoding-install"* ]]; then false; fi
}

@test "boot sync: silent skip, so it cannot nag on every container start" {
  _stub_sudo 1
  export AICODING_SYNC_MODE=boot
  run ensure_codex_managed_hooks
  [ "$status" -eq 0 ]
  [ ! -e "$REQ" ]
  [[ "$output" != *"cannot prompt"* ]]
}

@test "_codex_hook_can_prompt refuses in boot and non-interactive runs" {
  AICODING_SYNC_MODE=boot run _codex_hook_can_prompt
  [ "$status" -ne 0 ]
  AICODINGSETUP_NONINTERACTIVE=1 run _codex_hook_can_prompt
  [ "$status" -ne 0 ]
}
