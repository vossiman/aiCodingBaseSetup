#!/usr/bin/env bash
# SessionStart hook (Claude Code, cursor sessionStart): if redact-sessions has
# found a secrets-file value in a transcript and nobody has acknowledged the
# rotation yet, say so at the top of the session. The marker is NOT cleared
# here; `redact-sessions --ack KEY` clears it once the key is rotated, so the
# warning repeats in every new session on every container until someone acts.
# FAIL-OPEN: always exits 0. Intentionally no set -e.

# Output contract differs per harness: Claude Code takes plain stdout as
# context; cursor parses stdout as JSON and injects only additional_context.
# cursor's hooks.json passes --cursor to pick the JSON form.
fmt=plain
[ "${1:-}" = "--cursor" ] && fmt=json

state="${REDACT_SESSIONS_STATE:-$HOME/.claude/state/redact-sessions}"
[ -s "$state/pending" ] || exit 0

keys="$(grep -v '^SECRETS_FILE_UNREADABLE$' "$state/pending" 2>/dev/null | sort -u | tr '\n' ' ')"
unreadable=0
grep -qx 'SECRETS_FILE_UNREADABLE' "$state/pending" 2>/dev/null && unreadable=1

msg="# redact-sessions: credentials need rotating"$'\n'
if [ -n "${keys// /}" ]; then
  msg+="A transcript on this machine contained a secrets-file value of: $keys"$'\n'
  msg+="The file has been scrubbed, but the value reached an agent and is burned."$'\n'
  msg+="Last hit per key (a hit in an old session matched against a value the"$'\n'
  msg+="user rotated elsewhere is stale, so show the user these lines):"$'\n'
  for k in $keys; do
    last="$(grep " hit key=$k " "$state/log" 2>/dev/null | tail -n 1)"
    [ -n "$last" ] || continue
    msg+="  $k: $(printf '%s' "$last" | awk '{print $1}') $(printf '%s' "$last" | sed 's/.* file=\([^ ]*\).*/\1/')"$'\n'
  done
  msg+="Tell the user now: rotate each key, edit the host secrets file in place,"$'\n'
  msg+="then run \`redact-sessions --ack KEY\` for each one. Details: $state/log"$'\n'
  msg+="An agent must not run \`redact-sessions --ack\` itself: the ack is the user's"$'\n'
  msg+="statement that the key was rotated, and only they know."$'\n'
fi
if [ "$unreadable" = 1 ]; then
  msg+="Also: the secrets file exists but could not be read or parsed fully, so"$'\n'
  msg+="no transcript has been scrubbed. Tell the user; run \`redact-sessions --ack SECRETS_FILE_UNREADABLE\` once fixed."$'\n'
fi

if [ "$fmt" = json ]; then
  printf '%s' "$msg" | jq -Rs '{additional_context: .}' 2>/dev/null || exit 0
else
  printf '%s' "$msg"
fi
exit 0
