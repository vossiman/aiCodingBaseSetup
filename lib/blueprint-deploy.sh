# aiCodingBaseSetup — blueprint deployment primitives.
# Sourced by install.sh, install-host.sh and lib/sync.sh. Pure shell functions
# only; the one top-level side effect is the staging-only release heal (below).
# Caller is responsible for `set -euo pipefail`.
#
# Managed config follows four rules (docs/managed-config.md):
#   1. Blueprint-owned files are rendered and written whenever they differ.
#   2. Mixed files get their owned keys enforced and seeded keys set once.
#   3. Retired files and keys are removed only while they still match a
#      version the blueprint shipped.
#   4. The machine profile lives in its own one-word file.
# Containers share ~/.claude, ~/.codex and ~/.cursor, so an older release
# leaves files there to the newest release that wrote them. "Newer" is the
# count of commits behind a release, which only grows along main.

: "${AICODING_BLUEPRINT_CLONE:=/tmp/aicoding}"
: "${AICODING_STATE_DIR:=$HOME/.local/state/aicoding}"
# Must match bin/aicoding-status's default: a moved blueprint stamp drops
# that CLI's cache.
: "${AICODING_UPDATE_STATE:=$AICODING_STATE_DIR/updates}"

_aicoding_deploy_lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=release-heal.sh
. "$_aicoding_deploy_lib_dir/release-heal.sh"
# Runs at source time on purpose: a container stuck on an older release only
# executes new code by sourcing this file while it stages a newly selected one.
aicoding_heal_release_bytecode_when_staging "$_aicoding_deploy_lib_dir" || true
# Same trick for release ordering: whichever release does the staging, this
# file is sourced from the new clone while its .git still exists.
_aicoding_record_release_ordinal() {
  local root
  root=$(cd -- "$1/.." 2>/dev/null && pwd -P) || return 0
  [[ "${root##*/}" =~ ^aicoding\.[0-9a-f]{40}\.[0-9]+$ ]] && [ -d "$root/.git" ] \
    && [ ! -e "$root/.aicoding-release-ordinal" ] || return 0
  git -C "$root" rev-list --count HEAD > "$root/.aicoding-release-ordinal" 2>/dev/null \
    || rm -f "$root/.aicoding-release-ordinal"
}
_aicoding_record_release_ordinal "$_aicoding_deploy_lib_dir" || true
_AICODING_MANAGED_TOML="$_aicoding_deploy_lib_dir/managed_toml.py"
unset _aicoding_deploy_lib_dir

# --- Machine profile and stamps ---------------------------------------------

# Losing "host" would switch Codex to no approvals and full access, so the
# profile is a file of its own rather than a field in a disposable record.
aicoding_profile() {
  local p=${AICODING_PROFILE:-}
  [ -n "$p" ] || p=$(cat "$AICODING_STATE_DIR/profile" 2>/dev/null) || p=
  case "$p" in host|container|minimal-pi) ;; *) p=container ;; esac
  printf '%s\n' "$p"
}

aicoding_stamp_read() { cat "$AICODING_STATE_DIR/$1" 2>/dev/null || true; }

aicoding_stamp_write() {
  local name=$1 value=$2 tmp
  [ -n "$value" ] || return 0
  mkdir -p "$AICODING_STATE_DIR" || return 1
  tmp=$(mktemp "$AICODING_STATE_DIR/.$name.XXXXXX") || return 1
  printf '%s\n' "$value" > "$tmp" && mv -f "$tmp" "$AICODING_STATE_DIR/$name" || { rm -f "$tmp"; return 1; }
}

