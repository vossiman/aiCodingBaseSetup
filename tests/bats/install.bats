#!/usr/bin/env bats

setup() {
  : "${BLUEPRINT_ROOT:?unset — run via tests/bats/run.sh; refusing to default to / and copy the whole filesystem}"
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  export AICODING_MANIFEST="$TMPDIR/.aicodingsetup/manifest.json"
  export AICODINGSETUP_NONINTERACTIVE=1
  export AICODING_TMUX_COMMIT_FILE="$TMPDIR/tmux-commit"
  export BASHRC_BLOCK_START_LIT='# >>> aicoding managed block — do not edit between markers >>>'
  export BASHRC_BLOCK_END_LIT='# <<< aicoding managed block <<<'
  # Stub apt etc. so install.sh's prereq steps no-op.
  export PATH="$TMPDIR/stubs:$PATH"
  mkdir -p "$TMPDIR/stubs" "$TMPDIR/.local/bin"
  # Stub the prereq tools so install.sh's ensure_*/check_* steps no-op instead of
  # doing real work on every test (the biggest suite cost):
  #  - npx: check_playwright runs `npx playwright install chromium` (~22s Chromium
  #    re-download into the fresh per-test $HOME cache).
  #  - claude/opencode: prereq ensure_* invoke the real binaries (migration /
  #    version calls) when present on PATH.
  # NOT stubbed here: codex / agent / cursor-agent — dedicated ensure_codex /
  # ensure_cursor_agent tests set up their own present/absent scenarios for those.
  for cmd in apt-get sudo curl npm npx bash-build-tmux claude opencode; do
    cat > "$TMPDIR/stubs/$cmd" <<'STUB'
#!/bin/sh
exit 0
STUB
    chmod +x "$TMPDIR/stubs/$cmd"
  done
  # The real test host may have any tmux build. Keep installer tests offline
  # by presenting the exact pinned build through the test-owned marker.
  cat > "$TMPDIR/stubs/tmux" <<'STUB'
#!/bin/sh
if [ "${1:-}" = "-V" ]; then
  echo "tmux next-3.8"
fi
exit 0
STUB
  chmod +x "$TMPDIR/stubs/tmux"
  printf '%s\n' 'b07424224b88fcc02bcb9b58d8655f00b97909c6' > "$AICODING_TMUX_COMMIT_FILE"
}

teardown() {
  rm -rf "$TMPDIR"
}

# For tests that MUTATE blueprint sources (simulating "blueprint changed
# upstream"): work on a per-test copy, never on $BLUEPRINT_ROOT itself. The
# suite runs in parallel — an in-place edit of the real checkout is visible to
# every concurrently running test (deploys pick up the marker line → flaky
# hash mismatches), and a killed run leaks the edit into the working tree.
# Sets $BP; run install as `bash "$BP/install.sh"` for every run in the test.
blueprint_copy() {
  BP="$TMPDIR/blueprint"
  rsync -a --exclude=.git "$BLUEPRINT_ROOT/" "$BP/"
  (cd "$BP" && git init -q && git add -A && \
    git -c user.email=t@t -c user.name=t commit -q -m test-copy)
}

@test "install.sh mode: first-deploy when no manifest and no managed files" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ -f "$AICODING_MANIFEST" ]
  [ -f "$HOME/.tmux.conf" ]
}

@test "install.sh: container flow writes no profile key to the manifest" {
  # Regression pin (spec 2026-08-12-host-install-design.md): absent profile
  # key IS the container contract — only install-host.sh may write one.
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  run jq 'has("profile")' "$AICODING_MANIFEST"
  [ "$output" = "false" ]
}

@test "install.sh mode: adopt when managed files exist but no manifest" {
  mkdir -p "$HOME"
  echo "user-customised tmux config" > "$HOME/.tmux.conf"
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  # File content must be untouched.
  grep -q "user-customised" "$HOME/.tmux.conf"
  # Manifest must record the user's hash.
  local user_hash blueprint_hash
  user_hash=$(sha256sum "$HOME/.tmux.conf" | awk '{print $1}')
  blueprint_hash=$(jq -r '.files["'"$HOME"'/.tmux.conf"].deployed_hash' "$AICODING_MANIFEST")
  [ "$user_hash" = "$blueprint_hash" ]
}

@test "install.sh mode: reconcile when manifest exists" {
  # First-deploy populates a real manifest, then a re-run hits reconcile.
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]
  # Output announces reconcile mode (replaces the old "Container already initialized" line).
  echo "$output" | grep -q "Mode: reconcile"
}

# A provisioning run that advances blueprint_commit must invalidate the
# aicoding-status cache, exactly as the two sync paths do (lib/sync.sh). Without
# it the badge keeps the pre-run verdict and _cache_fresh suppresses any
# re-check for the full 6h TTL, so an already-current container shows a phantom
# ⬆aicoding until the TTL lapses. Hit for real 2026-07-26.
@test "install.sh reconcile: advancing blueprint_commit drops the stale aicoding-status cache" {
  export AICODING_UPDATE_STATE="$TMPDIR/state/updates"
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  # Rewind the recorded commit so the reconcile run genuinely advances it.
  local tmp
  tmp=$(mktemp)
  jq '.blueprint_commit = "old"' "$AICODING_MANIFEST" > "$tmp"
  mv "$tmp" "$AICODING_MANIFEST"
  # Seed a stale "behind" verdict, as aicoding-status would have cached it.
  mkdir -p "$AICODING_UPDATE_STATE"
  echo '{"tool":"aicoding","status":"behind"}' > "$AICODING_UPDATE_STATE/aicoding.json"

  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]

  [ "$(jq -r .blueprint_commit "$AICODING_MANIFEST")" != "old" ]
  [ ! -e "$AICODING_UPDATE_STATE/aicoding.json" ]
}

@test "install.sh detects a stale next-3.8 tmux commit marker" {
  printf '%s\n' '5356c62eadf8650ad1ffc95f52755d6f66029a20' > "$AICODING_TMUX_COMMIT_FILE"
  _run_install_fn "$(_isolated_path)" ensure_tmux
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "tmux 3.8 is not pinned commit b074242"
  echo "$output" | grep -q "Skipping tmux rebuild while network operations are disabled"
}

@test "install.sh --force-reinstall: deletes manifest and re-deploys" {
  mkdir -p "$HOME/.aicodingsetup"
  echo '{"schema_version":1,"files":{}}' > "$AICODING_MANIFEST"
  echo "user-edit-that-should-be-clobbered" > "$HOME/.tmux.conf"
  run bash "$BLUEPRINT_ROOT/install.sh" --force-reinstall </dev/null
  [ "$status" -eq 0 ]
  # File must be overwritten from blueprint.
  if grep -q "user-edit-that-should-be-clobbered" "$HOME/.tmux.conf"; then false; fi
  # Manifest must record blueprint-hash, not user's hash.
  local blueprint_hash deployed_hash
  blueprint_hash=$(sha256sum "$BLUEPRINT_ROOT/configs/tmux/tmux.conf" | awk '{print $1}')
  deployed_hash=$(jq -r '.files["'"$HOME"'/.tmux.conf"].deployed_hash' "$AICODING_MANIFEST")
  [ "$blueprint_hash" = "$deployed_hash" ]
}

