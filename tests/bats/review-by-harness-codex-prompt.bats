#!/usr/bin/env bats
# The codex adapter runs review mode with the shared review prompt and the
# diff range in the prompt, never `--base` (which drops a custom prompt).

bats_require_minimum_version 1.5.0

setup() {
  : "${BLUEPRINT_ROOT:?unset, run via tests/bats/run.sh}"
  TMPDIR=$(mktemp -d)
  mkdir -p "$TMPDIR/bin" "$TMPDIR/out" "$TMPDIR/wt"
  cat > "$TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CODEX_ARGS_FILE"
exit 0
STUB
  chmod +x "$TMPDIR/bin/codex"
  export CODEX_ARGS_FILE="$TMPDIR/args"
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "codex adapter: review passes the shared prompt and the range, not --base" {
  PATH="$TMPDIR/bin:$PATH" run bash "$BLUEPRINT_ROOT/skills/review-by-harness/harnesses/codex.sh" review "$TMPDIR/wt" abc123 "$TMPDIR/out"
  [ "$status" -eq 0 ]
  run grep -qx -- '--base' "$TMPDIR/args"
  [ "$status" -eq 1 ]
  grep -q 'abc123' "$TMPDIR/args"
  grep -q 'git diff abc123...HEAD' "$TMPDIR/args"
  grep -q 'Documentation, specs, plans, prompts and configuration are in scope' "$TMPDIR/args"
  grep -qx 'review' "$TMPDIR/args"
}

@test "review prompt: prose claims are in scope and no-code is not a result" {
  grep -q 'Documentation, specs, plans, prompts and configuration are in scope' "$BLUEPRINT_ROOT/skills/review-by-harness/prompts/review.md"
  grep -q 'is not a review result' "$BLUEPRINT_ROOT/skills/review-by-harness/prompts/review.md"
}