# The installed-blueprint stamp also drops aicoding-status's cached `latest`
# when it moves, so the next tick re-checks instead of reading "behind".
aicoding_stamp_blueprint() {
  local commit=$1
  [ -n "$commit" ] && [ "$commit" != unknown ] || return 0
  if [ "$(aicoding_stamp_read blueprint_commit)" != "$commit" ]; then
    rm -f "$AICODING_UPDATE_STATE"/*.json 2>/dev/null || true
  fi
  aicoding_stamp_write blueprint_commit "$commit"
}

# Carry the facts that outlive the old per-container manifest into their own
# files. Runs before anything reads the profile; the manifest itself is only
# deleted after a clean pass (aicoding_remove_legacy_state).
aicoding_migrate_legacy_state() {
  local manifest="$AICODING_STATE_DIR/manifest.json" value key
  if [ ! -s "$AICODING_STATE_DIR/profile" ]; then
    value=${AICODING_PROFILE:-}
    [ -n "$value" ] || value=$(jq -r '.profile // empty' "$manifest" 2>/dev/null) || value=
    case "$value" in host|container|minimal-pi) aicoding_stamp_write profile "$value" ;; esac
  fi
  [ -f "$manifest" ] || return 0
  for key in provision_commit blueprint_commit; do
    [ -n "$(aicoding_stamp_read "$key")" ] && continue
    value=$(jq -r --arg k "$key" '.[$k] // empty' "$manifest" 2>/dev/null) || value=
    aicoding_stamp_write "$key" "$value" || true
  done
}

aicoding_remove_legacy_state() {
  [ -s "$AICODING_STATE_DIR/profile" ] || [ ! -f "$AICODING_STATE_DIR/manifest.json" ] || return 0
  rm -f "$AICODING_STATE_DIR/manifest.json" "$HOME/.aicodingsetup/manifest.json" 2>/dev/null || true
  rm -rf "$HOME/.codex/.aicoding-sync" 2>/dev/null || true
}

# --- Shared-root writer locks ------------------------------------------------

# Acquire non-blocking writer locks inside the physical shared destinations.
# FDs stay open across a refresh exec, but the scheduled step releases them
# via aicoding_shared_locks_release before it returns.
aicoding_shared_locks_acquire() {
  local dest logical root fd
  local -a roots=()
  local -A seen=()
  declare -gA _AICODING_SHARED_LOCKED_ROOTS
  declare -ga _AICODING_SHARED_LOCK_FDS
  for dest in "$@"; do
    case "$dest" in
      "$HOME/.claude"/*) logical="$HOME/.claude" ;;
      "$HOME/.codex"/*) logical="$HOME/.codex" ;;
      "$HOME/.cursor"/*) logical="$HOME/.cursor" ;;
      "$HOME/.config/opencode"/*) logical="$HOME/.config/opencode" ;;
      "$HOME/.local/share/opencode"/*) logical="$HOME/.local/share/opencode" ;;
      *) continue ;;
    esac
    mkdir -p "$logical" || return 1
    root=$(readlink -f "$logical") || return 1
    [ -z "${seen[$root]:-}" ] || continue
    seen[$root]=1
    roots+=("$root")
  done
  while IFS= read -r root; do
    [ -z "${_AICODING_SHARED_LOCKED_ROOTS[$root]:-}" ] || continue
    exec {fd}>"$root/.aicoding-update.lock" || return 1
    flock -n "$fd" || { exec {fd}>&-; return 1; }
    _AICODING_SHARED_LOCKED_ROOTS[$root]=1
    _AICODING_SHARED_LOCK_FDS+=("$fd")
  done < <(printf '%s\n' "${roots[@]}" | LC_ALL=C sort)
}

# Lock every managed shared root before reading any destination, so a sibling
# container cannot change a file between its read and its rewrite.
aicoding_shared_locks_acquire_managed_roots() {
  aicoding_shared_locks_acquire \
    "$HOME/.claude/.aicoding-managed" \
    "$HOME/.codex/.aicoding-managed" \
    "$HOME/.cursor/.aicoding-managed" \
    "$HOME/.config/opencode/.aicoding-managed" \
    "$HOME/.local/share/opencode/.aicoding-managed"
}

# Long local work (a tmux build) must not keep other containers from updating
# shared config.
aicoding_shared_locks_release() {
  declare -p _AICODING_SHARED_LOCK_FDS >/dev/null 2>&1 || return 0
  local fd
  for fd in "${_AICODING_SHARED_LOCK_FDS[@]}"; do
    exec {fd}>&-
  done
  _AICODING_SHARED_LOCK_FDS=()
  declare -gA _AICODING_SHARED_LOCKED_ROOTS=()
}

# --- Writing -----------------------------------------------------------------

# Every deployed file goes through a private temp file in the destination
# directory and an atomic rename: several carry credentials, and a bare `cp`
# keeps whatever wide mode an existing destination already had.
_write_atomic() {
  local src=$1 dest=$2 mode=${3:-0600}
  local dir tmp rc
  dir=$(dirname "$dest")
  mkdir -p "$dir" || return 1
  tmp=$(mktemp "$dir/.aicoding-deploy.XXXXXX") || return 1
  cat "$src" > "$tmp" || { rc=$?; rm -f "$tmp"; return "$rc"; }
  chmod "$mode" "$tmp" || { rc=$?; rm -f "$tmp"; return "$rc"; }
  mv -f "$tmp" "$dest" || { rc=$?; rm -f "$tmp"; return "$rc"; }
}

# --- Rendering ---------------------------------------------------------------

load_secrets_env() {
  local f="${AICODING_SECRETS_FILE:-$HOME/.aicodingsetup/.secrets.env}"
  if [ -f "$f" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$f"
    set +a
  fi
}

# Agent-readable prose gets {{HOME}} and nothing else: a credential in a file
# an agent must read lands in model context and transcripts (CAF-003).
_substitute_home_only() {
  local src=$1 out=$2
  local home_esc
  home_esc=$(printf '%s' "$HOME" | sed -e 's/[\/&\\]/\\&/g')
  sed -e "s/{{HOME}}/$home_esc/g" "$src" > "$out"
}

# The route, not today's content, has to be safe: these destinations never
# receive secrets even if a placeholder is added to their source later.
_is_prose_dest() {
  case "$1" in
    */.claude/skills/*.md|*/.claude/commands/*.md|*/.claude/agents/*.md) return 0 ;;
    */CLAUDE.md|*/AGENTS.md) return 0 ;;
    *) return 1 ;;
  esac
}

