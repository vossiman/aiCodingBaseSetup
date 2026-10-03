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
  jq -e '(.routes | type == "object") and all(.routes[]; type == "object") and all(.routes[][]; type == "object")' \
    "$source_file" >/dev/null 2>&1 || block "$source_file is not valid JSON with routes.<entry>.<role> objects"
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

codex_models() {
  if [ -n "${DEV_PROCESS_LITE_CODEX_MODELS:-}" ]; then
    cat "$DEV_PROCESS_LITE_CODEX_MODELS" 2>/dev/null || true
  else
    codex debug models 2>/dev/null || true
  fi
}

cursor_models() {
  if [ -n "${DEV_PROCESS_LITE_CURSOR_MODELS:-}" ]; then
    cat "$DEV_PROCESS_LITE_CURSOR_MODELS" 2>/dev/null || true
  else
    cursor-agent --list-models 2>/dev/null || true
  fi
}

# Newest listed, non-retiring gpt-<version>-<family> slug.
resolve_codex() {
  local list
  list=$(codex_models)
  jq -e '.models | type == "array"' >/dev/null 2>&1 <<<"$list" \
    || block "no codex model list (consulted: codex debug models)"
  if [ -n "$model" ]; then
    jq -e --arg m "$model" 'any(.models[]; .slug == $m)' >/dev/null <<<"$list" \
      || block "codex model '$model' is not installed (consulted: codex debug models)"
    resolved_model=$model; how=pinned
    return
  fi
  resolved_model=$(jq -r --arg f "$family" '
      .models[] | select(.visibility == "list" and .upgrade == null) | .slug
      | select(test("^gpt-[0-9]+(\\.[0-9]+)*-" + $f + "$"))' <<<"$list" \
    | sed -E 's/^gpt-([0-9.]+)-.*$/\1\t&/' | sort -t$'\t' -k1,1V | tail -n 1 | cut -f2)
  [ -n "$resolved_model" ] \
    || block "no codex model of family '$family' (consulted: codex debug models)"
  how=family
}

# Newest [cursor-]<family>-<version>[-<variant>...]-<effort>[-fast] selector.
resolve_cursor() {
  local list fam_re suffix
  list=$(cursor_models | awk 'NF >= 1 && $2 == "-" { print $1 }')
  [ -n "$list" ] || block "no cursor model list (consulted: cursor-agent --list-models)"
  if [ -n "$model" ]; then
    grep -qxF -- "$model" <<<"$list" \
      || block "cursor model '$model' is not installed (consulted: cursor-agent --list-models)"
    resolved_model=$model; how=pinned
    return
  fi
  fam_re=${family//./\\.}
  if [ "$fast" = true ]; then suffix="-fast"; else suffix=""; fi
  resolved_model=$(grep -E "^(cursor-)?${fam_re}-[0-9]+([.-][0-9]+)*(-[a-z]+)*-${effort}${suffix}\$" <<<"$list" \
    | awk -v fam="$family" '{
        s = $0; sub(/^cursor-/, "", s)
        v = substr(s, length(fam) + 2)
        match(v, /^[0-9]+([.-][0-9]+)*/)
        ver = substr(v, 1, RLENGTH); gsub(/-/, ".", ver)
        print ver "\t" $0
      }' \
    | sort -s -t$'\t' -k1,1V | tail -n 1 | cut -f2 || true)
  [ -n "$resolved_model" ] \
    || block "no cursor model of family '$family' at effort '$effort'$([ "$fast" = true ] && echo ' (fast)') (consulted: cursor-agent --list-models)"
  how=family
}

case "$harness" in
  claude) resolve_claude ;;
  codex) resolve_codex ;;
  cursor) resolve_cursor ;;
  *) block "harness '$harness' in $entry.$role is not one of claude, codex, cursor" ;;
esac

jq -n --arg entry "$entry" --arg role "$role" --arg harness "$harness" \
  --arg family "$family" --arg effort "$effort" --arg model "$resolved_model" \
  --arg how "$how" --arg source "$source_file" --arg note "$note" \
  '{entry: $entry, role: $role, harness: $harness,
    family: (if $family == "" then null else $family end),
    effort: $effort, model: $model, resolved: $how, source: $source}
   + (if $note == "" then {} else {note: $note} end)'
