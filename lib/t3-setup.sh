# Setup (new workspace) and adopt (existing state moved onto the mount).
# version.json is written exactly once here, and setup-done only after it, so
# no start ever needs npm and a half-finished setup never counts as done.

t3_verify_identity() {
  local u="$T3CODE_HOME/userdata"
  [ -s "$u/environment-id" ] || { t3_say "missing $u/environment-id"; return 1; }
  [ -f "$u/secrets/cloud-cli-oauth-token.bin" ] || { t3_say "missing stored login in $u/secrets"; return 1; }
  t3_connect_green "$1" \
    || { t3_say "t3 connect status is not green (needs stored credential, provisioned link, publish enabled)"; return 1; }
}

# version.json and auto are created once; a later setup (re-login) keeps
# the owner's held version and auto choice.
t3_init_state() {
  if [ ! -f "$T3_STATE/version.json" ]; then
    t3_write_version latest "$1" && t3_write_file "$T3_STATE/auto" on || return 1
  fi
  t3_write_file "$T3_STATE/setup-done" "$(cat "$T3CODE_HOME/userdata/environment-id")"
}

t3_adopt_core() {
  local v=$1 cur
  t3_running && { t3_say "a server is running; t3-stop first"; return 1; }
  cur=$(t3_selected_version)
  if [ -n "$cur" ] && [ "$cur" != "$v" ]; then
    t3_say "this workspace already runs t3 $cur; adopting $v would open its state with a different release"
    return 1
  fi
  t3_install "$v" || { t3_say "cannot install t3 $v"; return 1; }
  t3_verify_identity "$v" || return 1
  t3_init_state "$v"
}

t3_cmd_setup() {
  local v l
  t3_entry
  t3_running && t3_die "a server is running; t3-stop first"
  v=$(t3_selected_version) || true
  [ -n "$v" ] || v=$(t3_latest) || t3_die "cannot resolve the newest t3 from npm"
  t3_install "$v" || t3_die "cannot install t3 $v"
  l=$(t3_launcher "$v")
  "$l" connect login --headless || t3_die "t3 connect login failed"
  "$l" connect link || t3_die "t3 connect link failed"
  "$l" connect publish || t3_die "t3 connect publish failed"
  t3_verify_identity "$v" || t3_die "setup did not reach a green state"
  t3_init_state "$v" || t3_die "cannot write state"
  t3_say "set up with t3 $v. Sign in on the phone with the account the CLI reported, then run t3-start."
}

t3_cmd_adopt() {
  local v=""
  case "${1:-}" in
    --version) v=${2:-} ;;
    '') ;;
    *) t3_die "usage: t3-adopt [--version X]" ;;
  esac
  t3_entry
  [ -n "$v" ] || v=$(t3_json_get "$T3_MIGRATE_DIR/$T3_KEY.json" .version)
  t3_valid_version "$v" || t3_die "which t3 version last ran on this state? Pass t3-adopt --version X"
  t3_adopt_core "$v" || t3_die "adopt failed; nothing was recorded"
  t3_say "adopted with t3 $v; now run t3-start"
}
