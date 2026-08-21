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
  # gh stores its token in ~/.config/gh/hosts.yml in plaintext. That file is
  # what lets gh work without GH_TOKEN in the environment, so it has to exist
  # — and therefore has to be unreadable to agents, exactly like .secrets.env.
  '*/.config/gh'
  '*/.config/gh/*'
)

# Individual files that carry LIVE secrets, matched on the full path.
#
# The secrets file is not the only copy on disk: the blueprint substitutes API
# keys into every agent's MCP config at deploy time, so firecrawl, brave and
# memory-router credentials sit in plaintext in each of these. Denying
# .secrets.env while leaving them readable protected nothing (found 2026-08-21
# — all five were wide open after the first two rounds of this work).
#
# Cost of this rule: an agent can no longer read its own MCP config to debug
# it. `claude mcp list` / `codex mcp list` still work and do not print
# credentials, and aicoding-sync reports config drift itself.
DENY_PATHS=(
  '*/.codex/config.toml'
  '*/.config/opencode/opencode.json'
  '*/.cursor/mcp.json'
  '*/.claude.json'
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

# Commands that hand an agent a secret VALUE without ever touching a denied
# file. Blocking the files alone was never enough: the GitHub token also
# reaches an agent through the git credential helper, through `gh auth token`,
# and through the process environment.
#
# These match on PRINTING or EXPANDING a value, not on mentioning a name —
# `grep -rn GH_TOKEN lib/` and editing a script that documents the variable
# stay allowed, while `echo $GH_TOKEN` does not. Git's own internal call to a
# credential helper is not a tool call and is unaffected; only an agent typing
# the helper's name is blocked.
SECRET_COMMAND_PATTERNS=(
  'git-credential-[A-Za-z0-9_-]+'
  'git[[:space:]]+credential[[:space:]]+(fill|approve|reject)'
  'gh[[:space:]]+auth[[:space:]]+token'
  '/proc/[^[:space:]]*/environ'
  '\$\{?(GH_TOKEN|GITHUB_TOKEN|[A-Z0-9]+(_[A-Z0-9]+)*_(TOKEN|KEY|SECRET|PASSWORD))\}?([^A-Za-z0-9_]|$)'
  'printenv[[:space:]]+[^|;&]*(TOKEN|KEY|SECRET|PASSWORD)'
)

# Same idea, matched case-INSENSITIVELY. Kept separate because the patterns
# above must stay case-sensitive: env var names are uppercase, and matching
# them loosely would deny `grep -rn gh_token docs/`. Here the filter word is
# whatever the user typed, so `env | grep -i token` has to match too. The
# leading boundary keeps `cat env.sh | grep key` out of it.
SECRET_COMMAND_PATTERNS_I=(
  '(^|[;&|[:space:]])(env|printenv|set)([[:space:]]|\|)[^;&]*\|[^;&]*(token|key|secret|password)'
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
  base="$(basename -- "$filepath")"

  for pattern in "${DENY_BASENAMES[@]}"; do
    glob_match "$base" "$pattern" && return 0
  done

  for pattern in "${DENY_PATHS[@]}"; do
    glob_match "$filepath" "$pattern" && return 0
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

# strip_heredoc_bodies — drop `<<EOF ... EOF` payloads from a command before
# the token scan.
#
# A heredoc body is DATA, not command arguments: writing a doc, a test, or a
# script that mentions ~/.aicodingsetup/.secrets.env is not reading it, and
# denying that is the kind of false positive that makes people work around the
# hook. Real access still gets caught — `cat ~/.aicodingsetup/.secrets.env` is
# not a heredoc, and `cat <<EOF > secrets.pem` puts its target in the command
# part, where pass 2 sees it.
strip_heredoc_bodies() {
  printf '%s' "$1" | awk '
    {
      if (in_body) { if ($0 == marker) { in_body = 0 }; next }
      line = $0
      if (match(line, /<<-?[[:space:]]*"?'"'"'?[A-Za-z_][A-Za-z0-9_]*"?'"'"'?/)) {
        marker = substr(line, RSTART, RLENGTH)
        gsub(/^<<-?[[:space:]]*/, "", marker)
        gsub(/["'"'"']/, "", marker)
        in_body = 1
      }
      print line
    }
  '
}

# is_env_dump — true when a command prints the WHOLE environment.
#
# `env | grep -i token` was already denied, but a bare `env`, `printenv` or
# `set` dumps every secret at once and slipped straight through — the worst of
# the three holes found on 2026-08-21. The distinction that matters is dump vs
# prefix: `env` alone prints secrets, `env -u GH_TOKEN gh auth status` runs a
# command and is used all over this repo. So strip the option words; if no
# command is left to run, it was a dump.
is_env_dump() {
  local segment
  # Split on the operators that start a new command, so `foo && env` is caught.
  # `|| [[ -n ... ]]`: the last segment has no trailing newline, and plain
  # `read` would discard it — which silently exempted every single-segment
  # command, i.e. exactly the bare `env` this is here to catch.
  while IFS= read -r segment || [[ -n "$segment" ]]; do
    # trim
    segment="${segment#"${segment%%[![:space:]]*}"}"
    segment="${segment%"${segment##*[![:space:]]}"}"
    [[ -z "$segment" ]] && continue

    local head=${segment%%[[:space:]]*}
    case "$head" in
      env|printenv|/usr/bin/env|/usr/bin/printenv|set|export|declare|typeset) ;;
      *) continue ;;
    esac

    # Everything after the command word.
    local rest=""
    [[ "$segment" == *[[:space:]]* ]] && rest="${segment#*[[:space:]]}"

    # Drop option words and VAR=VALUE assignments; `-u NAME` also eats NAME.
    local -a words=() w
    read -r -a words <<< "$rest"
    local i=0 remaining=0 saw_assignment=0
    while (( i < ${#words[@]} )); do
      w="${words[$i]}"
      case "$w" in
        -u|--unset) (( i += 2 )); continue ;;
        -*)         (( i += 1 )); continue ;;
        *=*)        saw_assignment=1; (( i += 1 )); continue ;;
        *)          remaining=1; break ;;
      esac
    done
    # `export PATH=...` / `declare -x FOO=bar` SET a variable, they do not
    # print the environment. Only env/printenv still dump when handed an
    # assignment and no command to run.
    if (( saw_assignment == 1 )); then
      case "$head" in
        set|export|declare|typeset) continue ;;
      esac
    fi
    # No command left to run (and no filter argument) => it printed everything.
    (( remaining == 0 )) && return 0
  done < <(printf '%s' "$1" | sed -E 's/(\|\||&&|[;|&])/\n/g')
  return 1
}

