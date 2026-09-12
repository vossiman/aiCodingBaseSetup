# Shell adapter for the value-safe Codex TOML merge engine.
# Sourced by blueprint-deploy.sh; no top-level filesystem or network effects.

# Pin the CLI to the library that sourced this adapter. Sync may load the
# refreshed clone while install-host runs from a durable copy, so /tmp/aicoding
# and the caller's original SCRIPT_DIR are not reliable locations.
_AICODING_CODEX_MERGE_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

_codex_smart_error_json() {
  jq -nc --arg code "$1" --arg action "${2:-plan}" \
    '{config_changed:false,state_changed:false,conflicts:[],error:{code:$code},unmanaged:false,token:null,changes:[],adoption_notices:[]}
     + if $action == "apply" then {applied:false} else {} end'
}

_codex_smart_valid_result() {
  local action=$1
  jq -e --arg action "$action" '
    type == "object" and
    keys == (
      ["adoption_notices","changes","config_changed","conflicts","error","state_changed","token","unmanaged"]
      + if $action == "apply" then ["applied"] else [] end
      | sort
    ) and
    (.config_changed | type == "boolean") and
    (.state_changed | type == "boolean") and
    (.unmanaged | type == "boolean") and
    (.conflicts | type == "array") and
    (.changes | type == "array") and
    (.adoption_notices | type == "array") and
    (.token == null or (.token | type == "string")) and
    (.error == null or (.error.code | type == "string")) and
    ($action != "apply" or (.applied | type == "boolean"))
  ' >/dev/null 2>&1
}

_codex_smart_python_available() {
  local marker
  command -v python3 >/dev/null 2>&1 || return 1
  marker="$(python3 -c 'import sys; print("aicoding-python-supported" if sys.version_info >= (3, 8) else "")' 2>/dev/null)" \
    || return 1
  [[ "$marker" == "aicoding-python-supported" ]]
}

# _codex_smart_invoke <plan|apply> <dest> <template> <context>
#                     [expected-token] [decisions-json]
# Sets CODEX_SMART_RESULT to engine JSON and always returns zero so set -e
# installers can preserve the destination and continue unrelated work. Callers
# decide whether a reported smart error should affect their final exit status.
_codex_smart_invoke() {
  local action=$1 dest=$2 template=$3 context=${4:-installer}
  local expected=${5:-} decisions=${6:-[]}
  local rendered decisions_file="" output="" entry="null"
  local provenance_git="" release_sha=""
  local -a command

  CODEX_SMART_RESULT=""
  if ! _codex_smart_python_available || \
     [[ ! -f "$_AICODING_CODEX_MERGE_LIB_DIR/codex-merge.py" ]]; then
    CODEX_SMART_RESULT=$(_codex_smart_error_json runtime_unavailable "$action")
    return 0
  fi

  # Prepare public source evidence before rendering any secret-bearing source.
  if [[ "${AICODING_BLUEPRINT_LOCAL:-0}" != 1 && ! -e "$AICODING_BLUEPRINT_CLONE/.git" ]]; then
    . "$_AICODING_CODEX_MERGE_LIB_DIR/codex-provenance.sh"
    if [[ ! -f "$AICODING_BLUEPRINT_CLONE/.aicoding-version" || -L "$AICODING_BLUEPRINT_CLONE/.aicoding-version" ]]; then
      CODEX_SMART_RESULT=$(_codex_smart_error_json invalid_blueprint_release "$action")
      return 0
    fi
    release_sha=$(cat "$AICODING_BLUEPRINT_CLONE/.aicoding-version")
    if ! _codex_provenance_prepare "$release_sha"; then
      CODEX_SMART_RESULT=$(_codex_smart_error_json "$CODEX_PROVENANCE_ERROR" "$action")
      return 0
    fi
    provenance_git=$CODEX_PROVENANCE_GIT
  fi

  rendered=$(mktemp "${TMPDIR:-/tmp}/aicoding-codex-render.XXXXXX") || {
    CODEX_SMART_RESULT=$(_codex_smart_error_json temporary_file_failed "$action")
    return 0
  }
  chmod 0600 "$rendered" 2>/dev/null || true
  if ! _render_managed_source "$template" "$dest" "$rendered" >/dev/null 2>&1; then
    rm -f -- "$rendered"
    CODEX_SMART_RESULT=$(_codex_smart_error_json source_render_failed "$action")
    return 0
  fi

  command=(python3 "$_AICODING_CODEX_MERGE_LIB_DIR/codex-merge.py" "$action"
    --source "$rendered" --template "$template" --dest "$dest"
    --clone "$AICODING_BLUEPRINT_CLONE" --profile "$(manifest_get_profile)")
  [[ "${AICODING_BLUEPRINT_LOCAL:-0}" == 1 ]] && command+=(--local)
  [[ -z "$provenance_git" ]] || command+=(--provenance-git "$provenance_git")

  # Any local manifest entry establishes legacy management when no shared
  # receipt exists. The engine then creates a conservative baseline rather
  # than interpreting the file as a fresh personal config.
  entry=$(manifest_get_file "$dest" 2>/dev/null || printf 'null')
  [[ "$entry" != null ]] && command+=(--tracked)
  case "$context" in
    interactive|yes|dry-run) command+=(--allow-adopt) ;;
  esac

  if [[ "$action" == apply && -n "$expected" ]]; then
    command+=(--expected "$expected")
  fi
  if [[ "$action" == apply && "$decisions" != '[]' ]]; then
    decisions_file=$(mktemp "${TMPDIR:-/tmp}/aicoding-codex-decisions.XXXXXX") || {
      rm -f -- "$rendered"
      CODEX_SMART_RESULT=$(_codex_smart_error_json temporary_file_failed "$action")
      return 0
    }
    chmod 0600 "$decisions_file" 2>/dev/null || true
    if ! printf '%s\n' "$decisions" > "$decisions_file"; then
      rm -f -- "$rendered" "$decisions_file"
      CODEX_SMART_RESULT=$(_codex_smart_error_json temporary_file_failed "$action")
      return 0
    fi
    command+=(--decisions "$decisions_file")
  fi

  # The CLI's public JSON is value-safe. Discard stderr so an interpreter or
  # argparse failure cannot echo a rendered temp path or raw argument.
  if output=$("${command[@]}" 2>/dev/null); then :; else :; fi
  rm -f -- "$rendered"
  [[ -z "$decisions_file" ]] || rm -f -- "$decisions_file"
  if ! printf '%s' "$output" | _codex_smart_valid_result "$action"; then
    output=$(_codex_smart_error_json engine_protocol_error "$action")
  fi
  CODEX_SMART_RESULT=$output
  return 0
}

