#!/usr/bin/env bash
# Resolve a dev-process-lite route.
#   routes.sh [entry] [role]
# Without a role, print the entry's routes table. With a role, resolve it to a
# model. Success: exit 0, one JSON object on stdout. Blocked: exit 2, one
# "blocked: ..." line on stderr. Never substitutes another family or harness.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
default_file="$here/routes.default.json"

block() { printf 'blocked: %s\n' "$*" >&2; exit 2; }

# --- Entry -------------------------------------------------------------------
entry=${1:-}
role=${2:-}
if [ -z "$entry" ]; then
  # Codex first: a Codex session started from Claude Code inherits CLAUDECODE.
  if [ -n "${CODEX_THREAD_ID:-}" ]; then entry=codex
  elif [ -n "${CLAUDECODE:-}" ]; then entry=claude
  else block "no entry harness detected; pass claude, codex or cursor"
  fi
fi
case "$entry" in
  claude|codex|cursor) ;;
  *) block "entry '$entry' is not supported; start runs from Claude, Codex or Cursor" ;;
esac

# --- Routes file -------------------------------------------------------------
source_file=$default_file
note=""
root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -n "$root" ] && [ -f "$root/.dev-process/routes.json" ]; then
  source_file="$root/.dev-process/routes.json"
  jq -e . "$source_file" >/dev/null 2>&1 || block "$source_file is not valid JSON"
fi
table=$(jq -c --arg e "$entry" '.routes[$e] // empty' "$source_file")
if [ -z "$table" ]; then
  [ "$source_file" != "$default_file" ] || block "no '$entry' table in $default_file"
  note="$source_file has no '$entry' table; used the default table from $default_file"
  source_file=$default_file
  table=$(jq -c --arg e "$entry" '.routes[$e]' "$default_file")
fi

if [ -z "$role" ]; then
  jq -n --arg e "$entry" --arg s "$source_file" --arg n "$note" --argjson t "$table" \
    '{entry: $e, source: $s, routes: $t} + (if $n == "" then {} else {note: $n} end)'
  exit 0
fi

# --- Route -------------------------------------------------------------------
route=$(jq -c --arg r "$role" '.[$r] // empty' <<<"$table")
[ -n "$route" ] || block "no '$role' route in the '$entry' table of $source_file"
harness=$(jq -r '.harness // ""' <<<"$route")
model=$(jq -r '.model // ""' <<<"$route")
family=$(jq -r '.family // ""' <<<"$route")
effort=$(jq -r '.effort // ""' <<<"$route")
fast=$(jq -r '.fast // false' <<<"$route")
[ -n "$model" ] && family=""

case "$effort" in
  low|medium|high|xhigh|max) ;;
  *) block "effort '$effort' in $entry.$role is not one of low, medium, high, xhigh, max" ;;
esac
if [ -z "$model" ]; then
  [[ "$family" =~ ^[a-z][a-z0-9-]*$ ]] || block "$entry.$role names neither a model nor a valid family"
fi

# --- Resolve -----------------------------------------------------------------
resolved_model=""
how=""

resolve_claude() {
  if [ -n "$model" ]; then
    [[ "$model" =~ ^claude-(fable|opus|sonnet|haiku)-[0-9]+(-[0-9]+)*(\[1m\])?$ ]] \
      || block "claude model '$model' is not a claude-<family>-<version> id"
    resolved_model=$model; how=pinned
  else
    case "$family" in
      fable|opus|sonnet|haiku) resolved_model=$family; how=alias ;;
      *) block "claude family '$family' is not one of fable, opus, sonnet, haiku" ;;
    esac
  fi
}

case "$harness" in
  claude) resolve_claude ;;
  codex|cursor) block "harness '$harness' resolution is not implemented yet" ;;
  *) block "harness '$harness' in $entry.$role is not one of claude, codex, cursor" ;;
esac

jq -n --arg entry "$entry" --arg role "$role" --arg harness "$harness" \
  --arg family "$family" --arg effort "$effort" --arg model "$resolved_model" \
  --arg how "$how" --arg source "$source_file" --arg note "$note" \
  '{entry: $entry, role: $role, harness: $harness,
    family: (if $family == "" then null else $family end),
    effort: $effort, model: $model, resolved: $how, source: $source}
   + (if $note == "" then {} else {note: $note} end)'
