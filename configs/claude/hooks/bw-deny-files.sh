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
  # `declare -p VAR` prints VAR's value just like `$VAR` does (found by
  # review 2026-08-21: -p counts as an option word, the var name as an
  # argument, so nothing else matched).
  '(declare|typeset)[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*p[a-zA-Z]*[[:space:]]+([^|;&]*[[:space:]])?\{?(\$)?[A-Z0-9_]*(TOKEN|KEY|SECRET|PASSWORD)\}?([^A-Za-z0-9_]|$)'
)

# Commands whose arguments are FILE CONTENTS, not listings or names. A bare
# sensitive-directory argument to one of these exfiltrates everything inside
# (`tar czf /tmp/a.tgz -C ~ .aicodingsetup`) — found by review 2026-08-21,
# where is_denied_path's "listing is fine" carve-out let them through.
# Listing (`ls`, completion) stays allowed; this list is about reading bytes.
CONTENT_COMMANDS=(
  tar cp mv rsync scp find zip unzip 7z 7za dd cpio pax gpg openssl
)

# Everything that READS BYTES or RUNS CODE, a superset of CONTENT_COMMANDS.
#
# 2026-08-31: used only to decide whether a protected path named inside a
# QUOTED argument is prose or an argument to a reader. Writing about a
# protected path is not reading it: refusing
# `kanban-post --body "...~/.codex/config.toml..."` blocked incident
# write-ups and ticket bodies, which are exactly the texts that have to name
# these files. Four such refusals paid for this list; see
# AICODINGBASESETUP-6.
#
# Over-inclusive on purpose. A name in here only ever RESTORES the old strict
# behaviour for the whole command, so a wrong guess costs a false positive,
# never a leak. Anything not listed still blocks unless the path sits inside
# quotes.
READER_COMMANDS=(
  "${CONTENT_COMMANDS[@]}"
  cat less more head tail od xxd hexdump strings source . eval
  bash sh zsh dash ksh fish
  python python2 python3 perl ruby node deno bun php lua
  awk gawk mawk sed grep egrep fgrep rg ag ack jq yq xargs tee
  base64 base32 uuencode uudecode gpg2
  md5sum sha1sum sha256sum sha512sum cksum sum
  wc sort uniq cut tr nl fold rev tac shuf split csplit iconv
  expand unexpand paste join comm diff cmp patch
  vim vi view nano emacs ed
  curl wget nc ncat socat ssh sftp ftp
  install ln readlink realpath
)

# Set per tool call. 1 only for Bash commands that invoke no reader at all;
# every other path keeps the pre-2026-08-31 strict behaviour.
PROSE_MENTION_OK=0

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

# in_sensitive_dir <path> — pattern check only, NO existence requirement.
# True when the path is, or sits inside, a known-sensitive directory.
# Used where existence cannot be trusted: a glob token (`~/.aicodingsetup/*`)
# resolves to nothing at scan time yet expands to everything at run time, and
# a relative token after `cd ~/.aicodingsetup` resolves against the shell's
# CWD, not this hook's (both bypassed pass 1 — review 2026-08-21).
in_sensitive_dir() {
  local filepath pattern
  filepath="$(expand_path "$1")"
  for pattern in "${SENSITIVE_DIRS[@]}"; do
    glob_match "$filepath" "$pattern" && return 0
  done
  return 1
}

# base_is_allowed <basename> — the DIR_ALLOW carve-out (deploy-state files,
# ssh public keys) stays readable even inside a sensitive directory.
base_is_allowed() {
  local pattern
  for pattern in "${DIR_ALLOW[@]}"; do
    glob_match "$1" "$pattern" && return 0
  done
  return 1
}

# basename_is_denied <basename> — known-secret FILE names, used when a bare
# relative token cannot be resolved against the shell's CWD.
basename_is_denied() {
  local pattern
  for pattern in "${DENY_BASENAMES[@]}"; do
    glob_match "$1" "$pattern" && return 0
  done
  return 1
}

# is_sensitive_root <path> — true when the path IS a known-sensitive
# directory itself, not its contents. Listing one (`ls ~/.ssh`) stays
# allowed by design; handing one to a content command does not.
is_sensitive_root() {
  local p pattern
  p="$(expand_path "$1")"
  p="${p%/}"
  for pattern in "${SENSITIVE_DIRS[@]}"; do
    case "$pattern" in *'*') ;; *) glob_match "$p" "$pattern" && return 0 ;; esac
  done
  return 1
}

