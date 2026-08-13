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
  unset MEMORY_LANES_TEE MEMORY_LANES_SPOOL

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
  if launched; then false; fi
}

@test "llmwiki-distill: missing transcript is a no-op" {
  run bash "$HOOK" <<< "$(hookjson "$TMPDIR/absent.jsonl" s1)"
  [ "$status" -eq 0 ]
  if launched; then false; fi
}

@test "llmwiki-distill: first eligible stop launches with agent, settings, env guard" {
  mktranscript "$TMPDIR/t.jsonl" 8192
  run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s1)"
  [ "$status" -eq 0 ]
  launched
  grep -qx -- '--agent' "$HOME/claude-args"
  grep -qx 'llmwiki-distiller' "$HOME/claude-args"
  grep -q 'disableAllHooks' "$HOME/claude-args"
  grep -q '"allow"' "$HOME/claude-args"
  grep -q 'Bash(git:\*)' "$HOME/claude-args"
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
  if launched; then false; fi
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
  if launched; then false; fi
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
  if grep -q 'A' "$HOME/slice-copy"; then false; fi
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
  if launched; then false; fi
  [ ! -f "$STATE_DIR/offsets/s1" ]
}

@test "llmwiki-distill: slice creation failure does not stamp state" {
  export LLMWIKI_NUDGE_INTERVAL=0   # Make throttle window always pass
  mktranscript "$TMPDIR/t.jsonl" 8192
  chmod 000 "$TMPDIR/t.jsonl"        # Unreadable — stat works, tail fails
  run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s1)"
  [ "$status" -eq 0 ]               # Hook exits 0 despite tail failure
  if launched; then false; fi   # claude never launched
  [ ! -f "$STATE_DIR/offsets/s1" ] # offset file not stamped
  # Verify no throttle files created (only offsets/ and slices/ dirs)
  [ "$(find "$STATE_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l)" -eq 0 ]
}

# --- memory-lanes slice tee ------------------------------------------------
# The tee is additive: it copies a REDACTED slice to the spool as
# <session-id>-<offset>. Nothing here may change distiller/offset/throttle
# behaviour, and no failure may make the hook exit non-zero.

SPOOL() { printf '%s' "$HOME/.local/state/memory-lanes/inbox"; }

@test "llmwiki-distill: tee spools the slice as <session>-<offset>" {
  export LLMWIKI_NUDGE_INTERVAL=0
  { head -c 4096 /dev/zero | tr '\0' 'A'; head -c 8192 /dev/zero | tr '\0' 'B'; } \
    > "$TMPDIR/t.jsonl"
  mkdir -p "$STATE_DIR/offsets"
  printf '4096' > "$STATE_DIR/offsets/s1"
  run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s1)"
  [ "$status" -eq 0 ]
  launched
  [ -f "$(SPOOL)/s1-4096" ]
  # Same window as the distiller slice: only the post-offset bytes.
  grep -q 'B' "$(SPOOL)/s1-4096"
  if grep -q 'A' "$(SPOOL)/s1-4096"; then false; fi
  # No stray temp files left behind.
  [ "$(find "$(SPOOL)" -name '.tmp-*' | wc -l)" -eq 0 ]
}

