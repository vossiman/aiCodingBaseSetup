#!/usr/bin/env bash
# UserPromptSubmit hook: stdout becomes extra model context. Fires only for
# Fable 5 and Mythos 5 (same model). The harness already injects the Fable
# prompting doc's progress-update, finish-the-whole-task and batch-tool-calls
# blocks, so this carries only what it does not: prose density, targeted
# edits, and no unrequested extras. See docs/fable-guidance.md. Every failure
# path exits 0 silently - a broken hook must never break a prompt.
set -u
command -v jq >/dev/null 2>&1 || exit 0
payload=$(</dev/stdin) || exit 0

model=$(printf '%s' "$payload" | jq -r '.model // empty' 2>/dev/null) || model=""
if [ -z "$model" ]; then
  transcript=$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null) || transcript=""
  if [ -n "$transcript" ] && [ -r "$transcript" ]; then
    model=$(tail -c 200000 -- "$transcript" 2>/dev/null \
      | grep -o '"model":"[^"]*"' | tail -1 | cut -d'"' -f4) || model=""
  fi
fi

case "$model" in
  *fable-5*|*mythos-5*) ;;
  *) exit 0 ;;
esac

cat <<'GUIDANCE'
Response shape for this turn:
Say what you mean in literal phrases; no metaphor or flourish standing in for a direct statement.
One idea per sentence, with paragraph breaks between ideas. Keep numbers and code identifiers out of prose unless they change what the reader does next.
When editing a file, make a targeted edit rather than rewriting the whole file unless most of it changes.
If you find a pre-existing bug, a performance concern, or behavior the task does not mention, do not fix or extend it in this change unless the requested behavior cannot work without it; report it as a follow-up in your summary. Commit tests only where the task asks for them or the repo already keeps tests for this kind of change, sized like the neighboring test files.
GUIDANCE
exit 0
