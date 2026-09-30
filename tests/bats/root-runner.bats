#!/usr/bin/env bats
# Host root runner (root/): applies root tasks only from CI-qualified main of
# the repo, and the user-side hook step defers /etc/codex to it.

setup() {
  : "${BLUEPRINT_ROOT:?run via run.sh}"
  TMP=$(mktemp -d)
  export HOME="$TMP/home"; mkdir -p "$HOME"
  export AICODING_ROOT_STATE_DIR="$TMP/state"
  export AICODING_ROOT_GIT_PROTOCOLS=file
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

  # A fixture "GitHub" repo. Its selector stub is what the runner sources, so
  # the test controls which commit counts as CI-qualified.
  ORIGIN="$TMP/origin"
  mkdir -p "$ORIGIN/lib" "$ORIGIN/root"
  git -C "$ORIGIN" init -q -b main
  printf 'aicoding_select_ci_sha() { [ -s "%s/selected" ] && cat "%s/selected"; }\n' "$TMP" "$TMP" \
    > "$ORIGIN/lib/ci-selector.sh"
  _fixture_commit first
  FIRST=$(git -C "$ORIGIN" rev-parse HEAD)
  _fixture_commit second
  SECOND=$(git -C "$ORIGIN" rev-parse HEAD)
  export AICODING_ROOT_REPO_URL="file://$ORIGIN"
}

teardown() { rm -rf "$TMP"; }

# Commit an apply.sh that records which commit ran it.
_fixture_commit() {
  cat > "$ORIGIN/root/apply.sh" <<EOF
#!/bin/bash
echo "$1" >> "$TMP/applied"
EOF
  git -C "$ORIGIN" add -Af
  git -C "$ORIGIN" commit -qm "$1"
}

# Mark a commit as the one CI qualified.
_select() { echo "$1" > "$TMP/selected"; }

@test "runner applies the CI-qualified commit, not the main tip" {
  _select "$FIRST"
  run bash "$BLUEPRINT_ROOT/root/runner"
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/applied")" = first ]
  read -r result sha _ < "$AICODING_ROOT_STATE_DIR/status"
  [ "$result" = ok ]
  [ "$sha" = "$FIRST" ]
}

@test "runner refuses a commit that is not on origin/main" {
  git -C "$ORIGIN" checkout -q -b side
  _fixture_commit side
  local side; side=$(git -C "$ORIGIN" rev-parse HEAD)
  git -C "$ORIGIN" checkout -q main
  _select "$side"
  run bash "$BLUEPRINT_ROOT/root/runner"
  [ "$status" -ne 0 ]
  [ ! -e "$TMP/applied" ]
  read -r result _ < "$AICODING_ROOT_STATE_DIR/status"
  [ "$result" = failed ]
}

@test "no qualifying commit applies nothing and reports stale, not failed" {
  run bash "$BLUEPRINT_ROOT/root/runner"
  [ "$status" -eq 0 ]
  [ ! -e "$TMP/applied" ]
  read -r result _ < "$AICODING_ROOT_STATE_DIR/status"
  [ "$result" = stale ]
}

@test "an unreachable repo reports stale, not failed" {
  export AICODING_ROOT_REPO_URL="file://$TMP/missing"
  run bash "$BLUEPRINT_ROOT/root/runner"
  [ "$status" -eq 0 ]
  read -r result _ < "$AICODING_ROOT_STATE_DIR/status"
  [ "$result" = stale ]
}

@test "unchanged main after a good pass skips selection" {
  _select "$SECOND"
  bash "$BLUEPRINT_ROOT/root/runner"
  echo bogus > "$TMP/selected"
  : > "$TMP/applied"
  run bash "$BLUEPRINT_ROOT/root/runner"
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/applied")" = second ]
}

