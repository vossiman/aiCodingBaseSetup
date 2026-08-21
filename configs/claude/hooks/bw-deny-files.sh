#!/bin/bash
# bw-deny-files.sh — Claude Code PreToolUse hook that blocks access to secrets
# and private keys.
#
# Originally vendored from bw-AICode, where it only activated inside the
# bubblewrap sandbox (BW_DENY_PATTERNS_FILE set). That made it a NO-OP in the
# devpod container and on hosts — the common case — so agents happily
# `cat ~/.aicodingsetup/.secrets.env` and spilled every token into their
# transcript. As of 2026-08-21 this is a deliberate fork: a built-in deny list
# is ALWAYS enforced, and BW_DENY_PATTERNS_FILE (when set) adds extra patterns
# on top rather than being the on/off switch.
#
# Receives JSON on stdin from Claude Code with tool_name and tool_input.
# Emits a PreToolUse "deny" decision, or exits 0 to allow.
#
# Escape hatch for legitimate troubleshooting: `secrets-check`, which reports
# which keys are present/empty without ever printing a value.

set -euo pipefail

# --- Deny lists -------------------------------------------------------------

# Basename globs. Matched against the basename of any candidate path.
DENY_BASENAMES=(
  '.secrets.env'
  '*.secrets.env'
  'secrets.env'
  '.env.secrets'
  'id_rsa'
  'id_dsa'
  'id_ecdsa'
  'id_ed25519'
  '*.pem'
  '*.key'
  '*.p12'
  '*.pfx'
  '.netrc'
  '.pgpass'
)

# Whole directories whose contents are sensitive. Matched against the full
# path. Anything inside is denied unless its basename is in DIR_ALLOW below —
# this is what catches extensionless private keys such as
# ~/.aicodingsetup/memory-lanes-ship.
SENSITIVE_DIRS=(
  '*/.aicodingsetup'
  '*/.aicodingsetup/*'
  '*/.ssh'
  '*/.ssh/*'
)

# Basenames that stay readable even inside a sensitive dir: deploy-state and
# boot scripts agents genuinely need, plus non-secret ssh metadata.
DIR_ALLOW=(
  'manifest.json'
  'on-start.sh'
  'update.sh'
  'config'
  'known_hosts'
  'known_hosts2'
  'authorized_keys'
  '*.pub'
)

# Extra patterns from the bubblewrap sandbox, when present. Additive.
if [[ -n "${BW_DENY_PATTERNS_FILE:-}" && -f "${BW_DENY_PATTERNS_FILE}" ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] && DENY_BASENAMES+=("$line")
  done < "$BW_DENY_PATTERNS_FILE"
fi

# --- Matching ---------------------------------------------------------------

glob_match() {
  local value="$1" pattern="$2"
  # shellcheck disable=SC2254
  case "$value" in
    $pattern) return 0 ;;
  esac
  return 1
}

# Expand a leading ~ and $HOME so tokens as typed can be tested on disk.
expand_path() {
  local p="$1"
  p="${p#\"}"; p="${p%\"}"
  p="${p#\'}"; p="${p%\'}"
  p="${p/#\~/$HOME}"
  p="${p//\$HOME/$HOME}"
  p="${p//\$\{HOME\}/$HOME}"
  printf '%s' "$p"
}

# is_denied_path <path> — pattern check only; does not care whether the file
# exists. Used for tool arguments and redirection targets.
is_denied_path() {
  local filepath base pattern
  filepath="$(expand_path "$1")"
  base="$(basename "$filepath")"

  for pattern in "${DENY_BASENAMES[@]}"; do
    glob_match "$base" "$pattern" && return 0
  done

  local dir_hit=false
  for pattern in "${SENSITIVE_DIRS[@]}"; do
    if glob_match "$filepath" "$pattern"; then dir_hit=true; break; fi
  done
  if [[ "$dir_hit" == true ]]; then
    for pattern in "${DIR_ALLOW[@]}"; do
      glob_match "$base" "$pattern" && return 1
    done
    # Listing a sensitive dir is fine; reading its contents is not.
    [[ -d "$filepath" ]] && return 1
    return 0
  fi

  return 1
}

