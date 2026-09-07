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
