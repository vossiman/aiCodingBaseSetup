#!/usr/bin/env bash
# Claude Code Stop / SessionEnd hook (also cursor stop / sessionEnd; cursor
# sends the same transcript_path and hook_event_name fields): scrub
# transcripts on disk with redact-sessions. On SessionEnd the session's own
# file is scrubbed now, because the harness has said it is done writing;
# everything else goes through the sweep, which honours the quiet period.
#
# FAIL-OPEN: never blocks the harness. Every path exits 0; the work runs
# detached unless REDACT_SESSIONS_SYNC=1 (tests).
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

# Claude Code says SessionEnd, cursor says sessionEnd; both mean "done writing".
# A codex rollout is also scrubbed on Stop: codex holds it open with O_APPEND
# and redact-sessions rewrites it in place, which that writer follows, so
# there is no reason to wait for a quiet period a chatty session never gives.
now=0
case "$event" in SessionEnd|sessionEnd) now=1 ;; esac
case "$event:$transcript" in Stop:*/.codex/sessions/*) now=1 ;; esac
[ "$now" = 1 ] && [ -n "$transcript" ] && [ -f "$transcript" ] || transcript=""

# Everything runs detached (own session, so the harness exiting does not
# take it down) and the hook returns at once: codex allows SessionEnd hooks
# only a few seconds, and nothing here needs the harness to wait.
work() {
  [ -n "$transcript" ] && { timeout 60 "$bin" --now "$transcript" >/dev/null 2>&1 || true; }
  timeout 300 "$bin" --sweep >/dev/null 2>&1 || true
}
if [ "${REDACT_SESSIONS_SYNC:-}" = "1" ]; then
  work
else
  setsid -f bash -c "$(declare -f work); bin=$(printf '%q' "$bin"); transcript=$(printf '%q' "$transcript"); work" >/dev/null 2>&1 < /dev/null \
    || { nohup bash -c "$(declare -f work); bin=$(printf '%q' "$bin"); transcript=$(printf '%q' "$transcript"); work" >/dev/null 2>&1 < /dev/null & }
fi
exit 0