@test "install.sh adopt: strips standalone Go-PATH export from ~/.bashrc" {
  mkdir -p "$HOME"
  cat > "$HOME/.bashrc" <<'EOF'
export PATH="/usr/local/go/bin:$PATH"
echo hello
EOF
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  # Standalone line is gone; managed block contains it inside markers.
  local outside_block
  outside_block=$(awk -v s="$BASHRC_BLOCK_START_LIT" -v e="$BASHRC_BLOCK_END_LIT" '
    $0 == s { in_block = 1; next }
    $0 == e { in_block = 0; next }
    !in_block { print }
  ' "$HOME/.bashrc")
  if echo "$outside_block" | grep -qF 'export PATH="/usr/local/go/bin:$PATH"'; then
    echo "Go-PATH export still present outside managed block:"
    echo "$outside_block"
    return 1
  fi
  grep -qF 'export PATH="/usr/local/go/bin:$PATH"' "$HOME/.bashrc"
}

@test "install.sh: does not install the removed shims (aicoding-update, update-status)" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ ! -e "$HOME/.local/bin/aicoding-update" ]
  [ ! -e "$HOME/.local/bin/update-status" ]
}

@test "install.sh symlinks aicoding-sync into ~/.local/bin" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ -L "$HOME/.local/bin/aicoding-sync" ]
  [ -x "$HOME/.local/bin/aicoding-sync" ]
  readlink "$HOME/.local/bin/aicoding-sync" | grep -q "bin/aicoding-sync"
}

@test "install.sh symlinks aicoding-install into ~/.local/bin" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ -L "$HOME/.local/bin/aicoding-install" ]
  [ -x "$HOME/.local/bin/aicoding-install" ]
  readlink "$HOME/.local/bin/aicoding-install" | grep -q "bin/aicoding-install"
}

@test "install.sh symlinks agent-notify into ~/.local/bin" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ -L "$HOME/.local/bin/agent-notify" ]
  [ -x "$HOME/.local/bin/agent-notify" ]
  readlink "$HOME/.local/bin/agent-notify" | grep -q "bin/agent-notify"
}

@test "install.sh reconcile mode: restores missing files without touching edited ones" {
  # First-deploy populates the manifest and all managed files.
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ -f "$AICODING_MANIFEST" ]
  [ -f "$HOME/.tmux.conf" ]
  [ -f "$HOME/.bashrc.d/aicoding-env.sh" ]

  # Simulate a rebuild: manifest persists (bind-mount), one file is wiped,
  # another (user-editable, non-owned) is locally edited.
  rm -f "$HOME/.bashrc.d/aicoding-env.sh"
  echo "user edit" >> "$HOME/.tmux.conf"
  local edited_hash
  edited_hash=$(sha256sum "$HOME/.tmux.conf" | awk '{print $1}')

  # Re-run install.sh — should enter reconcile mode.
  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]

  # Missing file restored.
  [ -f "$HOME/.bashrc.d/aicoding-env.sh" ]
  # Edited non-owned file untouched.
  local after_hash
  after_hash=$(sha256sum "$HOME/.tmux.conf" | awk '{print $1}')
  [ "$after_hash" = "$edited_hash" ]
  # Output mentions reconcile mode and restored count.
  echo "$output" | grep -q "Mode: reconcile"
  echo "$output" | grep -qE "restored [1-9]"
}

@test "install.sh reconcile mode: applies will_update for unedited file" {
  blueprint_copy
  bash "$BP/install.sh" </dev/null
  # Snapshot the deployed tmux.conf hash and overwrite the blueprint source
  # to simulate a blueprint update.
  local deployed_hash
  deployed_hash=$(jq -r '.files["'"$HOME"'/.tmux.conf"].deployed_hash' "$AICODING_MANIFEST")
  local blueprint_src="$BP/configs/tmux/tmux.conf"
  local original_blueprint
  original_blueprint=$(cat "$blueprint_src")
  echo "${original_blueprint}
# new blueprint addition" > "$blueprint_src"

  # Re-run; should auto-update since user hasn't touched ~/.tmux.conf.
  run bash "$BP/install.sh" </dev/null
  [ "$status" -eq 0 ]

  # File now matches new blueprint, not old deployed_hash.
  grep -q "# new blueprint addition" "$HOME/.tmux.conf"
  local new_hash
  new_hash=$(sha256sum "$HOME/.tmux.conf" | awk '{print $1}')
  [ "$new_hash" != "$deployed_hash" ]
  # Manifest deployed_hash refreshed.
  local manifest_hash
  manifest_hash=$(jq -r '.files["'"$HOME"'/.tmux.conf"].deployed_hash' "$AICODING_MANIFEST")
  [ "$manifest_hash" = "$new_hash" ]
}

@test "install.sh reconcile mode: does not auto-resolve drifted_and_updating" {
  blueprint_copy
  bash "$BP/install.sh" </dev/null
  # Edit the deployed file (user drift).
  echo "user local change" >> "$HOME/.tmux.conf"
  local edited_hash
  edited_hash=$(sha256sum "$HOME/.tmux.conf" | awk '{print $1}')

  # Also change the blueprint so the bucket is drifted_and_updating, not drifted_but_aligned.
  echo "
# blueprint also changed" >> "$BP/configs/tmux/tmux.conf"

  run bash "$BP/install.sh" </dev/null
  [ "$status" -eq 0 ]

  # User's edit must be preserved byte-for-byte.
  local after_hash
  after_hash=$(sha256sum "$HOME/.tmux.conf" | awk '{print $1}')
  [ "$after_hash" = "$edited_hash" ]
  # No .bak.* file created (reconcile didn't back up + overwrite).
  [ -z "$(ls "$HOME"/.tmux.conf.bak.* 2>/dev/null)" ]
}

@test "reconcile force-restores a drifted owned bashrc.d snippet (with backup)" {
  blueprint_copy
  bash "$BP/install.sh" </dev/null
  echo "# STALE old version" > "$HOME/.bashrc.d/aicoding-env.sh"
  printf '\n# blueprint moved\n' >> "$BP/configs/bash/env.sh"
  run bash "$BP/install.sh" </dev/null
  [ "$status" -eq 0 ]
  if grep -q "STALE old version" "$HOME/.bashrc.d/aicoding-env.sh"; then false; fi
  grep -q "blueprint moved" "$HOME/.bashrc.d/aicoding-env.sh"
  ls "$HOME"/.bashrc.d/aicoding-env.sh.bak.* >/dev/null 2>&1
}

@test "reconcile still preserves an edited non-owned overwrite file" {
  blueprint_copy
  bash "$BP/install.sh" </dev/null
  echo "# user tweak" >> "$HOME/.tmux.conf"
  local edited; edited=$(sha256sum "$HOME/.tmux.conf" | awk '{print $1}')
  printf '\n# blueprint moved\n' >> "$BP/configs/tmux/tmux.conf"
  run bash "$BP/install.sh" </dev/null
  [ "$status" -eq 0 ]
  [ "$(sha256sum "$HOME/.tmux.conf" | awk '{print $1}')" = "$edited" ]
}

@test "install.sh reconcile mode: does not delete to_remove entries" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  # Inject a manifest entry not present in the blueprint inventory.
  local fake_hash
  fake_hash=$(echo "junk" | sha256sum | awk '{print $1}')
  echo "obsolete content" > "$HOME/.obsolete"
  jq --arg p "$HOME/.obsolete" --arg h "$fake_hash" \
     '.files[$p] = {mode:"overwrite",source:"configs/obsolete",deployed_hash:$h}' \
     "$AICODING_MANIFEST" > "$AICODING_MANIFEST.tmp" && mv "$AICODING_MANIFEST.tmp" "$AICODING_MANIFEST"

  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]

  # File must still exist (to_remove is report-only in reconcile).
  [ -f "$HOME/.obsolete" ]
  # Manifest entry should still be there too — removal is aicoding-sync's job.
  jq -e '.files["'"$HOME"'/.obsolete"]' "$AICODING_MANIFEST"
}

