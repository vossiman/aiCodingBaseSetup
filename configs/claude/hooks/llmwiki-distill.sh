#!/bin/bash
# Async Stop-hook launcher for the background LLMWiki distiller.
# Replaces llmwiki-nudge.sh: injecting additionalContext forced an extra
# visible model turn every firing; instead we fire-and-forget a headless
# distiller agent over only the NEW transcript bytes. Design:
# docs/superpowers/specs/2026-08-09-llmwiki-distiller-design.md
#
#
# Memory-lanes slice tee (additive, 2026-08-13): after the delta slice is
# written and state is stamped, a redacted COPY of the slice is spooled to
# $MEMORY_LANES_SPOOL as <session-id>-<offset> for the memory-lanes A/B stack
# to ingest (that name is the idempotency key — re-teeing the same window
# overwrites rather than duplicating). The tee is wholly best-effort: every
# failure is swallowed, the distiller path is untouched. Spec:
# docs/superpowers/specs/2026-08-13-memory-ab-testing-design.md
#
# Tunables:
#   LLMWIKI_NUDGE_INTERVAL   seconds between launches per project (default 900)
#   LLMWIKI_MIN_DELTA_BYTES  minimum new transcript bytes to launch (default 4096)
#   MEMORY_LANES_TEE         set to 0 to disable the spool tee (default on)
#   MEMORY_LANES_SPOOL       spool dir (default ~/.local/state/memory-lanes/inbox)
# Never exits non-zero — a broken distiller must never block stopping.

# Recursion guard: never act inside a distiller-spawned session.
[ -n "$LLMWIKI_DISTILLER" ] && exit 0

THRESHOLD_SECONDS="${LLMWIKI_NUDGE_INTERVAL:-900}"
MIN_DELTA="${LLMWIKI_MIN_DELTA_BYTES:-4096}"

input="$(cat)"

transcript="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)"
[ -f "$transcript" ] || exit 0
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
case "$session_id" in (''|*[!a-zA-Z0-9_-]*) exit 0 ;; esac
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[ -z "$cwd" ] && cwd="$PWD"

# Throttle is per project root so parallel sessions in different repos don't
# starve each other; non-git dirs fall back to the cwd itself.
root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)"
[ -z "$root" ] && root="$cwd"
slug="$(printf '%s' "$root" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
[ -z "$slug" ] && slug="global"

state_dir="$HOME/.cache/aicoding/llmwiki-nudge"
mkdir -p "$state_dir/offsets" "$state_dir/slices" 2>/dev/null

state_file="$state_dir/$slug"
now="$(date +%s)"
last=0
[ -f "$state_file" ] && last="$(cat "$state_file" 2>/dev/null || echo 0)"
case "$last" in (*[!0-9]*|'') last=0 ;; esac
[ "$(( now - last ))" -lt "$THRESHOLD_SECONDS" ] && exit 0

# Transcript-delta gate. Offsets are per transcript (sessions each have their
# own file, the throttle is per project). Offset > size means the transcript
# was rewritten/compacted — start over from zero.
offset_file="$state_dir/offsets/$session_id"
offset=0
[ -f "$offset_file" ] && offset="$(cat "$offset_file" 2>/dev/null || echo 0)"
case "$offset" in (*[!0-9]*|'') offset=0 ;; esac
size="$(stat -c %s "$transcript" 2>/dev/null || echo 0)"
[ "$offset" -gt "$size" ] && offset=0
[ "$(( size - offset ))" -lt "$MIN_DELTA" ] && exit 0

command -v claude >/dev/null 2>&1 || exit 0

# Copy the new bytes out — the live transcript keeps growing under the agent.
slice="$state_dir/slices/$session_id.jsonl"
tail -c +"$(( offset + 1 ))" "$transcript" > "$slice" 2>/dev/null \
  || { rm -f "$slice"; exit 0; }

# Stamp only after slice succeeds — gated-out stops and slice failures must not
# push the window, and a slow agent run must not double-fire.
printf '%s' "$now"  > "$state_file"  2>/dev/null
printf '%s' "$size" > "$offset_file" 2>/dev/null
find "$state_dir/offsets" -type f -mtime +30 -delete 2>/dev/null
find "$state_dir/slices" -type f -mtime +30 -delete 2>/dev/null

