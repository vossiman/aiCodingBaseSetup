#!/usr/bin/env bash
# Self-contained, reviewed first-install verifier, invoked directly or embedded
# byte for byte in a template. It must not source downloaded code until
# the selected main commit's exact required workflow run is verified.
set -uo pipefail

profile=container
while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile) [ "$#" -ge 2 ] || exit 2; profile=$2; shift 2 ;;
    --profile=*) profile=${1#--profile=}; shift ;;
    -h|--help) echo 'usage: bootstrap-aicoding.sh [--profile container|host|minimal-pi]'; exit 0 ;;
    *) echo "bootstrap-aicoding: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$profile" in container|host|minimal-pi) ;; *) echo 'bootstrap-aicoding: invalid profile' >&2; exit 2 ;; esac

bootstrap_prerequisites() {
  local command missing=0
  for command in bash curl jq tar timeout git gh flock setsid; do
    command -v "$command" >/dev/null 2>&1 || missing=1
  done
  [ "$missing" -ne 0 ] || return 0
  if [ "$profile" = container ]; then
    echo 'bootstrap-aicoding: missing runtime capability; manual rebuild required' >&2
    return 1
  fi
  command -v timeout >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1 \
    && command -v sudo >/dev/null 2>&1 || {
    echo 'bootstrap-aicoding: minimal prerequisites unavailable and cannot be installed safely' >&2
    return 1
  }
  timeout 15 sudo -n apt-get --version </dev/null >/dev/null 2>&1 || {
    echo 'bootstrap-aicoding: minimal prerequisite install deferred: noninteractive privilege unavailable' >&2
    return 1
  }
  timeout 120 sudo -n apt-get update </dev/null >/dev/null 2>&1 || {
    echo 'bootstrap-aicoding: package index update failed; prerequisite installation deferred' >&2
    return 1
  }
  timeout 300 sudo -n apt-get install -y --no-install-recommends \
      curl jq tar coreutils git gh util-linux </dev/null >/dev/null 2>&1 || {
    echo 'bootstrap-aicoding: required package installation failed; check distro repositories' >&2
    return 1
  }
  for command in bash curl jq tar timeout git gh flock setsid; do
    command -v "$command" >/dev/null 2>&1 || return 1
  done
}
bootstrap_prerequisites || exit $?

repo=vossiman/aiCodingBaseSetup
workflow=tests.yml
workflow_id=330421083
workflow_name=tests

bootstrap_api() {
  local endpoint=$1 headers rc=0
  # Public repository metadata does not require stored gh credentials. Using
  # curl directly also avoids treating an installed-but-logged-out gh as an
  # API outage on a fresh image.
  headers=$(mktemp) || return 1
  timeout 20 curl -fsSL --max-time 20 -D "$headers" \
    -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/$endpoint" </dev/null || rc=$?
  if [ "$rc" -ne 0 ] && grep -qi '^x-ratelimit-remaining:[[:space:]]*0[[:space:]]*$' "$headers"; then
    echo 'bootstrap-aicoding: GitHub API rate limit exhausted; retry after the public quota resets' >&2
  fi
  rm -f -- "$headers"
  return "$rc"
}

metadata=$(bootstrap_api "repos/$repo/actions/workflows/$workflow") || {
  echo 'bootstrap-aicoding: required workflow inaccessible' >&2; exit 1;
}
resolved_id=$(jq -er --arg path ".github/workflows/$workflow" --arg name "$workflow_name" \
  --argjson expected "$workflow_id" '
    select(.state == "active" and .path == $path and .name == $name)
    | .id | select(type == "number" and . > 0 and . == floor and . == $expected)
  ' <<<"$metadata" 2>/dev/null) || {
  echo 'bootstrap-aicoding: required workflow missing or invalid' >&2; exit 1;
}
commits=$(bootstrap_api "repos/$repo/commits?sha=main&per_page=30") || {
  echo 'bootstrap-aicoding: main history inaccessible' >&2; exit 1;
}
jq -e 'type == "array" and length > 0 and all(.[]; .sha | type == "string" and test("^[0-9a-f]{40}$"))' \
  <<<"$commits" >/dev/null 2>&1 || {
  echo 'bootstrap-aicoding: invalid main history' >&2; exit 1;
}

