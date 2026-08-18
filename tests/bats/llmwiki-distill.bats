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
  unset MEMORY_LANES_SHIP MEMORY_LANES_SHIP_KEY MEMORY_LANES_SHIP_TARGET

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

# pad — 8KB of filler so the delta always clears MIN_DELTA. Plain 'q' runs
# match no redaction rule (single character class, no digits).
pad() { head -c 8192 /dev/zero | tr '\0' 'q'; printf '\n'; }

@test "llmwiki-distill: tee redacts pattern-shaped and literal secrets" {
  export LLMWIKI_NUDGE_INTERVAL=0
  # Literal-only value: 32 lowercase hex. Below the 48-hex rule, no uppercase
  # (so the entropy layer cannot see it), planted as bare prose (so the
  # credential-keyword rule cannot see it). ONLY the literal layer catches it,
  # which is what makes this assertion able to fail.
  literal="deadbeefcafebabefeedface12345678"
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

# Decision (a): an ABSENT secrets file is not a failure — a machine with no
# secrets file has no literal values to leak, so the tee proceeds with the
# pattern + entropy layers only. This test pins that, and simultaneously pins
# that the literal-only fixture above really is literal-only: without the
# secrets file the very same value survives.
@test "llmwiki-distill: no secrets file — tee proceeds, patterns still redact, literals do not" {
  export LLMWIKI_NUDGE_INTERVAL=0
  [ ! -e "$HOME/.aicodingsetup/.secrets.env" ]
  literal="deadbeefcafebabefeedface12345678"
  {
    printf 'router value %s inline\n' "$literal"
    printf 'gh token ghp_abcdefghijklmnopqrstuvwxyz012345 in a log line\n'
    pad
  } > "$TMPDIR/t.jsonl"
  run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s3)"
  [ "$status" -eq 0 ]
  launched
  [ -f "$(SPOOL)/s3-0" ]
  # Pattern layer still active.
  if grep -q 'ghp_abcdefghijklmnopqrstuvwxyz012345' "$(SPOOL)/s3-0"; then false; fi
  # No secrets file => no literal layer => the literal-only value survives.
  # (If this ever fails, some other layer now covers it and the literal test
  # above has gone vacuous.)
  grep -qF "$literal" "$(SPOOL)/s3-0"
}

@test "llmwiki-distill: secrets file present but unreadable — fail closed, nothing spooled" {
  if [ "$(id -u)" -eq 0 ]; then
    skip "running as root: chmod 000 does not make a file unreadable"
  fi
  export LLMWIKI_NUDGE_INTERVAL=0
  mkdir -p "$HOME/.aicodingsetup"
  printf 'MEMORY_ROUTER_TOKEN=deadbeefcafebabefeedface12345678\n' \
    > "$HOME/.aicodingsetup/.secrets.env"
  chmod 000 "$HOME/.aicodingsetup/.secrets.env"

  { printf 'router value deadbeefcafebabefeedface12345678 inline\n'; pad; } \
    > "$TMPDIR/t.jsonl"
  run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s3u)"

  # Fail closed means "no spool file", never "the hook fails".
  [ "$status" -eq 0 ]
  launched
  [ ! -e "$(SPOOL)/s3u-0" ]
  [ "$(find "$(SPOOL)" -maxdepth 1 -type f 2>/dev/null | wc -l)" -eq 0 ]
  # The distiller path is untouched: state still stamped.
  [ -f "$STATE_DIR/offsets/s3u" ]
}

@test "llmwiki-distill: partially parsed secrets file — fail closed, nothing spooled" {
  export LLMWIKI_NUDGE_INTERVAL=0
  mkdir -p "$HOME/.aicodingsetup"
  # `read` silently drops the trailing NUL, so the shell sees a 7-char value
  # (below the literal floor, no rule emitted) while the independent counter
  # sees the 8 bytes actually on disk and expects one rule. The counts diverge
  # => the literal layer is untrustworthy => nothing is spooled.
  printf 'MANGLED=abcdefg\000\n' > "$HOME/.aicodingsetup/.secrets.env"
  { printf 'value abcdefg inline\n'; pad; } > "$TMPDIR/t.jsonl"
  run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s3c)"
  [ "$status" -eq 0 ]
  launched
  [ ! -e "$(SPOOL)/s3c-0" ]
  [ "$(find "$(SPOOL)" -maxdepth 1 -type f 2>/dev/null | wc -l)" -eq 0 ]
}