# --- Memory-lanes slice tee ------------------------------------------------
# Everything below is additive and best-effort. Extraction lanes persist raw
# episodes and replay them into future contexts, so the slice is scrubbed
# before it leaves this machine's hook. Three layers, in order:
#
#   1. LITERAL   exact values read from the read-only secrets file, plus their
#                JSON-escaped variants (transcripts are JSONL, so a value
#                containing `"` or `\` appears on disk as `\"` / `\\`).
#   2. PATTERNS  secret-SHAPED tokens (vendor prefixes, private keys, JWTs,
#                URL credentials, credential-keyword assignments, long hex,
#                base64/AWS-secret-shaped blobs).
#   3. ENTROPY   catch-all for >=30-char 3-character-class tokens.
#
# The secrets file is only ever READ, never written.
#
# FAIL-CLOSED policy for the literal layer (security review 2026-08-13):
#   - secrets file ABSENT  -> proceed with the pattern + entropy layers only.
#     A machine with no secrets file has no literal values to leak, so there
#     is nothing for layer 1 to do and skipping the tee would buy nothing.
#   - secrets file EXISTS but is UNREADABLE -> skip the tee entirely (no spool
#     file is written). A no-op sed from an unreadable file would silently
#     ship an unredacted slice.
#   - secrets file PARSES PARTIALLY -> skip the tee entirely. The generated
#     rule count is compared against an independent count of qualifying
#     KEY=value lines; any mismatch means some value was missed, so nothing
#     is spooled.
# "Fail closed" always means "no spool file" — never "the hook fails".
#
# LITERAL-LAYER FLOOR: only values of 8+ characters (after quote-stripping)
# get a literal rule. Shorter values are too collision-prone to redact
# globally — a 4-char value would shred ordinary prose. They remain covered
# only if they happen to match a pattern rule.
#
# OUT OF SCOPE (documented residual gaps, accepted 2026-08-13):
#   - base64- or URL-encoded ENCODINGS of a secrets-file value. Only the raw
#     and JSON-escaped forms are matched.
#   - secrets-file values shorter than 8 characters (see the floor above).
#   - lowercase-only tokens shorter than 48 characters that are not written
#     under a credential-keyword assignment. The long-hex rule starts at 48
#     specifically to EXEMPT 40-character lowercase-hex git SHAs, which are
#     ubiquitous in these transcripts and carry no secret; redacting them
#     would gut the slice's usefulness. Anything in that 8..47 lowercase band
#     is covered by the literal layer when it comes from the secrets file.

# Applies the JSON string escaping that JSONL transcripts use: backslash
# first, then double quote.
_ml_json_escape() {
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  printf '%s' "$v"
}

# Escapes ERE metacharacters (backslashes first). The class lists `[` last:
# `[.` inside a bracket expression opens a POSIX collating symbol.
_ml_ere_escape() {
  printf '%s' "$1" | sed -e 's,\\,\\\\,g' -e 's,[]^$*+?(){}|/.[],\\&,g'
}