selected=
while IFS= read -r sha; do
  runs=$(bootstrap_api "repos/$repo/actions/workflows/$workflow/runs?head_sha=$sha&branch=main&event=push&per_page=100") || {
    echo 'bootstrap-aicoding: required checks inaccessible' >&2; exit 1;
  }
  jq -e '
    type == "object" and (.total_count | type == "number")
    and (.workflow_runs | type == "array") and .total_count == (.workflow_runs | length)
    and all(.workflow_runs[];
      type == "object" and (.id | type == "number") and (.run_number | type == "number")
      and (.run_attempt | type == "number") and (.workflow_id | type == "number")
      and (.head_sha | type == "string") and (.head_branch | type == "string")
      and (.event | type == "string") and (.status | type == "string")
      and has("conclusion")
      and ((.conclusion | type) == "string" or (.conclusion | type) == "null")
      and (.status != "completed" or (.conclusion | type) == "string"))
  ' <<<"$runs" >/dev/null 2>&1 || {
    echo 'bootstrap-aicoding: malformed or incomplete checks response' >&2; exit 1;
  }
  latest=$(jq -c --arg sha "$sha" --argjson workflow "$resolved_id" '
    [.workflow_runs[] | select(.workflow_id == $workflow and .head_sha == $sha
      and .head_branch == "main" and .event == "push")]
    | sort_by(.run_number, .run_attempt, .id) | last
  ' <<<"$runs") || exit 1
  if jq -e '.status == "completed" and .conclusion == "success"' <<<"$latest" >/dev/null 2>&1; then
    selected=$sha
    break
  fi
done < <(jq -r '.[].sha' <<<"$commits")
[ -n "$selected" ] || { echo 'bootstrap-aicoding: no main commit has successful required checks' >&2; exit 1; }

tmp=$(mktemp -d) || exit 1
trap 'rm -rf -- "$tmp"' EXIT
archive="$tmp/source.tar.gz"
extract="$tmp/source"
mkdir "$extract" || exit 1
timeout 120 curl -fL --max-time 120 \
  -H 'Accept: application/vnd.github+json' \
  "https://api.github.com/repos/$repo/tarball/$selected" -o "$archive" </dev/null || {
  echo 'bootstrap-aicoding: selected source download failed' >&2; exit 1;
}
tar -xzf "$archive" -C "$extract" || { echo 'bootstrap-aicoding: selected source archive invalid' >&2; exit 1; }
root=$(find "$extract" -mindepth 1 -maxdepth 1 -type d -print -quit)
[ -n "$root" ] && [ "$(find "$extract" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1 ] || {
  echo 'bootstrap-aicoding: selected source layout invalid' >&2; exit 1;
}
[ "$(cat "$root/.aicoding-bootstrap-version" 2>/dev/null)" = 1 ] || {
  echo 'bootstrap-aicoding: selected source lacks persistent enrollment capability' >&2; exit 1;
}
printf '%s\n' "$selected" > "$root/.aicoding-version" || exit 1
for file in bin/aicoding-install bin/aicoding-auto-update lib/runtime.sh lib/auto-update.sh lib/ci-selector.sh; do
  [ -f "$root/$file" ] && bash -n "$root/$file" || {
    echo "bootstrap-aicoding: selected source failed validation: $file" >&2; exit 1;
  }
done
chmod +x "$root/bin/aicoding-install" "$root/bin/aicoding-auto-update" || exit 1
"$root/bin/aicoding-install" --unattended --source "$root" --version "$selected" --profile "$profile" </dev/null
exit $?
