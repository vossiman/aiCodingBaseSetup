#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

setup() {
  export TMP=$(mktemp -d) HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME" "$TMP/bin" "$TMP/api"
  export PATH="$TMP/bin:$PATH" CI_FIXTURE="$TMP/api"
  unset AICODINGSETUP_SKIP_NETWORK  # gh below is an offline fixture, never the real client
  export NEW=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa OLD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env python3
import os,sys,json
args=sys.argv[1:]
if args[:1]!=['api']: sys.exit(90)
endpoint=args[1]
root=os.environ['CI_FIXTURE']
called=os.environ.get('GH_CALLED')
if called:
    open(called,'a').write(endpoint+'\n')
if endpoint.startswith('repos/vossiman/aiCodingBaseSetup/actions/workflows/tests.yml/runs?') and 'head_sha=' not in endpoint:
    name='runs-bulk'
elif endpoint.startswith('repos/vossiman/aiCodingBaseSetup/actions/workflows/tests.yml/runs?'):
    sha=endpoint.split('head_sha=')[1].split('&')[0]; name='runs-'+sha
elif endpoint == 'repos/vossiman/aiCodingBaseSetup/actions/workflows/tests.yml': name='workflow'
elif endpoint.startswith('repos/vossiman/dvw/actions/workflows/ci.yml/runs?'):
    sha=endpoint.split('head_sha=')[1].split('&')[0]; name='runs-dvw-'+sha
elif endpoint == 'repos/vossiman/dvw/actions/workflows/ci.yml': name='workflow-dvw'
elif endpoint.startswith('repos/vossiman/bw-AICode/actions/workflows/ci.yml/runs?'):
    sha=endpoint.split('head_sha=')[1].split('&')[0]; name='runs-bw-'+sha
elif endpoint == 'repos/vossiman/bw-AICode/actions/workflows/ci.yml': name='workflow-bw'
elif endpoint.startswith('repos/vossiman/ai-usage/actions/workflows/ci.yml/runs?'):
    sha=endpoint.split('head_sha=')[1].split('&')[0]; name='runs-ai-usage-'+sha
elif endpoint == 'repos/vossiman/ai-usage/actions/workflows/ci.yml': name='workflow-ai-usage'
elif endpoint in ('repos/vossiman/aiCodingBaseSetup/commits?sha=main&per_page=30',
                   'repos/vossiman/dvw/commits?sha=main&per_page=30',
                   'repos/vossiman/bw-AICode/commits?sha=main&per_page=30',
                   'repos/vossiman/ai-usage/commits?sha=main&per_page=30'): name='commits'
elif '/compare/' in endpoint: name='compare'
else: sys.exit(91)
try:
    data=open(root+'/'+name).read()
except FileNotFoundError: sys.exit(22)
print(data)
STUB
  chmod +x "$TMP/bin/gh"
  printf '#!/usr/bin/env bash\nexit 22\n' > "$TMP/bin/curl"
  chmod +x "$TMP/bin/curl"
  printf '%s\n' '{"id":330421083,"name":"tests","path":".github/workflows/tests.yml","state":"active"}' > "$CI_FIXTURE/workflow"
  printf '%s\n' '{"id":355909244,"name":"ci","path":".github/workflows/ci.yml","state":"active"}' > "$CI_FIXTURE/workflow-dvw"
  printf '%s\n' '{"id":344911642,"name":"ci","path":".github/workflows/ci.yml","state":"active"}' > "$CI_FIXTURE/workflow-bw"
  printf '%s\n' '{"id":367323599,"name":"ci","path":".github/workflows/ci.yml","state":"active"}' > "$CI_FIXTURE/workflow-ai-usage"
  printf '[{"sha":"%s"},{"sha":"%s"}]\n' "$NEW" "$OLD" > "$CI_FIXTURE/commits"
  printf '{"status":"ahead","merge_base_commit":{"sha":"%s"}}\n' "$NEW" > "$CI_FIXTURE/compare"
  fixture_run "$NEW" completed success
  fixture_run "$OLD" completed success
  fixture_run "$NEW" completed success 355909244 runs-dvw
  fixture_run "$OLD" completed success 355909244 runs-dvw
  fixture_run "$NEW" completed success 344911642 runs-bw
  fixture_run "$OLD" completed success 344911642 runs-bw
  fixture_run "$NEW" completed success 367323599 runs-ai-usage
  fixture_run "$OLD" completed success 367323599 runs-ai-usage
}
teardown() { rm -rf "$TMP"; }
fixture_run() {
  local sha=$1 status=$2 conclusion=$3 workflow_id=${4:-330421083} file_prefix=${5:-runs}
  jq -n --arg sha "$sha" --arg status "$status" --arg conclusion "$conclusion" \
    --argjson workflow_id "$workflow_id" \
    '{total_count:1,workflow_runs:[{id:22,run_number:4,run_attempt:1,workflow_id:$workflow_id,head_sha:$sha,head_branch:"main",event:"push",status:$status,conclusion:(if $conclusion == "null" then null else $conclusion end)}]}' \
    > "$CI_FIXTURE/$file_prefix-$sha"
}
select_sha() { bash "$BLUEPRINT_ROOT/bin/aicoding-select" aicoding; }

