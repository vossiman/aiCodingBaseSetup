#!/usr/bin/env bats
# bin/redact-sessions: scrub secrets-file values out of transcript files on
# disk and report each hit. Fixtures are dummy values under a temp HOME; the
# real secrets file is never read by these tests.

bats_require_minimum_version 1.5.0

setup() {
  : "${BLUEPRINT_ROOT:?unset, run via tests/bats/run.sh}"
  RS="$BLUEPRINT_ROOT/bin/redact-sessions"
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  mkdir -p "$HOME/.aicodingsetup" "$HOME/.claude/projects/-p/s1/subagents" \
           "$HOME/.codex/sessions/2026/09/07" "$HOME/.cursor/chats/w/c"
  SECRETS="$HOME/.aicodingsetup/.secrets.env"
  STATE="$HOME/.claude/state/redact-sessions"
  unset REDACT_SESSIONS_STATE REDACT_QUIET_SECONDS REDACT_SESSIONS_RACE_HOOK
  export AICODING_SECRETS_FILE="$SECRETS"
  V1="deadbeefcafebabefeedface12345678"
  V2="quickbrownfoxjumpsoverlazydogs99"
  printf 'OPENROUTER_API_KEY=%s\nPOSTGRES_PASSWORD=%s\n' "$V1" "$V2" > "$SECRETS"
}

teardown() { case "${TMPDIR:-}" in */tmp.*) rm -rf "$TMPDIR" ;; esac }

# old <file>: make a file look quiet (mtime 10 minutes ago).
old() { touch -d '-10 minutes' "$1"; }

@test "incident 1: docker compose config output in a Bash tool result" {
  local f="$HOME/.claude/projects/-p/s1.jsonl"
  printf '{"type":"tool_result","content":"services:\\n  api:\\n    environment:\\n      OPENROUTER_API_KEY: %s\\n"}\n' "$V1" > "$f"
  printf '{"type":"text","text":"ordinary prose"}\n' >> "$f"
  run --separate-stderr "$RS" --now "$f"
  [ "$status" -eq 0 ]
  [[ "$(cat "$f")" != *"$V1"* ]]
  grep -q '\[REDACTED:OPENROUTER_API_KEY\]' "$f"
  grep -q 'ordinary prose' "$f"
  [ "$(wc -l < "$f")" -eq 2 ]
  [[ "$stderr" != *"$V1"* ]]
}

@test "incident 2: value inside a base64 blob, all three alignments" {
  local f="$HOME/.claude/projects/-p/s1.jsonl"
  local b0 b1 b2 b3 b4
  b0="$(printf 'ENV=%s' "$V1" | base64 -w0)"
  b1="$(printf 'KEY=%s\n' "$V1" | base64 -w0)"
  b2="$(printf 'OPENROUTER_API_KEY=%s' "$V1" | base64 -w0)"
  b3="$(printf '%s' "$V1" | base64 -w0)"
  b4="$(printf 'XX%s' "$V1" | base64 -w0)"
  printf '{"notification":"%s %s %s %s %s"}\n' "$b0" "$b1" "$b2" "$b3" "$b4" > "$f"
  "$RS" --now "$f"
  for b in "$b0" "$b1" "$b2" "$b3" "$b4"; do
    [[ "$(cat "$f")" != *"$b"* ]]
  done
  grep -q 'REDACTED:OPENROUTER_API_KEY' "$f"
}

@test "incident 3: subagent transcript with an env-file dump, every key named" {
  local f="$HOME/.claude/projects/-p/s1/subagents/agent-1.jsonl"
  printf '{"content":"OPENROUTER_API_KEY=%s\\nPOSTGRES_PASSWORD=%s\\n"}\n' "$V1" "$V2" > "$f"
  "$RS" --now "$f"
  [[ "$(cat "$f")" != *"$V1"* ]]
  [[ "$(cat "$f")" != *"$V2"* ]]
  grep -q 'key=OPENROUTER_API_KEY count=1' "$STATE/log"
  grep -q 'key=POSTGRES_PASSWORD count=1' "$STATE/log"
  grep -q 'session=s1' "$STATE/log"
  grep -qx 'OPENROUTER_API_KEY' "$STATE/pending"
  grep -qx 'POSTGRES_PASSWORD' "$STATE/pending"
}