deny_secret_command() {
  local reason="This command would print a live credential into the transcript, so it is blocked. The token is reachable this way even though the secrets file itself is denied — that is the hole this rule closes. Do not work around it. Use 'secrets-check' to see which keys are set (names and status only, never values); git and gh are already authenticated, so run them directly instead of handling the token yourself."
  jq -n --arg r "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
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
      deny "$(basename -- "$FILE_PATH")"
    fi
    ;;

  Grep|Glob)
    # Only block when targeting a specific file; searching a directory is fine
    # (the hook cannot know what a recursive search will surface, and denying
    # every directory search would make the tool useless).
    TARGET="$(echo "$INPUT" | jq -r '.tool_input.path // empty')"
    if [[ -n "$TARGET" && ! -d "$(expand_path "$TARGET")" ]] && is_denied_path "$TARGET"; then
      deny "$(basename -- "$TARGET")"
    fi
    ;;

  Bash|apply_patch)
    # Codex uses the same PreToolUse contract as Claude Code — verified against
    # codex-cli 0.148.0 by feeding it a real tool call: tool_name "Bash" with
    # tool_input.command as a plain string, and "apply_patch" with the patch
    # text in that same field. So one script serves both agents.
    CMD="$(echo "$INPUT" | jq -r '.tool_input.command // empty')"
    [[ -z "$CMD" ]] && exit 0

    # Pass -1 — token oracles that never name a denied file.
    for secret_pattern in "${SECRET_COMMAND_PATTERNS[@]}"; do
      if echo "$CMD" | grep -qE "$secret_pattern"; then
        deny_secret_command
      fi
    done
    for secret_pattern in "${SECRET_COMMAND_PATTERNS_I[@]}"; do
      if echo "$CMD" | grep -qiE "$secret_pattern"; then
        deny_secret_command
      fi
    done
    is_env_dump "$CMD" && deny_secret_command

    # apply_patch pass 0 — a patch that CREATES a denied file has no existing
    # path for the token scan below to catch, so match the patch's declared
    # targets on pattern alone. Only the `*** <verb> File:` headers are read;
    # matching the whole patch body would trip on any content that merely looks
    # like a key name.
    if [[ "$TOOL_NAME" == "apply_patch" ]]; then
      while IFS= read -r patch_target; do
        [[ -z "$patch_target" ]] && continue
        if is_denied_path "$patch_target"; then
          deny "$(basename -- "$(expand_path "$patch_target")")"
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
        deny "$(basename -- "$expanded")"
      fi
    done < <(strip_heredoc_bodies "$CMD" | tr ' \t\n|;&()<>,' '\n' | sed -E 's/^["'\'']+//; s/["'\'']+$//')

    # Pass 2 — redirection targets are checked on pattern alone, since the
    # file being created (`... > new.pem`) does not exist yet.
    while IFS= read -r target; do
      [[ -z "$target" ]] && continue
      if is_denied_path "$target"; then
        deny "$(basename -- "$(expand_path "$target")")"
      fi
    # `<<` is a heredoc marker, not a file — matching it here fed things like
    # `<<-'MARK'` to basename as an option and broke the hook's output.
    done < <(echo "$CMD" | grep -oE '(^|[^<>])[<>]{1,2}[[:space:]]*[^[:space:]|;&<>-][^[:space:]|;&]*' \
               | grep -vE '<<' | sed -E 's/^[^<>]?[<>]{1,2}[[:space:]]*//' || true)
    ;;
esac

exit 0
