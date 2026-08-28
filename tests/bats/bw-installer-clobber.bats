#!/usr/bin/env bats
# The blueprint owns ~/.claude/hooks/bw-deny-files.sh and, since this change,
# ~/.pi/agent/extensions/bw-deny-files.ts. bw-AICode's installer writes both
# paths too, with sandbox-scoped versions that no-op unless
# BW_DENY_PATTERNS_FILE is set — so whenever its copies won, an always-on
# secrets guard silently became a sandbox-only one. It ran after the managed
# deploy in both installers, so its copies always won (2026-08-24 to
# 2026-08-28; bw-AICode PR #2 makes it skip paths that already exist).
#
# vendor/bw-AICode is re-pulled from its main on every provisioning run, so a
# regression upstream lands here with no signal. These are the tripwire.
#
# The failure mode is silent and security-relevant — an inert hook is
# indistinguishable from a working one on disk — so nothing here asserts that
# a file EXISTS. Everything asserts what it decides.

setup() {
  : "${BLUEPRINT_ROOT:?unset — run via tests/bats/run.sh}"
  REAL_HOME="$HOME"
  TMPDIR_T=$(mktemp -d)
  export HOME="$TMPDIR_T"
  export SCRIPT_DIR="$BLUEPRINT_ROOT"
  export AICODING_MANIFEST="$TMPDIR_T/manifest.json"

  HOOK_SRC="$BLUEPRINT_ROOT/configs/claude/hooks/bw-deny-files.sh"
  PI_SRC="$BLUEPRINT_ROOT/configs/pi/extensions/bw-deny-files.ts"
  # Same default install_bubblewrap uses; the real checkout on this machine.
  VENDOR="${AICODING_VENDOR_DIR:-$REAL_HOME/.local/share/aicoding/vendor}/bw-AICode"
}

teardown() { rm -rf "$TMPDIR_T"; }

_inventory() {
  bash -c "HOME='$HOME' . '$BLUEPRINT_ROOT/lib/blueprint-deploy.sh'; managed_inventory_overwrite"
}

@test "the pi extension is a managed file, so every sync reconciles it" {
  run _inventory
  [ "$status" -eq 0 ]
  [[ "$output" == *"$HOME/.pi/agent/extensions/bw-deny-files.ts|overwrite|configs/pi/extensions/bw-deny-files.ts"* ]]
}

@test "the blueprint's hook enforces with BW_DENY_PATTERNS_FILE unset" {
  # The bug PR #95 fixed, and the one bw's copy still carries: an early
  # `exit 0` when that variable is unset makes the hook inert everywhere
  # outside the sandbox.
  run bash -c "printf '%s' '{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"\$HOME/.aicodingsetup/.secrets.env\"}}' | bash '$HOOK_SRC'"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "the pi shim carries no sandbox gate of its own" {
  # Mentioning the variable in a comment is fine; branching on it is not —
  # that is precisely the downgrade this whole change removes.
  run grep -nE '^[^/]*\bBW_DENY_PATTERNS_FILE\b' "$PI_SRC"
  [ "$status" -ne 0 ]
}

@test "the pi shim delegates rather than reimplementing the deny rules" {
  # A second copy of 572 lines of deny logic would drift; the shim exists so
  # pi, Claude Code and codex can never disagree about what is a secret.
  grep -q "spawnSync" "$PI_SRC"
  run grep -cE "DENY_BASENAMES|SENSITIVE_DIRS|SECRET_COMMAND_PATTERNS" "$PI_SRC"
  [ "$output" -eq 0 ]
}

@test "the pi shim points at the managed hook's real destination" {
  # Cross-file pin: the shim shells out by absolute path, so moving either
  # side must not leave it silently calling nothing.
  local dest
  dest=$(_inventory | awk -F'|' '/\/bw-deny-files\.sh\|/ {print $1}')
  [ -n "$dest" ]
  grep -qF "${dest/#$HOME/\{\{HOME\}\}}" "$PI_SRC"
}

@test "install_bubblewrap does not try to repair those files after the fact" {
  # The fix belongs upstream (bw-AICode PR #2: skip paths that exist), not in
  # a clean-up pass here. A repair step would paper over a re-broken
  # installer instead of failing the test above.
  run grep -n "redeploy_bw_clobbered\|restored .* over bw" "$BLUEPRINT_ROOT/lib/provision-integrations.sh"
  [ "$status" -ne 0 ]
}

@test "the bw checkout lives outside the blueprint, so /tmp cannot orphan it" {
  # bw's installer symlinks ~/.local/bin/*-bw straight into this checkout. In a
  # container the blueprint is /tmp/aicoding, so keeping it there meant a /tmp
  # wipe left three dangling wrappers until the next full aicoding-install.
  run bash -c "grep -n 'vendor_root=' '$BLUEPRINT_ROOT/lib/provision-integrations.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *'$HOME/.local/share/aicoding/vendor'* ]]
  [[ "$output" != *'SCRIPT_DIR'* ]]
}

@test "vendored bw-AICode guards both paths this blueprint owns" {
  # The tripwire proper: vendor/ is re-pulled from bw-AICode main on every
  # provisioning run, so an upstream revert of PR #2 reaches this machine
  # with no other signal. Skipped where vendor/ is absent (CI, SKIP_NETWORK).
  [ -f "$VENDOR/install.sh" ] || skip "vendor/bw-AICode not cloned here"

  # Each cp into a path we own must sit behind an existence check. Asserting
  # on the `cp` lines rather than on log strings: the copy is the damage.
  local unguarded
  unguarded=$(awk '
    /\[\[ -e .*bw-deny-files\.(sh|ts)/ { guarded = 1 }
    /^[[:space:]]*cp .*bw-deny-files\.(sh|ts)/ { if (!guarded) print; guarded = 0 }
  ' "$VENDOR/install.sh")
  [ -z "$unguarded" ]
}
