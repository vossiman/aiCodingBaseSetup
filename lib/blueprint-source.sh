# lib/blueprint-source.sh — shared CLI parsing for selecting a local blueprint.
# Sourced by bin/aicoding-sync and bin/aicoding-install.

aicoding_parse_blueprint_args() {
  local command_name=$1
  shift

  AICODING_REMAINING_ARGS=()
  local local_path="" arg
  while (( $# > 0 )); do
    arg=$1
    case "$arg" in
      --blueprint)
        if (( $# < 2 )) || [[ -z "${2:-}" ]]; then
          echo "$command_name: --blueprint requires a checkout path" >&2
          return 2
        fi
        local_path=$2
        shift 2
        ;;
      --blueprint=*)
        local_path=${arg#--blueprint=}
        if [[ -z "$local_path" ]]; then
          echo "$command_name: --blueprint requires a checkout path" >&2
          return 2
        fi
        shift
        ;;
      *)
        AICODING_REMAINING_ARGS+=("$arg")
        shift
        ;;
    esac
  done

  [[ -n "$local_path" ]] || return 0
  if [[ ! -d "$local_path" ]]; then
    echo "$command_name: local blueprint is not a directory: $local_path" >&2
    return 2
  fi

  local_path=$(cd -- "$local_path" 2>/dev/null && pwd -P) || {
    echo "$command_name: cannot resolve local blueprint: $local_path" >&2
    return 2
  }

  local required
  for required in install.sh lib/sync.sh lib/blueprint-deploy.sh; do
    if [[ ! -f "$local_path/$required" ]]; then
      echo "$command_name: invalid local blueprint (missing $required): $local_path" >&2
      return 2
    fi
  done
  if [[ "$(git -C "$local_path" rev-parse --is-inside-work-tree 2>/dev/null || true)" != true ]]; then
    echo "$command_name: local blueprint is not a Git checkout: $local_path" >&2
    return 2
  fi

  export AICODING_BLUEPRINT_CLONE="$local_path"
  export AICODING_BLUEPRINT_LOCAL=1
}