@test "install.sh: prints summary line in expected format" {
  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^INSTALL OK  blueprint [0-9a-f]+  new [0-9]+  restored [0-9]+  updated [0-9]+  merged [0-9]+  drifted [0-9]+  to_review [0-9]+$'
}

@test "install.sh: prints NOTE follow-up when drifted or to_review > 0" {
  blueprint_copy
  bash "$BP/install.sh" </dev/null
  # Force a drifted_and_updating bucket.
  echo "user local change" >> "$HOME/.tmux.conf"
  echo "
# blueprint also changed" >> "$BP/configs/tmux/tmux.conf"

  run bash "$BP/install.sh" </dev/null
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^NOTE: [0-9]+ drifted file\(s\), [0-9]+ file\(s\) to review'
}

@test "install.sh: ERR trap announces step name on failure" {
  # Force a failure by stubbing jq to exit nonzero. install.sh uses jq heavily.
  cat > "$TMPDIR/stubs/jq" <<'STUB'
#!/bin/sh
exit 1
STUB
  chmod +x "$TMPDIR/stubs/jq"

  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -ne 0 ]
  echo "$output" | grep -qE '^INSTALL FAILED  step=.*  line=[0-9]+$'
}

# ---------------------------------------------------------------------------
# ensure_codex / ensure_cursor_agent — function-level unit tests.
#
# These source install.sh and call the two functions directly instead of
# booting the whole installer. That makes them fast and — crucially — hermetic.
# Both functions start with `command -v codex` / `command -v agent` existence
# checks, so the only way to test their "tool missing" paths is to control PATH
# so those binaries don't resolve. You cannot stub a command into *non-existence*
# (a stub file only makes it look present); the previous `bash install.sh` tests
# left the host's real codex/cursor-agent on PATH, so every "missing" assertion
# silently exercised the "already installed" short-circuit instead.
# ---------------------------------------------------------------------------

# Invoke one install.sh function in an isolated subshell with a pinned PATH.
#   - _AICODINGSETUP_NVS_STRIPPED=1 skips install.sh's nvs self-reexec.
#   - sourcing defines the functions; the `BASH_SOURCE != $0` guards keep
#     check_prerequisites()/main() from running as a side effect.
#   - we disarm install.sh's global `set -eEuo`/ERR-trap after sourcing so a
#     function's exit status is reported to `run` instead of killing the test.
# HOME and any per-test stubs are inherited from the test environment.
_run_install_fn() {
  local fn_path="$1"; shift
  run env _AICODINGSETUP_NVS_STRIPPED=1 PATH="$fn_path" \
    bash -c 'source "$1"; trap - ERR; set +eEu +o pipefail; shift; "$@"' \
    _ "$BLUEPRINT_ROOT/install.sh" "$@"
}

# Like _run_install_fn but runs the function under install.sh's REAL shell
# options (`set -euo pipefail`, install.sh:2). _run_install_fn deliberately
# disables them, which is fine for most assertions but blind to the whole class
# of bug where a helper's failing pipeline aborts provisioning instead of
# warning. Use this whenever a function must degrade gracefully.
_run_install_fn_strict() {
  local fn_path="$1"; shift
  run env _AICODINGSETUP_NVS_STRIPPED=1 PATH="$fn_path" \
    bash -c 'source "$1"; trap - ERR; shift; set -euo pipefail; "$@"' \
    _ "$BLUEPRINT_ROOT/install.sh" "$@"
}

# A PATH with only the tools install.sh touches before the curl check — and
# deliberately NO curl — so `command -v curl` genuinely fails. (curl shares
# /usr/bin with coreutils, so we curate a dir rather than drop one.) It also
# omits the host bin dirs, so codex/cursor-agent/agent don't resolve either.
_curl_less_path() {
  local d="$TMPDIR/nocurl"
  mkdir -p "$d"
  local t
  for t in bash sh dirname uname id; do ln -sf "$(command -v "$t")" "$d/$t"; done
  printf '%s' "$d"
}

# A PATH that keeps real coreutils + curl but excludes the host's user-bin dirs
# (~/.local/bin et al.), so only the *injected* stubs decide whether
# codex/cursor-agent/agent exist.
_isolated_path() { printf '%s' "$TMPDIR/stubs:/usr/bin:/bin"; }

@test "ensure_codex: warns and skips (non-fatal) when curl is unavailable" {
  _run_install_fn "$(_curl_less_path)" ensure_codex
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "WARN.*codex|skipping codex install"
}

@test "ensure_codex: runs the installer and keeps codex when curl works and codex is absent" {
  cat > "$TMPDIR/stubs/curl" <<EOF
#!/bin/sh
echo "(stub) curl-pipe-sh for codex installer ran" > "$TMPDIR/codex-install-attempted"
# Mimic the upstream installer dropping the binary in ~/.local/bin.
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/codex" <<'BIN'
#!/bin/sh
echo "codex 0.0.0-stub"
BIN
chmod +x "$HOME/.local/bin/codex"
EOF
  chmod +x "$TMPDIR/stubs/curl"

  _run_install_fn "$(_isolated_path)" ensure_codex
  [ -f "$TMPDIR/codex-install-attempted" ]
  [ -x "$HOME/.local/bin/codex" ]
}

@test "ensure_codex: pipes the installer into a non-interactive sh (CODEX_NON_INTERACTIVE=1)" {
  # Upstream install.sh grew y/N prompts (reads /dev/tty, so piping alone
  # doesn't suppress them). Stub curl to emit a script that records what the
  # piped sh sees in CODEX_NON_INTERACTIVE.
  # The quoted inner heredoc keeps \$CODEX_NON_INTERACTIVE unexpanded in the
  # stub's output, so the piped sh (not the stub) resolves it.
  cat > "$TMPDIR/stubs/curl" <<EOF
#!/bin/sh
cat <<'SCRIPT'
echo "\$CODEX_NON_INTERACTIVE" > '$TMPDIR/codex-noninteractive'
SCRIPT
EOF
  chmod +x "$TMPDIR/stubs/curl"

  _run_install_fn "$(_isolated_path)" ensure_codex
  [ -f "$TMPDIR/codex-noninteractive" ]
  [ "$(cat "$TMPDIR/codex-noninteractive")" = "1" ]
}

@test "install_claude_mcps: registers logfire at the EU endpoint, user scope" {
  # Recording stub: capture every claude invocation's args.
  cat > "$TMPDIR/stubs/claude" <<EOF
#!/bin/sh
echo "\$@" >> '$TMPDIR/claude-calls'
exit 0
EOF
  chmod +x "$TMPDIR/stubs/claude"

  _run_install_fn "$(_isolated_path)" install_claude_mcps
  [ "$status" -eq 0 ]
  grep -E "mcp add .*logfire" "$TMPDIR/claude-calls" | grep -q "https://logfire-eu.pydantic.dev/mcp"
}

@test "install_claude_mcps: registers memory-router over http with bearer auth" {
  cat > "$TMPDIR/stubs/claude" <<EOF
#!/bin/sh
echo "\$@" >> '$TMPDIR/claude-calls'
exit 0
EOF
  chmod +x "$TMPDIR/stubs/claude"
  export MEMORY_ROUTER_TOKEN=testtoken

  _run_install_fn "$(_isolated_path)" install_claude_mcps
  [ "$status" -eq 0 ]
  line=$(grep -E "mcp add .*memory-router" "$TMPDIR/claude-calls")
  echo "$line" | grep -q -- "--transport http"
  echo "$line" | grep -q "http://10.0.0.249:8091/mcp"
  echo "$line" | grep -q "Authorization: Bearer testtoken"
}

