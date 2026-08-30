#!/usr/bin/env bats
# ensure_https_origin: boot sync rewrites SSH github origins under
# /workspaces to HTTPS. Containers auth github over HTTPS only, so a
# workspace cloned from an SSH URL can never push; host clones keep their
# SSH remotes via the host-profile gate.

setup() {
  : "${BLUEPRINT_ROOT:?unset — run via tests/bats/run.sh}"
  HTTPS_ORIGIN_TMPD=$(mktemp -d)
  export AICODING_WORKSPACES_ROOT="$HTTPS_ORIGIN_TMPD/workspaces"
  export AICODING_PROFILE=container
  mkdir -p "$AICODING_WORKSPACES_ROOT"
  . "$BLUEPRINT_ROOT/lib/sync.sh"
}

# Only ever delete the dir this file's own mktemp created (see the
# teardown-vs-inherited-TMPDIR gotcha, PR #53 / PR #107).
teardown() { [ -n "${HTTPS_ORIGIN_TMPD:-}" ] && rm -rf "$HTTPS_ORIGIN_TMPD"; }

_mk_repo() {  # <name> <origin-url>
  git init -q "$AICODING_WORKSPACES_ROOT/$1"
  git -C "$AICODING_WORKSPACES_ROOT/$1" remote add origin "$2"
}

_origin_of() { git -C "$AICODING_WORKSPACES_ROOT/$1" remote get-url origin; }

@test "rewrites scp-style ssh origin to https" {
  _mk_repo proj "git@github.com:vossiman/proj.git"
  run ensure_https_origin
  [ "$status" -eq 0 ]
  [ "$(_origin_of proj)" = "https://github.com/vossiman/proj.git" ]
}

@test "rewrites ssh:// origin and adds missing .git suffix" {
  _mk_repo proj "ssh://git@github.com/vossiman/proj"
  run ensure_https_origin
  [ "$status" -eq 0 ]
  [ "$(_origin_of proj)" = "https://github.com/vossiman/proj.git" ]
}

@test "leaves https and non-github origins alone" {
  _mk_repo ok-https "https://github.com/vossiman/proj.git"
  _mk_repo gitlab "git@gitlab.com:group/proj.git"
  run ensure_https_origin
  [ "$status" -eq 0 ]
  [ "$(_origin_of ok-https)" = "https://github.com/vossiman/proj.git" ]
  [ "$(_origin_of gitlab)" = "git@gitlab.com:group/proj.git" ]
}

@test "host profile is a no-op" {
  _mk_repo proj "git@github.com:vossiman/proj.git"
  AICODING_PROFILE=host run ensure_https_origin
  [ "$status" -eq 0 ]
  [ "$(_origin_of proj)" = "git@github.com:vossiman/proj.git" ]
}

@test "missing workspaces root is a no-op" {
  AICODING_WORKSPACES_ROOT="$HTTPS_ORIGIN_TMPD/absent" run ensure_https_origin
  [ "$status" -eq 0 ]
}

@test "skips non-git directories and repos without origin" {
  mkdir -p "$AICODING_WORKSPACES_ROOT/not-a-repo"
  git init -q "$AICODING_WORKSPACES_ROOT/no-origin"
  run ensure_https_origin
  [ "$status" -eq 0 ]
}
