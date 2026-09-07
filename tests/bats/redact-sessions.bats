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
           "$HOME/.codex/sessions/2026/09/07" "$HOME/.cursor/chats/w/c" \
           "$HOME/.cursor/projects/ws/agent-transcripts/c1"
  SECRETS="$HOME/.aicodingsetup/.secrets.env"
  STATE="$HOME/.claude/state/redact-sessions"
  unset REDACT_SESSIONS_STATE REDACT_QUIET_SECONDS REDACT_SESSIONS_RACE_HOOK
  export AICODING_SECRETS_FILE="$SECRETS"
  export REDACT_SESSIONS_BIN="$RS" REDACT_SESSIONS_SYNC=1
  HOOK="$BLUEPRINT_ROOT/configs/claude/hooks/redact-sessions-hook.sh"
  PENDING="$BLUEPRINT_ROOT/configs/claude/hooks/redact-sessions-pending.sh"
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

@test "sweep: quiet file scrubbed, fresh file deferred, then scrubbed once quiet" {
  local q="$HOME/.claude/projects/-p/s1.jsonl" fr="$HOME/.codex/sessions/2026/09/07/r.jsonl"
  printf '{"text":"%s"}\n' "$V1" > "$q"; old "$q"
  printf '{"text":"%s"}\n' "$V2" > "$fr"
  "$RS" --sweep
  [[ "$(cat "$q")" != *"$V1"* ]]
  grep -q "$V2" "$fr"
  grep -qx "$fr" "$STATE/deferred"
  old "$fr"
  "$RS" --sweep
  [[ "$(cat "$fr")" != *"$V2"* ]]
  if grep -qx "$fr" "$STATE/deferred" 2>/dev/null; then false; fi
}

@test "sweep: --now ignores the quiet period" {
  local fr="$HOME/.claude/projects/-p/s1.jsonl"
  printf '{"text":"%s"}\n' "$V1" > "$fr"
  "$RS" --now "$fr"
  [[ "$(cat "$fr")" != *"$V1"* ]]
}

@test "sweep: covers every root including cursor json and subagents, not sqlite" {
  local a="$HOME/.claude/projects/-p/s1/subagents/x.jsonl"
  local b="$HOME/.codex/sessions/2026/09/07/r.jsonl"
  local c="$HOME/.cursor/chats/w/c/prompt_history.json"
  local d="$HOME/.cursor/chats/w/c/meta.json"
  local e="$HOME/.cursor/chats/w/c/store.db"
  for f in "$a" "$b" "$c" "$d" "$e"; do printf '%s\n' "$V1" > "$f"; old "$f"; done
  "$RS" --sweep
  for f in "$a" "$b" "$c" "$d"; do [[ "$(cat "$f")" != *"$V1"* ]]; done
  grep -q "$V1" "$e"
}

@test "sweep stamp: second sweep with nothing newer inspects nothing" {
  local q="$HOME/.claude/projects/-p/s1.jsonl"
  printf '{"text":"clean"}\n' > "$q"; old "$q"
  "$RS" --sweep
  local n1; n1="$(grep -c 'sweep inspected' "$STATE/log")"
  "$RS" --sweep
  grep -q 'sweep inspected=0 ' "$STATE/log"
  [ "$(grep -c 'sweep inspected' "$STATE/log")" -eq $((n1 + 1)) ]
}

@test "sweep: a deferred file is inspected even when older than the stamp" {
  local fr="$HOME/.claude/projects/-p/s1.jsonl"
  printf '{"text":"%s"}\n' "$V1" > "$fr"
  REDACT_QUIET_SECONDS=3600 "$RS" --sweep
  grep -qx "$fr" "$STATE/deferred"
  REDACT_QUIET_SECONDS=0 "$RS" --sweep
  [[ "$(cat "$fr")" != *"$V1"* ]]
}