@test "install_claude_mcps: skips memory-router when MEMORY_ROUTER_TOKEN is unset" {
  cat > "$TMPDIR/stubs/claude" <<EOF
#!/bin/sh
echo "\$@" >> '$TMPDIR/claude-calls'
exit 0
EOF
  chmod +x "$TMPDIR/stubs/claude"
  unset MEMORY_ROUTER_TOKEN

  _run_install_fn "$(_isolated_path)" install_claude_mcps
  [ "$status" -eq 0 ]
  if grep -qE "mcp add .*memory-router" "$TMPDIR/claude-calls"; then false; fi
  echo "$output" | grep -q "MEMORY_ROUTER_TOKEN not set"
}

@test "install_claude_mcps: heals memory-router URL drift by remove + re-add" {
  # Stub: `mcp get memory-router` reports the pre-#85 localhost URL until an
  # add for that name has run (marker file), then the new URL — so the
  # read-back verification sees what a real re-add would produce. Every call
  # is logged so we can assert the remove/re-add sequence.
  cat > "$TMPDIR/stubs/claude" <<EOF
#!/bin/sh
echo "\$@" >> '$TMPDIR/claude-calls'
case "\$*" in
  "mcp get memory-router")
    if [ -f '$TMPDIR/mr-added' ]; then
      printf 'memory-router:\n  Type: http\n  URL: http://10.0.0.249:8091/mcp\n'
    else
      printf 'memory-router:\n  Type: http\n  URL: http://localhost:8091/mcp\n'
    fi
    ;;
  "mcp add"*"memory-router"*)
    touch '$TMPDIR/mr-added'
    ;;
esac
exit 0
EOF
  chmod +x "$TMPDIR/stubs/claude"
  export MEMORY_ROUTER_TOKEN=testtoken

  _run_install_fn "$(_isolated_path)" install_claude_mcps
  [ "$status" -eq 0 ]
  grep -q "mcp remove -s user memory-router" "$TMPDIR/claude-calls"
  grep -E "mcp add .*memory-router" "$TMPDIR/claude-calls" | grep -q "http://10.0.0.249:8091/mcp"
  # Remove must precede the re-add.
  remove_line=$(grep -n "mcp remove -s user memory-router" "$TMPDIR/claude-calls" | head -1 | cut -d: -f1)
  add_line=$(grep -nE "mcp add .*memory-router" "$TMPDIR/claude-calls" | head -1 | cut -d: -f1)
  [ "$remove_line" -lt "$add_line" ]
  # Verified re-add reports configured and records the args fingerprint.
  echo "$output" | grep -q "memory-router MCP configured"
  [ -f "$HOME/.local/state/aicoding/mcp-fingerprints/memory-router.sha256" ]
}

# Seed the stored fingerprint ensure_http_mcp would have written for
# memory-router with this token, so "already configured" short-circuits.
_seed_mr_fingerprint() {
  local token=$1
  mkdir -p "$HOME/.local/state/aicoding/mcp-fingerprints"
  printf '%s\n' "-H" "Authorization: Bearer $token" | sha256sum | awk '{print $1}' \
    > "$HOME/.local/state/aicoding/mcp-fingerprints/memory-router.sha256"
}

@test "install_claude_mcps: does not touch memory-router when URL and token unchanged" {
  cat > "$TMPDIR/stubs/claude" <<EOF
#!/bin/sh
echo "\$@" >> '$TMPDIR/claude-calls'
case "\$*" in
  "mcp get memory-router")
    printf 'memory-router:\n  Type: http\n  URL: http://10.0.0.249:8091/mcp\n'
    ;;
esac
exit 0
EOF
  chmod +x "$TMPDIR/stubs/claude"
  export MEMORY_ROUTER_TOKEN=testtoken
  _seed_mr_fingerprint testtoken

  _run_install_fn "$(_isolated_path)" install_claude_mcps
  [ "$status" -eq 0 ]
  if grep -q "mcp remove -s user memory-router" "$TMPDIR/claude-calls"; then false; fi
  echo "$output" | grep -q "memory-router MCP already configured"
}

@test "ensure_http_mcp: re-registers when the token rotated at an unchanged URL" {
  # URL matches, but the stored fingerprint was taken with the OLD token —
  # the registration silently carries stale credentials and must be redone.
  cat > "$TMPDIR/stubs/claude" <<EOF
#!/bin/sh
echo "\$@" >> '$TMPDIR/claude-calls'
case "\$*" in
  "mcp get memory-router")
    printf 'memory-router:\n  Type: http\n  URL: http://10.0.0.249:8091/mcp\n'
    ;;
esac
exit 0
EOF
  chmod +x "$TMPDIR/stubs/claude"
  export MEMORY_ROUTER_TOKEN=rotated-token
  _seed_mr_fingerprint old-token

  _run_install_fn "$(_isolated_path)" install_claude_mcps
  [ "$status" -eq 0 ]
  grep -q "mcp remove -s user memory-router" "$TMPDIR/claude-calls"
  grep -E "mcp add .*memory-router" "$TMPDIR/claude-calls" \
    | grep -q "Bearer rotated-token"
}

@test "ensure_http_mcp: failed removal must not report success" {
  # `mcp remove` fails and `mcp get` keeps returning the stale URL — the
  # old code fell through to the get-based "already configured" fallback.
  cat > "$TMPDIR/stubs/claude" <<EOF
#!/bin/sh
echo "\$@" >> '$TMPDIR/claude-calls'
case "\$*" in
  "mcp get memory-router")
    printf 'memory-router:\n  Type: http\n  URL: http://localhost:8091/mcp\n'
    ;;
  "mcp remove"*)
    exit 1
    ;;
esac
exit 0
EOF
  chmod +x "$TMPDIR/stubs/claude"
  export MEMORY_ROUTER_TOKEN=testtoken

  _run_install_fn "$(_isolated_path)" install_claude_mcps
  [ "$status" -eq 0 ]
  if echo "$output" | grep -qE "memory-router MCP (already )?configured"; then false; fi
  echo "$output" | grep -q "memory-router MCP: failed to remove stale registration"
  if grep -qE "mcp add .*memory-router" "$TMPDIR/claude-calls"; then false; fi
}

@test "ensure_http_mcp: add that does not verify warns instead of reporting configured" {
  # add exits 0 but the read-back still shows the stale URL (e.g. the add
  # half-failed against a lingering registration).
  cat > "$TMPDIR/stubs/claude" <<EOF
#!/bin/sh
echo "\$@" >> '$TMPDIR/claude-calls'
case "\$*" in
  "mcp get memory-router")
    printf 'memory-router:\n  Type: http\n  URL: http://localhost:8091/mcp\n'
    ;;
esac
exit 0
EOF
  chmod +x "$TMPDIR/stubs/claude"
  export MEMORY_ROUTER_TOKEN=testtoken

  _run_install_fn "$(_isolated_path)" install_claude_mcps
  [ "$status" -eq 0 ]
  if echo "$output" | grep -qE "memory-router MCP (already )?configured"; then false; fi
  echo "$output" | grep -q "memory-router MCP: registration did not verify"
}