@test "a failing task marks the pass failed" {
  printf '#!/bin/bash\nexit 3\n' > "$ORIGIN/root/apply.sh"
  git -C "$ORIGIN" add -Af; git -C "$ORIGIN" commit -qm broken
  _select "$(git -C "$ORIGIN" rev-parse HEAD)"
  run bash "$BLUEPRINT_ROOT/root/runner"
  [ "$status" -ne 0 ]
  read -r result _ < "$AICODING_ROOT_STATE_DIR/status"
  [ "$result" = failed ]
}

@test "runner discards local edits in its clone before applying" {
  _select "$SECOND"
  bash "$BLUEPRINT_ROOT/root/runner"
  echo 'echo tampered >> "$TMP/applied"' >> "$AICODING_ROOT_STATE_DIR/repo/root/apply.sh"
  : > "$TMP/applied"
  bash "$BLUEPRINT_ROOT/root/runner"
  [ "$(cat "$TMP/applied")" = second ]
}

@test "runner ignores a redirected origin in its clone config" {
  _select "$SECOND"
  bash "$BLUEPRINT_ROOT/root/runner"
  git -C "$AICODING_ROOT_STATE_DIR/repo" remote set-url origin "file://$TMP/elsewhere"
  run bash "$BLUEPRINT_ROOT/root/runner"
  [ "$status" -eq 0 ]
  [ "$(git -C "$AICODING_ROOT_STATE_DIR/repo" remote get-url origin)" = "file://$ORIGIN" ]
}

@test "root task writes the blueprint's Codex managed hooks" {
  export CODEX_MANAGED_DIR="$TMP/etc-codex"
  AICODING_BLUEPRINT_ROOT="$BLUEPRINT_ROOT" run bash "$BLUEPRINT_ROOT/root/tasks.d/10-codex-managed-hooks.sh"
  [ "$status" -eq 0 ]
  . "$BLUEPRINT_ROOT/lib/codex-managed.sh"
  codex_managed_state "$BLUEPRINT_ROOT"
}

@test "root task refuses to overwrite a requirements.toml it did not write" {
  export CODEX_MANAGED_DIR="$TMP/etc-codex"
  mkdir -p "$CODEX_MANAGED_DIR"; echo 'admin = true' > "$CODEX_MANAGED_DIR/requirements.toml"
  AICODING_BLUEPRINT_ROOT="$BLUEPRINT_ROOT" run bash "$BLUEPRINT_ROOT/root/tasks.d/10-codex-managed-hooks.sh"
  [ "$status" -ne 0 ]
  [ "$(cat "$CODEX_MANAGED_DIR/requirements.toml")" = 'admin = true' ]
}

@test "install files lands runner and units once, reloading only on change" {
  mkdir -p "$TMP/bin"
  printf '#!/bin/sh\necho "$*" >> "%s/systemctl.log"\n' "$TMP" > "$TMP/bin/systemctl"
  printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/systemd-tmpfiles"
  chmod +x "$TMP/bin/systemctl" "$TMP/bin/systemd-tmpfiles"
  export PATH="$TMP/bin:$PATH" AICODING_ROOT_PREFIX="$TMP/root"
  . "$BLUEPRINT_ROOT/root/lib.sh"

  aicoding_root_install_files "$BLUEPRINT_ROOT"
  cmp "$BLUEPRINT_ROOT/root/runner" "$TMP/root/usr/local/libexec/aicoding-root/runner"
  [ -x "$TMP/root/usr/local/libexec/aicoding-root/runner" ]
  for u in service timer path; do
    cmp "$BLUEPRINT_ROOT/root/units/aicoding-root.$u" "$TMP/root/etc/systemd/system/aicoding-root.$u"
  done
  grep -q daemon-reload "$TMP/systemctl.log"

  : > "$TMP/systemctl.log"
  aicoding_root_install_files "$BLUEPRINT_ROOT"
  if grep -q daemon-reload "$TMP/systemctl.log"; then false; fi
  grep -q 'enable --quiet aicoding-root.timer aicoding-root.path' "$TMP/systemctl.log"
}

