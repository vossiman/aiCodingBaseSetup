#!/usr/bin/env bats
setup() {
  : "${BLUEPRINT_ROOT:?run via run.sh}"
  export TMP; TMP=$(mktemp -d); export HOME="$TMP"
  export AICODING_BLUEPRINT_CLONE="$BLUEPRINT_ROOT"
  export AICODING_MANIFEST="$TMP/.aicodingsetup/manifest.json"
  export AICODING_UPDATE_STATE="$TMP/state/updates"
  export AICODINGSETUP_NONINTERACTIVE=1
  mkdir -p "$TMP/stubs"
  # install.sh's ensure_cursor_agent ends on `[[ -d "$HOME/.local/bin" ]]`,
  # which returns 1 under set -e when the dir is absent. The real first-deploy
  # creates it as a side effect of the native `claude install`; here claude is
  # stubbed, so pre-create the dir (as install.bats's granular tests do).
  mkdir -p "$TMP/.local/bin"
  # Neutralise install.sh's prereq installers so install.sh no-ops them and
  # leaves our logging stubs (claude/opencode/agent) on PATH untouched.
  for cmd in apt-get sudo curl npm npx bash-build-tmux cursor-agent; do
    printf '#!/bin/sh\nexit 0\n' > "$TMP/stubs/$cmd"
    chmod +x "$TMP/stubs/$cmd"
  done
  for c in claude opencode agent; do
    printf '#!/bin/sh\necho "%s $*" >> "$TMP/ran.log"\n' "$c" > "$TMP/stubs/$c"
    chmod +x "$TMP/stubs/$c"
  done
  export PATH="$TMP/stubs:$PATH"
  . "$BLUEPRINT_ROOT/lib/sync.sh"
}
teardown() { rm -rf "$TMP"; }

@test "sync --boot is non-interactive and refreshes binaries" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  AICODING_UPDATE_TTL=0 aicoding_sync --boot
  grep -q "claude" "$TMP/ran.log"
  grep -q "opencode" "$TMP/ran.log"
}

@test "sync --boot skips binaries when the throttle stamp is fresh" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  : > "$TMP/ran.log"                       # ignore anything install.sh logged
  mkdir -p "$AICODING_UPDATE_STATE"; : > "$AICODING_UPDATE_STATE/.binaries.stamp"
  AICODING_UPDATE_TTL=3600 aicoding_sync --boot
  [ ! -s "$TMP/ran.log" ]                  # binaries were NOT refreshed
}

@test "sync exits 0 even if a binary update fails (fail-open)" {
  printf '#!/bin/sh\nexit 7\n' > "$TMP/stubs/claude"; chmod +x "$TMP/stubs/claude"
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  run env AICODING_UPDATE_TTL=0 bash -c '. "$BLUEPRINT_ROOT/lib/sync.sh"; aicoding_sync --boot'
  [ "$status" -eq 0 ]
}

@test "aicoding-sync --boot runs end to end (exit 0)" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  run env AICODING_BLUEPRINT_CLONE="$BLUEPRINT_ROOT" AICODING_UPDATE_TTL=0 \
      "$BLUEPRINT_ROOT/bin/aicoding-sync" --boot
  [ "$status" -eq 0 ]
}
@test "clean sync still advances the manifest blueprint_commit stamp" {
  # Regression: "Nothing to do." returned before stamping, so a sync with no
  # file changes left blueprint_commit stale and aicoding-status stuck on
  # "behind" until some file actually changed.
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  # Simulate an older recorded commit (blueprint advanced, no file deltas).
  local tmp; tmp=$(mktemp)
  jq '.blueprint_commit = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"' "$AICODING_MANIFEST" > "$tmp"
  mv "$tmp" "$AICODING_MANIFEST"
  run bash -c '. "$BLUEPRINT_ROOT/lib/sync.sh"; aicoding_sync --yes'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Nothing to do."
  local stamped head
  stamped=$(jq -r '.blueprint_commit' "$AICODING_MANIFEST")
  head=$(git -C "$BLUEPRINT_ROOT" rev-parse HEAD)
  [ "$stamped" = "$head" ]
}