@test "install_claude_mcps: heals logfire URL drift by remove + re-add" {
  cat > "$TMPDIR/stubs/claude" <<EOF
#!/bin/sh
echo "\$@" >> '$TMPDIR/claude-calls'
case "\$*" in
  "mcp get logfire")
    printf 'logfire:\n  Type: http\n  URL: https://mcp.pydantic.dev/mcp\n'
    ;;
esac
exit 0
EOF
  chmod +x "$TMPDIR/stubs/claude"

  _run_install_fn "$(_isolated_path)" install_claude_mcps
  [ "$status" -eq 0 ]
  grep -q "mcp remove -s user logfire" "$TMPDIR/claude-calls"
  grep -E "mcp add .*logfire" "$TMPDIR/claude-calls" | grep -q "https://logfire-eu.pydantic.dev/mcp"
}

@test "install_claude_plugins: does not install the logfire plugin, uninstalls it if present" {
  # The plugin's bundled MCP server hardcodes the US URL (no repoint, no
  # per-server disable) — we run the EU hosted MCP at user scope instead.
  cat > "$TMPDIR/stubs/claude" <<EOF
#!/bin/sh
echo "\$@" >> '$TMPDIR/claude-calls'
exit 0
EOF
  chmod +x "$TMPDIR/stubs/claude"

  _run_install_fn "$(_isolated_path)" install_claude_plugins
  [ "$status" -eq 0 ]
  if grep -q "plugin install logfire@claude-plugins-official" "$TMPDIR/claude-calls"; then false; fi
  grep -q "plugin uninstall logfire@claude-plugins-official" "$TMPDIR/claude-calls"
}

@test "ensure_cursor_agent: warns and skips (non-fatal) when curl is unavailable" {
  _run_install_fn "$(_curl_less_path)" ensure_cursor_agent
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "WARN.*cursor|skipping cursor-agent install"
}

@test "ensure_cursor_agent: symlinks agent -> cursor-agent when only cursor-agent is dropped" {
  # Stub curl to drop the binary as 'cursor-agent' (the older-release name).
  cat > "$TMPDIR/stubs/curl" <<EOF
#!/bin/sh
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/cursor-agent" <<'BIN'
#!/bin/sh
echo "cursor-agent 0.0.0-stub"
BIN
chmod +x "$HOME/.local/bin/cursor-agent"
EOF
  chmod +x "$TMPDIR/stubs/curl"

  _run_install_fn "$(_isolated_path)" ensure_cursor_agent
  # Both names must resolve so downstream tooling (on-start.sh) can call either.
  [ -x "$HOME/.local/bin/cursor-agent" ]
  [ -L "$HOME/.local/bin/agent" ] || [ -x "$HOME/.local/bin/agent" ]
}

@test "ensure_cursor_agent: skips the installer when 'agent' is already on PATH" {
  # Inject an 'agent' stub so the function's existence check trips.
  cat > "$TMPDIR/stubs/agent" <<'STUB'
#!/bin/sh
echo "agent 0.0.0-stub"
STUB
  chmod +x "$TMPDIR/stubs/agent"

  _run_install_fn "$(_isolated_path)" ensure_cursor_agent
  echo "$output" | grep -qE "cursor-agent already installed"
  # The install attempt must be short-circuited before it starts.
  if echo "$output" | grep -qE "Installing Cursor CLI"; then false; fi
}

@test "install.sh non-interactive: never rewrites an existing .secrets.env (no host-secret clobber)" {
  # ~/.aicodingsetup/.secrets.env is a host bind mount — the single source of
  # truth across containers. A non-interactive container install must NOT
  # regenerate it; doing so blanks keys it can't prompt for and destroys the
  # user's real tokens on the host. The file must come out byte-identical.
  mkdir -p "$HOME/.aicodingsetup"
  cat > "$HOME/.aicodingsetup/.secrets.env" <<'EOF'
# my host secrets — hand maintained, do not let a container touch this
GH_TOKEN=github_pat_REALTOKENVALUE
FIRECRAWL_API_KEY=fc-abc
MY_CUSTOM_KEY=keepme
EOF
  chmod 600 "$HOME/.aicodingsetup/.secrets.env"
  local before after
  before=$(sha256sum "$HOME/.aicodingsetup/.secrets.env" | awk '{print $1}')

  bash "$BLUEPRINT_ROOT/install.sh" </dev/null

  after=$(sha256sum "$HOME/.aicodingsetup/.secrets.env" | awk '{print $1}')
  [ "$before" = "$after" ]
  # The real token and a non-blueprint custom key must both survive verbatim.
  grep -qx 'GH_TOKEN=github_pat_REALTOKENVALUE' "$HOME/.aicodingsetup/.secrets.env"
  grep -qx 'MY_CUSTOM_KEY=keepme' "$HOME/.aicodingsetup/.secrets.env"
}

@test "first-deploy: codex config.toml deploys with substituted FIRECRAWL_API_KEY" {
  # Seed a secrets file so substitution has a value to inject.
  mkdir -p "$HOME/.aicodingsetup"
  cat > "$HOME/.aicodingsetup/.secrets.env" <<EOF
FIRECRAWL_API_KEY=fake-firecrawl-123
BRAVE_API_KEY=fake-brave-456
CLOUDFLARE_API_TOKEN=
CLOUDFLARE_ACCOUNT_ID=
EOF
  chmod 600 "$HOME/.aicodingsetup/.secrets.env"

  bash "$BLUEPRINT_ROOT/install.sh" </dev/null

  # File deployed under bind-mount target ~/.codex/.
  [ -f "$HOME/.codex/config.toml" ]
  # Secret substituted (no {{...}} placeholder survives).
  grep -qF 'FIRECRAWL_API_KEY = "fake-firecrawl-123"' "$HOME/.codex/config.toml"
  if grep -qF '{{FIRECRAWL_API_KEY}}' "$HOME/.codex/config.toml"; then false; fi
  # Manifest records overwrite mode + deployed_hash.
  local mode
  mode=$(jq -r '.files["'"$HOME"'/.codex/config.toml"].mode' "$AICODING_MANIFEST")
  [ "$mode" = "overwrite" ]
  local hash
  hash=$(jq -r '.files["'"$HOME"'/.codex/config.toml"].deployed_hash' "$AICODING_MANIFEST")
  [ -n "$hash" ]
  [ "$hash" != "null" ]
}

@test "first-deploy: cursor mcp.json merges 5 blueprint servers without dropping user adds" {
  # Pre-create ~/.cursor/mcp.json with one user-added server. The merge
  # pipeline must preserve it while adding the blueprint's 5 servers.
  mkdir -p "$HOME/.cursor"
  cat > "$HOME/.cursor/mcp.json" <<'EOF'
{
  "mcpServers": {
    "user-custom": {
      "command": "my-custom-mcp",
      "args": ["--flag"]
    }
  }
}
EOF
  # Make sure first-deploy fires (no manifest yet); Plan 1's detect_install_mode
  # picks 'adopt' when a managed file exists but no manifest is present, so
  # cursor mcp.json on disk -> mode=adopt. Use --force-reinstall to force first.
  mkdir -p "$HOME/.aicodingsetup"
  cat > "$HOME/.aicodingsetup/.secrets.env" <<EOF
FIRECRAWL_API_KEY=fake-firecrawl-123
BRAVE_API_KEY=fake-brave-456
CLOUDFLARE_API_TOKEN=
CLOUDFLARE_ACCOUNT_ID=
MEMORY_ROUTER_TOKEN=fake-memtoken-789
EOF

  bash "$BLUEPRINT_ROOT/install.sh" --force-reinstall </dev/null

  [ -f "$HOME/.cursor/mcp.json" ]
  # All 5 blueprint servers present.
  jq -e '.mcpServers.firecrawl'    "$HOME/.cursor/mcp.json"
  jq -e '.mcpServers["brave-search"]' "$HOME/.cursor/mcp.json"
  jq -e '.mcpServers.context7'     "$HOME/.cursor/mcp.json"
  jq -e '.mcpServers.playwright'   "$HOME/.cursor/mcp.json"
  jq -e '.mcpServers["memory-router"].url == "http://10.0.0.249:8091/mcp"' "$HOME/.cursor/mcp.json"
  # User's custom server preserved.
  jq -e '.mcpServers["user-custom"]' "$HOME/.cursor/mcp.json"
  # Substitution applied.
  jq -r '.mcpServers.firecrawl.env.FIRECRAWL_API_KEY' "$HOME/.cursor/mcp.json" | grep -qF 'fake-firecrawl-123'
  jq -r '.mcpServers["memory-router"].headers.Authorization' "$HOME/.cursor/mcp.json" | grep -qF 'Bearer fake-memtoken-789'
}