@test "select exact latest main commit with successful required workflow" {
  run --separate-stderr select_sha
  [ "$status" -eq 0 ]
  [ "$output" = "$NEW" ]
}
@test "failed cancelled or skipped latest CI selects older proven main" {
  for conclusion in failure cancelled skipped; do
    fixture_run "$NEW" completed "$conclusion"
    run --separate-stderr select_sha
    [ "$status" -eq 0 ]
    [ "$output" = "$OLD" ]
  done
}
@test "queued or in-progress CI with null conclusion selects older proven main" {
  for pending_status in queued in_progress; do
    fixture_run "$NEW" "$pending_status" null
    run --separate-stderr select_sha
    [ "$status" -eq 0 ]
    [ "$output" = "$OLD" ]
  done
}
@test "pending rerun cannot reuse an earlier successful run" {
  jq '.total_count=2 | .workflow_runs += [.workflow_runs[0] | .id=23 | .run_number=5 | .status="in_progress" | .conclusion=null]' "$CI_FIXTURE/runs-$NEW" > "$TMP/new"
  mv "$TMP/new" "$CI_FIXTURE/runs-$NEW"
  run --separate-stderr select_sha
  [ "$status" -eq 0 ]
  [ "$output" = "$OLD" ]
}
@test "wrong SHA branch event or unrelated workflow success does not qualify" {
  for mutation in '.head_sha="cccccccccccccccccccccccccccccccccccccccc"' '.head_branch="feature"' '.event="pull_request"' '.workflow_id=999'; do
    fixture_run "$NEW" completed success
    jq ".workflow_runs[0] |= ($mutation)" "$CI_FIXTURE/runs-$NEW" > "$TMP/new"
    mv "$TMP/new" "$CI_FIXTURE/runs-$NEW"
    run --separate-stderr select_sha
    [ "$status" -eq 0 ]
    [ "$output" = "$OLD" ]
  done
}
@test "inaccessible CI aborts instead of silently selecting older commit" {
  rm "$CI_FIXTURE/runs-$NEW"
  run --separate-stderr select_sha
  [ "$status" -ne 0 ]
  [[ "$output" != *"$OLD"* ]]
}
@test "missing disabled or substituted required workflow fails closed" {
  for mutation in '.state="disabled_manually"' '.id=999' '.path=".github/workflows/renovate.yml"'; do
    printf '%s\n' '{"id":330421083,"name":"tests","path":".github/workflows/tests.yml","state":"active"}' | jq "$mutation" > "$CI_FIXTURE/workflow"
    run --separate-stderr select_sha
    [ "$status" -ne 0 ]
  done
  rm "$CI_FIXTURE/workflow"
  run --separate-stderr select_sha
  [ "$status" -ne 0 ]
}
@test "malformed and truncated API responses never produce a selected version" {
  for invalid in '{"workflow_runs":null}' 'not JSON' '{"total_count":101,"workflow_runs":[]}'; do
    printf '%s\n' "$invalid" > "$CI_FIXTURE/runs-$NEW"
    run --separate-stderr select_sha
    [ "$status" -ne 0 ]
    [[ "$output" != *"$OLD"* ]]
  done
}
@test "missing or wrongly typed run policy fields abort instead of falling back" {
  for mutation in \
    'del(.head_branch)' '.head_branch=7' \
    'del(.event)' '.event=[]' \
    'del(.conclusion)' '.conclusion=7' \
    '.conclusion=null'; do
    fixture_run "$NEW" completed success
    jq ".workflow_runs[0] |= ($mutation)" "$CI_FIXTURE/runs-$NEW" > "$TMP/new"
    mv "$TMP/new" "$CI_FIXTURE/runs-$NEW"
    run --separate-stderr select_sha
    [ "$status" -eq 2 ]
    [[ "$output" != *"$OLD"* ]]
  done
}
@test "no green candidate fails without claiming success" {
  printf '%s\n' '{"total_count":0,"workflow_runs":[]}' > "$CI_FIXTURE/runs-$NEW"
  fixture_run "$OLD" completed failure
  run --separate-stderr select_sha
  [ "$status" -ne 0 ]
}
@test "qualification requires full SHA and ancestry on main" {
  run bash -c '. "$BLUEPRINT_ROOT/lib/ci-selector.sh"; aicoding_ci_qualified aicoding "$NEW"'
  [ "$status" -eq 0 ]
  printf '%s\n' '{"status":"diverged","merge_base_commit":{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}' > "$CI_FIXTURE/compare"
  run bash -c '. "$BLUEPRINT_ROOT/lib/ci-selector.sh"; aicoding_ci_qualified aicoding "$NEW"'
  [ "$status" -ne 0 ]
  run bash -c '. "$BLUEPRINT_ROOT/lib/ci-selector.sh"; aicoding_ci_qualified aicoding main'
  [ "$status" -ne 0 ]
}
@test "selection never mutates development checkout" {
  mkdir "$TMP/project"
  git -C "$TMP/project" init -q
  printf 'local work\n' > "$TMP/project/untracked"
  before=$(git -C "$TMP/project" status --porcelain)
  cd "$TMP/project"
  run --separate-stderr select_sha
  [ "$status" -eq 0 ]
  [ "$(git status --porcelain)" = "$before" ]
  [ "$(cat untracked)" = 'local work' ]
}
@test "network guard prevents gh invocation" {
  export GH_CALLED="$TMP/gh-called"
  AICODINGSETUP_SKIP_NETWORK=1 run --separate-stderr select_sha
  [ "$status" -eq 2 ]
  [ ! -e "$GH_CALLED" ]
}
@test "component policies use exact repository and workflow boundaries" {
  for component in dvw bw-AICode ai-usage; do
    run --separate-stderr bash "$BLUEPRINT_ROOT/bin/aicoding-select" "$component"
    [ "$status" -eq 0 ]
    [ "$output" = "$NEW" ]
  done
}