# The destination decides prose versus config, so every path that renders
# (deploy, retired-file provenance) agrees byte for byte.
_render_managed_source() {
  local src=$1 dest=$2 out=$3
  if _is_prose_dest "$dest"; then
    _substitute_home_only "$src" "$out"
  else
    _substitute_file_to "$src" "$out"
  fi
}

# CONFIGS ONLY: renders credentials and the profile-gated Codex posture.
# sed, not command substitution, so trailing newlines survive.
_substitute_file_to() {
  local src=$1 out=$2
  if [[ -e "$out" ]]; then
    chmod 0600 "$out" || return 1
  else
    (umask 077; : > "$out") || return 1
  fi
  local home_v="$HOME"
  local fc_v="${FIRECRAWL_API_KEY:-}"
  local br_v="${BRAVE_API_KEY:-}"
  local mr_v="${MEMORY_ROUTER_TOKEN:-}"
  local kb_v="${KANBAN_TOKEN:-}"
  # Hosts have no container isolation boundary: they keep Codex prompting and
  # sandboxed (user decision 2026-08-31).
  local codex_approval_v codex_sandbox_v
  if [[ "$(aicoding_profile)" == host ]]; then
    codex_approval_v="on-request"
    codex_sandbox_v="workspace-write"
  else
    codex_approval_v="never"
    codex_sandbox_v="danger-full-access"
  fi
  _esc() { printf '%s' "$1" | sed -e 's/[\/&\\]/\\&/g'; }
  if ! sed \
    -e "s/{{HOME}}/$(_esc "$home_v")/g" \
    -e "s/{{FIRECRAWL_API_KEY}}/$(_esc "$fc_v")/g" \
    -e "s/{{BRAVE_API_KEY}}/$(_esc "$br_v")/g" \
    -e "s/{{MEMORY_ROUTER_TOKEN}}/$(_esc "$mr_v")/g" \
    -e "s/{{KANBAN_TOKEN}}/$(_esc "$kb_v")/g" \
    -e "s/{{CODEX_APPROVAL_POLICY}}/$codex_approval_v/g" \
    -e "s/{{CODEX_SANDBOX_MODE}}/$codex_sandbox_v/g" \
    "$src" > "$out"; then
    return 1
  fi
  _strip_absent_secret_servers "$src" "$out"
}

