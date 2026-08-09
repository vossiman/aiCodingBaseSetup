#!/usr/bin/env bats
#
# Unit tests for configs/claude/hooks/llmwiki-distill.sh — the async Stop-hook
# launcher for the background LLMWiki distiller. `claude` is stubbed: it
# records its argv to $HOME/claude-args and snapshots the slice file (the real
# hook deletes the slice after the run). Time and transcripts are plain files
# under a temp HOME, so tests never touch real state.

setup() {
  : "${BLUEPRINT_ROOT:?unset — run via tests/bats/run.sh}"
  HOOK="$BLUEPRINT_ROOT/configs/claude/hooks/llmwiki-distill.sh"
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  unset LLMWIKI_DISTILLER LLMWIKI_NUDGE_INTERVAL LLMWIKI_MIN_DELTA_BYTES

  mkdir -p "$TMPDIR/stubs"
  cat > "$TMPDIR/stubs/claude" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" > "$HOME/claude-args"
printf '%s\n' "${LLMWIKI_DISTILLER:-}" > "$HOME/claude-env-guard"
cp "$HOME"/.cache/aicoding/llmwiki-nudge/slices/* "$HOME/slice-copy" 2>/dev/null || true
exit "${CLAUDE_STUB_EXIT:-0}"
STUB
  chmod +x "$TMPDIR/stubs/claude"
  export PATH="$TMPDIR/stubs:$PATH"

  STATE_DIR="$HOME/.cache/aicoding/llmwiki-nudge"
}

teardown() { case "${TMPDIR:-}" in */tmp.*) rm -rf "$TMPDIR" ;; esac }

# mktranscript <path> <bytes> [char] — deterministic transcript of exact size.
mktranscript() {
  head -c "$2" /dev/zero | tr '\0' "${3:-x}" > "$1"
}

# hookjson <transcript> <session_id> — minimal Stop-hook stdin payload.
hookjson() {
  jq -nc --arg t "$1" --arg s "$2" --arg c "$TMPDIR" \
    '{transcript_path:$t, session_id:$s, cwd:$c}'
}

launched() { [ -f "$HOME/claude-args" ]; }

@test "llmwiki-distill: recursion guard exits silently" {
  mktranscript "$TMPDIR/t.jsonl" 8192
  LLMWIKI_DISTILLER=1 run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s1)"
  [ "$status" -eq 0 ]
  ! launched
}

@test "llmwiki-distill: missing transcript is a no-op" {
  run bash "$HOOK" <<< "$(hookjson "$TMPDIR/absent.jsonl" s1)"
  [ "$status" -eq 0 ]
  ! launched
}

@test "llmwiki-distill: first eligible stop launches with agent, settings, env guard" {
  mktranscript "$TMPDIR/t.jsonl" 8192
  run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s1)"
  [ "$status" -eq 0 ]
  launched
  grep -qx -- '--agent' "$HOME/claude-args"
  grep -qx 'llmwiki-distiller' "$HOME/claude-args"
  grep -q 'disableAllHooks' "$HOME/claude-args"
  grep -qx '1' "$HOME/claude-env-guard"
  # full transcript sliced (offset 0)
  [ "$(wc -c < "$HOME/slice-copy")" -eq 8192 ]
  # state stamped: offset == size, throttle file exists
  [ "$(cat "$STATE_DIR/offsets/s1")" -eq 8192 ]
  slug_file=$(ls "$STATE_DIR" | grep -v offsets | grep -v slices | head -1)
  [ -n "$slug_file" ]
}

@test "llmwiki-distill: inside throttle window does not launch" {
  mktranscript "$TMPDIR/t.jsonl" 8192
  run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s1)"
  launched
  rm -f "$HOME/claude-args"
  mktranscript "$TMPDIR/t.jsonl" 65536   # plenty of delta, but window not elapsed
  run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s1)"
  [ "$status" -eq 0 ]
  ! launched
}

@test "llmwiki-distill: below-threshold delta skips AND leaves throttle unstamped" {
  mktranscript "$TMPDIR/t.jsonl" 8192
  export LLMWIKI_NUDGE_INTERVAL=0        # window always elapsed
  run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s1)"
  launched
  rm -f "$HOME/claude-args"
  slug_file=$(ls "$STATE_DIR" | grep -v offsets | grep -v slices | head -1)
  stamp_before=$(cat "$STATE_DIR/$slug_file")
  mktranscript "$TMPDIR/t.jsonl" 9000    # +808 bytes < 4096 default threshold
  sleep 1
  run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s1)"
  [ "$status" -eq 0 ]
  ! launched
  [ "$(cat "$STATE_DIR/$slug_file")" -eq "$stamp_before" ]
}

@test "llmwiki-distill: slice contains only bytes past the stored offset" {
  export LLMWIKI_NUDGE_INTERVAL=0
  { head -c 4096 /dev/zero | tr '\0' 'A'; head -c 8192 /dev/zero | tr '\0' 'B'; } \
    > "$TMPDIR/t.jsonl"
  mkdir -p "$STATE_DIR/offsets"
  printf '4096' > "$STATE_DIR/offsets/s1"
  run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s1)"
  [ "$status" -eq 0 ]
  launched
  [ "$(wc -c < "$HOME/slice-copy")" -eq 8192 ]
  ! grep -q 'A' "$HOME/slice-copy"
  [ "$(cat "$STATE_DIR/offsets/s1")" -eq 12288 ]
}

@test "llmwiki-distill: offset larger than transcript resets to full slice" {
  export LLMWIKI_NUDGE_INTERVAL=0
  mktranscript "$TMPDIR/t.jsonl" 8192
  mkdir -p "$STATE_DIR/offsets"
  printf '999999' > "$STATE_DIR/offsets/s1"
  run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s1)"
  [ "$status" -eq 0 ]
  launched
  [ "$(wc -c < "$HOME/slice-copy")" -eq 8192 ]
}

@test "llmwiki-distill: claude failure still exits 0 and cleans the slice" {
  mktranscript "$TMPDIR/t.jsonl" 8192
  CLAUDE_STUB_EXIT=7 run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s1)"
  [ "$status" -eq 0 ]
  launched
  [ -z "$(ls -A "$STATE_DIR/slices" 2>/dev/null)" ]
}

@test "llmwiki-distill: missing claude CLI is a no-op that leaves state unstamped" {
  mktranscript "$TMPDIR/t.jsonl" 8192
  PATH="/usr/bin:/bin" run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s1)"
  [ "$status" -eq 0 ]
  ! launched
  [ ! -f "$STATE_DIR/offsets/s1" ]
}
