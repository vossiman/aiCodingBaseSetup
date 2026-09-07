# redact-sessions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Scrub every secrets-file value out of persisted agent transcripts on disk, in every harness, and report each hit so the credential gets rotated.

**Architecture:** One shared bash library builds the literal redaction rules from the secrets file (raw, JSON-escaped, and base64-aligned variants). `redact-transcript` keeps its current behaviour through that library. A new `redact-sessions` binary sweeps the transcript roots with a quiet period and check-and-swap rename, logs hits to a shared state dir, and keeps a pending-rotation marker. Small hook scripts wire it to Claude Code, codex and cursor lifecycle events.

**Tech Stack:** bash, sed, awk, base64, jq, flock; bats for tests (`bash tests/bats/run.sh`).

**Spec:** `docs/superpowers/specs/2026-09-07-redact-sessions-design.md`

## Global Constraints

- Never print a secret value anywhere: not in logs, stderr, test output, or commit messages. Test fixtures use dummy values only.
- Fail closed on an unreadable or partially parsed secrets file: exit 3, touch no transcript.
- Hooks never block a harness: every hook path exits 0 and backgrounds the sweep.
- Literal-layer floor is 8 characters; base64 rules need 12.
- State lives in `$HOME/.claude/state/redact-sessions/` (shared mount), never `~/.local/state`.
- Replacement marker is `[REDACTED:KEYNAME]`.
- Suite must pass before every push: `bash tests/bats/run.sh`. Tests never write into `$BLUEPRINT_ROOT`.
- No em dashes in any prose, code comment, or commit message.
- Every external binary a test path can reach must be stubbed or harmless. `redact-sessions` is invoked from `on-start.sh`, which `sync.bats` runs for real: it must be safe on an empty temp HOME.

## File structure

| File | Responsibility |
|---|---|
| `lib/redact-literal.sh` (new) | Parse the secrets file, emit a sed script of literal rules for a given mode. Used by both binaries. |
| `bin/redact-transcript` (modify) | Source the library; behaviour unchanged. |
| `bin/redact-sessions` (new) | Sweep, `--now`, `--ack`; per-file scrub; state, log, pending marker. |
| `bin/codex-turn-done` (new) | codex `notify` target: agent-notify then a background sweep. |
| `configs/claude/hooks/redact-sessions-hook.sh` (new) | Stop / SessionEnd / cursor hook entry: backgrounds the sweep, `--now` on SessionEnd. |
| `configs/claude/hooks/redact-sessions-pending.sh` (new) | SessionStart: print pending rotation keys as context. |
| `configs/claude/settings.json` (modify) | Register the two hooks. |
| `configs/codex/config.toml` (modify) | `notify` points at `codex-turn-done`. |
| `configs/cursor/hooks.json` (new) | cursor `stop`, `sessionEnd`, `sessionStart` entries. |
| `lib/provision-integrations.sh`, `install.sh`, `lib/sync.sh` (modify) | Symlinks for the two new binaries. |
| `lib/blueprint-deploy.sh`, `lib/provision-managed-files.sh` (modify) | Managed inventory and `MANAGED_HOOKS`. |
| `on-start.sh` (modify) | Boot sweep. |
| `tests/bats/redact-literal.bats`, `tests/bats/redact-sessions.bats` (new), `tests/bats/agent-notify.bats`, `tests/bats/redact-transcript.bats` (modify) | Tests. |

---

### Task 1: `lib/redact-literal.sh`, the shared literal-rule builder

**Files:**
- Create: `lib/redact-literal.sh`
- Modify: `bin/redact-transcript` (replace `_ml_json_escape`, `_ml_ere_escape`, `_ml_expected_rules`, `_ml_literal_script` with a `source` of the library)
- Test: `tests/bats/redact-literal.bats`, existing `tests/bats/redact-transcript.bats` must stay green

**Interfaces:**
- Produces: `redact_literal_rules MODE [FILE]`: prints a sed script to stdout. `MODE` is `transcript` (`[REDACTED]`, raw + JSON-escaped variants) or `sessions` (`[REDACTED:KEY]`, raw + JSON-escaped + three standard base64 cores + three URL-safe base64 cores). `FILE` defaults to `$HOME/.aicodingsetup/.secrets.env`. Exit 0 with possibly empty output when the file is absent or fully parsed; exit 1 when the file exists but is unreadable or parses partially.
- Produces: `redact_literal_b64_core VALUE K`: prints the base64 run fully determined by `VALUE` at byte offset `K` (0, 1, 2), no padding, no edge characters.
- Produces: `redact_literal_ere_escape STRING` and `redact_literal_json_escape STRING`.

- [ ] **Step 1: Write the failing tests**