# Counts the KEY=value lines in the secrets file whose value (after the same
# quote-stripping the generator does) is >=8 chars. Independent of the
# generator loop, so a truncated/partial read of the file shows up as a count
# mismatch rather than as silently missing rules.
_ml_expected_rules() {
  awk '
    /^#/  { next }
    /^$/  { next }
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

# Emits a sed script redacting the literal values held in the secrets file.
# Printed to stdout and captured into a shell variable — never written to
# disk, so no plaintext secret is ever spilled by the redactor itself.
# Exit status: 0 = script is trustworthy (possibly empty, if the file is
# absent); non-zero = unreadable or partially parsed, caller must skip the tee.
_ml_literal_script() {
  local f="$HOME/.aicodingsetup/.secrets.env" line val esc jval jesc
  local out='' rules=0 expected=0
  # Absent file: nothing to redact literally. Documented above.
  [ -e "$f" ] || return 0
  [ -r "$f" ] || return 1

  expected="$(_ml_expected_rules "$f")" || return 1
  case "$expected" in (''|*[!0-9]*) return 1 ;; esac

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ('#'*|'') continue ;; (*=*) ;; (*) continue ;; esac
    val="${line#*=}"
    val="${val%\"}"; val="${val#\"}"
    val="${val%\'}"; val="${val#\'}"
    [ "${#val}" -ge 8 ] || continue
    esc="$(_ml_ere_escape "$val")" || return 1
    [ -n "$esc" ] || return 1
    out+="s/$esc/[REDACTED]/g"$'\n'
    rules=$(( rules + 1 ))
    # JSON-escaped variant — only when it actually differs from the raw form.
    jval="$(_ml_json_escape "$val")"
    if [ "$jval" != "$val" ]; then
      jesc="$(_ml_ere_escape "$jval")" || return 1
      [ -n "$jesc" ] || return 1
      out+="s/$jesc/[REDACTED]/g"$'\n'
    fi
  done < "$f" || return 1

  [ "$rules" -eq "$expected" ] || return 1
  printf '%s' "$out"
}

# stdin -> stdout, redacted. $1 is the literal sed script from
# _ml_literal_script (may be empty).
_ml_redact() {
  sed -E -f <(printf '%s' "$1") \
  | sed -E \
    -e 's/-----BEGIN[A-Za-z ]*PRIVATE KEY-----.*-----END[A-Za-z ]*PRIVATE KEY-----/[REDACTED]/g' \
    -e 's/-----BEGIN[A-Za-z ]*PRIVATE KEY-----.*/[REDACTED]/g' \
    -e 's/AKIA[0-9A-Z]{16}/[REDACTED]/g' \
    -e 's/(gh[pousr]|github_pat)_[A-Za-z0-9_]{20,}/[REDACTED]/g' \
    -e 's/xox[baprs]-[A-Za-z0-9-]{10,}/[REDACTED]/g' \
    -e 's/AIza[0-9A-Za-z_-]{30,}/[REDACTED]/g' \
    -e 's/sk-[A-Za-z0-9_-]{20,}/[REDACTED]/g' \
    -e 's/fc-[A-Za-z0-9]{20,}/[REDACTED]/g' \
    -e 's/npm_[A-Za-z0-9]{30,}/[REDACTED]/g' \
    -e 's/glpat-[A-Za-z0-9_-]{20,}/[REDACTED]/g' \
    -e 's/[0-9a-f]{48,}/[REDACTED]/g' \
    -e 's/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*/[REDACTED]/g' \
    -e 's/Bearer[[:space:]]+[A-Za-z0-9._=-]{20,}/Bearer [REDACTED]/g' \
    -e 's#([a-zA-Z][a-zA-Z0-9+.-]*://)[^/[:space:]:@]+:[^/[:space:]@]+@#\1[REDACTED]@#g' \
    -e 's/((password|passwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|private[_-]?key|token|key)["\x27]?[[:space:]]*[:=][[:space:]]*["\x27]?)[^"\x27[:space:],;)}]{8,}/\1[REDACTED]/Ig' \
  | awk '
      # AWS-secret-shaped / raw base64 material: a 40+ char run over the
      # base64 alphabet that contains at least one "/" or "+" AND both letters
      # and digits. The "/"-or-"+" requirement is what keeps ordinary long
      # identifiers, hex digests and git SHAs out; long base64 blobs in a
      # transcript are acceptable collateral (over-redacting a blob costs
      # nothing, leaking a key costs everything). Done in awk because the
      # three independent "contains" conditions do not express in one ERE.
      function b64(t) {
        if (length(t) >= 40 && t ~ /[\/+]/ && t ~ /[A-Za-z]/ && t ~ /[0-9]/)
          return "[REDACTED]"
        return t
      }
      {
        out = ""; tok = ""; n = length($0)
        for (i = 1; i <= n; i++) {
          c = substr($0, i, 1)
          if (c ~ /[A-Za-z0-9\/+=]/) { tok = tok c }
          else { out = out b64(tok) c; tok = "" }
        }
        print out b64(tok)
      }' \
  | awk '
      # High-entropy catch-all: 30+ chars mixing upper, lower and digits.
      function flushtok(t) {
        if (length(t) >= 30 && t ~ /[A-Z]/ && t ~ /[a-z]/ && t ~ /[0-9]/)
          return "[REDACTED]"
        return t
      }
      {
        out = ""; tok = ""; n = length($0)
        for (i = 1; i <= n; i++) {
          c = substr($0, i, 1)
          if (c ~ /[A-Za-z0-9+=_-]/) { tok = tok c }
          else { out = out flushtok(tok) c; tok = "" }
        }
        print out flushtok(tok)
      }'
}

# Redact into a temp file inside the spool dir (same filesystem), then rename
# atomically so a watcher never sees a partial or unredacted slice.
_ml_tee() {
  local src="$1" sid="$2" off="$3" spool tmp lit
  spool="${MEMORY_LANES_SPOOL:-$HOME/.local/state/memory-lanes/inbox}"
  # 0700: the spool holds session transcripts, so it must not inherit an
  # ambient umask that leaves it group/world readable. -m covers the leaf;
  # chmod makes it certain even when the dir already existed.
  mkdir -p -m 700 "$spool" || return 0
  chmod 700 "$spool" 2>/dev/null

  # Retention, mirroring the state-dir policy: the tee owns this directory
  # (the watcher only reads), so it is the one that prunes. Orphaned temp
  # files come from a killed redaction; an hour is far longer than any run.
  find "$spool" -maxdepth 1 -name '.tmp-*' -mmin +60 -delete 2>/dev/null
  find "$spool" -maxdepth 1 -type f -mtime +30 -delete 2>/dev/null

  # Fail closed: an unreadable or partially parsed secrets file means the
  # literal layer cannot be trusted, so nothing is spooled at all.
  lit="$(_ml_literal_script)" || return 0

  tmp="$(mktemp "$spool/.tmp-XXXXXX")" || return 0
  chmod 600 "$tmp" 2>/dev/null
  if _ml_redact "$lit" < "$src" > "$tmp"; then
    mv -f "$tmp" "$spool/${sid}-${off}" || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
  return 0
}

# Ship spooled slices to the central inbox on vossisrv. Best-effort and
# silent: any failure leaves files in the local spool and the next hook run
# re-ships (at-least-once; the watcher's markers dedupe). The key is
# command=-restricted server-side (rrsync write-only into the inbox), so it
# can drop slices and nothing else.
_ml_ship() {
  [ "${MEMORY_LANES_SHIP:-1}" != "0" ] || return 0
  local spool key target
  spool="${MEMORY_LANES_SPOOL:-$HOME/.local/state/memory-lanes/inbox}"
  key="${MEMORY_LANES_SHIP_KEY:-$HOME/.aicodingsetup/memory-lanes-ship}"
  target="${MEMORY_LANES_SHIP_TARGET:-vossi@10.0.0.249:/}"
  [ -f "$key" ] || return 0                  # no key deployed -> local spool only
  command -v rsync >/dev/null 2>&1 || return 0
  find "$spool" -maxdepth 1 -type f ! -name '.*' -print -quit 2>/dev/null | grep -q . || return 0
  rsync -a --timeout=10 --exclude='.tmp-*' --remove-source-files \
    -e "ssh -i $key -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new" \
    "$spool"/ "$target" >/dev/null 2>&1 || true
}

if [ "${MEMORY_LANES_TEE:-1}" != "0" ]; then
  ( _ml_tee "$slice" "$session_id" "$offset" ) >/dev/null 2>&1 || true
  ( _ml_ship ) >/dev/null 2>&1 || true
fi
# --- end memory-lanes slice tee --------------------------------------------

log="$HOME/.cache/aicoding/llmwiki-distill.log"
{
  printf '%s launch project=%s session=%s bytes=%s-%s\n' \
    "$(date -Is)" "$slug" "$session_id" "$offset" "$size"
  LLMWIKI_DISTILLER=1 claude -p \
    --agent llmwiki-distiller \
    --settings '{"disableAllHooks": true, "permissions": {"allow": ["Write", "Bash(git:*)", "Bash(mkdir:*)"]}}' \
    "Review the new session activity in $slice (project root: $root; this is the tail of a longer Claude Code session transcript in JSONL format). Follow your instructions: file durable lessons; if nothing durable emerged, do nothing."
  rc=$?
  printf '%s done session=%s exit=%s\n' "$(date -Is)" "$session_id" "$rc"
} >> "$log" 2>&1
rm -f "$slice"

exit 0
