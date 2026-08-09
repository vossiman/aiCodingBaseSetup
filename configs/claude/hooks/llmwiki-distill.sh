#!/bin/bash
# Async Stop-hook launcher for the background LLMWiki distiller.
# Replaces llmwiki-nudge.sh: injecting additionalContext forced an extra
# visible model turn every firing; instead we fire-and-forget a headless
# distiller agent over only the NEW transcript bytes. Design:
# docs/superpowers/specs/2026-08-09-llmwiki-distiller-design.md
#
# Tunables:
#   LLMWIKI_NUDGE_INTERVAL   seconds between launches per project (default 900)
#   LLMWIKI_MIN_DELTA_BYTES  minimum new transcript bytes to launch (default 4096)
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

# Stamp only now — gated-out stops must not push the window, and a slow agent
# run must not double-fire.
printf '%s' "$now"  > "$state_file"  2>/dev/null
printf '%s' "$size" > "$offset_file" 2>/dev/null
find "$state_dir/offsets" -type f -mtime +30 -delete 2>/dev/null

# Copy the new bytes out — the live transcript keeps growing under the agent.
slice="$state_dir/slices/$session_id.jsonl"
tail -c +"$(( offset + 1 ))" "$transcript" > "$slice" 2>/dev/null \
  || { rm -f "$slice"; exit 0; }

log="$HOME/.cache/aicoding/llmwiki-distill.log"
{
  printf '%s launch project=%s session=%s bytes=%s-%s\n' \
    "$(date -Is)" "$slug" "$session_id" "$offset" "$size"
  LLMWIKI_DISTILLER=1 claude -p \
    --agent llmwiki-distiller \
    --settings '{"disableAllHooks": true}' \
    "Review the new session activity in $slice (project root: $root; this is the tail of a longer Claude Code session transcript in JSONL format). Follow your instructions: file durable lessons; if nothing durable emerged, do nothing."
  printf '%s done session=%s exit=%s\n' "$(date -Is)" "$session_id" "$?"
} >> "$log" 2>&1
rm -f "$slice"

exit 0
