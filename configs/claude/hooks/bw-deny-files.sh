#!/bin/bash
# bw-deny-files.sh — Claude Code PreToolUse hook that blocks access to sensitive files.
# Installed globally but only activates when BW_DENY_PATTERNS_FILE is set (inside sandbox).
# Receives JSON on stdin from Claude Code with tool_name and tool_input.

set -euo pipefail

# No-op outside the sandbox
[[ -z "${BW_DENY_PATTERNS_FILE:-}" ]] && exit 0
[[ ! -f "$BW_DENY_PATTERNS_FILE" ]] && exit 0

# Read hook input
INPUT="$(cat)"
TOOL_NAME="$(echo "$INPUT" | jq -r '.tool_name // empty')"
[[ -z "$TOOL_NAME" ]] && exit 0

# Load deny patterns into array
PATTERNS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && PATTERNS+=("$line")
done < "$BW_DENY_PATTERNS_FILE"
(( ${#PATTERNS[@]} == 0 )) && exit 0

# Check if a basename matches any deny pattern (glob matching)
matches_deny_pattern() {
  local filepath="$1"
  local base
  base="$(basename "$filepath")"
  for pattern in "${PATTERNS[@]}"; do
    # shellcheck disable=SC2254
    case "$base" in
      $pattern) return 0 ;;
    esac
  done
  return 1
}

# Emit deny JSON
deny() {
  local filename="$1"
  cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "bw-AICode: access to '${filename}' blocked (sensitive file)"
  }
}
EOF
  exit 0
}

# --- Tool-specific checks ---

case "$TOOL_NAME" in
  Read|Edit|Write|MultiEdit)
    FILE_PATH="$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')"
    if [[ -n "$FILE_PATH" ]] && matches_deny_pattern "$FILE_PATH"; then
      deny "$(basename "$FILE_PATH")"
    fi
    ;;

  Grep)
    # Only block when targeting a specific file (not a directory)
    GREP_PATH="$(echo "$INPUT" | jq -r '.tool_input.path // empty')"
    if [[ -n "$GREP_PATH" && ! -d "$GREP_PATH" ]] && matches_deny_pattern "$GREP_PATH"; then
      deny "$(basename "$GREP_PATH")"
    fi
    ;;

  Bash)
    CMD="$(echo "$INPUT" | jq -r '.tool_input.command // empty')"
    [[ -z "$CMD" ]] && exit 0

    # Commands that read file contents
    READ_CMDS='cat|head|tail|less|more|bat|batcat|tac|nl|rev|strings|xxd|hexdump|od|file|wc|source|\.'
    # Commands that search/process files (take filename args)
    SEARCH_CMDS='grep|rg|ag|ack|sed|awk|gawk|perl|ruby'
    # Commands that write files
    WRITE_CMDS='tee|cp|mv|rm'

    ALL_CMDS="${READ_CMDS}|${SEARCH_CMDS}|${WRITE_CMDS}"

    # Extract potential file arguments from the command.
    # Strategy: find lines matching known commands and check each token.
    # This is intentionally simple — covers common cases, not all edge cases.

    # Split command into tokens and check each one that looks like a file path
    # against the deny list. We look for tokens after known commands.
    while IFS= read -r token; do
      [[ -z "$token" ]] && continue
      # Skip flags (start with -)
      [[ "$token" == -* ]] && continue
      # Check if this token's basename matches a deny pattern
      if matches_deny_pattern "$token"; then
        deny "$(basename "$token")"
      fi
    done < <(
      # Match lines that start with (or pipe into) a known command,
      # then extract all non-flag arguments
      echo "$CMD" | grep -oE "(^|[|;&])\s*(${ALL_CMDS})\s+[^|;&]+" | \
        sed -E "s/^\s*[|;&]?\s*(${ALL_CMDS})\s+//" | \
        tr ' ' '\n'
    )

    # Also check for redirection targets: > file, >> file
    while IFS= read -r redir_target; do
      [[ -z "$redir_target" ]] && continue
      if matches_deny_pattern "$redir_target"; then
        deny "$(basename "$redir_target")"
      fi
    done < <(echo "$CMD" | grep -oE '>{1,2}\s*[^ |;&]+' | sed -E 's/>{1,2}\s*//')

    # Check for input redirection: < file
    while IFS= read -r redir_source; do
      [[ -z "$redir_source" ]] && continue
      if matches_deny_pattern "$redir_source"; then
        deny "$(basename "$redir_source")"
      fi
    done < <(echo "$CMD" | grep -oE '<\s*[^ |;&]+' | sed -E 's/<\s*//')
    ;;
esac

# Default: allow
exit 0
