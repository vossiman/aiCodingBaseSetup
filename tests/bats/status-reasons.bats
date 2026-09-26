#!/usr/bin/env bats

setup() {
  : "${BLUEPRINT_ROOT:?run via tests/bats/run.sh}"
  TMP=$(mktemp -d)
  export HOME="$TMP/home" AICODING_STATE_DIR="$TMP/state"
  export AICODING_RESULTS_FILE="$TMP/state/update-results.json"
  export PYTHONDONTWRITEBYTECODE=1
  mkdir -p "$HOME"
  CHECK="$BLUEPRINT_ROOT/tests/status_reasons.py"
}

teardown() { rm -rf "$TMP"; }

@test "every literal reason in lib/ and bin/ has a catalog entry" {
  run python3 "$CHECK" static "$BLUEPRINT_ROOT"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "every catalog entry is still produced by lib/ or bin/" {
  run python3 "$CHECK" stale "$BLUEPRINT_ROOT"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "pattern markers in the catalog do not satisfy the stale check" {
  mkdir -p "$TMP/root/lib" "$TMP/root/bin"
  cat > "$TMP/root/lib/status-reasons.json" <<'EOF'
{"schema":1,"reasons":{},"patterns":{"dynamic_*":{"source_marker":"catalog_only_marker"}}}
EOF
  run python3 "$CHECK" stale "$TMP/root"
  [ "$status" -eq 1 ]
  [[ "$output" == *"dynamic_*"* ]]
}

@test "catalog entries are well formed" {
  jq -e '.schema == 1
    and ([.reasons[], .patterns[]] | all(
      (.kind | IN("ok", "wait", "action"))
      and (.meaning | type == "string" and length > 0)
      and (if .kind == "ok" then true else (.fix | type == "string" and length > 0) end)))
    and ([.patterns[] | .source_marker | type == "string" and length > 0] | all)' \
    "$BLUEPRINT_ROOT/lib/status-reasons.json"
}

@test "catalog text contains no em dashes" {
  if grep -q $'\xe2\x80\x94' "$BLUEPRINT_ROOT/lib/status-reasons.json"; then false; fi
}

@test "the audit wrapper list matches the wrappers the scanner discovers" {
  run python3 - "$BLUEPRINT_ROOT" <<'EOF'
import re, sys
from pathlib import Path
root = Path(sys.argv[1])
sys.path.insert(0, str(root / "tests"))
import status_reasons as s
found = set(s.recorders(root)) - set(s.BASE_RECORDERS)
text = (root / "lib/update-results.sh").read_text()
listed = set(re.search(r'_AICODING_REASON_WRAPPERS=" ([^"]*) "', text).group(1).split())
print("scanner:", sorted(found)); print("listed:", sorted(listed))
sys.exit(0 if found == listed else 1)
EOF
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "the scanner finds reasons forwarded through a wrapper alias" {
  mkdir -p "$TMP/root/lib" "$TMP/root/bin"
  cat > "$TMP/root/lib/x.sh" <<'EOF'
_my_wrapper() {
  local reason=$2
  aicoding_result_record "$1" blocked "" "$reason"
}
f() { _my_wrapper comp brand_new_reason; }
EOF
  echo '{"schema":1,"reasons":{},"patterns":{}}' > "$TMP/root/lib/status-reasons.json"
  run python3 "$CHECK" static "$TMP/root"
  [ "$status" -eq 1 ]
  [[ "$output" == *"brand_new_reason"* ]]
}

@test "the audit logs reasons recorded by lib code, not by test fixtures" {
  export AICODING_REASON_AUDIT="$TMP/audit"
  . "$BLUEPRINT_ROOT/lib/update-results.sh"
  . "$BLUEPRINT_ROOT/lib/update-components.sh"
  aicoding_result_record fixture failed "" fixture_only_reason
  _aicoding_record_deferred fixture blocked "" fixture_deferred_reason
  run aicoding_result_record fixture failed "" fixture_run_reason
  aicoding_update_bw() { :; }
  _aicoding_registration_recovery_clear() { return 0; }
  mkdir -p "$HOME/.local/bin"
  _aicoding_reconcile_claude_mcp_registration context7 mcp-context7 1.0.0 context7-mcp || true
  run cat "$AICODING_REASON_AUDIT"
  [[ "$output" == *"stable_launcher_missing"* ]]
  [[ "$output" != *"fixture_only_reason"* ]]
  [[ "$output" != *"fixture_deferred_reason"* ]]
  [[ "$output" != *"fixture_run_reason"* ]]
}

@test "the audit check fails on an uncatalogued recorded reason" {
  printf 'installed\nbrand_new_reason\ngo_runtime_unavailable\n' > "$TMP/audit"
  run python3 "$CHECK" audit "$TMP/audit" "$BLUEPRINT_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"brand_new_reason"* ]]
  [[ "$output" != *"go_runtime_unavailable"* ]]
}
