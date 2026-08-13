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
# before it leaves this machine's hook: literal secrets first (exact values
# from the read-only secrets file), then secret-SHAPED patterns, then a
# high-entropy catch-all. The secrets file is only ever read.

# Emits a sed script redacting the literal values held in the secrets file.
# Printed to stdout and consumed via process substitution — never written to
# disk, so no plaintext secret is ever spilled by the redactor itself.
_ml_literal_script() {
  local f="$HOME/.aicodingsetup/.secrets.env" line val esc
  [ -r "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ('#'*|'') continue ;; (*=*) ;; (*) continue ;; esac
    val="${line#*=}"
    val="${val%\"}"; val="${val#\"}"
    val="${val%\'}"; val="${val#\'}"
    [ "${#val}" -ge 8 ] || continue
    # Escape ERE metacharacters (backslashes first). The class lists `[` last:
    # `[.` inside a bracket expression opens a POSIX collating symbol.
    esc="$(printf '%s' "$val" | sed -e 's,\\,\\\\,g' -e 's,[]^$*+?(){}|/.[],\\&,g')" || continue
    printf 's/%s/[REDACTED]/g\n' "$esc"
  done < "$f"
}

# stdin -> stdout, redacted.
_ml_redact() {
  sed -E -f <(_ml_literal_script) \
  | sed -E \
    -e 's/-----BEGIN[A-Za-z ]*PRIVATE KEY-----.*-----END[A-Za-z ]*PRIVATE KEY-----/[REDACTED]/g' \
    -e 's/-----BEGIN[A-Za-z ]*PRIVATE KEY-----.*/[REDACTED]/g' \
    -e 's/AKIA[0-9A-Z]{16}/[REDACTED]/g' \
    -e 's/(gh[pousr]|github_pat)_[A-Za-z0-9_]{20,}/[REDACTED]/g' \
    -e 's/xox[baprs]-[A-Za-z0-9-]{10,}/[REDACTED]/g' \
    -e 's/AIza[0-9A-Za-z_-]{30,}/[REDACTED]/g' \
    -e 's/sk-[A-Za-z0-9_-]{20,}/[REDACTED]/g' \
    -e 's/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*/[REDACTED]/g' \
    -e 's/Bearer[[:space:]]+[A-Za-z0-9._=-]{20,}/Bearer [REDACTED]/g' \
    -e 's#([a-zA-Z][a-zA-Z0-9+.-]*://)[^/[:space:]:@]+:[^/[:space:]@]+@#\1[REDACTED]@#g' \
    -e 's/((password|passwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|private[_-]?key|token|key)["\x27]?[[:space:]]*[:=][[:space:]]*["\x27]?)[^"\x27[:space:],;)}]{8,}/\1[REDACTED]/Ig' \
  | awk '
      function flushtok(t) {
        if (length(t) >= 32 && t ~ /[A-Z]/ && t ~ /[a-z]/ && t ~ /[0-9]/)
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
  local src="$1" sid="$2" off="$3" spool tmp
  spool="${MEMORY_LANES_SPOOL:-$HOME/.local/state/memory-lanes/inbox}"
  mkdir -p "$spool" || return 0
  tmp="$(mktemp "$spool/.tmp-XXXXXX")" || return 0
  if _ml_redact < "$src" > "$tmp"; then
    mv -f "$tmp" "$spool/${sid}-${off}" || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
  return 0
}

if [ "${MEMORY_LANES_TEE:-1}" != "0" ]; then
  ( _ml_tee "$slice" "$session_id" "$offset" ) >/dev/null 2>&1 || true
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
