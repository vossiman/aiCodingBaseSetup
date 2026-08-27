#!/usr/bin/env bats
# ensure_gh_stored_auth: give gh its own stored credentials so GH_TOKEN no
# longer has to be exported into every shell (where any agent could read it
# with `printenv`). git is unaffected — it authenticates through
# git-credential-aicoding, which reads the secrets file directly.

setup() {
  : "${BLUEPRINT_ROOT:?unset — run via tests/bats/run.sh}"
  TMPD=$(mktemp -d)
  export HOME="$TMPD"
  export AICODING_SECRETS_FILE="$TMPD/.secrets.env"
  printf 'GH_TOKEN=ghp_testtoken123\nOTHER=x\n' > "$AICODING_SECRETS_FILE"

  mkdir -p "$TMPD/bin"
  # gh stub: records argv and stdin; `auth status` succeeds only once a
  # login has happened (mirrors the real "not logged into any host").
  cat > "$TMPD/bin/gh" <<'STUB'
#!/bin/bash
echo "argv: $*" >> "$TMPD/gh.log"
case "$1 $2" in
  "auth status")
    [ -f "$TMPD/logged-in" ] && exit 0
    exit 1 ;;
  "auth login")
    cat > "$TMPD/stdin-received"
    touch "$TMPD/logged-in"
    exit 0 ;;
esac
exit 0
STUB
  chmod +x "$TMPD/bin/gh"
  export PATH="$TMPD/bin:/usr/bin:/bin"
  export TMPD
  # run.sh sets this suite-wide to keep the tests offline, and
  # ensure_gh_stored_auth honours it. gh is stubbed here, so nothing
  # reaches the network and the real logic can be exercised.
  unset AICODINGSETUP_SKIP_NETWORK

  . "$BLUEPRINT_ROOT/lib/sync.sh"
}

teardown() { rm -rf "$TMPD"; }

@test "logs gh in from the secrets file when it has no credentials" {
  run ensure_gh_stored_auth
  [ "$status" -eq 0 ]
  grep -q -- '--with-token' "$TMPD/gh.log"
  grep -q -- '--insecure-storage' "$TMPD/gh.log"
  [ "$(cat "$TMPD/stdin-received")" = "ghp_testtoken123" ]
  [[ "$output" == *"no GH_TOKEN needed"* ]]
}

@test "the token goes in on STDIN and never appears in argv" {
  ensure_gh_stored_auth
  if grep -q 'ghp_testtoken123' "$TMPD/gh.log"; then false; fi
}

@test "does nothing when gh already has its own credentials" {
  touch "$TMPD/logged-in"
  run ensure_gh_stored_auth
  [ "$status" -eq 0 ]
  if grep -q -- 'auth login' "$TMPD/gh.log"; then false; fi
}

@test "an exported GH_TOKEN does not mask an unauthenticated gh" {
  # The status probe must strip the environment, or a machine that still
  # exports the token would look logged-in and never get stored credentials.
  export GH_TOKEN=ghp_fromenv
  run ensure_gh_stored_auth
  [ "$status" -eq 0 ]
  grep -q -- 'auth login' "$TMPD/gh.log"
}

@test "no gh installed: silent no-op" {
  rm "$TMPD/bin/gh"
  run ensure_gh_stored_auth
  [ "$status" -eq 0 ]
  [ ! -f "$TMPD/gh.log" ]
}

@test "no token in the secrets file: no login attempted" {
  printf 'OTHER=x\n' > "$AICODING_SECRETS_FILE"
  run ensure_gh_stored_auth
  [ "$status" -eq 0 ]
  if grep -q -- 'auth login' "$TMPD/gh.log"; then false; fi
}

@test "unreadable secrets file: no login attempted, no failure" {
  rm "$AICODING_SECRETS_FILE"
  run ensure_gh_stored_auth
  [ "$status" -eq 0 ]
  if grep -q -- 'auth login' "$TMPD/gh.log"; then false; fi
}