@test "first-deploy: opencode.json mcp field populated with 5 servers and substituted secrets" {
  mkdir -p "$HOME/.aicodingsetup"
  cat > "$HOME/.aicodingsetup/.secrets.env" <<EOF
FIRECRAWL_API_KEY=fake-firecrawl-123
BRAVE_API_KEY=fake-brave-456
CLOUDFLARE_API_TOKEN=
CLOUDFLARE_ACCOUNT_ID=
MEMORY_ROUTER_TOKEN=fake-memtoken-789
EOF

  bash "$BLUEPRINT_ROOT/install.sh" </dev/null

  [ -f "$HOME/.config/opencode/opencode.json" ]
  # All 5 servers present under the 'mcp' (not 'mcpServers') top-level key.
  jq -e '.mcp.firecrawl.type == "local"'                  "$HOME/.config/opencode/opencode.json"
  jq -e '.mcp["brave-search"].type == "local"'            "$HOME/.config/opencode/opencode.json"
  jq -e '.mcp.context7.type == "local"'                   "$HOME/.config/opencode/opencode.json"
  jq -e '.mcp.playwright.type == "local"'                 "$HOME/.config/opencode/opencode.json"
  # opencode schema uses 'environment' not 'env' and 'command' is an array.
  jq -e '.mcp.firecrawl.environment.FIRECRAWL_API_KEY == "fake-firecrawl-123"' "$HOME/.config/opencode/opencode.json"
  jq -e '.mcp.firecrawl.command | type == "array"'        "$HOME/.config/opencode/opencode.json"
  # memory-router is a remote server with substituted bearer auth; oauth off
  # (API-key-style shared secret, not an OAuth server).
  jq -e '.mcp["memory-router"].type == "remote"'          "$HOME/.config/opencode/opencode.json"
  jq -e '.mcp["memory-router"].url == "http://10.0.0.249:8091/mcp"' "$HOME/.config/opencode/opencode.json"
  jq -e '.mcp["memory-router"].headers.Authorization == "Bearer fake-memtoken-789"' "$HOME/.config/opencode/opencode.json"
  jq -e '.mcp["memory-router"].oauth == false'            "$HOME/.config/opencode/opencode.json"
}

@test "first-deploy: codex config.toml registers memory-router with substituted token" {
  mkdir -p "$HOME/.aicodingsetup"
  cat > "$HOME/.aicodingsetup/.secrets.env" <<EOF
FIRECRAWL_API_KEY=fake-firecrawl-123
BRAVE_API_KEY=fake-brave-456
CLOUDFLARE_API_TOKEN=
CLOUDFLARE_ACCOUNT_ID=
MEMORY_ROUTER_TOKEN=fake-memtoken-789
EOF

  bash "$BLUEPRINT_ROOT/install.sh" </dev/null

  [ -f "$HOME/.codex/config.toml" ]
  grep -q '^\[mcp_servers.memory-router\]' "$HOME/.codex/config.toml"
  grep -q 'url = "http://10.0.0.249:8091/mcp"' "$HOME/.codex/config.toml"
  grep -qF 'Authorization = "Bearer fake-memtoken-789"' "$HOME/.codex/config.toml"
}

@test "first-deploy: codex global AGENTS.md deployed with memory retrieval instructions" {
  # Codex reads global guidance from ~/.codex/AGENTS.md (CODEX_HOME). Unlike
  # opencode, it has no fallback to ~/.claude/CLAUDE.md, so the memory
  # read-path instructions need their own managed file.
  mkdir -p "$HOME/.aicodingsetup"
  cat > "$HOME/.aicodingsetup/.secrets.env" <<EOF
FIRECRAWL_API_KEY=fake-firecrawl-123
BRAVE_API_KEY=fake-brave-456
EOF

  bash "$BLUEPRINT_ROOT/install.sh" </dev/null

  [ -f "$HOME/.codex/AGENTS.md" ]
  grep -q 'memory_search' "$HOME/.codex/AGENTS.md"
  grep -q 'homelab-wiki' "$HOME/.codex/AGENTS.md"
  # Deployment is manifest-tracked (managed file, not a one-shot copy).
  hash=$(jq -r '.files["'"$HOME"'/.codex/AGENTS.md"].deployed_hash' "$AICODING_MANIFEST")
  [ -n "$hash" ]
  [ "$hash" != "null" ]
}

@test "merge: opencode.json mcp field preserves user-added server" {
  # Pre-populate opencode.json with an existing user-added mcp entry.
  mkdir -p "$HOME/.config/opencode"
  cat > "$HOME/.config/opencode/opencode.json" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "anthropic/claude-opus-5",
  "mcp": {
    "user-server": {
      "type": "local",
      "command": ["my-custom"],
      "enabled": true
    }
  }
}
EOF
  mkdir -p "$HOME/.aicodingsetup"
  cat > "$HOME/.aicodingsetup/.secrets.env" <<EOF
FIRECRAWL_API_KEY=fake-firecrawl-123
BRAVE_API_KEY=fake-brave-456
CLOUDFLARE_API_TOKEN=
CLOUDFLARE_ACCOUNT_ID=
MEMORY_ROUTER_TOKEN=fake-memtoken-789
EOF

  bash "$BLUEPRINT_ROOT/install.sh" --force-reinstall </dev/null

  # User server + all 5 blueprint servers both present.
  jq -e '.mcp["user-server"]'   "$HOME/.config/opencode/opencode.json"
  jq -e '.mcp.firecrawl'        "$HOME/.config/opencode/opencode.json"
  jq -e '.mcp["brave-search"]'  "$HOME/.config/opencode/opencode.json"
  jq -e '.mcp.context7'         "$HOME/.config/opencode/opencode.json"
  jq -e '.mcp.playwright'       "$HOME/.config/opencode/opencode.json"
  jq -e '.mcp["memory-router"]' "$HOME/.config/opencode/opencode.json"
}

@test "managed model defaults use the current pinned families" {
  grep -qx 'model = "gpt-5.6-sol"' "$BLUEPRINT_ROOT/configs/codex/config.toml"
  jq -e '.model == "anthropic/claude-opus-5"' "$BLUEPRINT_ROOT/configs/opencode/opencode.json"
}