```bash
#!/usr/bin/env bats
# lib/redact-literal.sh: the one place that turns the secrets file into sed
# rules. Both redact-transcript and redact-sessions source it.

bats_require_minimum_version 1.5.0

setup() {
  : "${BLUEPRINT_ROOT:?unset, run via tests/bats/run.sh}"
  LIB="$BLUEPRINT_ROOT/lib/redact-literal.sh"
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  mkdir -p "$HOME/.aicodingsetup"
  SECRETS="$HOME/.aicodingsetup/.secrets.env"
  . "$LIB"
}

teardown() { case "${TMPDIR:-}" in */tmp.*) rm -rf "$TMPDIR" ;; esac }

V="abcdefghijklmnopqrstuvwxyz"

@test "b64 core, offset 0: full encoding minus the mixed last char" {
  # 26 bytes, 26 % 3 == 2, so the last char carries padding bits.
  run redact_literal_b64_core "$V" 0
  [ "$output" = "YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eX" ]
}

@test "b64 core, offset 1: drops two leading chars, ends on a byte boundary" {
  run redact_literal_b64_core "$V" 1
  [ "$output" = "FiY2RlZmdoaWprbG1ub3BxcnN0dXZ3eHl6" ]
  # And it really is inside the encoding of the value with one byte before it
  # and one after.
  [[ "$(printf 'X%sY' "$V" | base64 -w0)" == *"$output"* ]]
}

@test "b64 core, offset 2: drops three leading chars and the mixed last char" {
  run redact_literal_b64_core "$V" 2
  [[ "$(printf 'XX%sYZ' "$V" | base64 -w0)" == *"$output"* ]]
  [ "${#output}" -ge 12 ]
}

@test "transcript mode: raw and json variants, anonymous marker" {
  printf 'GH_TOKEN=abc"def\\ghijklmno\n' > "$SECRETS"
  run redact_literal_rules transcript "$SECRETS"
  [ "$status" -eq 0 ]
  [[ "$output" == *'[REDACTED]/g'* ]]
  [[ "$output" != *'[REDACTED:'* ]]
  [ "$(printf '%s\n' "$output" | grep -c '^s/')" -eq 2 ]
}

@test "sessions mode: named marker, raw, json, and six base64 rules" {
  printf 'GH_TOKEN=%s\n' "$V" > "$SECRETS"
  run redact_literal_rules sessions "$SECRETS"
  [ "$status" -eq 0 ]
  [[ "$output" == *'[REDACTED:GH_TOKEN]/g'* ]]
  # raw + 3 b64 + 3 urlsafe (json variant identical to raw, so omitted)
  [ "$(printf '%s\n' "$output" | grep -c '^s/')" -eq 7 ]
}

@test "sessions mode: a value of 8 to 11 chars gets literal rules but no base64" {
  printf 'SHORT=abcdefgh\n' > "$SECRETS"
  run redact_literal_rules sessions "$SECRETS"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^s/')" -eq 1 ]
}

@test "sessions rules redact a value planted at every base64 alignment" {
  printf 'GH_TOKEN=%s\n' "$V" > "$SECRETS"
  local script; script="$(redact_literal_rules sessions "$SECRETS")"
  local blob0 blob1 blob2
  blob0="$(printf '%s' "$V" | base64 -w0)"
  blob1="$(printf 'X%sYZ' "$V" | base64 -w0)"
  blob2="$(printf 'XX%sY' "$V" | base64 -w0)"
  run sed -E -f <(printf '%s' "$script") <<EOF
plain $V here
b0 $blob0
b1 $blob1
b2 $blob2
EOF
  [[ "$output" != *"$V"* ]]
  [[ "$output" != *"$blob0"* ]]
  [[ "$output" != *"$blob1"* ]]
  [[ "$output" != *"$blob2"* ]]
  [ "$(printf '%s\n' "$output" | grep -c 'REDACTED:GH_TOKEN')" -eq 4 ]
}

@test "an unrelated base64 blob survives" {
  printf 'GH_TOKEN=%s\n' "$V" > "$SECRETS"
  local script; script="$(redact_literal_rules sessions "$SECRETS")"
  local other; other="$(printf 'the quick brown fox jumps over the lazy dog' | base64 -w0)"
  run sed -E -f <(printf '%s' "$script") <<< "keep $other"
  [ "$output" = "keep $other" ]
}

@test "absent file: exit 0, empty script" {
  run redact_literal_rules sessions "$SECRETS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "unreadable file: exit 1, empty script" {
  if [ "$(id -u)" -eq 0 ]; then skip "root can read a chmod 000 file"; fi
  printf 'GH_TOKEN=%s\n' "$V" > "$SECRETS"; chmod 000 "$SECRETS"
  run redact_literal_rules sessions "$SECRETS"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "comments, blanks, export prefix and quotes are handled" {
  cat > "$SECRETS" <<'EOF'
# comment

export A="abcdefghijkl"
B='mnopqrstuvwx'
C=
EOF
  run redact_literal_rules sessions "$SECRETS"
  [ "$status" -eq 0 ]
  [[ "$output" == *'[REDACTED:A]'* ]]
  [[ "$output" == *'[REDACTED:B]'* ]]
  [[ "$output" != *'"'* ]]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/bats/run.sh tests/bats/redact-literal.bats` (run.sh accepts file arguments; if it does not, run `bats tests/bats/redact-literal.bats` with `BLUEPRINT_ROOT` exported to the worktree root).
Expected: every test fails, `redact_literal_rules: command not found` or the library missing.

- [ ] **Step 3: Write the library**

