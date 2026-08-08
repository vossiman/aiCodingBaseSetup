#!/bin/bash
# Throttled Stop-hook nudge for knowledge distillation (LLMWiki rollout).
# Fires at end of each turn but stays silent unless enough time has passed,
# then injects a one-line reminder so lesson-filing doesn't drift over a long
# session. The model decides whether anything is actually worth filing; the
# workflow contract itself lives in homelab-wiki's AGENTS.md (four-CLI), this
# hook is a Claude-only reliability bonus. Pattern adapted from milepost
# (github.com/sashamitrovich/milepost, MIT).
#
# Tunable: LLMWIKI_NUDGE_INTERVAL (seconds, default 900 = 15 min).
# Never exits non-zero — a broken nudge must never block stopping.

THRESHOLD_SECONDS="${LLMWIKI_NUDGE_INTERVAL:-900}"

input="$(cat)"

cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[ -z "$cwd" ] && cwd="$PWD"

# Throttle per project root so parallel sessions in different repos don't
# starve each other.
root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)"
[ -z "$root" ] && root="$cwd"
slug="$(printf '%s' "$root" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
[ -z "$slug" ] && slug="global"

state_dir="$HOME/.cache/aicoding/llmwiki-nudge"
mkdir -p "$state_dir" 2>/dev/null
state_file="$state_dir/$slug"

now="$(date +%s)"
last=0
[ -f "$state_file" ] && last="$(cat "$state_file" 2>/dev/null || echo 0)"
case "$last" in (*[!0-9]*|'') last=0 ;; esac

if [ "$(( now - last ))" -lt "$THRESHOLD_SECONDS" ]; then
  exit 0
fi

printf '%s' "$now" > "$state_file" 2>/dev/null

msg="[homelab-wiki reminder] If this session surfaced a durable lesson that is not yet filed: cross-project facts (hosts, network, ports, backups, incidents, tool identities) belong in ~/homelab-wiki (clone github.com/vossiman/homelab-wiki if missing, follow its AGENTS.md: pull first, edit the owning page, commit+push to main autonomously); project-internal lessons go to this project's CLAUDE.md or docs/notes/. If nothing durable emerged, do nothing and stop."

jq -nc --arg m "$msg" \
  '{hookSpecificOutput:{hookEventName:"Stop", additionalContext:$m}}' 2>/dev/null \
  || printf '{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":%s}}' "\"$msg\""

exit 0