@test "reconcile: restores deleted ~/.codex/config.toml on rebuild" {
  mkdir -p "$HOME/.aicodingsetup"
  cat > "$HOME/.aicodingsetup/.secrets.env" <<EOF
FIRECRAWL_API_KEY=fake-firecrawl-123
BRAVE_API_KEY=fake-brave-456
CLOUDFLARE_API_TOKEN=
CLOUDFLARE_ACCOUNT_ID=
EOF
  # First-deploy seeds the manifest.
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ -f "$HOME/.codex/config.toml" ]
  local first_hash
  first_hash=$(sha256sum "$HOME/.codex/config.toml" | awk '{print $1}')

  # Simulate a rebuild: manifest persists (bind-mount), file is wiped.
  rm -f "$HOME/.codex/config.toml"
  [ ! -f "$HOME/.codex/config.toml" ]

  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]
  # File restored, content byte-identical to pre-wipe.
  [ -f "$HOME/.codex/config.toml" ]
  local restored_hash
  restored_hash=$(sha256sum "$HOME/.codex/config.toml" | awk '{print $1}')
  [ "$restored_hash" = "$first_hash" ]
  # Plan 1's summary line shows restored count >= 1.
  echo "$output" | grep -qE 'restored [1-9][0-9]* '
  # Mode line announces reconcile.
  echo "$output" | grep -q "Mode: reconcile"
}

@test "reconcile: leaves edited ~/.codex/config.toml byte-unchanged" {
  mkdir -p "$HOME/.aicodingsetup"
  cat > "$HOME/.aicodingsetup/.secrets.env" <<EOF
FIRECRAWL_API_KEY=fake-firecrawl-123
BRAVE_API_KEY=fake-brave-456
CLOUDFLARE_API_TOKEN=
CLOUDFLARE_ACCOUNT_ID=
EOF
  blueprint_copy
  bash "$BP/install.sh" </dev/null

  # User edits the file (drift).
  echo "# user-added line" >> "$HOME/.codex/config.toml"
  local edited_hash
  edited_hash=$(sha256sum "$HOME/.codex/config.toml" | awk '{print $1}')

  # Also change the blueprint source so the bucket is drifted_and_updating
  # (not drifted_but_aligned), which is the conservatism case we care about.
  echo "# blueprint also changed" >> "$BP/configs/codex/config.toml"

  run bash "$BP/install.sh" </dev/null
  [ "$status" -eq 0 ]
  # User's edit preserved byte-for-byte (reconcile excludes drifted_and_updating).
  local after_hash
  after_hash=$(sha256sum "$HOME/.codex/config.toml" | awk '{print $1}')
  [ "$after_hash" = "$edited_hash" ]
  # Summary shows drifted >= 1.
  echo "$output" | grep -qE 'drifted [1-9][0-9]* '
  # NOTE line surfaces.
  echo "$output" | grep -qE '^NOTE: [0-9]+ drifted file'
}