@test "sync --yes reconciles MCPs and plugins (provision step)" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  : > "$TMP/ran.log"
  run bash -c '. "$BLUEPRINT_ROOT/lib/sync.sh"; aicoding_sync --yes'
  [ "$status" -eq 0 ]
  grep -q "claude mcp add" "$TMP/ran.log"
  grep -q "claude plugin install" "$TMP/ran.log"
}

@test "sync --boot runs provision when the throttle is stale" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  : > "$TMP/ran.log"
  AICODING_UPDATE_TTL=0 aicoding_sync --boot
  grep -q "claude mcp add" "$TMP/ran.log"
}

@test "sync removes the retired shim symlinks (aicoding-update, update-status)" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  ln -sf /bin/true "$HOME/.local/bin/aicoding-update"
  ln -sf /bin/true "$HOME/.local/bin/update-status"
  AICODING_UPDATE_TTL=0 aicoding_sync --boot
  [ ! -e "$HOME/.local/bin/aicoding-update" ]
  [ ! -e "$HOME/.local/bin/update-status" ]
}

@test "sync right after install reports Nothing to do (no phantom drift)" {
  # Regression: substituted files (raw-source hash compare) and merge targets
  # (unconditional re-merge bucket) used to classify as actionable on every
  # run, so back-to-back syncs never converged to "Nothing to do."
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  run bash -c '. "$BLUEPRINT_ROOT/lib/sync.sh"; aicoding_sync --yes'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Nothing to do."
}

@test "sync --boot preserves a user-edited non-owned file (conservative apply set)" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  # ~/.tmux.conf is deployed and non-owned. Editing it makes on-disk differ from
  # both deployed_hash and blueprint -> drifted_and_updating, which boot's
  # conservative apply set excludes, so it must NOT be reverted.
  echo "# user edit" >> "$HOME/.tmux.conf"
  local before; before=$(sha256sum "$HOME/.tmux.conf" | awk '{print $1}')
  AICODING_UPDATE_TTL=0 aicoding_sync --boot
  [ "$(sha256sum "$HOME/.tmux.conf" | awk '{print $1}')" = "$before" ]
}

@test "aicoding-install: pulls the blueprint and re-runs the installer (reconcile)" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  run env AICODING_BLUEPRINT_CLONE="$BLUEPRINT_ROOT" \
      "$BLUEPRINT_ROOT/bin/aicoding-install" </dev/null
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Mode: reconcile"
}

@test "aicoding-install: passes --force-reinstall through (first-deploy)" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  run env AICODING_BLUEPRINT_CLONE="$BLUEPRINT_ROOT" \
      "$BLUEPRINT_ROOT/bin/aicoding-install" --force-reinstall </dev/null
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Mode: first"
}

@test "on-start.sh runs the boot path (exit 0)" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  run env AICODING_BLUEPRINT_CLONE="$BLUEPRINT_ROOT" AICODING_UPDATE_TTL=0 \
      bash "$BLUEPRINT_ROOT/on-start.sh"
  [ "$status" -eq 0 ]
}

# --- gh credential helper plumbing -------------------------------------------
# Rebuilt containers lose the container-local ~/.gitconfig, and with it the gh
# credential helper — HTTPS git then prompts "Username for 'https://github.com'".
# _sync_plumbing must (re)register it on every boot. 2026-07-06 dataenv incident.

@test "plumbing registers gh as git credential helper when missing" {
  printf '#!/bin/sh\necho "gh $*" >> "$TMP/ran.log"\n' > "$TMP/stubs/gh"; chmod +x "$TMP/stubs/gh"
  _sync_plumbing
  grep -q "gh auth setup-git" "$TMP/ran.log"
}

@test "plumbing skips gh auth setup-git when the helper is already configured" {
  printf '#!/bin/sh\necho "gh $*" >> "$TMP/ran.log"\n' > "$TMP/stubs/gh"; chmod +x "$TMP/stubs/gh"
  git config --global credential.https://github.com.helper '!/usr/bin/gh auth git-credential'
  _sync_plumbing
  ! grep -q "gh auth setup-git" "$TMP/ran.log" 2>/dev/null
}