# A missing MEMORY_ROUTER_TOKEN or KANBAN_TOKEN would render "Bearer " into
# an enabled MCP that 401s; drop that server from the rendered config instead,
# matching Claude, which skips registering it.
_strip_absent_secret_servers() {
  local src=$1 out=$2
  local -a servers=()
  [[ -n "${MEMORY_ROUTER_TOKEN:-}" ]] || servers+=(memory-router)
  [[ -n "${KANBAN_TOKEN:-}" ]] || servers+=(kanban)
  (( ${#servers[@]} )) || return 0
  local filter tmp names
  case "$src" in
    */configs/cursor/mcp.json) filter=cursor ;;
    */configs/opencode/opencode.json) filter=opencode ;;
    */configs/codex/config.toml) filter=codex ;;
    *) return 0 ;;
  esac
  tmp=$(mktemp "${out}.strip.XXXXXX") || return 1
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  names=$(printf '%s\n' "${servers[@]}" | jq -R . | jq -sc .) \
    || { rm -f -- "$tmp"; return 1; }
  case "$filter" in
    cursor)
      jq --argjson names "$names" \
        'reduce $names[] as $n (.; del(.mcpServers[$n]))' "$out" > "$tmp" \
        || { rm -f -- "$tmp"; return 1; }
      ;;
    opencode)
      jq --argjson names "$names" \
        'reduce $names[] as $n (.; del(.mcp[$n]))' "$out" > "$tmp" \
        || { rm -f -- "$tmp"; return 1; }
      ;;
    codex)
      awk -v names="${servers[*]}" '
        BEGIN { n = split(names, list, " "); for (i = 1; i <= n; i++) drop["[mcp_servers." list[i] "]"] = 1 }
        /^\[/ { skip = ($0 in drop) }
        !skip { print }
      ' "$out" > "$tmp" || { rm -f -- "$tmp"; return 1; }
      ;;
  esac
  mv -- "$tmp" "$out" || { rm -f -- "$tmp"; return 1; }
}

# --- Inventory ---------------------------------------------------------------

enumerate_skill_files() {
  local root=$1 f
  [[ -d "$root" ]] || return 0
  while IFS= read -r f; do
    printf '%s\n' "${f#"$root"/}"
  done < <(find "$root" -type f | LC_ALL=C sort)
}

_managed_config_data() { printf '%s\n' "$AICODING_BLUEPRINT_CLONE/configs/managed-config.json"; }

# Whole-file deployments as "dest|kind|source": kind "owned" is rendered,
# "raw" is copied byte for byte. Hosts skip container-only wiring (tmux,
# ssh-agent watcher) and gain the boot-sync trigger.
managed_inventory_overwrite() {
  cat <<EOF
$HOME/.claude/hooks/custom-statusline.js|owned|configs/claude/hooks/custom-statusline.js
$HOME/.claude/hooks/bw-deny-files.sh|owned|configs/claude/hooks/bw-deny-files.sh
$HOME/.claude/hooks/kanban-work-hook.sh|owned|configs/claude/hooks/kanban-work-hook.sh
$HOME/.pi/agent/extensions/bw-deny-files.ts|owned|configs/pi/extensions/bw-deny-files.ts
$HOME/.claude/hooks/check-archived-docs.sh|owned|configs/claude/hooks/check-archived-docs.sh
$HOME/.claude/hooks/llmwiki-distill.sh|owned|configs/claude/hooks/llmwiki-distill.sh
$HOME/.claude/hooks/agent-waiting.sh|owned|configs/claude/hooks/agent-waiting.sh
$HOME/.claude/hooks/agent-working.sh|owned|configs/claude/hooks/agent-working.sh
$HOME/.claude/hooks/memory-hint.sh|owned|configs/claude/hooks/memory-hint.sh
$HOME/.claude/hooks/opus-verbosity.sh|owned|configs/claude/hooks/opus-verbosity.sh
$HOME/.claude/hooks/fable-guidance.sh|owned|configs/claude/hooks/fable-guidance.sh
$HOME/.claude/hooks/redact-sessions-hook.sh|owned|configs/claude/hooks/redact-sessions-hook.sh
$HOME/.claude/hooks/redact-sessions-pending.sh|owned|configs/claude/hooks/redact-sessions-pending.sh
$HOME/.claude/agents/llmwiki-distiller.md|owned|configs/claude/agents/llmwiki-distiller.md
$HOME/.claude/CLAUDE.md|owned|configs/claude/CLAUDE.md
$HOME/.bashrc.d/aicoding-env.sh|owned|configs/bash/env.sh
$HOME/.bashrc.d/aicoding-update-notify.sh|owned|configs/bash/update-notify.sh
$HOME/.bashrc.d/aicoding-aliases.sh|owned|configs/bash/aliases.sh
$HOME/.local/bin/git-credential-aicoding|owned|configs/git/git-credential-aicoding
$HOME/.local/bin/memory-hint|owned|configs/memory/memory-hint
$HOME/.local/bin/aicoding-worktree|raw|bin/aicoding-worktree
$HOME/.local/bin/cloudflare-render|owned|configs/cloudflare/cloudflare-render
$HOME/.local/bin/secrets-check|owned|configs/secrets/secrets-check
$HOME/.codex/AGENTS.md|owned|configs/codex/AGENTS.md
$HOME/.cursor/skills/aicoding-estate/SKILL.md|owned|configs/cursor/skills/aicoding-estate/SKILL.md
$HOME/.cursor/hooks.json|owned|configs/cursor/hooks.json
$HOME/.config/opencode/plugins/kanban-work.js|owned|configs/opencode/plugins/kanban-work.js
EOF
  if [[ "$(aicoding_profile)" == host ]]; then
    echo "$HOME/.bashrc.d/aicoding-boot-sync.sh|owned|configs/bash/boot-sync.sh"
  else
    cat <<EOF
$HOME/.tmux.conf|owned|configs/tmux/tmux.conf
$HOME/.bashrc.d/aicoding-ssh-auth-sock.sh|owned|configs/bash/ssh-auth-sock.sh
EOF
  fi
}