@test "service unit hides /home from the runner" {
  grep -qx 'ProtectHome=yes' "$BLUEPRINT_ROOT/root/units/aicoding-root.service"
  grep -qx 'ExecStart=/usr/local/libexec/aicoding-root/runner' "$BLUEPRINT_ROOT/root/units/aicoding-root.service"
}

# --- user side: ensure_codex_managed_hooks ----------------------------------

_load_user_side() {
  header(){ :; }; info(){ echo "INFO: $*"; }; ok(){ echo "OK: $*"; }; warn(){ echo "WARN: $*"; }
  mkdir -p "$TMP/bin"
  printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/codex"; chmod +x "$TMP/bin/codex"
  export PATH="$TMP/bin:/usr/bin:/bin"
  export SCRIPT_DIR="$BLUEPRINT_ROOT"
  . "$BLUEPRINT_ROOT/lib/codex-managed.sh"
}

@test "with the runner installed, the user step defers and rings the trigger" {
  export CODEX_MANAGED_DIR=/etc/codex
  export AICODING_ROOT_RUNNER="$TMP/runner" AICODING_ROOT_TRIGGER="$TMP/trigger"
  export AICODING_ROOT_STATUS="$TMP/status"
  printf '#!/bin/sh\n' > "$AICODING_ROOT_RUNNER"; chmod +x "$AICODING_ROOT_RUNNER"
  _load_user_side
  codex_managed_state() { return 1; }
  SUDO=/nonexistent-sudo

  ensure_codex_managed_hooks
  [ "$codex_managed_defer_reason" = root_runner_pending ]
  [ -e "$TMP/trigger" ]
}

@test "a failed runner pass is reported as needing action" {
  export CODEX_MANAGED_DIR=/etc/codex
  export AICODING_ROOT_RUNNER="$TMP/runner" AICODING_ROOT_TRIGGER="$TMP/trigger"
  export AICODING_ROOT_STATUS="$TMP/status"
  printf '#!/bin/sh\n' > "$AICODING_ROOT_RUNNER"; chmod +x "$AICODING_ROOT_RUNNER"
  echo "failed abc 2026-01-01T00:00:00Z" > "$AICODING_ROOT_STATUS"
  _load_user_side
  codex_managed_state() { return 1; }

  ensure_codex_managed_hooks
  [ "$codex_managed_defer_reason" = root_runner_failed ]
}

@test "a relocated managed dir never defers to the runner" {
  export CODEX_MANAGED_DIR="$TMP/etc-codex"
  export AICODING_ROOT_RUNNER="$TMP/runner"
  printf '#!/bin/sh\n' > "$AICODING_ROOT_RUNNER"; chmod +x "$AICODING_ROOT_RUNNER"
  _load_user_side
  SUDO=""

  ensure_codex_managed_hooks
  [ -z "$codex_managed_defer_reason" ]
  codex_managed_state "$BLUEPRINT_ROOT"
}

@test "an unattended host run without the runner asks for aicoding-root-install" {
  export CODEX_MANAGED_DIR="$TMP/etc-codex" AICODINGSETUP_NONINTERACTIVE=1 ENV_TYPE=linux
  export AICODING_ROOT_RUNNER="$TMP/no-runner"
  _load_user_side
  printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/sudo"; chmod +x "$TMP/bin/sudo"
  SUDO=sudo

  run ensure_codex_managed_hooks
  [ "$status" -eq 0 ]
  [[ "$output" == *aicoding-root-install* ]]
  ensure_codex_managed_hooks >/dev/null
  [ "$codex_managed_defer_reason" = root_runner_not_installed ]
}

@test "an unattended container run keeps the old behaviour and defers nothing" {
  export CODEX_MANAGED_DIR="$TMP/etc-codex" AICODINGSETUP_NONINTERACTIVE=1 ENV_TYPE=container
  export AICODING_ROOT_RUNNER="$TMP/no-runner"
  _load_user_side
  printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/sudo"; chmod +x "$TMP/bin/sudo"
  SUDO=sudo

  ensure_codex_managed_hooks >/dev/null
  [ -z "$codex_managed_defer_reason" ]
}
