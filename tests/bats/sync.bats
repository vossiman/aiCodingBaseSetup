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
  # cwd must leave the real checkout: _sync_devcontainer_pin targets the
  # cwd's repo, and tests must never write into $BLUEPRINT_ROOT.
  cd "$TMP"
}
teardown() { cd /; rm -rf "$TMP"; }

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

@test "_sync_binaries: host profile refreshes claude only" {
  printf '#!/bin/sh\necho "codex $*" >> "$TMP/ran.log"\n' > "$TMP/stubs/codex"; chmod +x "$TMP/stubs/codex"
  mkdir -p "$(dirname "$AICODING_MANIFEST")"
  echo '{"profile":"host"}' > "$AICODING_MANIFEST"
  : > "$TMP/ran.log"
  . "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  _sync_binaries
  grep -q "^claude update" "$TMP/ran.log"
  [ "$(grep -c '^opencode' "$TMP/ran.log")" = 0 ]
  [ "$(grep -c '^agent' "$TMP/ran.log")" = 0 ]
  [ "$(grep -c '^codex' "$TMP/ran.log")" = 0 ]
}

@test "_sync_binaries: container/absent profile refreshes all CLIs" {
  : > "$TMP/ran.log"
  . "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  _sync_binaries
  grep -q "^claude update" "$TMP/ran.log"
  grep -q "^opencode upgrade" "$TMP/ran.log"
  grep -q "^agent update" "$TMP/ran.log"
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
  run "$BLUEPRINT_ROOT/bin/aicoding-install" --blueprint "$BLUEPRINT_ROOT" </dev/null
  [ "$status" -eq 0 ]
  echo "$output" | grep -Fq "Blueprint source: local $BLUEPRINT_ROOT"
  echo "$output" | grep -q "Mode: reconcile"
  [ "$(jq -r '.blueprint_origin' "$AICODING_MANIFEST")" = "local:$BLUEPRINT_ROOT" ]
}

@test "aicoding-install: passes --force-reinstall through (first-deploy)" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  run "$BLUEPRINT_ROOT/bin/aicoding-install" --force-reinstall \
      --blueprint="$BLUEPRINT_ROOT" </dev/null
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Mode: first"
}