```bash
#!/usr/bin/env bash
# lib/redact-literal.sh: turns the secrets file into sed rules. Sourced by
# bin/redact-transcript and bin/redact-sessions so the literal layer exists
# once. Never writes anything to disk and never prints a value except inside
# the sed script it returns to its caller.
#
# The secrets file is only ever READ.
#
# Modes:
#   transcript  s/V/[REDACTED]/g plus the JSON-escaped variant of V.
#   sessions    s/V/[REDACTED:KEY]/g plus JSON-escaped, plus the base64 runs
#               fully determined by V at each of the three byte alignments,
#               in both the standard and the URL-safe alphabet.
#
# Floors: values under 8 characters get no rule (too collision-prone to
# redact globally). Values under 12 get no base64 rule (the aligned core is
# too short to be unique).
#
# Fail-closed contract (shared by both callers): file absent means exit 0 and
# an empty script; file present but unreadable, or parsed to a different
# number of keys than an independent count, means exit 1 and an empty script.

redact_literal_json_escape() {
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  printf '%s' "$v"
}

# Escapes ERE metacharacters (backslashes first). The class lists `[` last:
# `[.` inside a bracket expression opens a POSIX collating symbol.
redact_literal_ere_escape() {
  printf '%s' "$1" | sed -e 's,\\,\\\\,g' -e 's,[]^$*+?(){}|/.[],\\&,g'
}

# redact_literal_b64_core VALUE K: the base64 characters that depend only on
# VALUE when VALUE starts K bytes (0, 1, 2) into a 3-byte group. Leading
# characters that mix in the filler bytes are dropped (0, 2, 3 of them), the
# padding is dropped, and when (K + len) % 3 != 0 the last character mixes
# VALUE's final bits with whatever byte follows in a larger blob, so it is
# dropped too.
redact_literal_b64_core() {
  local v="$1" k="$2" filler="" enc
  case "$k" in 1) filler="A" ;; 2) filler="AA" ;; esac
  enc="$(printf '%s%s' "$filler" "$v" | base64 -w0)"
  enc="${enc%%=*}"
  case "$k" in 1) enc="${enc:2}" ;; 2) enc="${enc:3}" ;; esac
  if [ $(( (k + ${#v}) % 3 )) -ne 0 ]; then enc="${enc%?}"; fi
  printf '%s' "$enc"
}

# Counts KEY=value lines whose stripped value is >= 8 chars, independently of
# the rule generator, so a partial read shows up as a mismatch.
_redact_literal_expected() {
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    index($0, "=") == 0 { next }
    {
      v = $0; sub(/^[^=]*=/, "", v)
      sub(/"$/,    "", v); sub(/^"/,    "", v)
      sub(/\047$/, "", v); sub(/^\047/, "", v)
      if (length(v) >= 8) c++
    }
    END { print c + 0 }
  ' "$1"
}

# _redact_literal_rule PATTERN MARKER: one sed substitution line.
_redact_literal_rule() {
  local esc
  esc="$(redact_literal_ere_escape "$1")" || return 1
  [ -n "$esc" ] || return 1
  printf 's/%s/%s/g\n' "$esc" "$2"
}

redact_literal_rules() {
  local mode="$1" f="${2:-$HOME/.aicodingsetup/.secrets.env}"
  local line key val marker jval out='' keys=0 expected=0 k core
  case "$mode" in transcript|sessions) ;; *) return 1 ;; esac
  [ -e "$f" ] || return 0
  [ -r "$f" ] || return 1

  expected="$(_redact_literal_expected "$f")" || return 1
  case "$expected" in (''|*[!0-9]*) return 1 ;; esac

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in ('#'*|'') continue ;; (*=*) ;; (*) continue ;; esac
    key="${line%%=*}"; key="${key#export }"; key="${key//[[:space:]]/}"
    val="${line#*=}"
    val="${val%\"}"; val="${val#\"}"
    val="${val%\'}"; val="${val#\'}"
    [ "${#val}" -ge 8 ] || continue
    keys=$(( keys + 1 ))

    if [ "$mode" = sessions ] && [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      marker="[REDACTED:$key]"
    else
      marker="[REDACTED]"
    fi

    out+="$(_redact_literal_rule "$val" "$marker")"$'\n' || return 1
    jval="$(redact_literal_json_escape "$val")"
    if [ "$jval" != "$val" ]; then
      out+="$(_redact_literal_rule "$jval" "$marker")"$'\n' || return 1
    fi

    if [ "$mode" = sessions ] && [ "${#val}" -ge 12 ]; then
      for k in 0 1 2; do
        core="$(redact_literal_b64_core "$val" "$k")"
        [ "${#core}" -ge 12 ] || continue
        out+="$(_redact_literal_rule "$core" "$marker")"$'\n' || return 1
        out+="$(_redact_literal_rule "$(printf '%s' "$core" | tr '+/' '-_')" "$marker")"$'\n' || return 1
      done
    fi
  done < "$f" || return 1

  [ "$keys" -eq "$expected" ] || return 1
  printf '%s' "$out"
}
```

Note on the sessions-mode base64 count in the test: the standard and URL-safe cores are identical when the core contains neither `+` nor `/`, which is the case for the alphabet-only fixture. The rule count test expects 7 (raw + 3 + 3) because both are emitted regardless; sed simply applies an identical rule twice. Keep it that way: deduplication is not worth a branch.

- [ ] **Step 4: Point `redact-transcript` at the library**

In `bin/redact-transcript`, delete the four function definitions `_ml_json_escape`, `_ml_ere_escape`, `_ml_expected_rules`, `_ml_literal_script` and their comments, and insert after `set -uo pipefail`:

```bash
# The literal layer lives in lib/redact-literal.sh, shared with
# bin/redact-sessions. This file is installed as a symlink, so resolve it.
_ml_self="$(readlink -f "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/redact-literal.sh
. "$(dirname "$_ml_self")/../lib/redact-literal.sh"

_ml_literal_script() { redact_literal_rules transcript; }
```

Leave `_ml_redact` and `main` untouched. Update the header comment's layer 1 description to say the rules come from `lib/redact-literal.sh`.

- [ ] **Step 5: Run both test files**

Run: `bash tests/bats/run.sh` (full suite; `redact-transcript.bats` and `llmwiki-distill.bats` exercise the symlinked path).
Expected: all green, including the new file.

- [ ] **Step 6: Commit**

```bash
git add lib/redact-literal.sh bin/redact-transcript tests/bats/redact-literal.bats
git commit -m "feat: lib/redact-literal.sh, the literal secrets layer shared by both redactors

Adds a sessions mode with named markers and base64-aligned cores so a value
inside a larger base64 blob is found at any byte offset. redact-transcript
keeps its behaviour by sourcing the library."
```

---

### Task 2: `bin/redact-sessions` core: `--now FILE`, scrub, check-and-swap, fail closed

**Files:**
- Create: `bin/redact-sessions`
- Test: `tests/bats/redact-sessions.bats`

**Interfaces:**
- Consumes: `redact_literal_rules sessions "$SECRETS"` from Task 1.
- Produces: `redact-sessions --now FILE...` (scrub named files regardless of mtime), exit 0 on success, 3 when the secrets file is unreadable or partial. Env: `AICODING_SECRETS_FILE`, `REDACT_SESSIONS_STATE` (default `$HOME/.claude/state/redact-sessions`), `REDACT_QUIET_SECONDS` (default 120), `REDACT_SESSIONS_RACE_HOOK` (test-only: a command run between read and rename).
- Produces: state files `log`, `pending`, `deferred`, `stamp`, `lock` under the state dir. Log line format: `<iso> hit key=<K> count=<n> file=<path> container=<hostname>[ session=<id>]`.

- [ ] **Step 1: Write the failing tests (core subset)**

```bash
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
  local b0 b1 b2
  b0="$(printf 'ENV=%s' "$V1" | base64 -w0)"          # 4-byte prefix: offset 1
  b1="$(printf 'KEY=%s\n' "$V1" | base64 -w0)"        # 4-byte prefix: offset 1
  b2="$(printf 'OPENROUTER_API_KEY=%s' "$V1" | base64 -w0)"  # 19 bytes: offset 1
  local b3; b3="$(printf '%s' "$V1" | base64 -w0)"    # offset 0
  local b4; b4="$(printf 'XX%s' "$V1" | base64 -w0)"  # offset 2
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
  [ ! -s "$STATE/log" ] || ! grep -q ' hit ' "$STATE/log"
  [ ! -e "$STATE/pending" ]
}

@test "atomic rewrite: mode preserved, no temp file left behind" {
  local f="$HOME/.claude/projects/-p/s1.jsonl"
  printf '{"text":"%s"}\n' "$V1" > "$f"; chmod 600 "$f"
  "$RS" --now "$f"
  [ "$(stat -c '%a' "$f")" = "600" ]
  [ "$(ls "$HOME/.claude/projects/-p" | wc -l)" -eq 2 ]   # s1.jsonl and the s1 dir
}

@test "racing append: swap refused, retry scrubs, appended line survives" {
  local f="$HOME/.claude/projects/-p/s1.jsonl"
  printf '{"text":"%s"}\n' "$V1" > "$f"
  cat > "$HOME/race.sh" <<EOF
#!/bin/sh
# fire once: append a line to the transcript between read and rename
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
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/bats/run.sh tests/bats/redact-sessions.bats`
Expected: all fail, binary missing.

- [ ] **Step 3: Write the binary (core; sweep and ack are added in Task 3)**

```bash
#!/usr/bin/env bash
# redact-sessions: scrub secrets-file values out of agent transcripts on
# disk and report each hit so the credential gets rotated.
# Spec: docs/superpowers/specs/2026-09-07-redact-sessions-design.md
#
#   redact-sessions --sweep        every quiet transcript under the known roots
#   redact-sessions --now FILE...  exactly these files, ignoring the quiet period
#   redact-sessions --ack KEY      clear KEY from the pending-rotation marker
#
# Literal layer only (lib/redact-literal.sh, sessions mode): raw, JSON-escaped
# and base64-aligned forms of every secrets-file value, replaced with
# [REDACTED:KEYNAME]. The pattern and entropy layers of redact-transcript are
# deliberately not used here; they would eat digests and ids a resumed
# session needs, and their hits carry no key name to rotate.
#
# Live files: no harness holds its transcript open (Claude Code appends by
# path) and the roots are host mounts shared across containers with separate
# PID namespaces, so there is no open-file test. Safety is a quiet period on
# sweeps plus check-and-swap: the rename lands only if the file is still
# byte-for-byte what was read.
#
# State (shared ~/.claude mount, visible from every container):
#   log       one line per hit, never a value
#   pending   key names awaiting --ack, or SECRETS_FILE_UNREADABLE
#   deferred  files skipped this sweep (quiet period, swap refused twice)
#   stamp     mtime watermark for --sweep
#
# Exit: 0 ok, 2 usage, 3 secrets file unreadable or partially parsed (nothing
# touched). Never prints a secret value. The secrets file is only ever READ.
set -uo pipefail

_rs_self="$(readlink -f "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/redact-literal.sh
. "$(dirname "$_rs_self")/../lib/redact-literal.sh"

STATE="${REDACT_SESSIONS_STATE:-$HOME/.claude/state/redact-sessions}"
QUIET="${REDACT_QUIET_SECONDS:-120}"
SECRETS="${AICODING_SECRETS_FILE:-$HOME/.aicodingsetup/.secrets.env}"
HOST="$(hostname 2>/dev/null || echo unknown)"

# Roots, one per harness. OpenCode is listed with no pattern: its store is
# SQLite and out of scope (spec, non-goals); it stays here so the gap is
# visible in the code.
ROOTS=(
  "$HOME/.claude/projects|*.jsonl"
  "$HOME/.codex/sessions|*.jsonl"
  "$HOME/.cursor/chats|prompt_history.json"
  "$HOME/.cursor/chats|meta.json"
  "$HOME/.local/share/opencode|"
)

mkdir -p "$STATE" 2>/dev/null || true
log() { printf '%s %s\n' "$(date -Is)" "$*" >> "$STATE/log" 2>/dev/null || true; }
locked() { ( flock -w 5 9 && "$@" ) 9>>"$STATE/lock"; }
_pending_add() { grep -qx "$1" "$STATE/pending" 2>/dev/null || printf '%s\n' "$1" >> "$STATE/pending"; }
pending_add() { locked _pending_add "$1"; }

# session_of <path>: best-effort session id from the path, for the log.
session_of() {
  local b; b="$(basename "$1")"
  case "$1" in
    */subagents/*) basename "$(dirname "$(dirname "$1")")" ;;
    *) printf '%s' "${b%.jsonl}" ;;
  esac
}

# Builds the sed script once per run. Sets RULES; returns 3 on refusal.
load_rules() {
  if ! RULES="$(redact_literal_rules sessions "$SECRETS")"; then
    log "refused secrets file unreadable or partially parsed; nothing touched"
    pending_add SECRETS_FILE_UNREADABLE
    echo "redact-sessions: secrets file exists but is unreadable or parsed partially; refusing" >&2
    return 3
  fi
  return 0
}

# marker_counts <file>: "KEY count" per marker found.
marker_counts() {
  grep -o '\[REDACTED:[A-Za-z_][A-Za-z0-9_]*\]' "$1" 2>/dev/null \
    | sed 's/^\[REDACTED:\(.*\)\]$/\1/' | sort | uniq -c | awk '{print $2, $1}'
}

# scrub_one <file>: returns 0 clean, 0 scrubbed, 1 deferred (swap refused
# twice or unreadable), never touches a clean file.
scrub_one() {
  local f="$1" attempt tmp before after sig1 sig2 sess
  [ -n "$RULES" ] || return 0
  [ -f "$f" ] && [ -r "$f" ] && [ -w "$f" ] || return 1
  for attempt in 1 2; do
    sig1="$(stat -c '%s %Y' "$f")" || return 1
    tmp="$(mktemp "$(dirname "$f")/.redact-sessions.XXXXXX")" || return 1
    if ! sed -E -f <(printf '%s' "$RULES") "$f" > "$tmp"; then rm -f "$tmp"; return 1; fi
    if cmp -s "$f" "$tmp"; then rm -f "$tmp"; return 0; fi
    chmod --reference="$f" "$tmp" 2>/dev/null || true
    [ -n "${REDACT_SESSIONS_RACE_HOOK:-}" ] && "$REDACT_SESSIONS_RACE_HOOK" "$f"
    sig2="$(stat -c '%s %Y' "$f")" || { rm -f "$tmp"; return 1; }
    if [ "$sig1" != "$sig2" ]; then
      rm -f "$tmp"
      log "swap refused file=$f attempt=$attempt"
      continue
    fi
    before="$(marker_counts "$f")"
    after="$(marker_counts "$tmp")"
    if ! mv -f "$tmp" "$f"; then rm -f "$tmp"; return 1; fi
    sess="$(session_of "$f")"
    # Report the delta: markers that were already in the file are old news.
    while read -r key n; do
      [ -n "$key" ] || continue
      local prev; prev="$(printf '%s\n' "$before" | awk -v k="$key" '$1==k{print $2}')"
      n=$(( n - ${prev:-0} ))
      [ "$n" -gt 0 ] || continue
      log "hit key=$key count=$n file=$f container=$HOST session=$sess"
      pending_add "$key"
    done <<< "$after"
    return 0
  done
  return 1
}

usage() { sed -n '2,8p' "$_rs_self" | sed 's/^# \{0,1\}//' >&2; exit 2; }

main() {
  [ $# -ge 1 ] || usage
  case "$1" in
    --now)
      shift; [ $# -ge 1 ] || usage
      load_rules || exit 3
      local f rc=0
      for f in "$@"; do scrub_one "$f" || rc=1; done
      exit "$rc" ;;
    --sweep) shift; sweep "$@" ;;
    --ack) shift; [ $# -eq 1 ] || usage; ack "$1" ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
}

main "$@"
```

`sweep` and `ack` are defined in Task 3; for this task add temporary stubs directly above `main`:

```bash
sweep() { echo "redact-sessions: --sweep not implemented" >&2; exit 2; }
ack() { echo "redact-sessions: --ack not implemented" >&2; exit 2; }
```

Note on the race test: `RACE_HOOK` runs after the temp file is written and before the second stat. The hook appends after a one-second sleep, which also moves the mtime past the first stat's second, so the signature differs. On the retry the hook exits immediately (marker file exists), the swap lands, and the appended line is present in the read that fed the retry.

- [ ] **Step 4: Make it executable and run the tests**

```bash
chmod +x bin/redact-sessions
bash tests/bats/run.sh tests/bats/redact-sessions.bats
```
Expected: the nine core tests pass.

- [ ] **Step 5: Commit**

```bash
git add bin/redact-sessions tests/bats/redact-sessions.bats
git commit -m "feat: redact-sessions --now, scrub named transcripts with check-and-swap and hit reporting"
```

---

### Task 3: `--sweep` with quiet period, stamp and deferred set; `--ack`

**Files:**
- Modify: `bin/redact-sessions` (replace the two stubs)
- Test: `tests/bats/redact-sessions.bats` (append)

**Interfaces:**
- Produces: `redact-sessions --sweep` walks `ROOTS`, considers files newer than `stamp` plus every path in `deferred`, skips files with mtime age below `REDACT_QUIET_SECONDS` (deferring them), scrubs the rest, rewrites `deferred` with what is still pending, and moves `stamp` to the sweep's start time. Exit 0, or 3 on refusal.
- Produces: `redact-sessions --ack KEY` removes exactly that line from `pending`; exit 0 even when absent.

- [ ] **Step 1: Append the failing tests**

```bash
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

@test "sweep: covers every root including cursor json and subagents" {
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
  REDACT_QUIET_SECONDS=3600 "$RS" --sweep          # deferred: too fresh
  grep -qx "$fr" "$STATE/deferred"
  # Do not touch the file; the stamp is now newer than its mtime.
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
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/bats/run.sh tests/bats/redact-sessions.bats`
Expected: the new tests fail on the stubs (exit 2).

- [ ] **Step 3: Replace the stubs**

```bash
# candidates: files newer than the stamp under every root, plus the deferred
# set. Emits absolute paths, one per line, deduplicated.
candidates() {
  local entry root pat
  for entry in "${ROOTS[@]}"; do
    root="${entry%%|*}"; pat="${entry#*|}"
    [ -n "$pat" ] && [ -d "$root" ] || continue
    if [ -e "$STATE/stamp" ]; then
      find "$root" -type f -name "$pat" -newer "$STATE/stamp" 2>/dev/null
    else
      find "$root" -type f -name "$pat" 2>/dev/null
    fi
  done
  [ -f "$STATE/deferred" ] && cat "$STATE/deferred"
  return 0
}

sweep() {
  local start f age now inspected=0 scrubbed=0 deferred=0 list
  start="$(date +%s)"
  load_rules || exit 3
  list="$(candidates | sort -u)"
  : > "$STATE/deferred.next"
  now="$(date +%s)"
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    inspected=$(( inspected + 1 ))
    age=$(( now - $(stat -c '%Y' "$f" 2>/dev/null || echo "$now") ))
    if [ "$age" -lt "$QUIET" ]; then
      printf '%s\n' "$f" >> "$STATE/deferred.next"; deferred=$(( deferred + 1 )); continue
    fi
    if scrub_one "$f"; then scrubbed=$(( scrubbed + 1 ))
    else printf '%s\n' "$f" >> "$STATE/deferred.next"; deferred=$(( deferred + 1 )); fi
  done <<< "$list"
  mv -f "$STATE/deferred.next" "$STATE/deferred"
  touch -d "@$start" "$STATE/stamp" 2>/dev/null || touch "$STATE/stamp"
  log "sweep inspected=$inspected scrubbed=$scrubbed deferred=$deferred container=$HOST"
  exit 0
}

_ack() {
  [ -f "$STATE/pending" ] || return 0
  grep -vx "$1" "$STATE/pending" > "$STATE/pending.next" || true
  mv -f "$STATE/pending.next" "$STATE/pending"
}
ack() { locked _ack "$1"; exit 0; }
```

Two details the tests pin down:

- `scrubbed` counts files that were inspected and left in a good state, clean or rewritten; "scrubbed" in the log means "done with", not "changed". Hits are what the `hit` lines count.
- The parallel test works because each sweep's `sed` output is compared with `cmp` against the current file: the second sweep either sees the already-clean file (no change, no hit) or loses the check-and-swap and retries against the clean file. The `flock` around pending keeps the marker to one line. The `deferred.next` rename is the one shared-state race left; two sweeps at once can only lose a deferral, which the next sweep's stamp logic recovers because a deferred file's mtime is, by definition, recent.

- [ ] **Step 4: Run the tests**

Run: `bash tests/bats/run.sh tests/bats/redact-sessions.bats`
Expected: all pass. If `sweep stamp` flakes because `find -newer` compares whole seconds, set the stamp with `touch -d "@$((start - 1))"` and keep the test.

- [ ] **Step 5: Commit**

```bash
git add bin/redact-sessions tests/bats/redact-sessions.bats
git commit -m "feat: redact-sessions --sweep with quiet period, deferred set and stamp; --ack"
```

---

### Task 4: Claude Code hooks: Stop / SessionEnd sweep, SessionStart pending report

**Files:**
- Create: `configs/claude/hooks/redact-sessions-hook.sh`
- Create: `configs/claude/hooks/redact-sessions-pending.sh`
- Modify: `configs/claude/settings.json` (hooks block)
- Modify: `lib/provision-managed-files.sh:86` (`MANAGED_HOOKS`)
- Modify: `lib/blueprint-deploy.sh:552-560` (managed inventory, add two lines after `fable-guidance.sh`)
- Test: `tests/bats/redact-sessions.bats` (append)

**Interfaces:**
- Consumes: `redact-sessions --now FILE`, `--sweep`, state file `pending`.
- Produces: `redact-sessions-hook.sh` reads the hook JSON from stdin (optional), runs `--now <transcript_path>` synchronously when `hook_event_name` is `SessionEnd`, then backgrounds `--sweep` with `nohup`, always exits 0. `redact-sessions-pending.sh` prints a context block naming pending keys, exits 0 always, prints nothing when there is nothing pending.
- Env: `REDACT_SESSIONS_BIN` overrides the binary for tests; `REDACT_SESSIONS_SYNC=1` makes the hook run the sweep in the foreground (tests).

- [ ] **Step 1: Append the failing tests**

```bash
HOOK="$BLUEPRINT_ROOT/configs/claude/hooks/redact-sessions-hook.sh"
PENDING="$BLUEPRINT_ROOT/configs/claude/hooks/redact-sessions-pending.sh"

@test "hook: SessionEnd scrubs the named transcript now, then sweeps" {
  local f="$HOME/.claude/projects/-p/s1.jsonl" g="$HOME/.claude/projects/-p/s2.jsonl"
  printf '{"text":"%s"}\n' "$V1" > "$f"
  printf '{"text":"%s"}\n' "$V2" > "$g"; old "$g"
  run bash "$HOOK" <<< "$(jq -nc --arg t "$f" '{hook_event_name:"SessionEnd", transcript_path:$t, session_id:"s1"}')"
  [ "$status" -eq 0 ]
  [[ "$(cat "$f")" != *"$V1"* ]]
  [[ "$(cat "$g")" != *"$V2"* ]]
}

@test "hook: Stop sweeps only quiet files and exits 0 immediately" {
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
```

Add to `setup()`: `export REDACT_SESSIONS_BIN="$RS" REDACT_SESSIONS_SYNC=1`.

- [ ] **Step 2: Run to verify failure**

Expected: hook files missing, settings assertions fail.

- [ ] **Step 3: Write `redact-sessions-hook.sh`**

```bash
#!/usr/bin/env bash
# Claude Code Stop / SessionEnd hook (also cursor stop / sessionEnd): scrub
# transcripts on disk with redact-sessions. On SessionEnd the session's own
# file is scrubbed now, because the harness has said it is done writing;
# everything else goes through the sweep, which honours the quiet period.
#
# FAIL-OPEN: never blocks the harness. Every path exits 0; the sweep runs in
# the background unless REDACT_SESSIONS_SYNC=1 (tests).
# Intentionally no set -e.

bin="${REDACT_SESSIONS_BIN:-}"
if [ -z "$bin" ]; then
  for c in "$(command -v redact-sessions 2>/dev/null)" \
           "$HOME/.local/bin/redact-sessions" \
           "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../../bin/redact-sessions"; do
    [ -n "$c" ] && [ -x "$c" ] && { bin="$c"; break; }
  done
fi
[ -n "$bin" ] && [ -x "$bin" ] || exit 0

input=""
if [ ! -t 0 ]; then input="$(timeout 2 cat 2>/dev/null || true)"; fi
event="$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null)"
transcript="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)"

if [ "$event" = "SessionEnd" ] && [ -n "$transcript" ] && [ -f "$transcript" ]; then
  timeout 60 "$bin" --now "$transcript" >/dev/null 2>&1 || true
fi

if [ "${REDACT_SESSIONS_SYNC:-}" = "1" ]; then
  timeout 300 "$bin" --sweep >/dev/null 2>&1 || true
else
  nohup timeout 300 "$bin" --sweep >/dev/null 2>&1 &
fi
exit 0
```

- [ ] **Step 4: Write `redact-sessions-pending.sh`**

```bash
#!/usr/bin/env bash
# SessionStart hook (Claude Code, cursor sessionStart): if redact-sessions has
# found a secrets-file value in a transcript and nobody has acknowledged the
# rotation yet, say so at the top of the session. The marker is NOT cleared
# here; `redact-sessions --ack KEY` clears it once the key is rotated, so the
# warning repeats in every new session on every container until someone acts.
# FAIL-OPEN: always exits 0. Intentionally no set -e.

state="${REDACT_SESSIONS_STATE:-$HOME/.claude/state/redact-sessions}"
[ -s "$state/pending" ] || exit 0

keys="$(grep -v '^SECRETS_FILE_UNREADABLE$' "$state/pending" 2>/dev/null | sort -u | tr '\n' ' ')"
unreadable=0
grep -qx 'SECRETS_FILE_UNREADABLE' "$state/pending" 2>/dev/null && unreadable=1

echo "# redact-sessions: credentials need rotating"
if [ -n "${keys// /}" ]; then
  echo "A transcript on this machine contained the live value of: $keys"
  echo "The file has been scrubbed, but the value reached an agent and is burned."
  echo "Tell the user now: rotate each key, edit the host secrets file in place,"
  echo "then run \`redact-sessions --ack KEY\` for each one. Details: $state/log"
fi
if [ "$unreadable" = 1 ]; then
  echo "Also: the secrets file exists but could not be read or parsed fully, so"
  echo "no transcript has been scrubbed. Tell the user; run \`redact-sessions --ack SECRETS_FILE_UNREADABLE\` once fixed."
fi
exit 0
```

- [ ] **Step 5: Register in settings.json, inventory, MANAGED_HOOKS**

In `configs/claude/settings.json`, inside `"hooks"`:

- Append to the existing `Stop` group's `hooks` array, after the distill entry:
  ```json
  {
    "type": "command",
    "command": "bash \"{{HOME}}/.claude/hooks/redact-sessions-hook.sh\"",
    "async": true,
    "timeout": 300
  }
  ```
- Add a new top-level key:
  ```json
  "SessionEnd": [
    {
      "hooks": [
        {
          "type": "command",
          "command": "bash \"{{HOME}}/.claude/hooks/redact-sessions-hook.sh\"",
          "timeout": 90
        }
      ]
    }
  ],
  ```
- Append to the existing `SessionStart` group's `hooks` array (matcher `startup|resume`):
  ```json
  {
    "type": "command",
    "command": "bash \"{{HOME}}/.claude/hooks/redact-sessions-pending.sh\"",
    "timeout": 5
  }
  ```

In `lib/blueprint-deploy.sh` after the `fable-guidance.sh` inventory line add:
```
$HOME/.claude/hooks/redact-sessions-hook.sh|overwrite|configs/claude/hooks/redact-sessions-hook.sh
$HOME/.claude/hooks/redact-sessions-pending.sh|overwrite|configs/claude/hooks/redact-sessions-pending.sh
```

In `lib/provision-managed-files.sh:86` append `"redact-sessions-hook.sh" "redact-sessions-pending.sh"` to `MANAGED_HOOKS`.

`chmod +x` both hook files.

- [ ] **Step 6: Run the full suite**

Run: `bash tests/bats/run.sh`
Expected: green. `blueprint-deploy.bats` and `install.bats` exercise the inventory; a missing source file for an inventory line fails there.

- [ ] **Step 7: Commit**

```bash
git add configs/claude/hooks/redact-sessions-hook.sh configs/claude/hooks/redact-sessions-pending.sh configs/claude/settings.json lib/blueprint-deploy.sh lib/provision-managed-files.sh tests/bats/redact-sessions.bats
git commit -m "feat(claude): wire redact-sessions to Stop, SessionEnd and SessionStart"
```

---

### Task 5: codex and cursor triggers, boot sweep, symlinks

**Files:**
- Create: `bin/codex-turn-done`
- Create: `configs/cursor/hooks.json`
- Modify: `configs/codex/config.toml:15` (notify line)
- Modify: `lib/provision-integrations.sh` (add `install_redact_sessions_symlinks` after `install_redact_transcript_symlink`)
- Modify: `install.sh:128` and `lib/sync.sh:807` (call it)
- Modify: `lib/blueprint-deploy.sh` inventory (cursor hooks.json)
- Modify: `on-start.sh` (after the sync block)
- Test: `tests/bats/agent-notify.bats:136-141` (update), `tests/bats/redact-sessions.bats` (append)

**Interfaces:**
- Produces: `codex-turn-done [args...]`: calls `agent-notify --source codex "$@"`, then backgrounds `redact-sessions --sweep`; exit 0 always. Env `REDACT_SESSIONS_SYNC=1` foregrounds the sweep, `AGENT_NOTIFY_BIN` and `REDACT_SESSIONS_BIN` override lookups (tests).
- Produces: `install_redact_sessions_symlinks`: links `bin/redact-sessions` and `bin/codex-turn-done` into `~/.local/bin`.

- [ ] **Step 1: Update the codex notify test and append new tests**

Replace the body of `"codex config wires notify to agent-notify above the first table"` in `tests/bats/agent-notify.bats` with:

```bash
  local cfg="$BLUEPRINT_ROOT/configs/codex/config.toml"
  # notify goes through codex-turn-done, which flags the window via
  # agent-notify and then sweeps transcripts with redact-sessions.
  grep -q 'notify = \["{{HOME}}/.local/bin/codex-turn-done"' "$cfg"
  awk '/^\[/{exit 1} /^notify = /{found=1} END{exit !found}' "$cfg"
```

Append to `tests/bats/redact-sessions.bats`:

```bash
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
  . "$BLUEPRINT_ROOT/lib/provision-integrations.sh" 2>/dev/null || true
  header(){ :; }; ok(){ :; }; warn(){ echo "WARN $*"; }
  SCRIPT_DIR="$BLUEPRINT_ROOT" install_redact_sessions_symlinks
  [ -L "$HOME/.local/bin/redact-sessions" ]
  [ -L "$HOME/.local/bin/codex-turn-done" ]
}
```

If sourcing `provision-integrations.sh` in isolation fails on an unrelated dependency, mirror how `codex-managed-hooks.bats` sources `provision-system.sh` (define the loggers first, `export SCRIPT_DIR`).

- [ ] **Step 2: Run to verify failure**

Expected: the codex config test and the five new tests fail.

- [ ] **Step 3: Write `bin/codex-turn-done`**

```bash
#!/usr/bin/env bash
# codex-turn-done: the codex `notify` target. codex invokes argv plus one JSON
# argument at the end of every agent turn. This flags the tmux window through
# agent-notify (the existing behaviour) and then sweeps transcripts with
# redact-sessions, so a container used only by codex still scrubs.
# Contract: never exits non-zero, never blocks codex.
set -u

notify="${AGENT_NOTIFY_BIN:-}"
[ -n "$notify" ] || notify="$(command -v agent-notify 2>/dev/null || true)"
[ -n "$notify" ] || notify="$HOME/.local/bin/agent-notify"
if [ -x "$notify" ]; then
  "$notify" --source codex --title "✔ codex turn done" "$@" >/dev/null 2>&1 || true
fi

rs="${REDACT_SESSIONS_BIN:-}"
[ -n "$rs" ] || rs="$(command -v redact-sessions 2>/dev/null || true)"
[ -n "$rs" ] || rs="$HOME/.local/bin/redact-sessions"
if [ -x "$rs" ]; then
  if [ "${REDACT_SESSIONS_SYNC:-}" = "1" ]; then
    timeout 300 "$rs" --sweep >/dev/null 2>&1 || true
  else
    nohup timeout 300 "$rs" --sweep >/dev/null 2>&1 &
  fi
fi
exit 0
```

`chmod +x bin/codex-turn-done`.

- [ ] **Step 4: codex config, cursor hooks, inventory, symlinks, boot**

`configs/codex/config.toml:15` becomes:
```toml
notify = ["{{HOME}}/.local/bin/codex-turn-done"]
```
and the comment above it gains one sentence: "codex-turn-done wraps agent-notify and then runs a redact-sessions sweep."

Create `configs/cursor/hooks.json`:
```json
{
  "version": 1,
  "hooks": {
    "stop": [{ "command": "bash \"{{HOME}}/.claude/hooks/redact-sessions-hook.sh\"" }],
    "sessionEnd": [{ "command": "bash \"{{HOME}}/.claude/hooks/redact-sessions-hook.sh\"" }],
    "sessionStart": [{ "command": "bash \"{{HOME}}/.claude/hooks/redact-sessions-pending.sh\"" }]
  }
}
```

Inventory line in `lib/blueprint-deploy.sh`, next to the other cursor entries (the overwrite list, near line 572):
```
$HOME/.cursor/hooks.json|overwrite|configs/cursor/hooks.json
```
If `~/.cursor/hooks.json` already exists on a machine with user hooks, overwrite would clobber them; the blueprint has no cursor hooks today and the deny rules live in `cli-config.json`, so overwrite is the right mode now. Note it in the file's inventory comment.

`lib/provision-integrations.sh`, after `install_redact_transcript_symlink`:
```bash
# --- transcript scrubber ---
# redact-sessions sweeps persisted transcripts for secrets-file values;
# codex-turn-done is codex's notify target that triggers it. Symlinked so
# hooks and the codex config find one implementation.
install_redact_sessions_symlinks() {
  header "transcript scrubber"
  local name src
  for name in redact-sessions codex-turn-done; do
    src="$SCRIPT_DIR/bin/$name"
    [[ -f "$src" ]] || { warn "bin/$name not found, skipping"; continue; }
    mkdir -p "$HOME/.local/bin"; chmod +x "$src"
    ln -sf "$src" "$HOME/.local/bin/$name"
    ok "$name installed at ~/.local/bin/$name -> $src"
  done
}
```
(The warn text above may use a plain hyphen instead of the em dash the neighbours use; do not copy their dash.)

Call it in `install.sh` right after `install_redact_transcript_symlink` and in `lib/sync.sh:807` as `install_redact_sessions_symlinks || true`.

`on-start.sh`, after the `if [ -n "$sync_cmd" ] ... fi` block:
```bash
# Boot sweep: scrub transcripts left by crashed sessions or other containers.
# Fail-open and backgrounded; the sync above has just refreshed the symlink.
if command -v redact-sessions >/dev/null 2>&1; then
  nohup timeout 300 redact-sessions --sweep >/dev/null 2>&1 &
fi
```

- [ ] **Step 5: Run the full suite**

Run: `bash tests/bats/run.sh`
Expected: green. Watch `sync.bats "on-start.sh runs the boot path"`: it runs the real `on-start.sh` under a temp HOME, so the sweep must be silent there (Task 3's empty-HOME test guarantees that). Check for leaked background processes afterwards: `pgrep -f 'redact-sessions --sweep' || true` should print nothing once the runs finish.

- [ ] **Step 6: Commit**

```bash
git add bin/codex-turn-done configs/codex/config.toml configs/cursor/hooks.json lib/provision-integrations.sh install.sh lib/sync.sh lib/blueprint-deploy.sh on-start.sh tests/bats/agent-notify.bats tests/bats/redact-sessions.bats
git commit -m "feat: trigger redact-sessions from codex notify, cursor hooks and container boot"
```

---

### Task 6: README, spec status, live smoke test, PR

**Files:**
- Modify: `README.md:178` (the helper list that reads the secrets file)
- Modify: `docs/superpowers/specs/2026-09-07-redact-sessions-design.md` (status line, and the codex/cursor measurement note in 3.4 once measured)

- [ ] **Step 1: README**

In the sentence at `README.md:178` that lists helpers reading the secrets file, add `redact-sessions`. Add one paragraph to the section describing agent hooks (search for `bw-deny-files` in README) stating: transcripts on disk are swept by `redact-sessions` for secrets-file values, hits are logged under `~/.claude/state/redact-sessions/`, and a pending rotation is announced at every session start until `redact-sessions --ack KEY`.

- [ ] **Step 2: Live smoke test in this container (dummy values only)**

Do not use the real secrets file. Run:
```bash
export HOME_REAL="$HOME"
tmp=$(mktemp -d); mkdir -p "$tmp/.aicodingsetup" "$tmp/.claude/projects/-x"
printf 'DUMMY_KEY=dummyvalue0123456789\n' > "$tmp/.aicodingsetup/.secrets.env"
printf '{"text":"dummyvalue0123456789"}\n' > "$tmp/.claude/projects/-x/s.jsonl"
touch -d '-10 minutes' "$tmp/.claude/projects/-x/s.jsonl"
HOME="$tmp" bin/redact-sessions --sweep
cat "$tmp/.claude/projects/-x/s.jsonl"; cat "$tmp/.claude/state/redact-sessions/log"
rm -rf "$tmp"
```
Expected: the marker in the file, one `hit` line and one `sweep` line in the log.

Measure whether codex holds its rollout file open: start `codex exec` on a trivial prompt in the background, run `lsof +D ~/.codex/sessions` while it runs, record the answer in spec section 3.4 (replace "not measured" with the finding and the date). Cursor: same with `cursor-agent` if installed; otherwise write "cursor: not measured, cursor-agent absent in this container".

- [ ] **Step 3: Spec status**

Change the status line to `Status: implemented on feat/redact-sessions (PR #139).`

- [ ] **Step 4: Full suite, then push and mark the PR ready**

```bash
bash tests/bats/run.sh
git add README.md docs/superpowers/specs/2026-09-07-redact-sessions-design.md
git commit -m "docs: README and spec status for redact-sessions"
git push
gh pr ready 139
gh pr edit 139 --title "feat: redact-sessions, scrub secrets-file values out of transcripts on disk (AICODINGBASESETUP-15)"
```
Update the PR body: summary of the binary, the triggers per harness, the state dir, the `--ack` flow, the SQLite non-goal, and a test plan listing the bats files.

- [ ] **Step 5: codex review of the PR**

```bash
~/.claude/skills/review-by-harness/run.sh 139 /workspaces/devmachine/devpod/aicoding --harness codex --review-only
```
Verify every finding against the code before acting on it. Fix real ones on the branch, re-run the suite, push, and re-run the review until it returns nothing real. Remove the review worktree and branch afterwards.

- [ ] **Step 6: Follow-up ticket and wiki**

From `/workspaces/devmachine/devpod/aicoding`:
```bash
kanban-post "redact-sessions: cover the SQLite session stores (cursor store.db, opencode.db)" --repo aiCodingBaseSetup --priority medium --body "Spec docs/superpowers/specs/2026-09-07-redact-sessions-design.md names both stores as out of scope: live SQLite with WAL on shared mounts, rewriting rows under a running writer needs its own design (sqlite3 UPDATE with replace() over the message tables, WAL checkpoint, writer quiescence). Until then a secret printed in a cursor or opencode session stays in the db."
kanban-post --link <new key> --relates AICODINGBASESETUP-15
```
Wiki (`~/homelab-wiki`, `wiki/aicoding.md` Gotchas): one entry, after `memory_search` confirms no existing owner: Claude Code does not hold its transcript open (lsof shows nothing, appends by path); the transcript roots are shared host mounts across containers with separate PID namespaces, so open-file detection cannot gate a scrubber. Source trailer: `Source: devMachine session 2026-09-07, aiCodingBaseSetup#139`.

---

## Self-review

**Spec coverage.** 3.1 modes: Tasks 2, 3. 3.2 roots incl. OpenCode placeholder: Task 2 `ROOTS`. 3.3 rules incl. base64 and URL-safe, named markers, check-and-swap, count before rewrite (implemented as marker delta, equivalent): Tasks 1, 2. 3.4 quiet period, no open-file test, measurement note: Tasks 3, 6. 3.5 triggers for all CLIs, boot, stamp and deferred: Tasks 3, 4, 5. 3.6 shared state dir, log format, pending under flock, SessionStart surfacing, `--ack`: Tasks 2, 3, 4. 3.7 fail closed: Task 2. 3.8 install: Tasks 4, 5. Section 4 tests 1 to 11 map to the bats cases in Tasks 1 to 5 (test 10b is the parallel-sweep case). Follow-up ticket for SQLite: Task 6.

**Placeholders.** None; every step has the code.

**Type consistency.** `redact_literal_rules sessions FILE` (Task 1) is what `load_rules` calls (Task 2). `scrub_one` returns 0/1 as `sweep` expects (Task 3). Hook env names `REDACT_SESSIONS_BIN`, `REDACT_SESSIONS_SYNC`, `REDACT_SESSIONS_STATE` are the same in Tasks 2, 4, 5. State file names `log`, `pending`, `deferred`, `stamp`, `lock` match across Tasks 2, 3, 4.