@test "install.sh first-deploy: installs slash commands and tracks them in the manifest" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  # Every blueprint command lands in ~/.claude/commands and is manifest-tracked.
  local cmd_file cmd_name
  for cmd_file in "$BLUEPRINT_ROOT/commands"/*.md; do
    cmd_name=$(basename "$cmd_file")
    [ -f "$HOME/.claude/commands/$cmd_name" ]
    local h
    h=$(jq -r '.files["'"$HOME"'/.claude/commands/'"$cmd_name"'"].deployed_hash' "$AICODING_MANIFEST")
    [ "$h" != "null" ] && [ -n "$h" ]
  done
}

@test "install.sh first-deploy: installs check-archived-docs hook so settings.json reference is not dangling" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  # The SessionStart hook wired in settings.json must actually exist on disk.
  [ -f "$HOME/.claude/hooks/check-archived-docs.sh" ]
  [ -x "$HOME/.claude/hooks/check-archived-docs.sh" ]
  grep -q "check-archived-docs.sh" "$HOME/.claude/settings.json"
  # Manifest tracks it as a managed overwrite file.
  local h
  h=$(jq -r '.files["'"$HOME"'/.claude/hooks/check-archived-docs.sh"].deployed_hash' "$AICODING_MANIFEST")
  [ "$h" != "null" ] && [ -n "$h" ]
}

@test "install.sh first-deploy: mirrors project templates into ~/.aicodingsetup" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  local dest="$HOME/.aicodingsetup/templates/project"
  [ -d "$dest" ]
  [ -f "$dest/CLAUDE.md.tpl" ]
  [ -f "$dest/AGENTS.md.tpl" ]
  [ -f "$dest/dot-claude/settings.json.tpl" ]
  # The docs scaffold dirs (carried by .gitkeep) must survive the mirror so
  # /scaffold-project can walk them.
  [ -f "$dest/docs/specs/active/.gitkeep" ]
  # AGENTS.md is the canonical, agent-agnostic conventions file; CLAUDE.md
  # imports it via `@AGENTS.md` so Claude Code and the other CLIs share one
  # source of truth.
  grep -q "@AGENTS.md" "$dest/CLAUDE.md.tpl"
  # Scaffold-time placeholders must NOT be expanded at install time.
  grep -q "{{PROJECT_NAME}}" "$dest/AGENTS.md.tpl"
}

@test "install.sh reconcile mode: restores a deleted slash command" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  local one
  one=$(basename "$(ls "$BLUEPRINT_ROOT/commands"/*.md | head -1)")
  [ -f "$HOME/.claude/commands/$one" ]
  rm -f "$HOME/.claude/commands/$one"

  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Mode: reconcile"
  # The deleted command is restored by reconcile (classify → restore bucket).
  [ -f "$HOME/.claude/commands/$one" ]
}

@test "install.sh first-deploy: deploys update-notify snippet and aicoding-status symlink" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  [ -f "$HOME/.bashrc.d/aicoding-update-notify.sh" ]
  grep -q "aicoding-status --banner" "$HOME/.bashrc.d/aicoding-update-notify.sh"
  [ -x "$HOME/.local/bin/aicoding-status" ]
  local h
  h=$(jq -r '.files["'"$HOME"'/.bashrc.d/aicoding-update-notify.sh"].deployed_hash' "$AICODING_MANIFEST")
  [ "$h" != "null" ] && [ -n "$h" ]
}

@test "install.sh reconcile: stamps blueprint_commit to the current blueprint HEAD" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null            # first-deploy stamps it
  # Simulate a stale recorded commit (as if installed from an older blueprint).
  local tmp; tmp=$(mktemp)
  jq '.blueprint_commit = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"' "$AICODING_MANIFEST" > "$tmp"
  mv "$tmp" "$AICODING_MANIFEST"

  run bash "$BLUEPRINT_ROOT/install.sh" </dev/null        # reconcile
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Mode: reconcile"
  # Manifest must now record the actual deployed blueprint HEAD, not the stale one.
  local head stamped
  head=$(git -C "$BLUEPRINT_ROOT" rev-parse HEAD)
  stamped=$(jq -r '.blueprint_commit' "$AICODING_MANIFEST")
  [ "$stamped" = "$head" ]
}

# ---------------------------------------------------------------------------
# ensure_playwright_browsers — system-library provisioning.
#
# `npx playwright install chromium` downloads browser binaries only; the shared
# libraries they link against (libatk, libgbm, libasound, …) are not in the
# universal devcontainer image. These tests pin the two halves: the browser
# download and the system-dep install are decided independently, so a container
# that already has the browser cached still gets its libs.
# ---------------------------------------------------------------------------

# Fake an installed chromium plus recording stubs for npx/sudo/ldd.
# $1: what the ldd stub reports — "missing" or "resolved".
_playwright_fixture() {
  local libs="$1"
  export PLAYWRIGHT_BROWSERS_PATH="$TMPDIR/ms-playwright"
  mkdir -p "$PLAYWRIGHT_BROWSERS_PATH/chromium-1234/chrome-linux64"
  printf '#!/bin/sh\nexit 0\n' > "$PLAYWRIGHT_BROWSERS_PATH/chromium-1234/chrome-linux64/chrome"
  chmod +x "$PLAYWRIGHT_BROWSERS_PATH/chromium-1234/chrome-linux64/chrome"

  cat > "$TMPDIR/stubs/npx" <<NPX
#!/bin/sh
echo "\$@" >> '$TMPDIR/npx-calls'
exit 0
NPX
  # \$SUDO must not swallow the recorded call — pass through to the real command.
  printf '#!/bin/sh\nexec "$@"\n' > "$TMPDIR/stubs/sudo"
  if [ "$libs" = "unreadable" ]; then
    # ldd exits NON-ZERO on a truncated/partially-extracted download. install.sh
    # runs under `set -euo pipefail`, so this must not fail a pipeline.
    cat > "$TMPDIR/stubs/ldd" <<'LDD'
#!/bin/sh
echo "	not a dynamic executable" >&2
exit 1
LDD
  elif [ "$libs" = "missing" ]; then
    cat > "$TMPDIR/stubs/ldd" <<'LDD'
#!/bin/sh
echo "	libatk-1.0.so.0 => not found"
echo "	libgbm.so.1 => not found"
LDD
  else
    cat > "$TMPDIR/stubs/ldd" <<'LDD'
#!/bin/sh
echo "	libgbm.so.1 => /lib/x86_64-linux-gnu/libgbm.so.1"
LDD
  fi
  chmod +x "$TMPDIR/stubs/npx" "$TMPDIR/stubs/sudo" "$TMPDIR/stubs/ldd"
}

@test "ensure_playwright_browsers: installs system deps when the cached chromium has unresolved libs" {
  _playwright_fixture missing
  _run_install_fn "$(_isolated_path)" ensure_playwright_browsers
  [ "$status" -eq 0 ]
  # Browser download is skipped (cache populated) but install-deps still runs.
  grep -q "install-deps chromium" "$TMPDIR/npx-calls"
  if grep -qE "^-y playwright install chromium$" "$TMPDIR/npx-calls"; then false; fi
}

@test "ensure_playwright_browsers: warns with the manual command when install-deps does not fix the libs" {
  _playwright_fixture missing   # ldd keeps reporting "not found" after the install
  _run_install_fn "$(_isolated_path)" ensure_playwright_browsers
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "libatk-1.0.so.0"
  echo "$output" | grep -q "playwright install-deps chromium"
}

@test "ensure_playwright_browsers: no install-deps when the chromium libs already resolve" {
  _playwright_fixture resolved
  _run_install_fn "$(_isolated_path)" ensure_playwright_browsers
  [ "$status" -eq 0 ]
  [ ! -f "$TMPDIR/npx-calls" ] || ! grep -q "install-deps" "$TMPDIR/npx-calls"
}

@test "ensure_playwright_browsers: downloads chromium when the cache is empty" {
  _playwright_fixture missing
  rm -rf "$PLAYWRIGHT_BROWSERS_PATH"
  _run_install_fn "$(_isolated_path)" ensure_playwright_browsers
  [ "$status" -eq 0 ]
  grep -q "playwright install chromium" "$TMPDIR/npx-calls"
}

@test "check_playwright: reports missing system libraries instead of a bare OK" {
  _playwright_fixture missing
  _run_install_fn "$(_isolated_path)" check_playwright
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "libatk-1.0.so.0"
}

# A truncated / partially-extracted chromium makes `ldd` exit non-zero ("not a
# dynamic executable"). install.sh runs under `set -euo pipefail`, so piping
# ldd straight into awk|sort aborted the whole provisioning run instead of
# warning — and install-deps cannot fix a bad download anyway, so the CTA has
# to be a re-download.

@test "ensure_playwright_browsers: survives an ldd failure instead of aborting the run" {
  _playwright_fixture unreadable
  _run_install_fn_strict "$(_isolated_path)" ensure_playwright_browsers
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "ldd"
  # install-deps cannot repair a truncated download — must not be attempted.
  [ ! -f "$TMPDIR/npx-calls" ] || ! grep -q "install-deps" "$TMPDIR/npx-calls"
  # The actionable fix is re-downloading the browser.
  echo "$output" | grep -q "playwright install --force chromium"
}

@test "check_playwright: survives an ldd failure instead of aborting the run" {
  _playwright_fixture unreadable
  _run_install_fn_strict "$(_isolated_path)" check_playwright
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "ldd"
}

@test "install stamps provision_commit in the container-local manifest" {
  # Directly exercise the helper + the install.sh call site wiring.
  TMP=$(mktemp -d)
  export AICODING_MANIFEST="$TMP/state/manifest.json"
  run bash -c '. "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"; manifest_stamp_provision deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
  [ "$status" -eq 0 ]
  [ "$(jq -r .provision_commit "$AICODING_MANIFEST")" = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" ]
  # install.sh wires it: the call site exists and derives the sha from the blueprint checkout
  grep -q 'manifest_stamp_provision "$(git -C "$SCRIPT_DIR" rev-parse HEAD' "$BLUEPRINT_ROOT/install.sh"
  rm -rf "$TMP"
}

@test "install.sh main(): registers the git credential helpers and logs gh in" {
  # Deliberately structural. A full network-enabled install.sh run is exactly
  # what the suite's AICODINGSETUP_SKIP_NETWORK=1 exists to prevent (and
  # ensure_gh_stored_auth honours that flag, so it would no-op anyway). The
  # regression being guarded is pure wiring — main() simply never called these,
  # so a container rebuild left gh unauthenticated until someone ran
  # aicoding-sync by hand — and an absent call cannot survive this assertion.
  export _AICODINGSETUP_NVS_STRIPPED=1   # or sourcing re-execs $0, which is bats
  source "$BLUEPRINT_ROOT/install.sh"
  run declare -f main
  [ "$status" -eq 0 ]
  [[ "$output" == *"ensure_gh_credential_helper"* ]]
  [[ "$output" == *"ensure_gh_stored_auth"* ]]
  [[ "$output" == *"ensure_git_credential_file_fallback"* ]]
}

@test "report_unmanaged: ignores the installer's own .bak.<stamp> backups" {
  # Regression: _backup_file leaves timestamped siblings next to managed
  # hooks; the unmanaged-components scan then reported every one as a
  # foreign hook ("Found hook 'bw-deny-files.sh.bak.20260821-191316' ...").
  export _AICODINGSETUP_NVS_STRIPPED=1   # or sourcing re-execs $0, which is bats
  source "$BLUEPRINT_ROOT/install.sh"
  mkdir -p "$CLAUDE_DIR/hooks"
  printf '#!/bin/sh\n' > "$CLAUDE_DIR/hooks/bw-deny-files.sh.bak.20260821-191316"
  printf '#!/bin/sh\n' > "$CLAUDE_DIR/hooks/my-own-hook.sh"
  run report_unmanaged
  [ "$status" -eq 0 ]
  # A genuinely personal hook is still reported…
  [[ "$output" == *"my-own-hook.sh"* ]]
  # …but the installer's own backups are not.
  if echo "$output" | grep -q "bak"; then false; fi
}

@test "install.sh symlinks the clipboard-bridge shims (xclip, wl-paste)" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  for name in xclip wl-paste; do
    [ -L "$HOME/.local/bin/$name" ]
    [ -x "$HOME/.local/bin/$name" ]
    readlink "$HOME/.local/bin/$name" | grep -q "bin/clip-shim"
  done
}