@test "llmwiki-distill: tee redacts pattern-shaped and literal secrets" {
  export LLMWIKI_NUDGE_INTERVAL=0
  literal="zz11aaBB22ccDD33eeFF44ggHH55iiJJ"
  mkdir -p "$HOME/.aicodingsetup"
  printf 'MEMORY_ROUTER_TOKEN=%s\n' "$literal" > "$HOME/.aicodingsetup/.secrets.env"

  {
    printf 'ordinary prose about the tmux server that must survive\n'
    printf 'gh token ghp_abcdefghijklmnopqrstuvwxyz012345 in a log line\n'
    printf 'openai key sk-abcdefghijklmnopqrstuvwx here\n'
    printf 'FOO_TOKEN=abcdef123456\n'
    printf 'router token %s inline\n' "$literal"
    head -c 8192 /dev/zero | tr '\0' 'q'; printf '\n'
  } > "$TMPDIR/t.jsonl"

  run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s2)"
  [ "$status" -eq 0 ]
  spooled="$(SPOOL)/s2-0"
  [ -f "$spooled" ]
  if grep -q 'ghp_abcdefghijklmnopqrstuvwxyz012345' "$spooled"; then false; fi
  if grep -q 'sk-abcdefghijklmnopqrstuvwx' "$spooled"; then false; fi
  if grep -q 'abcdef123456' "$spooled"; then false; fi
  if grep -qF "$literal" "$spooled"; then false; fi
  grep -q 'REDACTED' "$spooled"
  # Key names and ordinary prose survive — the slice stays useful.
  grep -q 'ordinary prose about the tmux server that must survive' "$spooled"
  grep -q 'FOO_TOKEN=' "$spooled"
  # The read-only secrets file is never rewritten.
  grep -qx "MEMORY_ROUTER_TOKEN=$literal" "$HOME/.aicodingsetup/.secrets.env"
}

@test "llmwiki-distill: tee works with no secrets file present" {
  export LLMWIKI_NUDGE_INTERVAL=0
  [ ! -e "$HOME/.aicodingsetup/.secrets.env" ]
  mktranscript "$TMPDIR/t.jsonl" 8192 'z'
  run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s3)"
  [ "$status" -eq 0 ]
  launched
  [ -f "$(SPOOL)/s3-0" ]
}

@test "llmwiki-distill: unusable spool dir still exits 0 and still runs the distiller" {
  export LLMWIKI_NUDGE_INTERVAL=0
  # A regular file where the spool's parent dir must be: mkdir -p can never
  # succeed. (chmod 000 would be a no-op for a root CI runner.)
  printf 'not a directory' > "$TMPDIR/blocked"
  export MEMORY_LANES_SPOOL="$TMPDIR/blocked/inbox"
  mktranscript "$TMPDIR/t.jsonl" 8192
  run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s4)"
  [ "$status" -eq 0 ]
  launched
  [ ! -e "$TMPDIR/blocked/inbox" ]
  [ "$(cat "$STATE_DIR/offsets/s4")" -eq 8192 ]
}

@test "llmwiki-distill: MEMORY_LANES_TEE=0 disables the tee" {
  export LLMWIKI_NUDGE_INTERVAL=0 MEMORY_LANES_TEE=0
  mktranscript "$TMPDIR/t.jsonl" 8192
  run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s5)"
  [ "$status" -eq 0 ]
  launched
  [ ! -d "$(SPOOL)" ]
}

@test "llmwiki-distiller agent: frontmatter name/model match the hook contract" {
  AGENT_DEF="$BLUEPRINT_ROOT/configs/claude/agents/llmwiki-distiller.md"
  [ -f "$AGENT_DEF" ]
  head -1 "$AGENT_DEF" | grep -qx -- '---'
  grep -qx 'name: llmwiki-distiller' "$AGENT_DEF"
  grep -qx 'model: sonnet' "$AGENT_DEF"
}

@test "llmwiki-distiller agent: encodes write-policy guardrails" {
  AGENT_DEF="$BLUEPRINT_ROOT/configs/claude/agents/llmwiki-distiller.md"
  grep -q 'homelab-wiki' "$AGENT_DEF"
  grep -q 'docs/notes/' "$AGENT_DEF"
  grep -qi 'never edit CLAUDE.md' "$AGENT_DEF"
  # 2026-08-12 revision: notes land on the default branch via a disposable
  # worktree, docs-only, no force-push, untracked fallback preserved.
  grep -q 'worktree add' "$AGENT_DEF"
  grep -qi 'never force-push' "$AGENT_DEF"
  grep -qi 'leave them untracked' "$AGENT_DEF"
}