@test "sweep: two parallel sweeps produce one scrub and no corruption" {
  local q="$HOME/.claude/projects/-p/s1.jsonl"
  printf '{"text":"%s"}\n{"text":"tail"}\n' "$V1" > "$q"; old "$q"
  "$RS" --sweep & "$RS" --sweep & wait
  [ "$(wc -l < "$q")" -eq 2 ]
  grep -q '"text":"tail"' "$q"
  [ "$(grep -c 'key=OPENROUTER_API_KEY' "$STATE/log")" -eq 1 ]
  [ "$(grep -cx 'OPENROUTER_API_KEY' "$STATE/pending")" -eq 1 ]
}

@test "--ack removes exactly that key" {
  mkdir -p "$STATE"; printf 'A\nB\n' > "$STATE/pending"
  "$RS" --ack A
  [ "$(cat "$STATE/pending")" = "B" ]
  "$RS" --ack ZZZ
  [ "$(cat "$STATE/pending")" = "B" ]
}

@test "sweep on an empty HOME is a silent no-op with exit 0" {
  rm -rf "$HOME/.claude/projects" "$HOME/.codex" "$HOME/.cursor"
  run --separate-stderr "$RS" --sweep
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "usage errors exit 2 without touching state" {
  run "$RS"; [ "$status" -eq 2 ]
  run "$RS" --bogus; [ "$status" -eq 2 ]
  run "$RS" --now; [ "$status" -eq 2 ]
  [ ! -e "$STATE/log" ]
}

@test "hook: SessionEnd scrubs the named transcript now, then sweeps" {
  local f="$HOME/.claude/projects/-p/s1.jsonl" g="$HOME/.claude/projects/-p/s2.jsonl"
  printf '{"text":"%s"}\n' "$V1" > "$f"
  printf '{"text":"%s"}\n' "$V2" > "$g"; old "$g"
  run bash "$HOOK" <<< "$(jq -nc --arg t "$f" '{hook_event_name:"SessionEnd", transcript_path:$t, session_id:"s1"}')"
  [ "$status" -eq 0 ]
  [[ "$(cat "$f")" != *"$V1"* ]]
  [[ "$(cat "$g")" != *"$V2"* ]]
}

@test "hook: Stop sweeps only quiet files and exits 0" {
  local f="$HOME/.claude/projects/-p/s1.jsonl" g="$HOME/.claude/projects/-p/s2.jsonl"
  printf '{"text":"%s"}\n' "$V1" > "$f"
  printf '{"text":"%s"}\n' "$V2" > "$g"; old "$g"
  run bash "$HOOK" <<< '{"hook_event_name":"Stop","transcript_path":"'"$f"'"}'
  [ "$status" -eq 0 ]
  grep -q "$V1" "$f"
  [[ "$(cat "$g")" != *"$V2"* ]]
}

@test "hook: no stdin and no binary still exits 0" {
  run bash "$HOOK" < /dev/null
  [ "$status" -eq 0 ]
  REDACT_SESSIONS_BIN=/nonexistent run bash "$HOOK" < /dev/null
  [ "$status" -eq 0 ]
}

@test "pending hook: prints keys as context and leaves the marker" {
  mkdir -p "$STATE"; printf 'GH_TOKEN\nLOGFIRE_TOKEN\n' > "$STATE/pending"
  run bash "$PENDING"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GH_TOKEN"* ]]
  [[ "$output" == *"LOGFIRE_TOKEN"* ]]
  [[ "$output" == *"redact-sessions --ack"* ]]
  [ "$(wc -l < "$STATE/pending")" -eq 2 ]
}

@test "pending hook: silent with no marker" {
  run bash "$PENDING"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pending hook: names the unreadable secrets file case" {
  mkdir -p "$STATE"; printf 'SECRETS_FILE_UNREADABLE\n' > "$STATE/pending"
  run bash "$PENDING"
  [[ "$output" == *"secrets file"* ]]
}

@test "settings.json registers both hooks and the inventory ships them" {
  local s="$BLUEPRINT_ROOT/configs/claude/settings.json"
  jq -e '.hooks.Stop[].hooks[] | select(.command | test("redact-sessions-hook")) | .async == true' "$s"
  jq -e '.hooks.SessionEnd[].hooks[] | select(.command | test("redact-sessions-hook"))' "$s"
  jq -e '.hooks.SessionStart[].hooks[] | select(.command | test("redact-sessions-pending"))' "$s"
  grep -q 'hooks/redact-sessions-hook.sh|overwrite|' "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  grep -q 'hooks/redact-sessions-pending.sh|overwrite|' "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  grep -q '"redact-sessions-hook.sh"' "$BLUEPRINT_ROOT/lib/provision-managed-files.sh"
  grep -q '"redact-sessions-pending.sh"' "$BLUEPRINT_ROOT/lib/provision-managed-files.sh"
}

TURN="$BLUEPRINT_ROOT/bin/codex-turn-done"

@test "codex-turn-done: notifies, then sweeps, exits 0" {
  mkdir -p "$HOME/stubs"
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "$HOME/notify-args"\n' > "$HOME/stubs/agent-notify"
  chmod +x "$HOME/stubs/agent-notify"
  local g="$HOME/.codex/sessions/2026/09/07/r.jsonl"
  printf '{"text":"%s"}\n' "$V2" > "$g"; old "$g"
  AGENT_NOTIFY_BIN="$HOME/stubs/agent-notify" run "$TURN" '{"type":"agent-turn-complete"}'
  [ "$status" -eq 0 ]
  grep -q -- '--source' "$HOME/notify-args"
  grep -q 'agent-turn-complete' "$HOME/notify-args"
  [[ "$(cat "$g")" != *"$V2"* ]]
}

@test "codex-turn-done: missing binaries still exit 0" {
  AGENT_NOTIFY_BIN=/nonexistent REDACT_SESSIONS_BIN=/nonexistent run "$TURN" '{}'
  [ "$status" -eq 0 ]
}

@test "cursor hooks.json wires stop, sessionEnd and sessionStart to the hook scripts" {
  local h="$BLUEPRINT_ROOT/configs/cursor/hooks.json"
  jq -e '.version == 1' "$h"
  jq -e '.hooks.stop[0].command | test("redact-sessions-hook.sh")' "$h"
  jq -e '.hooks.sessionEnd[0].command | test("redact-sessions-hook.sh")' "$h"
  jq -e '.hooks.sessionStart[0].command | test("redact-sessions-pending.sh")' "$h"
  grep -q 'cursor/hooks.json|overwrite|configs/cursor/hooks.json' "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
}

@test "on-start.sh runs a boot sweep when redact-sessions is on PATH" {
  grep -q 'redact-sessions --sweep' "$BLUEPRINT_ROOT/on-start.sh"
}

@test "install symlinks both binaries" {
  header(){ :; }; ok(){ :; }; warn(){ echo "WARN $*"; }; info(){ :; }
  export SCRIPT_DIR="$BLUEPRINT_ROOT"
  . "$BLUEPRINT_ROOT/lib/provision-integrations.sh" >/dev/null 2>&1 || true
  install_redact_sessions_symlinks
  [ -L "$HOME/.local/bin/redact-sessions" ]
  [ -L "$HOME/.local/bin/codex-turn-done" ]
  grep -q 'install_redact_sessions_symlinks' "$BLUEPRINT_ROOT/install.sh"
  grep -q 'install_redact_sessions_symlinks' "$BLUEPRINT_ROOT/lib/sync.sh"
}

@test "codex root: in-place rewrite keeps an O_APPEND writer's later records" {
  local f="$HOME/.codex/sessions/2026/09/07/r.jsonl"
  printf '{"text":"%s"}\n' "$V1" > "$f"; old "$f"
  local ino; ino="$(stat -c '%i' "$f")"
  exec 7>>"$f"                       # a live codex holds exactly this: O_APPEND
  "$RS" --now "$f"
  printf '{"text":"after scrub"}\n' >&7
  exec 7>&-
  [ "$(stat -c '%i' "$f")" = "$ino" ]
  [[ "$(cat "$f")" != *"$V1"* ]]
  grep -q 'REDACTED:OPENROUTER_API_KEY' "$f"
  [ "$(tail -n1 "$f")" = '{"text":"after scrub"}' ]
  [ "$(wc -l < "$f")" -eq 2 ]
}

@test "claude root: rename changes the inode and a path-based appender follows" {
  local f="$HOME/.claude/projects/-p/s1.jsonl"
  printf '{"text":"%s"}\n' "$V1" > "$f"; old "$f"
  local ino; ino="$(stat -c '%i' "$f")"
  "$RS" --now "$f"
  [ "$(stat -c '%i' "$f")" != "$ino" ]
  printf '{"text":"by path"}\n' >> "$f"
  [ "$(wc -l < "$f")" -eq 2 ]
}

@test "cursor root: agent-transcripts jsonl is swept and attributed to its conversation" {
  local f="$HOME/.cursor/projects/ws/agent-transcripts/c1/c1.jsonl"
  printf '{"role":"assistant","message":{"content":[{"type":"text","text":"%s"}]}}\n' "$V1" > "$f"; old "$f"
  "$RS" --sweep
  [[ "$(cat "$f")" != *"$V1"* ]]
  grep -q 'session=c1' "$STATE/log"
}

@test "hook: cursor's sessionEnd spelling also scrubs the named transcript now" {
  local f="$HOME/.cursor/projects/ws/agent-transcripts/c1/c1.jsonl"
  printf '{"text":"%s"}\n' "$V1" > "$f"
  run bash "$HOOK" <<< "$(jq -nc --arg t "$f" '{hook_event_name:"sessionEnd", transcript_path:$t, conversation_id:"c1"}')"
  [ "$status" -eq 0 ]
  [[ "$(cat "$f")" != *"$V1"* ]]
}

@test "pending hook --cursor: emits JSON with additional_context" {
  mkdir -p "$STATE"; printf 'GH_TOKEN\n' > "$STATE/pending"
  run bash "$PENDING" --cursor
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.additional_context | test("GH_TOKEN")'
  printf '%s' "$output" | jq -e '.additional_context | test("redact-sessions --ack")'
}

@test "pending hook --cursor: silent with no marker" {
  run bash "$PENDING" --cursor
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "two keys sharing a value are both logged and both pending" {
  printf 'A_KEY=%s\nB_KEY=%s\n' "$V1" "$V1" > "$SECRETS"
  local f="$HOME/.claude/projects/-p/s1.jsonl"
  printf '{"text":"%s"}\n' "$V1" > "$f"
  "$RS" --now "$f"
  grep -q 'REDACTED:A_KEY,B_KEY' "$f"
  grep -q 'key=A_KEY count=1' "$STATE/log"
  grep -q 'key=B_KEY count=1' "$STATE/log"
  grep -qx 'A_KEY' "$STATE/pending"
  grep -qx 'B_KEY' "$STATE/pending"
}

@test "codex root: a record appended during the in-place rewrite is kept and logged" {
  local f="$HOME/.codex/sessions/2026/09/07/r.jsonl"
  printf '{"text":"%s"}\n' "$V1" > "$f"; old "$f"
  # Append through an O_APPEND fd from the race hook, which runs after the
  # temp file is built and before the swap: the record must survive whole.
  cat > "$HOME/race.sh" <<EOF
#!/bin/sh
[ -e "$HOME/raced" ] && exit 0
touch "$HOME/raced"
printf '{"text":"mid-rewrite"}\\n' >> "$f"
EOF
  chmod +x "$HOME/race.sh"
  REDACT_SESSIONS_RACE_HOOK="$HOME/race.sh" "$RS" --now "$f"
  [[ "$(cat "$f")" != *"$V1"* ]]
  grep -qx '{"text":"mid-rewrite"}' "$f"
  [ "$(wc -l < "$f")" -eq 2 ]
}
