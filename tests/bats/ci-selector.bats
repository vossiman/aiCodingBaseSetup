#!/usr/bin/env bats

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
if '/actions/workflows/tests.yml/runs?' in endpoint:
    sha=endpoint.split('head_sha=')[1].split('&')[0]; name='runs-'+sha
elif endpoint.endswith('/actions/workflows/tests.yml'): name='workflow'
elif '/commits?sha=main&per_page=30' in endpoint: name='commits'
elif '/compare/' in endpoint: name='compare'
else: sys.exit(91)
try:
    data=open(root+'/'+name).read()
except FileNotFoundError: sys.exit(22)
print(data)
STUB
  chmod +x "$TMP/bin/gh"
  printf '%s\n' '{"id":330421083,"name":"tests","path":".github/workflows/tests.yml","state":"active"}' > "$CI_FIXTURE/workflow"
  printf '[{"sha":"%s"},{"sha":"%s"}]\n' "$NEW" "$OLD" > "$CI_FIXTURE/commits"
  printf '{"status":"ahead","merge_base_commit":{"sha":"%s"}}\n' "$NEW" > "$CI_FIXTURE/compare"
  fixture_run "$NEW" completed success
  fixture_run "$OLD" completed success
}
teardown() { rm -rf "$TMP"; }
fixture_run() {
  jq -n --arg sha "$1" --arg status "$2" --arg conclusion "$3" \
    '{total_count:1,workflow_runs:[{id:22,run_number:4,run_attempt:1,workflow_id:330421083,head_sha:$sha,head_branch:"main",event:"push",status:$status,conclusion:$conclusion}]}' > "$CI_FIXTURE/runs-$1"
}
select_sha() { bash "$BLUEPRINT_ROOT/bin/aicoding-select" aicoding; }

@test "select exact latest main commit with successful required workflow" {
  run select_sha
  [ "$status" -eq 0 ]
  [ "$output" = "$NEW" ]
}
@test "pending failed cancelled or skipped latest CI selects older proven main" {
  for conclusion in failure cancelled skipped pending; do
    fixture_run "$NEW" completed "$conclusion"
    run select_sha
    [ "$status" -eq 0 ]
    [ "$output" = "$OLD" ]
  done
}
@test "pending rerun cannot reuse an earlier successful run" {
  jq '.total_count=2 | .workflow_runs += [.workflow_runs[0] | .id=23 | .run_number=5 | .status="in_progress" | .conclusion=null]' "$CI_FIXTURE/runs-$NEW" > "$TMP/new"
  mv "$TMP/new" "$CI_FIXTURE/runs-$NEW"
  run select_sha
  [ "$status" -eq 0 ]
  [ "$output" = "$OLD" ]
}
@test "wrong SHA branch event or unrelated workflow success does not qualify" {
  for mutation in '.head_sha="cccccccccccccccccccccccccccccccccccccccc"' '.head_branch="feature"' '.event="pull_request"' '.workflow_id=999'; do
    fixture_run "$NEW" completed success
    jq ".workflow_runs[0] |= ($mutation)" "$CI_FIXTURE/runs-$NEW" > "$TMP/new"
    mv "$TMP/new" "$CI_FIXTURE/runs-$NEW"
    run select_sha
    [ "$status" -eq 0 ]
    [ "$output" = "$OLD" ]
  done
}
@test "inaccessible CI aborts instead of silently selecting older commit" {
  rm "$CI_FIXTURE/runs-$NEW"
  run select_sha
  [ "$status" -ne 0 ]
  [[ "$output" != *"$OLD"* ]]
}
@test "missing disabled or substituted required workflow fails closed" {
  for mutation in '.state="disabled_manually"' '.id=999' '.path=".github/workflows/renovate.yml"'; do
    printf '%s\n' '{"id":330421083,"name":"tests","path":".github/workflows/tests.yml","state":"active"}' | jq "$mutation" > "$CI_FIXTURE/workflow"
    run select_sha
    [ "$status" -ne 0 ]
  done
  rm "$CI_FIXTURE/workflow"
  run select_sha
  [ "$status" -ne 0 ]
}
@test "malformed and truncated API responses never produce a selected version" {
  for invalid in '{"workflow_runs":null}' 'not JSON' '{"total_count":101,"workflow_runs":[]}'; do
    printf '%s\n' "$invalid" > "$CI_FIXTURE/runs-$NEW"
    run select_sha
    [ "$status" -ne 0 ]
    [[ "$output" != *"$OLD"* ]]
  done
}
@test "no green candidate fails without claiming success" {
  printf '%s\n' '{"total_count":0,"workflow_runs":[]}' > "$CI_FIXTURE/runs-$NEW"
  fixture_run "$OLD" completed failure
  run select_sha
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
  run select_sha
  [ "$status" -eq 0 ]
  [ "$(git status --porcelain)" = "$before" ]
  [ "$(cat untracked)" = 'local work' ]
}