@test "plumbing sources the secrets file so gh sees GH_TOKEN in non-interactive boot" {
  # postStart shells never source ~/.bashrc.d/aicoding-env.sh, so GH_TOKEN is
  # absent — and `gh auth setup-git` refuses without an authenticated host.
  printf '#!/bin/sh\necho "token=${GH_TOKEN:-unset}" >> "$TMP/ran.log"\n' > "$TMP/stubs/gh"; chmod +x "$TMP/stubs/gh"
  mkdir -p "$TMP/.aicodingsetup"
  echo 'GH_TOKEN=test-token-123' > "$TMP/.aicodingsetup/.secrets.env"
  run env GH_TOKEN= bash -c '. "$BLUEPRINT_ROOT/lib/sync.sh"; ensure_gh_credential_helper'
  [ "$status" -eq 0 ]
  grep -q "token=test-token-123" "$TMP/ran.log"
}

@test "plumbing is fail-open when gh auth setup-git fails" {
  printf '#!/bin/sh\nexit 1\n' > "$TMP/stubs/gh"; chmod +x "$TMP/stubs/gh"
  run bash -c '. "$BLUEPRINT_ROOT/lib/sync.sh"; ensure_gh_credential_helper'
  [ "$status" -eq 0 ]
}

# --- file-based GH_TOKEN credential fallback ----------------------------------
# codex strips *TOKEN* env vars from spawned commands, so the gh helper fails
# inside codex sessions; git must fall through to the file-based helper.

@test "plumbing registers the file-fallback credential helper (idempotent)" {
  printf '#!/bin/sh\nexit 0\n' > "$TMP/stubs/gh"; chmod +x "$TMP/stubs/gh"
  _sync_plumbing
  _sync_plumbing
  run bash -c 'git config --global --get-all credential.https://github.com.helper | grep -c git-credential-aicoding'
  [ "$output" = "1" ]
}

@test "credential helper: answers get for https/github.com from the secrets file" {
  mkdir -p "$TMP/.aicodingsetup"
  echo 'GH_TOKEN=file-token-456' > "$TMP/.aicodingsetup/.secrets.env"
  run bash -c 'printf "protocol=https\nhost=github.com\n\n" | bash "$BLUEPRINT_ROOT/configs/git/git-credential-aicoding" get'
  [ "$status" -eq 0 ]
  [[ "$output" == *"username=x-access-token"* ]]
  [[ "$output" == *"password=file-token-456"* ]]
}

@test "credential helper: silent for other hosts, other actions, empty/missing token" {
  mkdir -p "$TMP/.aicodingsetup"
  echo 'GH_TOKEN=file-token-456' > "$TMP/.aicodingsetup/.secrets.env"
  run bash -c 'printf "protocol=https\nhost=gitlab.com\n\n" | bash "$BLUEPRINT_ROOT/configs/git/git-credential-aicoding" get'
  [ "$status" -eq 0 ]; [ -z "$output" ]
  run bash -c 'printf "protocol=https\nhost=github.com\n\n" | bash "$BLUEPRINT_ROOT/configs/git/git-credential-aicoding" store'
  [ "$status" -eq 0 ]; [ -z "$output" ]
  echo 'GH_TOKEN=' > "$TMP/.aicodingsetup/.secrets.env"
  run bash -c 'printf "protocol=https\nhost=github.com\n\n" | bash "$BLUEPRINT_ROOT/configs/git/git-credential-aicoding" get'
  [ "$status" -eq 0 ]; [ -z "$output" ]
  rm "$TMP/.aicodingsetup/.secrets.env"
  run bash -c 'printf "protocol=https\nhost=github.com\n\n" | bash "$BLUEPRINT_ROOT/configs/git/git-credential-aicoding" get'
  [ "$status" -eq 0 ]; [ -z "$output" ]
}