@test "llmwiki-distill: tee redacts JSON-escaped forms of literal secrets" {
  export LLMWIKI_NUDGE_INTERVAL=0
  quoted='abc"def12345'
  slashed='abc\def12345'
  mkdir -p "$HOME/.aicodingsetup"
  { printf 'Q_TOKEN=%s\n' "$quoted"; printf 'S_TOKEN=%s\n' "$slashed"; } \
    > "$HOME/.aicodingsetup/.secrets.env"

  # Transcripts are JSONL: a `"` is stored as \" and a `\` as \\.
  {
    printf 'line one %s tail\n' 'abc\"def12345'
    printf 'line two %s tail\n' 'abc\\def12345'
    pad
  } > "$TMPDIR/t.jsonl"

  run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s3j)"
  [ "$status" -eq 0 ]
  spooled="$(SPOOL)/s3j-0"
  [ -f "$spooled" ]
  if grep -qF 'abc\"def12345' "$spooled"; then false; fi
  if grep -qF 'abc\\def12345' "$spooled"; then false; fi
  grep -q 'REDACTED' "$spooled"
}

@test "llmwiki-distill: literal values containing ERE metacharacters are matched literally" {
  export LLMWIKI_NUDGE_INTERVAL=0
  meta='a.b*c[d]e+f$g12345'
  mkdir -p "$HOME/.aicodingsetup"
  printf 'META_TOKEN=%s\n' "$meta" > "$HOME/.aicodingsetup/.secrets.env"
  {
    printf 'exact %s here\n' "$meta"
    printf 'regexy aXbYcZdWeVfUg12345 here\n'
    pad
  } > "$TMPDIR/t.jsonl"
  run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s3m)"
  [ "$status" -eq 0 ]
  spooled="$(SPOOL)/s3m-0"
  [ -f "$spooled" ]
  if grep -qF "$meta" "$spooled"; then false; fi
  # The metacharacters were escaped, not interpreted: a string the value would
  # match only as a REGEX survives untouched.
  grep -q 'aXbYcZdWeVfUg12345' "$spooled"
}

@test "llmwiki-distill: literal layer floor is 8 chars (7 survives, 8 redacted)" {
  export LLMWIKI_NUDGE_INTERVAL=0
  mkdir -p "$HOME/.aicodingsetup"
  { printf 'SEVEN=qwertyu\n'; printf 'EIGHT=zxcvbnml\n'; } \
    > "$HOME/.aicodingsetup/.secrets.env"
  { printf 'seven qwertyu inline\neight zxcvbnml inline\n'; pad; } \
    > "$TMPDIR/t.jsonl"
  run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s3f)"
  [ "$status" -eq 0 ]
  spooled="$(SPOOL)/s3f-0"
  [ -f "$spooled" ]
  # Characterization: below the floor, values are deliberately NOT redacted —
  # a short value would shred ordinary prose.
  grep -q 'seven qwertyu inline' "$spooled"
  if grep -q 'zxcvbnml' "$spooled"; then false; fi
}

@test "llmwiki-distill: spool dir is 0700 and the spooled slice is 0600" {
  export LLMWIKI_NUDGE_INTERVAL=0
  mktranscript "$TMPDIR/t.jsonl" 8192 'z'
  run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s3p)"
  [ "$status" -eq 0 ]
  [ -f "$(SPOOL)/s3p-0" ]
  [ "$(stat -c %a "$(SPOOL)")" = "700" ]
  [ "$(stat -c %a "$(SPOOL)/s3p-0")" = "600" ]
}

@test "llmwiki-distill: tee prunes orphan temp files older than 60 minutes" {
  export LLMWIKI_NUDGE_INTERVAL=0
  mkdir -p "$(SPOOL)"
  : > "$(SPOOL)/.tmp-oldorphan"
  touch -d '2 hours ago' "$(SPOOL)/.tmp-oldorphan"
  : > "$(SPOOL)/.tmp-freshorphan"
  mktranscript "$TMPDIR/t.jsonl" 8192 'z'
  run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s3t)"
  [ "$status" -eq 0 ]
  [ -f "$(SPOOL)/s3t-0" ]
  [ ! -e "$(SPOOL)/.tmp-oldorphan" ]
  # An in-flight temp file from a concurrent run must survive.
  [ -f "$(SPOOL)/.tmp-freshorphan" ]
}