@test "public read-only API fallback applies the same policy when gh has no stored auth" {
  mv "$TMP/bin/gh" "$TMP/bin/gh-fixture"
  cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in https://api.github.com/*) endpoint=${arg#https://api.github.com/} ;; esac
done
[ -n "${endpoint:-}" ] || exit 92
exec "$TMP/bin/gh-fixture" api "$endpoint"
EOF
  chmod +x "$TMP/bin/gh" "$TMP/bin/curl"
  export TMP

  run --separate-stderr select_sha
  [ "$status" -eq 0 ]
  [ "$output" = "$NEW" ]
}

@test "dvw rejects a recreated workflow even when its path and name match" {
  jq '.id = 355909245' "$CI_FIXTURE/workflow-dvw" > "$CI_FIXTURE/replaced-workflow"
  mv "$CI_FIXTURE/replaced-workflow" "$CI_FIXTURE/workflow-dvw"
  run bash "$BLUEPRINT_ROOT/bin/aicoding-select" dvw
  [ "$status" -eq 2 ]
  [[ "$output" == *"required workflow missing or invalid"* ]]
}

@test "missing selector component returns a policy error under nounset" {
  run bash -uc '. "$BLUEPRINT_ROOT/lib/ci-selector.sh"; aicoding_select_ci_sha'
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown component"* ]]
}

bulk_runs() {
  # bulk_runs <total_count> <sha:status:conclusion:run_number:created_at>...
  local total=$1; shift
  printf '%s\n' "$@" | jq -R 'split(":") as $f | {id:($f[3]|tonumber),run_number:($f[3]|tonumber),run_attempt:1,
    workflow_id:330421083,head_sha:$f[0],head_branch:"main",event:"push",status:$f[1],
    conclusion:(if $f[2] == "null" then null else $f[2] end),created_at:($f[4:]|join(":"))}' \
    | jq -s --argjson total "$total" '{total_count:$total,workflow_runs:.}' > "$CI_FIXTURE/runs-bulk"
}
dated_commits() {
  jq -n --arg new "$NEW" --arg old "$OLD" \
    '[{sha:$new,commit:{committer:{date:"2026-09-20T10:00:00Z"}}},{sha:$old,commit:{committer:{date:"2026-09-19T10:00:00Z"}}}]' \
    > "$CI_FIXTURE/commits"
}
per_sha_calls() { grep -c 'head_sha=' "$GH_CALLED" || true; }