@test "aicoding-install --blueprint rejects a non-checkout directory" {
  mkdir -p "$TMP/not-a-blueprint"
  run "$BLUEPRINT_ROOT/bin/aicoding-install" --blueprint "$TMP/not-a-blueprint"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "invalid local blueprint"
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
  if grep -q "gh auth setup-git" "$TMP/ran.log" 2>/dev/null; then false; fi
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

@test "plumbing symlinks ~/.agents/skills to ~/.claude/skills (idempotent)" {
  printf '#!/bin/sh\nexit 0\n' > "$TMP/stubs/gh"; chmod +x "$TMP/stubs/gh"
  _sync_plumbing
  _sync_plumbing
  [ -L "$TMP/.agents/skills" ]
  [ "$(readlink "$TMP/.agents/skills")" = "$TMP/.claude/skills" ]
}

@test "plumbing leaves a real ~/.agents/skills dir untouched (user's own adoption)" {
  printf '#!/bin/sh\nexit 0\n' > "$TMP/stubs/gh"; chmod +x "$TMP/stubs/gh"
  mkdir -p "$TMP/.agents/skills/my-skill"
  _sync_plumbing
  [ ! -L "$TMP/.agents/skills" ]
  [ -d "$TMP/.agents/skills/my-skill" ]
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

# ensure_claude_runtime_scope: ~/.claude/{jobs,sessions,daemon} must become
# symlinks into a container-local base so a home dir shared across devpod
# containers stops leaking background agents between agents views (and stops
# daemons clobbering each other's roster). See the function comment in sync.sh.
@test "plumbing scopes claude runtime dirs into the container-local base" {
  export AICODING_CLAUDE_RUNTIME_DIR="$TMP/runtime"
  _sync_plumbing
  for d in jobs sessions daemon; do
    [ -L "$TMP/.claude/$d" ]
    [ "$(readlink "$TMP/.claude/$d")" = "$TMP/runtime/$d" ]
    [ -d "$TMP/runtime/$d" ]
  done
  _sync_plumbing                                   # idempotent re-run
  [ "$(readlink "$TMP/.claude/jobs")" = "$TMP/runtime/jobs" ]
}

@test "claude runtime scope adopts own jobs, leaves foreign ones in the backup" {
  export AICODING_CLAUDE_RUNTIME_DIR="$TMP/runtime"
  mkdir -p "$TMP/.claude/jobs/ownjob" "$TMP/.claude/jobs/foreignjob" "$TMP/mywork"
  printf '{"cwd":"%s"}' "$TMP/mywork" > "$TMP/.claude/jobs/ownjob/state.json"
  printf '{"cwd":"/no/such/workspace"}' > "$TMP/.claude/jobs/foreignjob/state.json"
  echo '{}' > "$TMP/.claude/jobs/pins.json"
  _sync_plumbing
  [ -d "$TMP/runtime/jobs/ownjob" ]                # ours: migrated
  [ -f "$TMP/runtime/jobs/pins.json" ]
  [ -d "$TMP/.claude/jobs.premigrate/foreignjob" ] # theirs: stays in backup
  [ ! -e "$TMP/.claude/jobs.premigrate/ownjob" ]
}

@test "claude runtime scope heals a dangling symlink after container rebuild" {
  export AICODING_CLAUDE_RUNTIME_DIR="$TMP/runtime"
  mkdir -p "$TMP/.claude"
  ln -s "$TMP/runtime/jobs" "$TMP/.claude/jobs"    # rebuild wiped the base
  _sync_plumbing
  [ -d "$TMP/runtime/jobs" ]
}

@test "claude runtime scope is fail-open when the base is uncreatable" {
  export AICODING_CLAUDE_RUNTIME_DIR=/proc/nonexistent/base
  mkdir -p "$TMP/.claude/jobs"
  run ensure_claude_runtime_scope
  [ "$status" -eq 0 ]
  [ ! -L "$TMP/.claude/jobs" ]                     # left untouched
}

# --- /dev/kvm group access ----------------------------------------------------
# Privileged devpods carry the host's /dev, but /dev/kvm is 0660 root:<host gid>
# with no matching container group — so the Android emulator / qemu can't open it
# without sudo. Plumbing joins the owning group on every boot (membership is
# container state and dies with a rebuild). /dev/null stands in for the device:
# it is a char device on every host, and `stat` is stubbed for the gid.

_kvm_stub_stat() {   # $1 = gid the fake device reports
  printf '#!/bin/sh\necho "%s"\n' "$1" > "$TMP/stubs/stat"; chmod +x "$TMP/stubs/stat"
}
_kvm_stub_sudo() {   # log calls instead of running them
  printf '#!/bin/sh\necho "sudo $*" >> "$TMP/ran.log"\n' > "$TMP/stubs/sudo"; chmod +x "$TMP/stubs/sudo"
}

@test "kvm access is skipped on a host without /dev/kvm" {
  _kvm_stub_sudo
  export AICODING_KVM_DEVICE="$TMP/no-such-kvm"
  run ensure_kvm_group_access
  [ "$status" -eq 0 ]
  if grep -q usermod "$TMP/ran.log" 2>/dev/null; then false; fi
}

@test "kvm access creates the missing group and joins it" {
  _kvm_stub_sudo; _kvm_stub_stat 994
  printf '#!/bin/sh\nexit 2\n' > "$TMP/stubs/getent"; chmod +x "$TMP/stubs/getent"   # no group, any name
  export AICODING_KVM_DEVICE=/dev/null
  run ensure_kvm_group_access
  [ "$status" -eq 0 ]
  grep -q "sudo -n groupadd -g 994 kvm" "$TMP/ran.log"
  grep -q "sudo -n usermod -aG kvm " "$TMP/ran.log"
}

@test "kvm access reuses an existing group with the device's gid" {
  _kvm_stub_sudo; _kvm_stub_stat 994
  printf '#!/bin/sh\necho "kvm:x:994:"\n' > "$TMP/stubs/getent"; chmod +x "$TMP/stubs/getent"
  export AICODING_KVM_DEVICE=/dev/null
  ensure_kvm_group_access
  if grep -q groupadd "$TMP/ran.log" 2>/dev/null; then false; fi
  grep -q "sudo -n usermod -aG kvm " "$TMP/ran.log"
}

@test "kvm access picks a distinct name when 'kvm' is taken by another gid" {
  _kvm_stub_sudo; _kvm_stub_stat 994
  # gid lookup misses; the NAME lookup hits (a different gid already owns 'kvm')
  printf '#!/bin/sh\n[ "$2" = kvm ] && { echo "kvm:x:108:"; exit 0; }\nexit 2\n' \
    > "$TMP/stubs/getent"; chmod +x "$TMP/stubs/getent"
  export AICODING_KVM_DEVICE=/dev/null
  ensure_kvm_group_access
  grep -q "sudo -n groupadd -g 994 kvm994" "$TMP/ran.log"
}

@test "kvm access is a no-op when the user is already a member" {
  _kvm_stub_sudo; _kvm_stub_stat "$(id -g)"
  export AICODING_KVM_DEVICE=/dev/null
  ensure_kvm_group_access
  if grep -q -e groupadd -e usermod "$TMP/ran.log" 2>/dev/null; then false; fi
}

@test "kvm access is fail-open when groupadd is not permitted" {
  printf '#!/bin/sh\nexit 1\n' > "$TMP/stubs/sudo"; chmod +x "$TMP/stubs/sudo"
  _kvm_stub_stat 994
  printf '#!/bin/sh\nexit 2\n' > "$TMP/stubs/getent"; chmod +x "$TMP/stubs/getent"
  export AICODING_KVM_DEVICE=/dev/null
  run ensure_kvm_group_access
  [ "$status" -eq 0 ]
}

@test "kvm access is skipped on the host profile (bare-metal thin client)" {
  # /dev/kvm often exists on a real desktop; joining a system group there is an
  # unrequested privilege change, and the core profile runs no emulator.
  _kvm_stub_sudo; _kvm_stub_stat 994
  printf '#!/bin/sh\nexit 2\n' > "$TMP/stubs/getent"; chmod +x "$TMP/stubs/getent"
  manifest_get_profile() { echo host; }
  export AICODING_KVM_DEVICE=/dev/null
  run ensure_kvm_group_access
  [ "$status" -eq 0 ]
  if grep -q -e groupadd -e usermod "$TMP/ran.log" 2>/dev/null; then false; fi
}

@test "kvm access still runs on the container profile" {
  _kvm_stub_sudo; _kvm_stub_stat 994
  printf '#!/bin/sh\nexit 2\n' > "$TMP/stubs/getent"; chmod +x "$TMP/stubs/getent"
  manifest_get_profile() { echo container; }
  export AICODING_KVM_DEVICE=/dev/null
  ensure_kvm_group_access
  grep -q "sudo -n usermod -aG kvm " "$TMP/ran.log"
}