@test "llmwiki-distill: token-family rules redact long hex and base64 but spare git SHAs" {
  export LLMWIKI_NUDGE_INTERVAL=0
  hex64="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  sha40="8f2a1c9d0e4b7a6f3c5d2e1b0a9f8e7d6c5b4a39"
  aws="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
  {
    printf 'bare hex %s inline\n' "$hex64"
    printf 'commit %s landed\n' "$sha40"
    printf 'blob %s inline\n' "$aws"
    pad
  } > "$TMPDIR/t.jsonl"
  run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s3k)"
  [ "$status" -eq 0 ]
  spooled="$(SPOOL)/s3k-0"
  [ -f "$spooled" ]
  if grep -qF "$hex64" "$spooled"; then false; fi
  if grep -qF "$aws" "$spooled"; then false; fi
  # 40-char lowercase hex is a git SHA, not a secret — the 48-char floor on
  # the hex rule exists precisely to keep these readable.
  grep -qF "$sha40" "$spooled"
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

# --- memory-lanes slice ship (rsync over ssh, restricted key) --------------
# _ml_ship runs right after _ml_tee and best-effort-ships whatever is sitting
# in the spool to vossisrv. Network is never touched here: rsync is stubbed.

@test "ml_ship invokes rsync with remove-source-files and the ship key" {
  export LLMWIKI_NUDGE_INTERVAL=0
  mkdir -p "$HOME/.aicodingsetup"
  printf 'fake-restricted-key' > "$HOME/.aicodingsetup/memory-lanes-ship"

  cat > "$TMPDIR/stubs/rsync" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" >> "$HOME/rsync-args"
printf 'x\n' >> "$HOME/rsync-calls"
exit 0
STUB
  chmod +x "$TMPDIR/stubs/rsync"

  mktranscript "$TMPDIR/t.jsonl" 8192 'z'
  run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s6)"
  [ "$status" -eq 0 ]

  # called exactly once
  [ "$(wc -l < "$HOME/rsync-calls")" -eq 1 ]
  grep -qx -- '--remove-source-files' "$HOME/rsync-args"
  grep -qxF -- "--exclude=.tmp-*" "$HOME/rsync-args"
  grep -q "$HOME/.aicodingsetup/memory-lanes-ship" "$HOME/rsync-args"
  grep -q "$(SPOOL)/" "$HOME/rsync-args"
}

@test "ml_ship is silent no-op when the ship key is absent" {
  export LLMWIKI_NUDGE_INTERVAL=0
  export MEMORY_LANES_SHIP_KEY="$HOME/no-such-key"

  cat > "$TMPDIR/stubs/rsync" <<'STUB'
#!/bin/sh
printf 'x\n' >> "$HOME/rsync-calls"
exit 0
STUB
  chmod +x "$TMPDIR/stubs/rsync"

  mktranscript "$TMPDIR/t.jsonl" 8192 'z'
  run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s7)"
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/rsync-calls" ]
  # slice stayed in the spool — nothing shipped it away
  [ -f "$(SPOOL)/s7-0" ]
}

@test "ml_ship failure leaves the slice in the spool and does not fail the hook" {
  export LLMWIKI_NUDGE_INTERVAL=0
  mkdir -p "$HOME/.aicodingsetup"
  printf 'fake-restricted-key' > "$HOME/.aicodingsetup/memory-lanes-ship"

  cat > "$TMPDIR/stubs/rsync" <<'STUB'
#!/bin/sh
printf 'x\n' >> "$HOME/rsync-calls"
exit 30
STUB
  chmod +x "$TMPDIR/stubs/rsync"

  mktranscript "$TMPDIR/t.jsonl" 8192 'z'
  run bash "$HOOK" <<< "$(hookjson "$TMPDIR/t.jsonl" s8)"
  [ "$status" -eq 0 ]
  [ -f "$HOME/rsync-calls" ]
  [ -f "$(SPOOL)/s8-0" ]
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
  grep -qi 'never edit CLAUDE.md' "$AGENT_DEF"
  # 2026-08-17 revision: ALL lessons land in the wiki (project-scoped ones
  # on wiki/<project>.md); the wiki is the only repo the agent may commit
  # to, and the untracked in-repo note is only the wiki-unreachable
  # fallback. Guards against regressing to project-repo pushes, which can
  # trigger CI/CD deploys (dataEnv incident 2026-08-17).
  grep -q 'wiki/<project>.md' "$AGENT_DEF"
  grep -qi 'the ONLY repo you may run' "$AGENT_DEF"
  grep -q 'docs/notes/' "$AGENT_DEF"
  if grep -q 'worktree add' "$AGENT_DEF"; then false; fi
  if grep -q 'push origin HEAD' "$AGENT_DEF"; then false; fi
  if grep -q 'direct-push-ok' "$AGENT_DEF"; then false; fi
}