@test "env.sh exports no secret from the secrets file" {
  mkdir -p "$HOME/.aicodingsetup"
  printf 'GH_TOKEN=ghp_x\nBRAVE_API_KEY=brave123\nOPENROUTER_API_KEY=sk-or-x\nFIRECRAWL_API_KEY=fc_x\nMEMORY_ROUTER_TOKEN=mrt_x\nCLOUDFLARE_API_TOKEN=cf_x\nLOGFIRE_TOKEN=lf_x\nDOKPLOY_API_TOKEN=dk_x\nKANBAN_TOKEN=kb_x\n' \
    > "$HOME/.aicodingsetup/.secrets.env"
  run bash -c ". '$BLUEPRINT_ROOT/configs/bash/env.sh'; \
    for k in GH_TOKEN BRAVE_API_KEY OPENROUTER_API_KEY FIRECRAWL_API_KEY \
             MEMORY_ROUTER_TOKEN CLOUDFLARE_API_TOKEN LOGFIRE_TOKEN \
             DOKPLOY_API_TOKEN KANBAN_TOKEN; do \
      echo \"\$k=[\${!k:-}]\"; done"
  [ "$status" -eq 0 ]
  # Every key must render empty. A non-empty one means env.sh leaked it into
  # the shell, which is the whole leak path this file exists to close.
  # Asserted per key rather than with `grep -qv '=\[\]$'`: this container's
  # `grep` is ugrep 7.8.4, where `-qv` exits 1 on input that plain `-v` both
  # prints and exits 0 for — an assertion written that way passes no matter
  # what env.sh does. Verified 2026-08-27.
  local k
  for k in GH_TOKEN BRAVE_API_KEY OPENROUTER_API_KEY FIRECRAWL_API_KEY \
           MEMORY_ROUTER_TOKEN CLOUDFLARE_API_TOKEN LOGFIRE_TOKEN \
           DOKPLOY_API_TOKEN KANBAN_TOKEN; do
    [[ "$output" == *"$k=[]"* ]] || { echo "leaked into the environment: $k"; return 1; }
  done
}

@test "env.sh clears a secret exported by something else (remoteEnv, parent shell)" {
  mkdir -p "$HOME/.aicodingsetup"
  : > "$HOME/.aicodingsetup/.secrets.env"
  run bash -c "export OPENROUTER_API_KEY=sk-or-leaked CLOUDFLARE_API_TOKEN=cf-leaked; \
    . '$BLUEPRINT_ROOT/configs/bash/env.sh'; \
    echo \"or=[\${OPENROUTER_API_KEY:-}] cf=[\${CLOUDFLARE_API_TOKEN:-}]\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"or=[]"* ]]
  [[ "$output" == *"cf=[]"* ]]
}

@test "respects the offline guard so the suite never calls the real gh" {
  export AICODINGSETUP_SKIP_NETWORK=1
  run ensure_gh_stored_auth
  [ "$status" -eq 0 ]
  [ ! -f "$TMPD/gh.log" ]
}

# --- Diagnosability -----------------------------------------------------
# Every branch above is fail-open, and until 2026-08-22 most returned 0 in
# silence. In a container that mattered: configs/bash/boot-sync.sh (which owns
# ~/.cache/aicoding/boot-sync.log) is deployed on host-profile machines only,
# so the container path's single attempt runs from on-start.sh, whose stderr
# lands in devpod's postStart output and is read by nobody. Three containers
# reached an agent with gh unauthenticated and no evidence of which branch
# fired. Each outcome now appends a reason to the log.

@test "logs the reason when gh auth login fails" {
  export AICODING_BOOT_SYNC_LOG="$TMPD/boot-sync.log"
  cat > "$TMPD/bin/gh" <<'STUB'
#!/bin/bash
exit 1
STUB
  chmod +x "$TMPD/bin/gh"
  run ensure_gh_stored_auth
  [ "$status" -eq 0 ]
  grep -q 'gh auth login --with-token failed' "$AICODING_BOOT_SYNC_LOG"
}

@test "logs the reason when the secrets file carries no GH_TOKEN" {
  export AICODING_BOOT_SYNC_LOG="$TMPD/boot-sync.log"
  printf 'OTHER=x\n' > "$AICODING_SECRETS_FILE"
  run ensure_gh_stored_auth
  [ "$status" -eq 0 ]
  grep -q 'no GH_TOKEN' "$AICODING_BOOT_SYNC_LOG"
}

@test "logs success too, so a healthy boot is distinguishable from a skipped one" {
  export AICODING_BOOT_SYNC_LOG="$TMPD/boot-sync.log"
  run ensure_gh_stored_auth
  [ "$status" -eq 0 ]
  grep -q 'authenticated' "$AICODING_BOOT_SYNC_LOG"
}

@test "logging never breaks the sync when the log is unwritable" {
  export AICODING_BOOT_SYNC_LOG=/proc/nonexistent/boot-sync.log
  run ensure_gh_stored_auth
  [ "$status" -eq 0 ]
  grep -q -- '--with-token' "$TMPD/gh.log"
}

@test "logs the already-authenticated case too, or a healthy boot looks like no boot" {
  # The common outcome on a healthy container. Without a line here the log is
  # empty exactly when everything worked, so "gh was fine" and "the sync never
  # ran" stay indistinguishable — the thing #99 set out to fix, missed because
  # the no-login assertion above says nothing about logging.
  export AICODING_BOOT_SYNC_LOG="$TMPD/boot-sync.log"
  touch "$TMPD/logged-in"
  run ensure_gh_stored_auth
  [ "$status" -eq 0 ]
  grep -q 'already authenticated' "$AICODING_BOOT_SYNC_LOG"
  if grep -q -- 'auth login' "$TMPD/gh.log"; then false; fi
}