# segment_head <segment> — the real command word of one command segment, with
# any directory prefix removed. Skips the wrappers that only prefix another
# command (`sudo`, `command`, `env FOO=bar`, leading VAR=VALUE assignments), so
# `/bin/cat`, `command cat` and `env cat` all report `cat`. Non-zero when the
# segment has no command word at all.
segment_head() {
  local -a w=()
  local i=0 word
  read -r -a w <<< "$1"
  while (( i < ${#w[@]} )); do
    word="${w[$i]}"
    case "${word##*/}" in
      command|builtin|sudo|doas|nohup|exec|time|stdbuf|nice|ionice)
        (( i += 1 ))
        while (( i < ${#w[@]} )) && [[ "${w[$i]}" == -* ]]; do (( i += 1 )); done
        ;;
      timeout)
        (( i += 2 ))
        ;;
      env)
        (( i += 1 ))
        while (( i < ${#w[@]} )); do
          case "${w[$i]}" in
            -u|--unset) (( i += 2 )) ;;
            -*|*=*)     (( i += 1 )) ;;
            *)          break ;;
          esac
        done
        ;;
      *=*) (( i += 1 )) ;;
      *)   printf '%s' "${word##*/}"; return 0 ;;
    esac
  done
  return 1
}

# command_has_reader <command> — true when ANY segment of the command runs one
# of READER_COMMANDS. Command substitutions and backticks are split out too, so
# `echo "$(cat ~/.codex/config.toml)"` reports the `cat`, not the `echo`.
command_has_reader() {
  local segment head reader
  while IFS= read -r segment || [[ -n "$segment" ]]; do
    [[ -z "${segment//[[:space:]]/}" ]] && continue
    head="$(segment_head "$segment")" || continue
    for reader in "${READER_COMMANDS[@]}"; do
      [[ "$head" == "$reader" ]] && return 0
    done
  done < <(printf '%s' "$1" | sed -E 's/(\|\||&&|\$\(|[;|&()`])/\n/g')
  return 1
}

# quoted_regions <command> — the contents of every single- or double-quoted
# region, one per line. A region that never closes (or spans a newline) is
# simply not emitted, which fails toward blocking.
quoted_regions() {
  printf '%s' "$1" | awk '
    {
      q = ""; buf = ""
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (q == "") {
          if (c == "\"" || c == "\047") { q = c; buf = "" }
        } else if (c == q) {
          print buf; q = ""; buf = ""
        } else {
          buf = buf c
        }
      }
    }
  '
}