deny() {
  local filename="$1"
  local reason="Access to '${filename}' is blocked: it holds secrets or private keys, and reading it would copy them into this transcript. Do not work around this block. Run 'secrets-check' to see which keys are set (names and status only, never values), or ask the user."
  jq -n --arg r "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

# --- Main -------------------------------------------------------------------

INPUT="$(cat)"
# Malformed input must never make the hook exit non-zero: a failing PreToolUse
# hook is an error surfaced to the agent, not a clean allow. Fall through to
# "allow" instead — this hook is a guard, not a validator.
TOOL_NAME="$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
[[ -z "$TOOL_NAME" ]] && exit 0

case "$TOOL_NAME" in
  Read|Edit|Write|MultiEdit|NotebookEdit)
    FILE_PATH="$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')"
    if [[ -n "$FILE_PATH" ]] && is_denied_path "$FILE_PATH"; then
      deny "$(basename "$FILE_PATH")"
    fi
    ;;

  Grep|Glob)
    # Only block when targeting a specific file; searching a directory is fine
    # (the hook cannot know what a recursive search will surface, and denying
    # every directory search would make the tool useless).
    TARGET="$(echo "$INPUT" | jq -r '.tool_input.path // empty')"
    if [[ -n "$TARGET" && ! -d "$(expand_path "$TARGET")" ]] && is_denied_path "$TARGET"; then
      deny "$(basename "$TARGET")"
    fi
    ;;

  Bash|apply_patch)
    # Codex uses the same PreToolUse contract as Claude Code — verified against
    # codex-cli 0.148.0 by feeding it a real tool call: tool_name "Bash" with
    # tool_input.command as a plain string, and "apply_patch" with the patch
    # text in that same field. So one script serves both agents.
    CMD="$(echo "$INPUT" | jq -r '.tool_input.command // empty')"
    [[ -z "$CMD" ]] && exit 0

    # apply_patch pass 0 — a patch that CREATES a denied file has no existing
    # path for the token scan below to catch, so match the patch's declared
    # targets on pattern alone. Only the `*** <verb> File:` headers are read;
    # matching the whole patch body would trip on any content that merely looks
    # like a key name.
    if [[ "$TOOL_NAME" == "apply_patch" ]]; then
      while IFS= read -r patch_target; do
        [[ -z "$patch_target" ]] && continue
        if is_denied_path "$patch_target"; then
          deny "$(basename "$(expand_path "$patch_target")")"
        fi
      done < <(echo "$CMD" | sed -nE 's/^\*\*\* (Add|Update|Delete) File: (.*)$/\2/p')
    fi

    # Pass 1 — every token in the whole command, not just arguments to a
    # hand-maintained list of reader commands. The old command-list approach
    # missed anything unusual (python -c, dd, a shell function, ...). To keep
    # false positives down, a token only counts if it actually resolves to an
    # existing file: `grep -rn ".secrets.env" docs/` stays allowed because the
    # bare string is not a file, while `cat ~/.aicodingsetup/.secrets.env` is
    # denied because it is.
    while IFS= read -r token; do
      [[ -z "$token" ]] && continue
      [[ "$token" == -* ]] && continue
      expanded="$(expand_path "$token")"
      [[ -e "$expanded" ]] || continue
      if is_denied_path "$token"; then
        deny "$(basename "$expanded")"
      fi
    done < <(echo "$CMD" | tr ' \t\n|;&()<>,' '\n' | sed -E 's/^["'\'']+//; s/["'\'']+$//')

    # Pass 2 — redirection targets are checked on pattern alone, since the
    # file being created (`... > new.pem`) does not exist yet.
    while IFS= read -r target; do
      [[ -z "$target" ]] && continue
      if is_denied_path "$target"; then
        deny "$(basename "$(expand_path "$target")")"
      fi
    done < <(echo "$CMD" | grep -oE '[<>]{1,2}[[:space:]]*[^[:space:]|;&]+' | sed -E 's/^[<>]{1,2}[[:space:]]*//' || true)
    ;;
esac

exit 0