@test "json-escaped variant is caught" {
  printf 'GH_TOKEN=ab"cd\\efghijklmnop\n' > "$SECRETS"
  local f="$HOME/.codex/sessions/2026/09/07/r.jsonl"
  printf '{"text":"token ab\\"cd\\\\efghijklmnop end"}\n' > "$f"
  "$RS" --now "$f"
  grep -q 'REDACTED:GH_TOKEN' "$f"
  grep -q '"text":"token \[REDACTED:GH_TOKEN\] end"' "$f"
}

@test "clean file: content, mtime and inode untouched, nothing logged" {
  local f="$HOME/.claude/projects/-p/s1.jsonl"
  printf '{"text":"nothing secret here"}\n' > "$f"; old "$f"
  local before; before="$(stat -c '%i %Y %s' "$f")"
  "$RS" --now "$f"
  [ "$(stat -c '%i %Y %s' "$f")" = "$before" ]
  if [ -e "$STATE/log" ] && grep -q ' hit ' "$STATE/log"; then false; fi
  [ ! -e "$STATE/pending" ]
}

@test "atomic rewrite: mode preserved, no temp file left behind" {
  local f="$HOME/.claude/projects/-p/s1.jsonl"
  printf '{"text":"%s"}\n' "$V1" > "$f"; chmod 600 "$f"
  "$RS" --now "$f"
  [ "$(stat -c '%a' "$f")" = "600" ]
  [ "$(ls -A "$HOME/.claude/projects/-p" | wc -l)" -eq 2 ]
}

@test "racing append: swap refused, retry scrubs, appended line survives" {
  local f="$HOME/.claude/projects/-p/s1.jsonl"
  printf '{"text":"%s"}\n' "$V1" > "$f"
  cat > "$HOME/race.sh" <<EOF
#!/bin/sh
[ -e "$HOME/raced" ] && exit 0
touch "$HOME/raced"
sleep 1
printf '{"text":"late append"}\n' >> "$f"
EOF
  chmod +x "$HOME/race.sh"
  REDACT_SESSIONS_RACE_HOOK="$HOME/race.sh" run "$RS" --now "$f"
  [ "$status" -eq 0 ]
  grep -q 'late append' "$f"
  [[ "$(cat "$f")" != *"$V1"* ]]
  grep -q 'swap refused' "$STATE/log"
}

@test "fail closed: unreadable secrets file exits 3, touches nothing, flags it" {
  if [ "$(id -u)" -eq 0 ]; then skip "root can read a chmod 000 file"; fi
  local f="$HOME/.claude/projects/-p/s1.jsonl"
  printf '{"text":"%s"}\n' "$V1" > "$f"
  chmod 000 "$SECRETS"
  run --separate-stderr "$RS" --now "$f"
  [ "$status" -eq 3 ]
  grep -q "$V1" "$f"
  grep -qx 'SECRETS_FILE_UNREADABLE' "$STATE/pending"
  [[ "$stderr" != *"$V1"* ]]
}

@test "short value (7 chars) is not redacted; 11-char value has no base64 rule" {
  printf 'A=abcdefg\nB=abcdefghijk\n' > "$SECRETS"
  local f="$HOME/.claude/projects/-p/s1.jsonl"
  local b; b="$(printf '%s' "abcdefghijk" | base64 -w0)"
  printf 'abcdefg and abcdefghijk and %s\n' "$b" > "$f"
  "$RS" --now "$f"
  grep -q '^abcdefg and \[REDACTED:B\] and ' "$f"
  grep -q "$b" "$f"
}
