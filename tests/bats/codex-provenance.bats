#!/usr/bin/env bats
setup() {
  PROV_TMP=$(mktemp -d)
  export HOME="$PROV_TMP/home" AICODING_STATE_DIR="$PROV_TMP/state"
  mkdir -p "$HOME" "$PROV_TMP/source"
  git init -q "$PROV_TMP/source"
  git -C "$PROV_TMP/source" -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -qm initial
  export PROV_SHA=$(git -C "$PROV_TMP/source" rev-parse HEAD)
  export PROV_SOURCE="$PROV_TMP/source"
}
teardown() { rm -rf "$PROV_TMP"; }
@test "provenance uncached offline refuses without creating cache" {
  run bash -c '. "$BLUEPRINT_ROOT/lib/codex-provenance.sh"; _codex_provenance_prepare "$PROV_SHA"; rc=$?; echo "$CODEX_PROVENANCE_ERROR"; exit "$rc"'
  [ "$status" -ne 0 ]
  [[ "$output" == *revision_unavailable* ]]
  [ ! -e "$AICODING_STATE_DIR/code-provenance/aicoding.git" ]
}
seed_cache() (
  umask 077
  mkdir -p "$AICODING_STATE_DIR/code-provenance"
  chmod 700 "$AICODING_STATE_DIR/code-provenance"
  (umask 077; git clone -q --bare --no-local "$PROV_SOURCE" "$AICODING_STATE_DIR/code-provenance/aicoding.git")
  git --git-dir="$AICODING_STATE_DIR/code-provenance/aicoding.git" remote set-url origin https://github.com/vossiman/aiCodingBaseSetup
  git --git-dir="$AICODING_STATE_DIR/code-provenance/aicoding.git" update-ref "refs/aicoding/qualified/$PROV_SHA" "$PROV_SHA"
)
@test "provenance qualified cached evidence works offline with ambient Git overrides ignored" {
  seed_cache
  run bash -c 'export GIT_DIR=/nonexistent GIT_OBJECT_DIRECTORY=/nonexistent GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.bare GIT_CONFIG_VALUE_0=false; . "$BLUEPRINT_ROOT/lib/codex-provenance.sh"; _codex_provenance_prepare "$PROV_SHA" || { echo "$CODEX_PROVENANCE_ERROR"; exit 1; }; echo "$CODEX_PROVENANCE_GIT"'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *code-provenance/aicoding.git ]]
}
@test "provenance rejects cache symlink" {
  seed_cache
  mv "$AICODING_STATE_DIR/code-provenance/aicoding.git" "$PROV_TMP/elsewhere"
  ln -s "$PROV_TMP/elsewhere" "$AICODING_STATE_DIR/code-provenance/aicoding.git"
  run bash -c '. "$BLUEPRINT_ROOT/lib/codex-provenance.sh"; _codex_provenance_prepare "$PROV_SHA"'
  [ "$status" -ne 0 ]
}
@test "provenance rejects altered graph mechanisms" {
  seed_cache
  touch "$AICODING_STATE_DIR/code-provenance/aicoding.git/shallow"
  run bash -c '. "$BLUEPRINT_ROOT/lib/codex-provenance.sh"; _codex_provenance_prepare "$PROV_SHA"'
  [ "$status" -ne 0 ]
}
@test "provenance object without qualification is not reusable offline" {
  seed_cache
  git --git-dir="$AICODING_STATE_DIR/code-provenance/aicoding.git" update-ref -d "refs/aicoding/qualified/$PROV_SHA"
  run bash -c '. "$BLUEPRINT_ROOT/lib/codex-provenance.sh"; _codex_provenance_prepare "$PROV_SHA"'
  [ "$status" -ne 0 ]
}
@test "provenance online hydration qualifies before fetching and caches offline evidence" {
  run bash -c '
    . "$BLUEPRINT_ROOT/lib/codex-provenance.sh"
    _codex_provenance_qualify() { echo qualified > "$HOME/order"; }
    _codex_provenance_fetch() {
      [ "$(cat "$HOME/order")" = qualified ] || return 1
      git --git-dir="$1" fetch --quiet "$PROV_SOURCE" "$2"
    }
    AICODINGSETUP_SKIP_NETWORK=0 _codex_provenance_prepare "$PROV_SHA" || exit 1
    _codex_provenance_fetch() { return 99; }
    AICODINGSETUP_SKIP_NETWORK=1 _codex_provenance_prepare "$PROV_SHA"
  '
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
@test "provenance failed CI qualification never fetches or publishes evidence" {
  run bash -c '
    . "$BLUEPRINT_ROOT/lib/codex-provenance.sh"
    _codex_provenance_qualify() { return 1; }
    _codex_provenance_fetch() { touch "$HOME/fetched"; }
    AICODINGSETUP_SKIP_NETWORK=0 _codex_provenance_prepare "$PROV_SHA"
  '
  [ "$status" -ne 0 ]
  [ ! -e "$HOME/fetched" ]
  [ ! -e "$AICODING_STATE_DIR/code-provenance/aicoding.git" ]
}
@test "provenance adapter prepares evidence before rendering config" {
  mkdir -p "$PROV_TMP/release"
  printf '%s\n' "$PROV_SHA" > "$PROV_TMP/release/.aicoding-version"
  export AICODING_BLUEPRINT_CLONE="$PROV_TMP/release"
  run bash -c '
    . "$BLUEPRINT_ROOT/lib/codex-merge.sh"
    _render_managed_source() { touch "$HOME/rendered"; }
    _codex_smart_invoke plan "$HOME/config.toml" "$HOME/template.toml"
    echo "$CODEX_SMART_RESULT"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *revision_unavailable* ]]
  [ ! -e "$HOME/rendered" ]
}
@test "provenance migrates owned state permissions and rejects injected config includes" {
  seed_cache
  chmod 0775 "$AICODING_STATE_DIR"
  run bash -c '. "$BLUEPRINT_ROOT/lib/codex-provenance.sh"; _codex_provenance_prepare "$PROV_SHA"; rc=$?; echo "$CODEX_PROVENANCE_ERROR"; exit "$rc"'
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$AICODING_STATE_DIR")" = 700 ]
  git --git-dir="$AICODING_STATE_DIR/code-provenance/aicoding.git" config include.path /nonexistent
  run bash -c '. "$BLUEPRINT_ROOT/lib/codex-provenance.sh"; _codex_provenance_prepare "$PROV_SHA"; rc=$?; echo "$CODEX_PROVENANCE_ERROR"; exit "$rc"'
  [ "$status" -ne 0 ]
  [[ "$output" == *invalid_provenance_cache* ]]
}
@test "provenance fetch pins canonical HTTPS and clears Git overrides" {
  mkdir -p "$PROV_TMP/bin"
  cat > "$PROV_TMP/bin/git" <<'SH'
#!/usr/bin/env bash
[[ "$GIT_CONFIG_GLOBAL" == /dev/null && "$GIT_CONFIG_NOSYSTEM" == 1 && "$GIT_NO_REPLACE_OBJECTS" == 1 ]] || exit 3
[[ -z "${GIT_DIR:-}" && -z "${GIT_CONFIG_COUNT:-}" ]] || exit 4
printf '%s\n' "$@" > "$HOME/git-arguments"
SH
  chmod +x "$PROV_TMP/bin/git"
  export PROV_BIN="$PROV_TMP/bin"
  run bash -c '
    export PATH="$PROV_BIN:$PATH" GIT_DIR=/injected GIT_CONFIG_COUNT=1
    . "$BLUEPRINT_ROOT/lib/codex-provenance.sh"
    . "$BLUEPRINT_ROOT/lib/update-progress.sh"
    aicoding_progress_run "test: fetching evidence" _codex_provenance_fetch /fixture/evidence.git "$PROV_SHA"
  '
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run tail -n 5 "$HOME/git-arguments"
  [ "$output" = "fetch
--quiet
--no-tags
https://github.com/vossiman/aiCodingBaseSetup
$PROV_SHA" ]
}

@test "provenance refuses symlink state without changing target permissions" {
  seed_cache
  mv "$AICODING_STATE_DIR" "$PROV_TMP/moved-state"
  chmod 0775 "$PROV_TMP/moved-state"
  ln -s "$PROV_TMP/moved-state" "$AICODING_STATE_DIR"
  run bash -c '. "$BLUEPRINT_ROOT/lib/codex-provenance.sh"; _codex_provenance_prepare "$PROV_SHA"'
  [ "$status" -ne 0 ]
  [ "$(stat -c %a "$PROV_TMP/moved-state")" = 775 ]
}
@test "provenance refuses a foreign-owned state directory without chmod" {
  [ "$(id -u)" != 0 ] || skip 'root has no foreign-owned fixture'
  original_mode=$(stat -c %a /)
  run bash -c '. "$BLUEPRINT_ROOT/lib/codex-provenance.sh"; AICODING_STATE_DIR=/ _codex_provenance_prepare "$PROV_SHA"'
  [ "$status" -ne 0 ]
  [ "$(stat -c %a /)" = "$original_mode" ]
}
@test "Codex adapter early errors preserve plan and apply result protocols" {
  run bash -c '
    set -e
    for scenario in runtime blueprint provenance temporary render protocol decisions; do
      for action in plan apply; do
        (
          . "$BLUEPRINT_ROOT/lib/codex-merge.sh"
          export AICODING_BLUEPRINT_LOCAL=1 AICODING_BLUEPRINT_CLONE="$PROV_SOURCE"
          _codex_smart_python_available() { return 0; }
          _render_managed_source() { return 0; }
          manifest_get_profile() { echo host; }
          manifest_get_file() { echo null; }
          case "$scenario" in
            runtime) _codex_smart_python_available() { return 1; }; expected=runtime_unavailable ;;
            blueprint) AICODING_BLUEPRINT_LOCAL=0; AICODING_BLUEPRINT_CLONE="$HOME/missing"; expected=invalid_blueprint_release ;;
            provenance)
              AICODING_BLUEPRINT_LOCAL=0; AICODING_BLUEPRINT_CLONE="$HOME/release"
              mkdir -p "$AICODING_BLUEPRINT_CLONE"
              printf "%s\n" "$PROV_SHA" > "$AICODING_BLUEPRINT_CLONE/.aicoding-version"
              expected=revision_unavailable ;;
            temporary) mktemp() { return 1; }; expected=temporary_file_failed ;;
            render) _render_managed_source() { return 1; }; expected=source_render_failed ;;
            protocol) python3() { echo invalid; }; expected=engine_protocol_error ;;
            decisions)
              [ "$action" = apply ] || exit 0
              mktemp() { case "$*" in *decisions*) return 1 ;; *) command mktemp "$@" ;; esac; }
              expected=temporary_file_failed ;;
          esac
          _codex_smart_invoke "$action" "$HOME/config.toml" "$HOME/template.toml" installer "" "[{\"path\":[\"model\"],\"choice\":\"local\"}]"
          printf "%s" "$CODEX_SMART_RESULT" | _codex_smart_valid_result "$action" || { echo "$scenario/$action: $CODEX_SMART_RESULT"; exit 1; }
          [ "$(printf "%s" "$CODEX_SMART_RESULT" | jq -r .error.code)" = "$expected" ]
          if [ "$action" = apply ]; then
            [ "$(printf "%s" "$CODEX_SMART_RESULT" | jq -r .applied)" = false ]
          fi
        )
      done
    done
  '
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