codex_smart_plan() {
  _codex_smart_invoke plan "$1" "$2" "${3:-installer}"
}

codex_smart_bucket() {
  local result=$1
  if [[ $(printf '%s' "$result" | jq -r '.error != null') == true ]]; then
    printf 'smart_error'
  elif (( $(printf '%s' "$result" | jq '[.conflicts[], .adoption_notices[]] | length') > 0 )); then
    printf 'smart_conflict'
  elif [[ $(printf '%s' "$result" | jq -r '.unmanaged') == true ]]; then
    printf 'new_file_existing'
  elif [[ $(printf '%s' "$result" | jq -r '.config_changed or .state_changed') == true ]]; then
    printf 'smart_update'
  else
    printf 'up_to_date'
  fi
}

codex_smart_error_code() {
  printf '%s' "$1" | jq -r '.error.code // empty' 2>/dev/null
}

codex_smart_path_text() {
  jq -r '
    .path
    | map(if test("^[A-Za-z_][A-Za-z0-9_-]*$") then . else tojson end)
    | join(".")
  '
}

codex_smart_record_manifest() {
  local dest=$1 source=$2
  manifest_set_file "$dest" \
    "$(jq -nc --arg source "$source" '{mode:"toml_merge",source:$source}')"
  _aicoding_pending_manifest=$(printf '%s' "$_aicoding_pending_manifest" \
    | jq '.schema_version = 2')
}

# codex_smart_apply <dest> <template> <source-label> <context>
#                   [expected-token] [decisions-json]
# Sets CODEX_SMART_RESULT. A successful managed apply records schema 2; an
# unmanaged result or any error leaves the existing manifest entry unchanged.
codex_smart_apply() {
  local dest=$1 template=$2 source=$3 context=${4:-installer}
  local expected=${5:-} decisions=${6:-[]}
  _codex_smart_invoke apply "$dest" "$template" "$context" "$expected" "$decisions"
  if [[ $(printf '%s' "$CODEX_SMART_RESULT" | jq -r '.error == null and .unmanaged == false and .applied == true') == true ]]; then
    codex_smart_record_manifest "$dest" "$source"
  fi
  return 0
}
