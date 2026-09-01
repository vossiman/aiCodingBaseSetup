#!/usr/bin/env bash
# UserPromptSubmit hook: stdout becomes extra model context. Fires only for
# Opus 5, whose short system-prompt preset carries none of the response-shaping
# rules the other models get. Every failure path exits 0 silently - a broken
# hook must never break a prompt.
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
  *opus-5*) ;;
  *) exit 0 ;;
esac

cat <<'GUIDANCE'
Response shape for this turn:
Before your first tool call, say in one sentence what you are about to do.
While working, give a brief update only when you find something important or
change direction. When you finish, lead with the outcome: your first sentence
answers "what happened" or "what did you find", with supporting detail after it
for readers who want it. Close a multi-step task with a short summary.
Name functions, line numbers and library internals only where they change a
decision the reader has to make.
GUIDANCE
exit 0