# Every managed destination, one "dest|kind|source" row each. Kinds: owned,
# raw, mixed (owned/seeded keys from configs/managed-config.json) and block
# (the ~/.bashrc marker block).
managed_inventory() {
  local rel
  managed_inventory_overwrite
  jq -r --arg h "$HOME" '.mixed | to_entries[] | "\($h)/\(.key)|mixed|\(.value.source)"' \
    "$(_managed_config_data)" || return 1
  printf '%s|block|\n' "$HOME/.bashrc"
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    if [[ "$rel" == *.md ]]; then
      printf '%s|owned|skills/%s\n' "$HOME/.claude/skills/$rel" "$rel"
    else
      printf '%s|raw|skills/%s\n' "$HOME/.claude/skills/$rel" "$rel"
    fi
  done < <(enumerate_skill_files "$AICODING_BLUEPRINT_CLONE/skills")
  for rel in "$AICODING_BLUEPRINT_CLONE/commands"/*.md; do
    [[ -f "$rel" ]] || continue
    printf '%s|owned|commands/%s\n' "$HOME/.claude/commands/${rel##*/}" "${rel##*/}"
  done
}

managed_marker_block_start() { printf '%s' '# >>> aicoding managed block — do not edit between markers >>>'; }
managed_marker_block_end()   { printf '%s' '# <<< aicoding managed block <<<'; }