@test "one bulk runs request qualifies the newest covered commit" {
  export GH_CALLED="$TMP/called"
  dated_commits
  bulk_runs 2 "$NEW:completed:success:9:2026-09-20T10:05:00Z" "$OLD:completed:success:8:2026-09-19T10:05:00Z"
  run --separate-stderr select_sha
  [ "$status" -eq 0 ]
  [ "$output" = "$NEW" ]
  [ "$(per_sha_calls)" -eq 0 ]
  [ "$(grep -c '/runs?' "$GH_CALLED")" -eq 1 ]
}

@test "bulk selection keeps latest-run semantics: a newer pending run blocks an older success" {
  export GH_CALLED="$TMP/called"
  dated_commits
  bulk_runs 3 "$NEW:in_progress:null:10:2026-09-20T11:00:00Z" "$NEW:completed:success:9:2026-09-20T10:05:00Z" \
    "$OLD:completed:success:8:2026-09-19T10:05:00Z"
  run --separate-stderr select_sha
  [ "$status" -eq 0 ]
  [ "$output" = "$OLD" ]
  [ "$(per_sha_calls)" -eq 0 ]
}

@test "bulk selection ignores runs from another workflow identity" {
  export GH_CALLED="$TMP/called"
  dated_commits
  bulk_runs 2 "$NEW:completed:success:9:2026-09-20T10:05:00Z" "$OLD:completed:success:8:2026-09-19T10:05:00Z"
  jq '.workflow_runs[0].workflow_id = 1' "$CI_FIXTURE/runs-bulk" > "$TMP/b" && mv "$TMP/b" "$CI_FIXTURE/runs-bulk"
  run --separate-stderr select_sha
  [ "$status" -eq 0 ]
  [ "$output" = "$OLD" ]
}

@test "a truncated bulk page that may miss a commit's runs falls back to the exact query" {
  export GH_CALLED="$TMP/called"
  dated_commits
  # 500 runs exist; the page's oldest run is younger than NEW's commit time plus a day.
  bulk_runs 500 "$NEW:completed:failure:9:2026-09-20T10:05:00Z"
  run --separate-stderr select_sha
  [ "$status" -eq 0 ]
  [ "$output" = "$NEW" ]
  grep -q "head_sha=$NEW" "$GH_CALLED"
}

@test "a truncated bulk page still answers commits it provably covers" {
  export GH_CALLED="$TMP/called"
  dated_commits
  bulk_runs 500 "$NEW:completed:success:9:2026-09-22T10:05:00Z" "$OLD:completed:success:1:2026-09-18T00:00:00Z"
  run --separate-stderr select_sha
  [ "$status" -eq 0 ]
  [ "$output" = "$NEW" ]
  [ "$(per_sha_calls)" -eq 0 ]
}

@test "malformed or undated bulk runs fall back to exact queries" {
  export GH_CALLED="$TMP/called"
  dated_commits
  printf '{"total_count":1,"workflow_runs":[{"id":1}]}\n' > "$CI_FIXTURE/runs-bulk"
  run --separate-stderr select_sha
  [ "$status" -eq 0 ]
  [ "$output" = "$NEW" ]
  grep -q "head_sha=$NEW" "$GH_CALLED"
  bulk_runs 1 "$NEW:completed:failure:9:not-a-date"
  : > "$GH_CALLED"
  run --separate-stderr select_sha
  [ "$status" -eq 0 ]
  [ "$output" = "$NEW" ]
  grep -q "head_sha=$NEW" "$GH_CALLED"
}

@test "a bulk page whose total_count cannot describe its runs falls back to exact queries" {
  export GH_CALLED="$TMP/called"
  dated_commits
  local total
  for total in 1 -1 2.5; do
    bulk_runs "$total" "$NEW:completed:success:9:2026-09-22T10:05:00Z" "$OLD:completed:success:1:2026-09-18T00:00:00Z"
    : > "$GH_CALLED"
    run --separate-stderr select_sha
    [ "$status" -eq 0 ]
    grep -q "head_sha=$NEW" "$GH_CALLED"
  done
}
