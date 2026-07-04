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
@test "aicoding-update shim still works (delegates to aicoding-sync)" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  run env AICODING_BLUEPRINT_CLONE="$BLUEPRINT_ROOT" AICODING_UPDATE_TTL=0 \
      "$BLUEPRINT_ROOT/bin/aicoding-update" --yes
  [ "$status" -eq 0 ]
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

@test "on-start.sh runs the boot path (exit 0)" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  run env AICODING_BLUEPRINT_CLONE="$BLUEPRINT_ROOT" AICODING_UPDATE_TTL=0 \
      bash "$BLUEPRINT_ROOT/on-start.sh"
  [ "$status" -eq 0 ]
}
