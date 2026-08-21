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

@test "env.sh stops exporting GH_TOKEN but still exports the other keys" {
  mkdir -p "$HOME/.aicodingsetup"
  printf 'GH_TOKEN=ghp_x\nBRAVE_API_KEY=brave123\n' > "$HOME/.aicodingsetup/.secrets.env"
  run bash -c ". '$BLUEPRINT_ROOT/configs/bash/env.sh'; echo \"gh=[\${GH_TOKEN:-}] brave=[\${BRAVE_API_KEY:-}]\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"gh=[]"* ]]
  [[ "$output" == *"brave=[brave123]"* ]]
}

@test "respects the offline guard so the suite never calls the real gh" {
  export AICODINGSETUP_SKIP_NETWORK=1
  run ensure_gh_stored_auth
  [ "$status" -eq 0 ]
  [ ! -f "$TMPD/gh.log" ]
}
