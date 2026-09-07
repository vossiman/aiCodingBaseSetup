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