# is_quoted_prose_mention <token> — true when the token is only being WRITTEN
# ABOUT: it sits inside a quoted argument, and the command runs no reader.
#
# 2026-08-31: narrowed so that naming a protected path is not treated as
# reading it. Prose about credential handling (a ticket body, an incident
# write-up) is exactly the text that must name these files, and a hook that
# fires on a harmless mention trains an agent to reword until something
# passes, which is the workaround reflex the block exists to prevent. A path
# handed to cat/tar/source/base64, an unquoted path, a redirection target and
# every $VAR expansion still block. See AICODINGBASESETUP-6 for the four false
# positives that paid for this.
is_quoted_prose_mention() {
  local needle="$1" region
  [[ "$PROSE_MENTION_OK" == 1 ]] || return 1
  [[ -n "$needle" ]] || return 1
  while IFS= read -r region || [[ -n "$region" ]]; do
    [[ "$region" == *"$needle"* ]] && return 0
  done < <(quoted_regions "${CMD:-}")
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

    # A redirection fused to the command word (`env>/tmp/x`, no space) left the
    # operator glued onto `head`, so the case below never matched `env` and the
    # dump slipped through (review 2026-08-24). Space out an operator welded to
    # an ordinary word while leaving fd-qualified/doubled forms (`2>&1`, `>>`,
    # `>&`) intact — those are preceded by a digit or another operator char.
    segment=$(printf '%s' "$segment" | sed -E 's/([^[:space:]0-9<>&])([<>])/\1 \2/g')

    local head=${segment%%[[:space:]]*}
    case "$head" in
      env|printenv|/usr/bin/env|/usr/bin/printenv|set|export|declare|typeset) ;;
      *) continue ;;
    esac

    # Everything after the command word.
    local rest=""
    [[ "$segment" == *[[:space:]]* ]] && rest="${segment#*[[:space:]]}"

    # Drop option words, VAR=VALUE assignments, and redirection operators
    # with their targets. Redirections mattered: `env > /tmp/e.txt` left `>`
    # as a remaining command word, so the dump went undetected and the Read
    # tool — which nothing denied for /tmp — picked the file up afterwards
    # (review 2026-08-21). `2>&1` has no target word; skip it whole.
    local -a words=() w
    read -r -a words <<< "$rest"
    local i=0 remaining=0 saw_assignment=0 skip_target=0
    while (( i < ${#words[@]} )); do
      w="${words[$i]}"
      case "$w" in
        -u|--unset) (( i += 2 )); continue ;;
        \>*|\<*|\>\>*|\<\<*|\>\&*|[0-9]*\&*|[0-9]*\>*|[0-9]*\>\>*|[0-9]*\<*) skip_target=1; (( i += 1 )); continue ;;
        -*)         (( i += 1 )); continue ;;
        *=*)        saw_assignment=1; (( i += 1 )); continue ;;
        *)
          if (( skip_target )); then skip_target=0; (( i += 1 )); continue; fi
          remaining=1; break ;;
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
    # Only block when targeting a specific file — EXCEPT for sensitive
    # directories: a recursive search rooted inside one surfaces the very
    # contents this hook exists to protect, so the "searching a directory
    # is fine" exemption must not apply there (review 2026-08-21).
    TARGET="$(echo "$INPUT" | jq -r '.tool_input.path // empty')"
    if [[ -n "$TARGET" ]]; then
      if in_sensitive_dir "$TARGET"; then
        deny "$(basename -- "$(expand_path "$TARGET")")"
      fi
      if [[ ! -d "$(expand_path "$TARGET")" ]] && is_denied_path "$TARGET"; then
        deny "$(basename -- "$TARGET")"
      fi
    fi
    ;;

  Bash|apply_patch)
    # Codex uses the same PreToolUse contract as Claude Code — verified against
    # codex-cli 0.148.0 by feeding it a real tool call: tool_name "Bash" with
    # tool_input.command as a plain string, and "apply_patch" with the patch
    # text in that same field. So one script serves both agents.
    CMD="$(echo "$INPUT" | jq -r '.tool_input.command // empty')"
    [[ -z "$CMD" ]] && exit 0

    # Only a real shell command can be prose about a path; an apply_patch body
    # keeps the strict rule, and so does any command that runs a reader.
    if [[ "$TOOL_NAME" == "Bash" ]] && ! command_has_reader "$CMD"; then
      PROSE_MENTION_OK=1
    fi

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
    # missed anything unusual (python -c, dd, a shell function, ...).
    #
    # Existence gating is deliberately asymmetric (review 2026-08-21): a
    # token that lands inside a known-sensitive directory is denied on
    # PATTERN alone. Requiring existence let two bypasses through:
    #   - `cat ~/.aicodingsetup/*` — the hook sees pre-expansion globs, no
    #     single token resolves to a file, then the shell expands at runtime;
    #   - `cd ~/.aicodingsetup && cat .secrets.env` — relative tokens were
    #     tested against this hook's CWD instead of the shell's.
    # Bare basename mentions still must exist on disk, so writing docs or
    # grepping source for ".secrets.env" stays allowed.
    scan_tokens() {
      local cmd="$1"
      local token stripped expanded base exp_cd
      local prev_cd=0 scan_cwd="$PWD" relative_to_sensitive=0
      while IFS= read -r token || [[ -n "$token" ]]; do
        [[ -z "$token" ]] && continue
        [[ "$token" == -* ]] && continue
        stripped="${token//\"/}"
        stripped="${stripped//\'}"
        if (( prev_cd )); then
          prev_cd=0
          exp_cd="$(expand_path "$stripped")"
          [[ "$exp_cd" == /* ]] || exp_cd="$scan_cwd/$exp_cd"
          # Lexically normalize the complete shell cwd. Remembering only a
          # sensitive cwd missed `cd $HOME && cd .aicodingsetup`, nested cds,
          # and leaving a sensitive directory again.
          scan_cwd="$(realpath -m -- "$exp_cd")"
          continue
        fi
        # A quoted `cd` is documentation/data, not shell state.
        if [[ "$token" == "cd" ]]; then prev_cd=1; continue; fi
        expanded="$(expand_path "$stripped")"
        relative_to_sensitive=0
        if [[ "$expanded" != /* ]]; then
          in_sensitive_dir "$scan_cwd" && relative_to_sensitive=1
          expanded="$(realpath -m -- "$scan_cwd/$expanded")"
        fi
        base="$(basename -- "${expanded%/}")"
        if in_sensitive_dir "$expanded" && ! base_is_allowed "$base" \
           && ! is_sensitive_root "$expanded"; then
          # Absolute tokens inside a sensitive dir are denied on pattern
          # alone (glob bypass). A RELATIVE token after `cd` into the dir
          # needs more care: `cat .secrets.env` must be denied but `ls` and
          # other bare command words must survive — so deny only when the
          # basename names a known-secret file or actually resolves.
          if [[ "$relative_to_sensitive" == 0 ]] \
             || basename_is_denied "$base" || [[ -e "$expanded" ]]; then
            is_quoted_prose_mention "$stripped" || deny "$base"
          fi
        fi
        [[ -e "$expanded" ]] || continue
        if is_denied_path "$expanded"; then
          is_quoted_prose_mention "$stripped" || deny "$(basename -- "$expanded")"
        fi
      # Keep quote characters until after command-word classification so a
      # quoted literal `"cd"` cannot alter cwd tracking. `stripped` above is
      # still used for path matching.
      done < <(printf '%s' "$cmd" | tr ' \t\n|;&()<>,{}' '\n')
    }

    scan_tokens "$(strip_heredoc_bodies "$CMD")"

    # Pass 1b — heredoc bodies are DATA when they are written somewhere, but
    # an EXECUTION CHANNEL when the same command feeds them to a SHELL:
    # `bash <<'X' … X` runs exactly what stripping removed (review
    # 2026-08-21). When both are present, scan the raw command too. Only
    # shell interpreters count — a python heredoc whose body mentions a path
    # is overwhelmingly a string literal being written, and denying those is
    # the false positive the stripping exists to prevent.
    if [[ "$CMD" != "$(strip_heredoc_bodies "$CMD")" ]] \
       && echo "$CMD" | grep -qE '(^|[[:space:]/;&|])(bash|sh|zsh|dash|ksh|eval|source)([[:space:]<]|$)'; then
      scan_tokens "$CMD"
    fi

    # Pass 1c — the sensitive directories THEMSELVES as arguments to content
    # commands. is_denied_path allows directories ("listing is fine"), but
    # `tar czf /tmp/a.tgz -C ~ .aicodingsetup`, `cp -r`, and
    # `find <dir> -exec cat {} ;` read bytes, not listings (review
    # 2026-08-21). `ls` and `cd` stay allowed.
    while IFS= read -r segment || [[ -n "$segment" ]]; do
      segment="${segment#"${segment%%[![:space:]]*}"}"
      segment="${segment%"${segment##*[![:space:]]}"}"
      [[ -z "$segment" ]] && continue
      seg_words=()
      seg_i=0
      seg_word=""
      seg_cmd=""
      content_cmd=""
      read -r -a seg_words <<< "$segment"
      # Resolve the real command through common wrappers and absolute paths;
      # `/bin/tar`, `command cp`, and `env find` read exactly the same bytes as
      # their previously-covered unqualified forms.
      while (( seg_i < ${#seg_words[@]} )); do
        seg_word="${seg_words[$seg_i]}"
        case "${seg_word##*/}" in
          command|builtin|sudo|doas|nohup)
            (( seg_i += 1 ))
            while (( seg_i < ${#seg_words[@]} )) && [[ "${seg_words[$seg_i]}" == -* ]]; do
              (( seg_i += 1 ))
            done
            ;;
          env)
            (( seg_i += 1 ))
            while (( seg_i < ${#seg_words[@]} )); do
              case "${seg_words[$seg_i]}" in
                -u|--unset) (( seg_i += 2 )) ;;
                -*|*=*) (( seg_i += 1 )) ;;
                *) break ;;
              esac
            done
            ;;
          *) seg_cmd="${seg_word##*/}"; break ;;
        esac
      done
      is_content=1
      for content_cmd in "${CONTENT_COMMANDS[@]}"; do
        if [[ "$seg_cmd" == "$content_cmd" ]]; then is_content=0; break; fi
      done
      (( is_content == 0 )) || continue
      while IFS= read -r token || [[ -n "$token" ]]; do
        [[ -z "$token" ]] && continue
        [[ "$token" == -* ]] && continue
        expanded="$(expand_path "${token//\"/}")"
        if is_sensitive_root "$expanded" || is_sensitive_root "$HOME/$expanded"; then
          deny "$(basename -- "${expanded%/}")"
        fi
      done < <(printf '%s' "$segment" | tr ' \t\n|;&()<>,{}' '\n')
    done < <(printf '%s' "$CMD" | sed -E 's/(\|\||&&|[;|&])/\n/g')

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
