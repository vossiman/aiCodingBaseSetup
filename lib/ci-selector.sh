# Exact main-commit selection using explicitly required GitHub Actions workflows.
# Read-only API calls; no checkout, credential-store access, or activation.

_aicoding_ci_policy() {
  case "${1:-}" in
    aicoding) _CI_REPO=vossiman/aiCodingBaseSetup; _CI_WORKFLOW=tests.yml; _CI_ID=330421083; _CI_NAME=tests ;;
    dvw) _CI_REPO=vossiman/dvw; _CI_WORKFLOW=ci.yml; _CI_ID=355909244; _CI_NAME=ci ;;
    bw-AICode) _CI_REPO=vossiman/bw-AICode; _CI_WORKFLOW=ci.yml; _CI_ID=344911642; _CI_NAME=ci ;;
    *) echo 'CI selection: unknown component' >&2; return 2 ;;
  esac
}

_aicoding_ci_api() {
  [ "${AICODINGSETUP_SKIP_NETWORK:-0}" != 1 ] || return 2
  local endpoint=$1 response
  response=$(mktemp) || return 2
  if command -v gh >/dev/null 2>&1; then
    if timeout 20 gh api "$endpoint" </dev/null >"$response" 2>/dev/null; then
      cat "$response"
      rm -f -- "$response"
      return 0
    fi
  fi
  command -v curl >/dev/null 2>&1 || { rm -f -- "$response"; return 2; }
  if ! timeout 20 curl -fsSL --max-time 20 \
    -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/$endpoint" </dev/null >"$response" 2>/dev/null; then
    rm -f -- "$response"
    return 2
  fi
  cat "$response"
  rm -f -- "$response"
}

_aicoding_ci_workflow() {
  local metadata id
  metadata=$(_aicoding_ci_api "repos/$_CI_REPO/actions/workflows/$_CI_WORKFLOW") || {
    echo 'CI selection: required workflow inaccessible' >&2; return 2;
  }
  id=$(jq -er --arg path ".github/workflows/$_CI_WORKFLOW" --arg name "$_CI_NAME" \
    --arg expected "$_CI_ID" '
      select(.state == "active" and .path == $path and .name == $name)
      | .id | select(type == "number" and . > 0 and . == floor)
      | select($expected == "" or tostring == $expected)' <<< "$metadata" 2>/dev/null) || {
    echo 'CI selection: required workflow missing or invalid' >&2; return 2;
  }
  _CI_RESOLVED_ID=$id
}

# 0 qualified; 1 no successful required run; 2 inaccessible/malformed API.
_aicoding_ci_run_qualified() {
  local sha=$1 runs latest
  runs=$(_aicoding_ci_api "repos/$_CI_REPO/actions/workflows/$_CI_WORKFLOW/runs?head_sha=$sha&branch=main&event=push&per_page=100") || {
    echo 'CI selection: required checks inaccessible' >&2; return 2;
  }
  # Fail closed on truncated responses instead of accidentally accepting an
  # old success when a newer run was omitted. This also detects API errors.
  jq -e '
    type == "object" and (.total_count | type == "number")
    and (.workflow_runs | type == "array")
    and .total_count == (.workflow_runs | length)
    and all(.workflow_runs[];
      type == "object"
      and (.id | type == "number") and (.run_number | type == "number")
      and (.run_attempt | type == "number") and (.workflow_id | type == "number")
      and (.head_sha | type == "string") and (.head_branch | type == "string")
      and (.event | type == "string") and (.status | type == "string")
      and has("conclusion")
      and ((.conclusion | type) == "string" or (.conclusion | type) == "null")
      and (.status != "completed" or (.conclusion | type) == "string"))
  ' <<< "$runs" >/dev/null 2>&1 || {
    echo 'CI selection: malformed or incomplete checks response' >&2; return 2;
  }
  latest=$(jq -c --arg sha "$sha" --argjson workflow "$_CI_RESOLVED_ID" '
    [.workflow_runs[] | select(.workflow_id == $workflow and .head_sha == $sha
      and .head_branch == "main" and .event == "push")]
    | sort_by(.run_number, .run_attempt, .id) | last
  ' <<< "$runs") || return 2
  jq -e '.status == "completed" and .conclusion == "success"' <<< "$latest" >/dev/null 2>&1
}

aicoding_select_ci_sha() (
  local component=${1:-} commits sha rc
  _aicoding_ci_policy "$component" || return $?
  _aicoding_ci_workflow || return $?
  commits=$(_aicoding_ci_api "repos/$_CI_REPO/commits?sha=main&per_page=30") || {
    echo 'CI selection: main history inaccessible' >&2; return 2;
  }
  jq -e 'type == "array" and length > 0 and all(.[]; .sha | type == "string" and test("^[0-9a-f]{40}$"))' \
    <<< "$commits" >/dev/null 2>&1 || {
    echo 'CI selection: invalid main history' >&2; return 2;
  }
  while IFS= read -r sha; do
    if _aicoding_ci_run_qualified "$sha"; then
      printf '%s\n' "$sha"
      return 0
    else
      rc=$?
      [ "$rc" -eq 1 ] || return "$rc"
    fi
  done < <(jq -r '.[].sha' <<< "$commits")
  echo 'CI selection: no main commit has successful required checks' >&2
  return 1
)

aicoding_ci_qualified() (
  local component=${1:-} sha=${2:-} ancestry
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo 'CI selection: full SHA required' >&2; return 2; }
  _aicoding_ci_policy "$component" || return $?
  ancestry=$(_aicoding_ci_api "repos/$_CI_REPO/compare/$sha...main") || {
    echo 'CI selection: main ancestry inaccessible' >&2; return 2;
  }
  jq -e --arg sha "$sha" '(.status == "ahead" or .status == "identical") and .merge_base_commit.sha == $sha' \
    <<< "$ancestry" >/dev/null 2>&1 || { echo 'CI selection: commit is not verified on main' >&2; return 1; }
  _aicoding_ci_workflow || return $?
  _aicoding_ci_run_qualified "$sha"
)