managed_bashrc_block_body() {
  cat <<'EOF'
# Sourced from configs/bash/* via the aicoding blueprint. Edit those
# files (or your own ~/.bashrc.d/local-*.sh additions), not this block.
export PATH="/usr/local/go/bin:$PATH"
for _aicoding_f in "$HOME"/.bashrc.d/*.sh; do
  [ -r "$_aicoding_f" ] && . "$_aicoding_f"
done
unset _aicoding_f
EOF
}

# --- Desired content ---------------------------------------------------------

_managed_bashrc() {
  local dest=$1 out=$2 start end body
  start=$(managed_marker_block_start); end=$(managed_marker_block_end)
  body=$(managed_bashrc_block_body)
  if [[ -f "$dest" ]] && grep -qxF "$start" "$dest" && grep -qxF "$end" "$dest"; then
    awk -v s="$start" -v e="$end" -v b="$body" '
      $0 == s { print; print b; in_block = 1; next }
      $0 == e { print; in_block = 0; next }
      !in_block { print }
    ' "$dest" > "$out"
  else
    {
      [[ -f "$dest" ]] && cat "$dest"
      printf '\n%s\n%s\n%s\n' "$start" "$body" "$end"
    } > "$out"
  fi
}

_MANAGED_JSON_MERGE='
def rule($s):
  if ($s | endswith(".*")) then {p: ($s[:-2] | split(".")), k: "each"}
  elif ($s | endswith("[]")) then {p: ($s[:-2] | split(".")), k: "union"}
  else {p: ($s | split(".")), k: "whole"} end;
def at($p): try getpath($p) catch null;
def member($xs; $x): $xs | any(.[]; . == $x);
.[0] as $b | .[1] as $raw
| reduce $rules.owned[] as $s ($dest;
    rule($s) as $r | ($b | at($r.p)) as $in
    | if $r.k == "each" then
        ((($raw | at($r.p)) // {}) | to_entries) as $shipped
        | reduce $shipped[] as $e (.;
            if (($in // {}) | has($e.key)) then .
            elif ($e.value | type) == "object" and ($e.value.url // null) != null
                 and (at($r.p + [$e.key]) | type) == "object"
                 and at($r.p + [$e.key]).url == $e.value.url
            then delpaths([$r.p + [$e.key]]) else . end)
        | if $in == null then .
          else reduce ($in | keys_unsorted[]) as $k (.; setpath($r.p + [$k]; $in[$k])) end
      elif $in == null then .
      elif $r.k == "union" then
        at($r.p) as $cur
        | if ($cur | type) == "array"
          then setpath($r.p; $cur + [$in[] | select(member($cur; .) | not)])
          else setpath($r.p; $in) end
      else setpath($r.p; $in) end)
| reduce $rules.seeded[] as $s (.;
    rule($s) as $r | ($b | at($r.p)) as $in
    | if $in == null then .
      elif $r.k == "each" then
        reduce ($in | keys_unsorted[]) as $k (.;
          if at($r.p + [$k]) == null then setpath($r.p + [$k]; $in[$k]) else . end)
      elif at($r.p) == null then setpath($r.p; $in)
      else . end)
| reduce $rules.retired[] as $x (.;
    if member($x.shipped; at($x.path)) then delpaths([$x.path]) else . end)
'

# Owned keys take the blueprint value, seeded keys are set only when missing,
# and everything else in the file stays personal. Returns 3 for a malformed
# destination, which is never overwritten.
_managed_mixed() {
  local dest=$1 src=$2 out=$3 rel rules rendered rc=0
  rel=${dest#"$HOME"/}
  rules=$(jq -c --arg r "$rel" \
    '.mixed[$r] + {retired: [.retired_keys[] | select(.dest == $r)]}' \
    "$(_managed_config_data)") || return 1
  rendered=$(mktemp) || return 1
  _substitute_file_to "$src" "$rendered" || { rm -f "$rendered"; return 1; }
  if [[ ! -s "$dest" ]]; then
    cat "$rendered" > "$out"
  elif [[ "$dest" == *.toml ]]; then
    python3 "$_AICODING_MANAGED_TOML" "$dest" "$rendered" "$src" "$rules" "$out" || rc=$?
  elif ! jq -e 'type == "object"' "$dest" >/dev/null 2>&1; then
    rc=3
  else
    jq -s --argjson rules "$rules" --slurpfile dest "$dest" \
      "\$dest[0] as \$dest | $_MANAGED_JSON_MERGE" "$rendered" "$src" > "$out" || rc=3
  fi
  rm -f "$rendered"
  return "$rc"
}

# Write the content <dest> should have into <out>.
_managed_desired() {
  local dest=$1 kind=$2 src=$3 out=$4
  case "$kind" in
    owned) _render_managed_source "$src" "$dest" "$out" ;;
    raw) cat "$src" > "$out" ;;
    mixed) _managed_mixed "$dest" "$src" "$out" ;;
    block) _managed_bashrc "$dest" "$out" ;;
    *) return 1 ;;
  esac
}

_managed_differs() {
  local dest=$1 kind=$2 src=$3 out=$4
  [[ -e "$dest" ]] || return 0
  if [[ "$kind" == mixed && "$dest" == *.json ]]; then
    [[ "$(jq -S . "$dest" 2>/dev/null)" != "$(jq -S . "$out" 2>/dev/null)" ]] && return 0
  else
    cmp -s "$out" "$dest" || return 0
  fi
  [[ "$kind" == owned || "$kind" == raw ]] && [[ -x "$src" && ! -x "$dest" ]]
}

_managed_write() {
  local dest=$1 kind=$2 src=$3 out=$4 mode=0600
  case "$kind" in
    owned|raw) [[ -x "$src" ]] && mode=0700 ;;
    block) [[ -f "$dest" ]] && mode=$(stat -c '%a' "$dest") ;;
  esac
  _write_atomic "$out" "$dest" "$mode"
}

# --- Retired files -----------------------------------------------------------

# True only when <dest> equals some version of <source> the blueprint once
# shipped, rendered for this HOME/profile. Staged releases carry no .git, so
# staging keeps those historical bytes under .aicoding-generated-provenance.
owned_file_has_generated_provenance() {
  local dest=$1 source=$2 commit tmp historical rendered
  [ -f "$dest" ] || return 1
  tmp=$(mktemp) || return 1
  rendered="$tmp.rendered"
  for historical in "$AICODING_BLUEPRINT_CLONE/.aicoding-generated-provenance/$source"/*; do
    [ -f "$historical" ] || continue
    _render_managed_source "$historical" "$dest" "$rendered" 2>/dev/null || continue
    if cmp -s "$rendered" "$dest"; then rm -f "$tmp" "$rendered"; return 0; fi
  done
  if [ -d "$AICODING_BLUEPRINT_CLONE/.git" ]; then
    while IFS= read -r commit; do
      [ -n "$commit" ] || continue
      git -C "$AICODING_BLUEPRINT_CLONE" show "$commit:$source" >"$tmp" 2>/dev/null || continue
      _render_managed_source "$tmp" "$dest" "$rendered" 2>/dev/null || continue
      if cmp -s "$rendered" "$dest"; then rm -f "$tmp" "$rendered"; return 0; fi
    done < <(git -C "$AICODING_BLUEPRINT_CLONE" log --format=%H --all -- "$source" 2>/dev/null)
  fi
  rm -f "$tmp" "$rendered"
  return 1
}

managed_retired_files() {
  jq -r '.retired_files[] | "\(.dest)\t\(.source)"' "$(_managed_config_data)"
}

# A retired file that no longer matches anything the blueprint shipped was
# edited or created by hand: keep it and say so once.
_managed_retire_files() {
  local dry=$1 hold=${2:-0} rel source dest retired kept="$AICODING_STATE_DIR/retired-kept"
  retired=$(managed_retired_files) || return 1
  while IFS=$'\t' read -r rel source; do
    [[ -n "$rel" ]] || continue
    dest="$HOME/$rel"
    [[ -e "$dest" ]] || continue
    [[ "$hold" == 1 ]] && _managed_is_shared "$dest" && continue
    if owned_file_has_generated_provenance "$dest" "$source"; then
      if [[ "$dry" == 1 ]]; then
        echo "      would remove retired file: $dest"
      elif rm -f "$dest"; then
        echo "      removed retired file: $dest"
      fi
    elif ! grep -qxF "$dest" "$kept" 2>/dev/null; then
      echo "      kept retired file (changed locally): $dest"
      [[ "$dry" == 1 ]] || { mkdir -p "$AICODING_STATE_DIR" && printf '%s\n' "$dest" >> "$kept"; } || true
    fi
  done <<< "$retired"
}

# --- Release ordering on shared roots ----------------------------------------

_managed_release_ordinal() {
  local n
  n=$(cat "$AICODING_BLUEPRINT_CLONE/.aicoding-release-ordinal" 2>/dev/null) || n=
  if ! [[ "$n" =~ ^[0-9]+$ ]] \
      && [ "$(git -C "$AICODING_BLUEPRINT_CLONE" rev-parse --is-shallow-repository 2>/dev/null)" = false ]; then
    n=$(git -C "$AICODING_BLUEPRINT_CLONE" rev-list --count HEAD 2>/dev/null) || n=
  fi
  [[ "$n" =~ ^[0-9]+$ ]] && printf '%s\n' "$n"
}

_managed_release_marker() { printf '%s\n' "$HOME/.claude/.aicoding-release"; }

_managed_is_shared() {
  case "$1" in
    "$HOME"/.claude/*|"$HOME"/.codex/*|"$HOME"/.cursor/*) return 0 ;;
  esac
  return 1
}

# True when a newer release than this one has written the shared roots. A
# local --blueprint run is development and always writes. A release with no
# ordinal (a bootstrap tarball, a shallow checkout) yields to any marker: the
# next staged update gives it one.
_managed_newer_release_owns_shared() {
  local mine theirs
  [[ "${AICODING_BLUEPRINT_LOCAL:-0}" != 1 ]] || return 1
  read -r theirs _ < "$(_managed_release_marker)" 2>/dev/null || return 1
  [[ "$theirs" =~ ^[0-9]+$ ]] || return 1
  mine=$(_managed_release_ordinal) || return 0
  (( theirs > mine ))
}

# Local runs never move the marker, so a dev branch cannot hold back the
# released containers sharing these roots.
_managed_claim_shared() {
  local time sha marker tmp
  [[ "${AICODING_BLUEPRINT_LOCAL:-0}" != 1 ]] || return 0
  time=$(_managed_release_ordinal) || return 0
  sha=$(cat "$AICODING_BLUEPRINT_CLONE/.aicoding-version" 2>/dev/null) \
    || sha=$(git -C "$AICODING_BLUEPRINT_CLONE" rev-parse HEAD 2>/dev/null) || sha=unknown
  marker=$(_managed_release_marker)
  mkdir -p "$(dirname "$marker")" || return 1
  tmp=$(mktemp "$marker.XXXXXX") || return 1
  printf '%s %s\n' "$time" "$sha" > "$tmp" && mv -f "$tmp" "$marker" || { rm -f "$tmp"; return 1; }
}

# --- Apply -------------------------------------------------------------------

# Bring every managed destination to its desired content. Sets
# MANAGED_RESULT[dest] to unchanged, updated, pending (dry run), held (a
# newer release owns the shared roots), malformed, failed,
# "skipped:<tool>_not_installed" or "blocked:<reason>". MANAGED_CONFIG_GATE
# may name a function that
# vetoes a write (prints a reason, returns nonzero) when a destination's tool
# is not ready for it. Returns nonzero when any write failed.
managed_config_apply() {
  local dry=0 dest kind source src out reason rc=0 changes=0 inventory hold=0 held=0
  [[ "${1:-}" == --dry-run ]] && dry=1
  declare -gA MANAGED_RESULT=()
  inventory=$(managed_inventory) || { echo "      could not list managed files" >&2; return 1; }
  _managed_newer_release_owns_shared && hold=1
  while IFS='|' read -r dest kind source; do
    [[ -n "$dest" ]] || continue
    src="$AICODING_BLUEPRINT_CLONE/$source"
    if [[ "$hold" == 1 ]] && _managed_is_shared "$dest"; then
      MANAGED_RESULT[$dest]=held; held=$((held + 1))
      continue
    fi
    if [[ "$kind" != block && ! -f "$src" ]]; then
      MANAGED_RESULT[$dest]=failed; rc=1
      echo "      missing blueprint source $source for $dest" >&2
      continue
    fi
    out=$(mktemp) || { MANAGED_RESULT[$dest]=failed; rc=1; continue; }
    reason=0
    _managed_desired "$dest" "$kind" "$src" "$out" || reason=$?
    if [[ "$reason" == 3 ]]; then
      MANAGED_RESULT[$dest]=malformed
      echo "      left unreadable file unchanged (fix or remove it): $dest" >&2
    elif [[ "$reason" != 0 ]]; then
      MANAGED_RESULT[$dest]=failed; rc=1
      echo "      could not render $dest" >&2
    elif ! _managed_differs "$dest" "$kind" "$src" "$out"; then
      MANAGED_RESULT[$dest]=unchanged
    elif [[ "$dry" == 1 ]]; then
      MANAGED_RESULT[$dest]=pending; changes=$((changes + 1))
      echo "      would update: $dest"
    elif [[ -n "${MANAGED_CONFIG_GATE:-}" ]] && ! reason=$("$MANAGED_CONFIG_GATE" "$dest"); then
      if [[ "$reason" == *_not_installed ]]; then
        MANAGED_RESULT[$dest]="skipped:$reason"
        echo "      skipped (${reason%_not_installed} not installed): $dest"
      else
        MANAGED_RESULT[$dest]="blocked:${reason:-runtime_compatibility_unavailable}"
        echo "      blocked (${reason:-runtime_compatibility_unavailable}): $dest"
      fi
    elif _managed_write "$dest" "$kind" "$src" "$out"; then
      MANAGED_RESULT[$dest]=updated; changes=$((changes + 1))
      echo "      updated: $dest"
    else
      MANAGED_RESULT[$dest]=failed; rc=1
      echo "      could not write $dest" >&2
    fi
    rm -f "$out"
  done <<< "$inventory"
  _managed_retire_files "$dry" "$hold" || rc=1
  if [[ "$held" -gt 0 ]]; then
    echo "      left $held shared files to the newer release in $(_managed_release_marker)"
  elif [[ "$dry" == 0 && "$rc" == 0 ]]; then
    _managed_claim_shared || rc=1
  fi
  [[ "$changes" -gt 0 ]] || echo "      managed config already current"
  return "$rc"
}
