# Installed-component discovery and safe staged vendor adapters. Sourced only.

: "${AICODING_STATE_DIR:=$HOME/.local/state/aicoding}"
: "${AICODING_DATA_DIR:=$HOME/.local/share/aicoding}"
: "${AICODING_VENDOR_TIMEOUT:=600}"

if ! declare -F aicoding_activate_version >/dev/null 2>&1; then
  _aicoding_runtime_root=${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
  . "$_aicoding_runtime_root/lib/runtime.sh"
  unset _aicoding_runtime_root
fi

_aicoding_command_is_linux() {
  local path
  path=$(command -v "$1" 2>/dev/null) || return 1
  path=$(readlink -f "$path" 2>/dev/null || printf '%s' "$path")
  case "$path" in
    "${AICODING_WSL_MOUNT_PREFIX:-/mnt/}"*) return 1 ;;
  esac
  return 0
}

aicoding_installed_components() {
  local selection="$AICODING_STATE_DIR/component-selection.json"
  if [ -f "$selection" ] \
      && [ "$(jq -r '.profile // empty' "$selection" 2>/dev/null)" = minimal-pi ]; then
    jq -r 'select(.schema == 1 and (.components | type == "array"))
      | .components[] | select(. == "aicoding" or . == "dvw")' \
      "$selection" 2>/dev/null
    return 0
  fi
  printf 'aicoding\n'
  _aicoding_command_is_linux claude && printf 'claude\n'
  _aicoding_command_is_linux codex && printf 'codex\n'
  _aicoding_command_is_linux opencode && printf 'opencode\n'
  if _aicoding_command_is_linux agent || _aicoding_command_is_linux cursor-agent; then printf 'cursor\n'; fi
  _aicoding_command_is_linux pi && printf 'pi\n'
  _aicoding_command_is_linux dvw && printf 'dvw\n'
  _aicoding_command_is_linux firecrawl-mcp && printf 'mcp-firecrawl\n'
  _aicoding_command_is_linux brave-search-mcp-server && printf 'mcp-brave\n'
  _aicoding_mcp_selected context7 && printf 'mcp-context7\n'
  _aicoding_mcp_selected playwright && printf 'mcp-playwright\n'
  if _aicoding_command_is_linux bw || _aicoding_command_is_linux claude-bw \
      || [ -d "${AICODING_VENDOR_DIR:-$AICODING_DATA_DIR/vendor}/bw-AICode/.git" ]; then
    printf 'bw-AICode\n'
  fi
}

# Boolean-only discovery: never prints registration/config contents. Stable
# launchers, an existing Claude registration/plugin, or another tool's named
# MCP config make the component eligible. Absent harnesses stay absent.
_aicoding_mcp_selected() {
  local name=$1 command_name registration
  case "$name" in context7) command_name=context7-mcp ;; playwright) command_name=playwright-mcp ;; *) return 1 ;; esac
  _aicoding_command_is_linux "$command_name" && return 0
  if _aicoding_command_is_linux claude; then
    registration=$(timeout "${AICODING_PROBE_TIMEOUT:-15}" claude mcp get "$name" </dev/null 2>/dev/null) || registration=""
    printf '%s\n' "$registration" | grep -q '^[[:space:]]*Command:[[:space:]]*' && return 0
  fi
  case "$name" in
    context7)
      grep -Eq '^\[mcp_servers\.context7\][[:space:]]*$' "$HOME/.codex/config.toml" 2>/dev/null && return 0
      jq -e '.mcp.context7 // .mcpServers.context7' "$HOME/.config/opencode/opencode.json" >/dev/null 2>&1 && return 0
      jq -e '.mcpServers.context7' "$HOME/.cursor/mcp.json" >/dev/null 2>&1 && return 0
      jq -e '.enabledPlugins["context7@claude-plugins-official"] == true' "$HOME/.claude/settings.json" >/dev/null 2>&1 && return 0
      ;;
    playwright)
      grep -Eq '^\[mcp_servers\.playwright\][[:space:]]*$' "$HOME/.codex/config.toml" 2>/dev/null && return 0
      jq -e '.mcp.playwright // .mcpServers.playwright' "$HOME/.config/opencode/opencode.json" >/dev/null 2>&1 && return 0
      jq -e '.mcpServers.playwright' "$HOME/.cursor/mcp.json" >/dev/null 2>&1 && return 0
      jq -e '.enabledPlugins["playwright@claude-plugins-official"] == true' "$HOME/.claude/settings.json" >/dev/null 2>&1 && return 0
      ;;
  esac
  return 1
}

_aicoding_version_from_command() {
  timeout "${AICODING_PROBE_TIMEOUT:-15}" "$1" --version </dev/null 2>/dev/null \
    | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?' | head -1
}

_aicoding_npm_target() {
  aicoding_progress_run "${AICODING_PROGRESS_COMPONENT:-package}: resolving version (timeout ${AICODING_VENDOR_TIMEOUT}s)" timeout "$AICODING_VENDOR_TIMEOUT" npm view "$1" version --json </dev/null \
    | jq -r 'if type == "array" then last else . end // empty' 2>/dev/null
}

_aicoding_version_at_least() {
  local actual=$1 required=$2
  [ -n "$actual" ] && [ "$(printf '%s\n%s\n' "$required" "$actual" | sort -V | head -1)" = "$required" ]
}

# Record a conservative deferral and bind it to the adapter invocation that
# successfully wrote the receipt. The aggregate updater resets this marker
# before every component, so an old blocked receipt cannot qualify a later
# failure that returned before recording its own outcome.
_aicoding_record_deferred() {
  aicoding_result_record "$@" || return $?
  AICODING_COMPONENT_ATTEMPT_DISPOSITION=deferred
}

# Print a short result reason and return nonzero when an actionable managed
# config depends on a tool capability that is not installed and verified.
aicoding_config_is_compatible() {
  local dest=$1 command_name version
  case "$dest" in
    "$HOME/.codex/config.toml")
      _aicoding_update_receipt_allows codex || { echo codex_update_not_verified; return 1; }
      _aicoding_exact_mcp_config_allows "$dest" \
        || { echo mcp_exact_version_staging_unavailable; return 1; }
      _aicoding_shared_consumers_allow codex 0.148.0 "$HOME/.codex" || { echo codex_shared_consumers_incompatible; return 1; }
      _aicoding_command_is_linux codex || { echo codex_not_installed; return 1; }
      version=$(_aicoding_version_from_command codex) || true
      _aicoding_version_at_least "$version" 0.148.0 || { echo codex_requires_0.148; return 1; }
      ;;
    "$HOME/.config/opencode/opencode.json")
      _aicoding_update_receipt_allows opencode || { echo opencode_update_not_verified; return 1; }
      _aicoding_exact_mcp_config_allows "$dest" \
        || { echo mcp_exact_version_staging_unavailable; return 1; }
      _aicoding_shared_consumers_allow opencode "" "$HOME/.config/opencode" || { echo opencode_shared_consumers_incompatible; return 1; }
      _aicoding_command_is_linux opencode || { echo opencode_not_installed; return 1; }
      timeout "${AICODING_PROBE_TIMEOUT:-15}" opencode debug config </dev/null >/dev/null 2>&1 \
        || { echo opencode_config_probe_failed; return 1; }
      ;;
    "$HOME/.cursor/mcp.json"|"$HOME/.cursor/cli-config.json"|"$HOME/.cursor/hooks.json")
      _aicoding_update_receipt_allows cursor || { echo cursor_update_not_verified; return 1; }
      if [ "$dest" = "$HOME/.cursor/mcp.json" ]; then
        _aicoding_exact_mcp_config_allows "$dest" \
          || { echo mcp_exact_version_staging_unavailable; return 1; }
      fi
      _aicoding_shared_consumers_allow cursor "" "$HOME/.cursor" || { echo cursor_shared_consumers_incompatible; return 1; }
      if _aicoding_command_is_linux agent; then command_name=agent
      elif _aicoding_command_is_linux cursor-agent; then command_name=cursor-agent
      else echo cursor_not_installed; return 1; fi
      timeout "${AICODING_PROBE_TIMEOUT:-15}" "$command_name" --version </dev/null >/dev/null 2>&1 \
        || { echo cursor_config_probe_failed; return 1; }
      ;;
    "$HOME/.pi/agent/extensions/"*)
      _aicoding_update_receipt_allows pi || { echo pi_update_not_verified; return 1; }
      _aicoding_shared_consumers_allow pi "" "$HOME/.pi" || { echo pi_shared_consumers_incompatible; return 1; }
      _aicoding_command_is_linux pi || { echo pi_not_installed; return 1; }
      timeout "${AICODING_PROBE_TIMEOUT:-15}" pi --version </dev/null >/dev/null 2>&1 \
        || { echo pi_config_probe_failed; return 1; }
      ;;
    "$HOME/.claude/settings.json")
      _aicoding_update_receipt_allows claude || { echo claude_update_not_verified; return 1; }
      _aicoding_exact_mcp_config_allows "$dest" \
        || { echo mcp_exact_version_staging_unavailable; return 1; }
      _aicoding_shared_consumers_allow claude "" "$HOME/.claude" || { echo claude_shared_consumers_incompatible; return 1; }
      _aicoding_command_is_linux claude || { echo claude_not_installed; return 1; }
      timeout "${AICODING_PROBE_TIMEOUT:-15}" claude --version </dev/null >/dev/null 2>&1 \
        || { echo claude_config_probe_failed; return 1; }
      ;;
  esac
  return 0
}

_aicoding_exact_mcp_config_allows() {
  [ "${AICODING_REQUIRE_UPDATE_RECEIPT:-0}" != 1 ] || aicoding_exact_mcp_config_ready "$1"
}

# Package and Claude registration receipts are independent: another harness
# may use an activated package even when Claude has a user-owned registration
# that cannot be migrated. Shared config additionally requires every
# inventoried consumer to report both packages ready for that destination.
aicoding_exact_mcp_config_ready() {
  local dest=$1 component
  [ -f "$AICODING_RESULTS_FILE" ] || return 1
  for component in mcp-context7 mcp-playwright; do
    case "$(jq -r --arg c "$component" '.components[$c].state // empty' "$AICODING_RESULTS_FILE" 2>/dev/null)" in
      current|updated) ;;
      *) return 1 ;;
    esac
    _aicoding_shared_consumers_require "$component" "" "$dest" || return 1
  done
  case "$dest" in
    "$HOME/.claude/settings.json")
      for component in mcp-registration-claude-context7 mcp-registration-claude-playwright; do
        case "$(jq -r --arg c "$component" '.components[$c].state // empty' "$AICODING_RESULTS_FILE" 2>/dev/null)" in
          current|updated) ;;
          *) return 1 ;;
        esac
      done
      ;;
  esac
}

# Print the canonical root only when a destination belongs to a configured or
# directly mounted shared config root. A directory merely living under HOME is
# local. OpenCode's shared runtime root does not make ~/.config/opencode shared.
# C may supply colon-separated canonical roots with AICODING_SHARED_CONFIG_ROOTS.
aicoding_config_shared_root() {
  local dest=$1 candidate="" physical mount_target redirected=0
  local -a configured=()
  case "$dest" in
    "$HOME/.claude"|"$HOME/.claude/"*) candidate="$HOME/.claude" ;;
    "$HOME/.codex"|"$HOME/.codex/"*) candidate="$HOME/.codex" ;;
    "$HOME/.cursor"|"$HOME/.cursor/"*) candidate="$HOME/.cursor" ;;
    "$HOME/.config/opencode"|"$HOME/.config/opencode/"*)
      candidate="$HOME/.config/opencode" ;;
    "$HOME/.local/share/opencode"|"$HOME/.local/share/opencode/"*)
      candidate="$HOME/.local/share/opencode" ;;
    *) return 1 ;;
  esac
  [ -L "$candidate" ] && redirected=1
  # A missing ordinary directory cannot currently be a mount target. It is a
  # local first-deploy destination; a dangling symlink remains unknown.
  [ "$redirected" -eq 1 ] || [ -e "$candidate" ] || return 1
  # A recognized config root that cannot be resolved is unknown, not proven
  # local. Return 2 so the authorization layer can fail closed.
  physical=$(readlink -f "$candidate" 2>/dev/null) || return 2
  IFS=: read -ra configured <<< "${AICODING_SHARED_CONFIG_ROOTS:-}"
  local root
  for root in "${configured[@]}"; do
    [ -n "$root" ] || continue
    [ "$(readlink -f "$root" 2>/dev/null)" = "$physical" ] && { printf '%s\n' "$physical"; return 0; }
  done
  # Redirecting one of the known config roots may place it below a shared
  # mount whose target is an ancestor. Treat that ambiguity conservatively.
  [ "$redirected" -eq 0 ] || { printf '%s\n' "$physical"; return 0; }
  command -v findmnt >/dev/null 2>&1 || return 2
  mount_target=$(findmnt -T "$physical" -n -o TARGET 2>/dev/null) || return 2
  [ "$(readlink -f "$mount_target" 2>/dev/null)" = "$physical" ] || return 1
  printf '%s\n' "$physical"
}

aicoding_config_is_shared() { aicoding_config_shared_root "$1" >/dev/null; }

# A scheduler may publish non-secret consumer capability evidence in the
# shared aicodingsetup mount. Until every known consumer opts in, changing
# version-dependent shared settings is unsafe and remains deferred.
_aicoding_shared_consumers_allow() {
  local component=$1 minimum=${2:-} destination=${3:-} registry shared_root shared_rc
  registry=${AICODING_SHARED_CONSUMERS_FILE:-$HOME/.aicodingsetup/consumer-versions.json}
  [ "${AICODING_REQUIRE_SHARED_COMPATIBILITY:-0}" != 1 ] && return 0
  if shared_root=$(aicoding_config_shared_root "$destination"); then
    :
  else
    shared_rc=$?
    [ "$shared_rc" -eq 1 ] && return 0
    return 1
  fi
  local now version
  [ -f "$registry" ] || return 1
  now=$(date +%s)
  jq -e --arg c "$component" --arg root "$shared_root" --argjson now "$now" '
    .schema == 1 and (.roots | type == "array")
    and ([.roots[] | select(.shared_root == $root)] | length == 1)
    and ([.roots[] | select(.shared_root == $root)][0] as $r
      | $r.inventory_complete == true
      and ($r.expires_at | type == "number" and . > $now)
      and ($r.consumers | type == "array" and length > 0)
      and all($r.consumers[];
      (.id | type == "string" and length > 0)
      and (.components[$c].config_compatible == true)
      and (.components[$c].version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+"))
    ))' "$registry" >/dev/null 2>&1 || return 1
  [ -z "$minimum" ] && return 0
  while IFS= read -r version; do
    _aicoding_version_at_least "$version" "$minimum" || return 1
  done < <(jq -r --arg c "$component" --arg root "$shared_root" \
    '.roots[] | select(.shared_root == $root) | .consumers[].components[$c].version' "$registry")
}

# Mutation/readiness call sites use this wrapper so shared-root authorization
# follows the destination itself and cannot be disabled by a caller unsetting a
# temporary reconcile flag.
_aicoding_shared_consumers_require() {
  AICODING_REQUIRE_SHARED_COMPATIBILITY=1 \
    _aicoding_shared_consumers_allow "$@"
}

_aicoding_update_receipt_allows() {
  [ "${AICODING_REQUIRE_UPDATE_RECEIPT:-0}" != 1 ] && return 0
  [ -f "$AICODING_RESULTS_FILE" ] || return 1
  case "$(jq -r --arg c "$1" '.components[$c].state // empty' "$AICODING_RESULTS_FILE" 2>/dev/null)" in
    current|updated) return 0 ;;
    *) return 1 ;;
  esac
}

_aicoding_config_component() {
  case "$1" in
    "$HOME/.codex/"*) echo config-codex ;;
    "$HOME/.config/opencode/"*|"$HOME/.local/share/opencode/"*) echo config-opencode ;;
    "$HOME/.cursor/"*) echo config-cursor ;;
    "$HOME/.pi/"*) echo config-pi ;;
    "$HOME/.claude/"*) echo config-claude ;;
    *) echo config ;;
  esac
}

_aicoding_claude_mcp_selected() {
  local name=$1 plugin registration
  _aicoding_command_is_linux claude || return 1
  registration=$(_aicoding_claude_mcp_get "$name") || registration=""
  printf '%s\n' "$registration" | grep -q '^[[:space:]]*Command:[[:space:]]*' && return 0
  plugin="${name}@claude-plugins-official"
  jq -e --arg p "$plugin" '.enabledPlugins[$p] == true' "$HOME/.claude/settings.json" >/dev/null 2>&1
}

_aicoding_claude_mcp_get() {
  timeout "${AICODING_PROBE_TIMEOUT:-15}" claude mcp get "$1" </dev/null 2>/dev/null
}

_aicoding_registration_recovery_write() {
  local name=$1; shift
  local dir="$AICODING_STATE_DIR/registration-recovery" final tmp
  final="$dir/claude-$name.json"
  mkdir -p "$dir" || return 1
  tmp=$(mktemp "$dir/.claude-$name.XXXXXX") || return 1
  if ! jq -n --arg command npx --args \
      '{schema:1,command:$command,args:$ARGS.positional}' -- "$@" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$final" || { rm -f "$tmp"; return 1; }
}

_aicoding_registration_recovery_clear() {
  rm -f "$AICODING_STATE_DIR/registration-recovery/claude-$1.json"
}

# Migrate only known blueprint-era moving registrations. Unknown commands are
# user configuration and remain byte-for-byte untouched. If replacement fails,
# restore the exact recognized command/argument vector before returning failure.
_aicoding_reconcile_claude_mcp_registration() {
  local name=$1 component=$2 version=$3 launcher_name=$4; shift 4
  local registration_component="mcp-registration-claude-$name"
  local launcher="$HOME/.local/bin/$launcher_name" current="" command_line="" args_line="" had=0
  local -a wanted_args=("$@") old_args=()
  [ "${AICODING_MCP_REGISTRATION_DISABLE:-0}" != 1 ] || return 0
  [ -x "$launcher" ] || { aicoding_result_record "$registration_component" failed "$version" stable_launcher_missing; return 1; }
  if [ "${AICODING_MCP_REGISTRATION_FORCE:-0}" != 1 ] \
      && ! _aicoding_claude_mcp_selected "$name"; then
    _aicoding_record_deferred "$registration_component" blocked "$version" registration_not_selected
    return 0
  fi
  _aicoding_update_receipt_allows claude \
    || { _aicoding_record_deferred "$registration_component" blocked "$version" claude_update_not_verified; return 1; }
  local claude_version
  claude_version=$(_aicoding_version_from_command claude) || true
  [ -n "$claude_version" ] \
    || { _aicoding_record_deferred "$registration_component" blocked "$version" claude_version_unavailable; return 1; }
  _aicoding_shared_consumers_require claude "" "$HOME/.claude" \
    || { _aicoding_record_deferred "$registration_component" blocked "$version" claude_consumers_incompatible; return 1; }
  _aicoding_shared_consumers_require "$component" "" "$HOME/.claude" \
    || { _aicoding_record_deferred "$registration_component" blocked "$version" shared_registration_consumers_incompatible; return 1; }
  if declare -F aicoding_shared_locks_acquire >/dev/null 2>&1; then
    aicoding_shared_locks_acquire "$HOME/.claude/settings.json" \
      || { _aicoding_record_deferred "$registration_component" blocked "$version" shared_registration_busy; return 1; }
  fi
  current=$(_aicoding_claude_mcp_get "$name") || current=""
  command_line=$(printf '%s\n' "$current" | sed -n 's/^[[:space:]]*Command:[[:space:]]*//p' | head -1)
  args_line=$(printf '%s\n' "$current" | sed -n 's/^[[:space:]]*Args:[[:space:]]*//p' | head -1)
  if [ "$command_line" = "$launcher" ] && [ "$args_line" = "${wanted_args[*]}" ]; then
    aicoding_result_record "$registration_component" current "$version" registration_verified "$version"
    return 0
  fi
  if [ -n "$command_line" ]; then
    had=1
    case "$name|$command_line|$args_line" in
      'context7|npx|-y @upstash/context7-mcp') old_args=(-y @upstash/context7-mcp) ;;
      'context7|npx|@upstash/context7-mcp') old_args=(@upstash/context7-mcp) ;;
      'playwright|npx|@playwright/mcp@latest --browser chromium') old_args=(@playwright/mcp@latest --browser chromium) ;;
      'playwright|npx|-y @playwright/mcp@latest --browser chromium') old_args=(-y @playwright/mcp@latest --browser chromium) ;;
      *) _aicoding_record_deferred "$registration_component" conflict "$version" registration_conflict; return 1 ;;
    esac
    _aicoding_registration_recovery_write "$name" "${old_args[@]}" \
      || { aicoding_result_record "$registration_component" failed "$version" registration_recovery_write_failed; return 1; }
    timeout "$AICODING_VENDOR_TIMEOUT" claude mcp remove -s user "$name" </dev/null >/dev/null 2>&1 \
      || { aicoding_result_record "$registration_component" failed "$version" registration_remove_failed; return 1; }
  fi
  if timeout "$AICODING_VENDOR_TIMEOUT" claude mcp add "$name" -s user -- "$launcher" "${wanted_args[@]}" \
      </dev/null >/dev/null 2>&1; then
    current=$(_aicoding_claude_mcp_get "$name") || current=""
    command_line=$(printf '%s\n' "$current" | sed -n 's/^[[:space:]]*Command:[[:space:]]*//p' | head -1)
    args_line=$(printf '%s\n' "$current" | sed -n 's/^[[:space:]]*Args:[[:space:]]*//p' | head -1)
    if [ "$command_line" = "$launcher" ] && [ "$args_line" = "${wanted_args[*]}" ]; then
      _aicoding_registration_recovery_clear "$name" \
        || { aicoding_result_record "$registration_component" failed "$version" registration_recovery_cleanup_failed; return 1; }
      aicoding_result_record "$registration_component" updated "$version" registration_migrated "$version"
      return 0
    fi
  fi
  current=$(_aicoding_claude_mcp_get "$name") || current=""
  command_line=$(printf '%s\n' "$current" | sed -n 's/^[[:space:]]*Command:[[:space:]]*//p' | head -1)
  if [ -n "$command_line" ] \
      && ! timeout "$AICODING_VENDOR_TIMEOUT" claude mcp remove -s user "$name" </dev/null >/dev/null 2>&1; then
      aicoding_result_record "$registration_component" failed "$version" registration_rollback_cleanup_failed
      return 1
  fi
  if [ "$had" -eq 1 ]; then
    if ! timeout "$AICODING_VENDOR_TIMEOUT" claude mcp add "$name" -s user -- npx "${old_args[@]}" \
        </dev/null >/dev/null 2>&1; then
      aicoding_result_record "$registration_component" failed "$version" registration_rollback_restore_failed
      return 1
    fi
    current=$(_aicoding_claude_mcp_get "$name") || current=""
    command_line=$(printf '%s\n' "$current" | sed -n 's/^[[:space:]]*Command:[[:space:]]*//p' | head -1)
    args_line=$(printf '%s\n' "$current" | sed -n 's/^[[:space:]]*Args:[[:space:]]*//p' | head -1)
    if [ "$command_line" != npx ] || [ "$args_line" != "${old_args[*]}" ]; then
      aicoding_result_record "$registration_component" failed "$version" registration_rollback_restore_failed
      return 1
    fi
    _aicoding_registration_recovery_clear "$name" \
      || { aicoding_result_record "$registration_component" failed "$version" registration_recovery_cleanup_failed; return 1; }
  fi
  aicoding_result_record "$registration_component" failed "$version" registration_migration_failed
  return 1
}

_aicoding_activate_vendor_release() {
  aicoding_activate_version "$@"
}

# Materialize an exact repository commit into an immutable release directory.
# Callers validate the release before making it active.
_aicoding_stage_git_source() {
  local remote=$1 sha=$2 final=$3 stage
  stage="${final}.staging.$$"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  if [ -d "$final" ]; then
    [ "$(cat "$final/.aicoding-version" 2>/dev/null)" = "$sha" ] || return 1
    return 0
  fi
  rm -rf "$stage"; mkdir -p "$(dirname "$final")"
  timeout "$AICODING_VENDOR_TIMEOUT" git clone --no-checkout "$remote" "$stage" >/dev/null 2>&1 || { rm -rf "$stage"; return 1; }
  timeout "$AICODING_VENDOR_TIMEOUT" git -C "$stage" checkout --detach "$sha" >/dev/null 2>&1 || { rm -rf "$stage"; return 1; }
  [ "$(git -C "$stage" rev-parse HEAD 2>/dev/null)" = "$sha" ] || { rm -rf "$stage"; return 1; }
  rm -rf "$stage/.git"
  printf '%s\n' "$sha" > "$stage/.aicoding-version"
  mv "$stage" "$final"
}

_aicoding_codex_sidecar_ready() {
  local installed=$1 command_path resolved_command current active versions_root physical sidecar
  command_path=$(command -v codex 2>/dev/null) || return 1
  resolved_command=$(readlink -f "$command_path" 2>/dev/null) || return 1

  # A legacy direct install keeps the sidecar beside its resolved binary.
  if [ "$command_path" != "$HOME/.local/bin/codex" ] \
      || ! grep -Fxq '# Managed by aicoding immutable runtime.' "$command_path" 2>/dev/null; then
    [ -x "$(dirname "$resolved_command")/codex-code-mode-host" ]
    return $?
  fi

  # The stable managed launcher is a regular wrapper, so its sidecar lives in
  # the physical release selected by current/codex. Tie that release to the
  # installed version and keep every resolved path inside versions/codex.
  current="$AICODING_DATA_DIR/current/codex"
  [ -L "$current" ] || return 1
  [ "$(readlink "$current" 2>/dev/null)" = "../versions/codex/$installed" ] || return 1
  active=$(readlink -f "$current" 2>/dev/null) || return 1
  versions_root=$(readlink -f "$AICODING_DATA_DIR/versions/codex" 2>/dev/null) || return 1
  case "$active" in "$versions_root"/*) ;; *) return 1 ;; esac
  physical="$active/node_modules/.bin/codex"
  [ -x "$physical" ] || return 1
  [ "$(_aicoding_version_from_command "$physical" 2>/dev/null || true)" = "$installed" ] || return 1
  sidecar=$(find "$active/node_modules" -type f -name codex-code-mode-host \
    -perm -u+x -print -quit 2>/dev/null) || return 1
  [ -n "$sidecar" ]
}

# Stage an exact npm package under an immutable version directory, validate the
# staged executable (and Codex sidecar), then switch the managed launcher.
aicoding_update_npm_component() {
  local component=$1 command_name=$2 package=$3
  local installed target stage final actual
  installed=$(_aicoding_version_from_command "$command_name") || true
  target=$(_aicoding_npm_target "$package") || true
  if [[ ! "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
    aicoding_result_record "$component" failed "" target_version_unavailable
    return 1
  fi
  if [ "$installed" = "$target" ]; then
    if [ "$component" != codex ] || _aicoding_codex_sidecar_ready "$installed"; then
      aicoding_result_record "$component" current "$target" current "$installed"
      return 0
    fi
  fi
  stage="$AICODING_DATA_DIR/versions/$component/.staging.$target.$$"
  final="$AICODING_DATA_DIR/versions/$component/$target"
  mkdir -p "$(dirname "$stage")"
  rm -rf "$stage"
  if ! HOME="$stage/home" XDG_CONFIG_HOME="$stage/home/.config" \
      XDG_DATA_HOME="$stage/home/.local/share" XDG_CACHE_HOME="$stage/home/.cache" \
      XDG_STATE_HOME="$stage/home/.local/state" NPM_CONFIG_CACHE="$stage/.npm-cache" \
      aicoding_progress_run "$component: downloading runtime (timeout ${AICODING_VENDOR_TIMEOUT}s)" \
        _aicoding_progress_capture /dev/null timeout "$AICODING_VENDOR_TIMEOUT" npm install --prefix "$stage" --no-audit --no-fund \
        "$package@$target" </dev/null; then
    rm -rf "$stage"
    aicoding_result_record "$component" failed "$target" stage_install_failed
    return 1
  fi
  rm -rf "$stage/home" "$stage/.npm-cache"
  local staged_bin="$stage/node_modules/.bin/$command_name"
  actual=$(_aicoding_version_from_command "$staged_bin") || true
  if [ "$actual" != "$target" ]; then
    rm -rf "$stage"
    aicoding_result_record "$component" failed "$target" staged_version_mismatch
    return 1
  fi
  if [ "$component" = codex ] && ! find "$stage/node_modules" -type f -name codex-code-mode-host -perm -u+x -print -quit 2>/dev/null | grep -q .; then
    rm -rf "$stage"
    aicoding_result_record "$component" failed "$target" codex_sidecar_missing
    return 1
  fi
  if [ ! -d "$final" ]; then
    mv "$stage" "$final" || return 1
  else
    rm -rf "$stage"
    actual=$(_aicoding_version_from_command "$final/node_modules/.bin/$command_name") || true
    if [ "$actual" != "$target" ] \
        || { [ "$component" = codex ] && ! find "$final/node_modules" -type f -name codex-code-mode-host -perm -u+x -print -quit 2>/dev/null | grep -q .; }; then
      aicoding_result_record "$component" failed "$target" existing_release_invalid
      return 1
    fi
  fi
  if ! _aicoding_activate_vendor_release "$component" "$target" "$command_name" "node_modules/.bin/$command_name"; then
    aicoding_result_record "$component" failed "$target" activation_failed
    return 1
  fi
  aicoding_result_record "$component" updated "$target" installed "$target"
}

# Resolve only the browser cache bound to the selected Playwright MCP package.
# Other package versions keep their own cache and are never removed.
_aicoding_playwright_browser_bin() {
  local version=$1 root bin marker
  root="$AICODING_DATA_DIR/browser-cache/mcp-playwright/$version"
  marker=$(cat "$root/.browser-bin" 2>/dev/null || true)
  case "$marker" in "$root"/*) [ -x "$marker" ] && { printf '%s\n' "$marker"; return 0; } ;; esac
  while IFS= read -r bin; do
    [ -x "$bin" ] && { printf '%s\n' "$bin"; return 0; }
  done < <(find "$root" -type f \( -name chrome -o -name headless_shell \) -perm -u+x 2>/dev/null | sort)
  return 1
}

_aicoding_playwright_missing_libs() {
  local bin=$1 out
  command -v ldd >/dev/null 2>&1 || return 0
  out=$(ldd "$bin" 2>/dev/null) || return 2
  printf '%s\n' "$out" | awk '/not found/ {print $1}' | sort -u
}

_aicoding_prepare_playwright_browser() {
  local component=$1 version=$2 release=$3
  local cache="$AICODING_DATA_DIR/browser-cache/mcp-playwright/$version"
  local cli="$release/node_modules/@playwright/mcp/cli.js"
  local core_cli="$release/node_modules/playwright-core/cli.js" bin missing="" rc=0 node_path
  local runtime_home="$AICODING_STATE_DIR/playwright-stage/$version"
  if ! rm -rf "$runtime_home"; then
    aicoding_result_record "$component" failed "$version" browser_stage_cleanup_failed
    return 1
  fi
  mkdir -p "$cache" "$runtime_home" \
    || { aicoding_result_record "$component" failed "$version" browser_stage_prepare_failed; return 1; }
  HOME="$runtime_home" XDG_CONFIG_HOME="$runtime_home/.config" \
    XDG_DATA_HOME="$runtime_home/.local/share" XDG_CACHE_HOME="$runtime_home/.cache" \
    PLAYWRIGHT_BROWSERS_PATH="$cache" timeout "$AICODING_VENDOR_TIMEOUT" \
      "$cli" install-browser --no-remove chromium </dev/null >/dev/null 2>&1 \
    || { rm -rf "$runtime_home"; aicoding_result_record "$component" failed "$version" browser_install_failed; return 1; }
  if ! rm -rf "$runtime_home"; then
    aicoding_result_record "$component" failed "$version" browser_stage_cleanup_failed
    return 1
  fi
  bin=$(_aicoding_playwright_browser_bin "$version") \
    || { aicoding_result_record "$component" failed "$version" browser_validation_failed; return 1; }
  missing=$(_aicoding_playwright_missing_libs "$bin") || rc=$?
  [ "$rc" -eq 0 ] || { aicoding_result_record "$component" failed "$version" browser_validation_failed; return 1; }
  if [ -n "$missing" ]; then
    node_path=$(command -v node 2>/dev/null) || true
    if [ -x "$core_cli" ] && [ -n "$node_path" ]; then
      if [ "$(id -u)" -eq 0 ]; then
        PLAYWRIGHT_BROWSERS_PATH="$cache" timeout "$AICODING_VENDOR_TIMEOUT" \
          "$node_path" "$core_cli" install-deps chromium </dev/null >/dev/null 2>&1 || true
      elif command -v sudo >/dev/null 2>&1 \
          && timeout "${AICODING_PROBE_TIMEOUT:-15}" sudo -n true </dev/null >/dev/null 2>&1; then
        timeout "$AICODING_VENDOR_TIMEOUT" sudo -n env PLAYWRIGHT_BROWSERS_PATH="$cache" \
          "$node_path" "$core_cli" install-deps chromium </dev/null >/dev/null 2>&1 || true
      fi
      missing=$(_aicoding_playwright_missing_libs "$bin") || rc=$?
    fi
  fi
  if [ "$rc" -ne 0 ] || [ -n "$missing" ]; then
    local reason=playwright_system_libs_unavailable
    declare -F _sync_profile >/dev/null 2>&1 && [ "$(_sync_profile)" = container ] \
      && reason=manual_rebuild_required_playwright_system_libs
    _aicoding_record_deferred "$component" blocked "$version" "$reason"
    return 1
  fi
  if ! printf '%s\n' "$bin" > "$cache/.browser-bin.tmp.$$" \
      || ! mv "$cache/.browser-bin.tmp.$$" "$cache/.browser-bin"; then
    rm -f "$cache/.browser-bin.tmp.$$"
    aicoding_result_record "$component" failed "$version" browser_marker_commit_failed
    return 1
  fi
}

_aicoding_entry_min_node() {
  case "$1" in
    mcp-firecrawl) printf '22.0.0\n' ;;
    mcp-brave|mcp-playwright) printf '20.0.0\n' ;;
    mcp-context7) printf '20.18.1\n' ;;
  esac
}

_aicoding_npm_lock_valid() {
  local lock=$1 package=$2 version=$3 key="node_modules/$2"
  jq -e --arg key "$key" --arg version "$version" '
    (.lockfileVersion | type == "number" and . >= 2)
    and (.packages[$key].version == $version)
    and (.packages[$key].integrity | type == "string" and startswith("sha"))
  ' "$lock" >/dev/null 2>&1
}

_aicoding_release_tree_digest() {
  aicoding_progress_run "${AICODING_PROGRESS_COMPONENT:-package}: checking release integrity" _aicoding_release_tree_digest_impl "$@"
}

_aicoding_release_tree_digest_impl() {
  local root=$1 inventory path relative mode kind value digest
  inventory=$(mktemp "${TMPDIR:-/tmp}/aicoding-release-integrity.XXXXXX") || return 1
  while IFS= read -r -d '' path; do
    relative=${path#"$root/"}
    [ "$relative" != .aicoding-release-integrity ] || continue
    mode=$(stat -c '%a' -- "$path" 2>/dev/null) || { rm -f "$inventory"; return 1; }
    if [ -L "$path" ]; then
      kind=link; value=$(readlink -- "$path") || { rm -f "$inventory"; return 1; }
    elif [ -f "$path" ]; then
      kind=file; value=$(sha256sum -- "$path" | awk '{print $1}') \
        || { rm -f "$inventory"; return 1; }
    elif [ -d "$path" ]; then
      kind=directory; value=
    else
      rm -f "$inventory"
      return 1
    fi
    printf '%s\0%s\0%s\0%s\0' "$relative" "$kind" "$mode" "$value" >>"$inventory" \
      || { rm -f "$inventory"; return 1; }
  done < <(find "$root" -mindepth 1 -print0 2>/dev/null | sort -z)
  digest=$(sha256sum "$inventory" | awk '{print $1}') || { rm -f "$inventory"; return 1; }
  rm -f "$inventory" || return 1
  printf '%s\n' "$digest"
}

_aicoding_release_integrity_write() {
  local root=$1 digest
  digest=$(_aicoding_release_tree_digest "$root") || return 1
  printf '%s\n' "$digest" >"$root/.aicoding-release-integrity"
}

_aicoding_release_integrity_valid() {
  local root=$1 recorded actual
  recorded=$(cat "$root/.aicoding-release-integrity" 2>/dev/null) || return 1
  [[ "$recorded" =~ ^[0-9a-f]{64}$ ]] || return 1
  actual=$(_aicoding_release_tree_digest "$root") || return 1
  [ "$actual" = "$recorded" ]
}

# tldjs 2.3.2 ships its public-suffix rules. Its audited postinstall only
# refreshes them when npm_config_tldjs_update_rules=true; it is unnecessary
# for runtime. Keep --ignore-scripts: this exception NEVER executes a hook.
# Pin registry provenance and the reviewed hook/data bytes; any package update
# or added lifecycle work requires a new audit, rather than a broad allowlist.
_aicoding_npm_optional_refresh_is_bundled() {
  local root=$1 key=$2 dir="$1/$2" hook_hash rules_hash
  case "$key" in node_modules/*) ;; *) return 1 ;; esac
  case "/$key/" in */../*|*/./*) return 1 ;; esac
  jq -e --arg key "$key" '.packages[$key]
    | .version == "2.3.2" and .link != true
      and .resolved == "https://registry.npmjs.org/tldjs/-/tldjs-2.3.2.tgz"
      and .integrity == "sha512-EORDwFMSZKrHPUVDhejCMDeAovRS5d8jZKiqALFiPp3cjKjEldPkxBY39ZSx3c45awz3RpKwJD1cCgGxEfy8/A=="' \
    "$root/package-lock.json" >/dev/null 2>&1 || return 1
  jq -e '.name == "tldjs" and .version == "2.3.2"
    and (.scripts.preinstall // "") == ""
    and (.scripts.install // "") == ""
    and .scripts.postinstall == "node ./bin/postinstall.js"' \
    "$dir/package.json" >/dev/null 2>&1 || return 1
  [ -f "$dir/bin/postinstall.js" ] && [ ! -L "$dir/bin/postinstall.js" ] \
    && [ -f "$dir/rules.json" ] && [ ! -L "$dir/rules.json" ] || return 1
  hook_hash=$(sha256sum "$dir/bin/postinstall.js") || return 1
  rules_hash=$(sha256sum "$dir/rules.json") || return 1
  [ "${hook_hash%% *}" = a967eff8a98099b264a5dd8b0c91289c064ba16fe9fe92ee0fb41c04e5734b38 ] \
    && [ "${rules_hash%% *}" = f8acee981e0a21eb83e4df023413247607b8f7af2d322a46ee4fc3877fbb68a1 ]
}

# npm was deliberately invoked with --ignore-scripts. Reject any resolved
# package whose required install lifecycle would therefore be skipped.
_aicoding_npm_tree_ignores_scripts_safely() {
  local root=$1 manifest manifests key install_keys rc=0
  install_keys=$(jq -er '.packages | to_entries
    | map(select(.value.hasInstallScript == true) | .key) | join("\n")' \
    "$root/package-lock.json") || return 1
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    _aicoding_npm_optional_refresh_is_bundled "$root" "$key" || return 1
  done <<< "$install_keys"
  # Finish enumeration before inspecting. Returning early from a process-
  # substitution reader gives find SIGPIPE and fires an inherited installer
  # ERR trap; it also used to hide genuine enumeration failures.
  manifests=$(mktemp) || return 2
  if ! find "$root/node_modules" -type f -name package.json -print0 >"$manifests" 2>/dev/null; then
    rm -f "$manifests"
    return 2
  fi
  while IFS= read -r -d '' manifest; do
    jq -e '(.scripts // {}) as $s
      | all(["preinstall","install","postinstall"][];
          ($s[.] // "") == "")' "$manifest" >/dev/null 2>&1 || {
      key=${manifest#"$root/"}; key=${key%/package.json}
      _aicoding_npm_optional_refresh_is_bundled "$root" "$key" || { rc=1; break; }
    }
    if ! jq -e '(.scripts // {}) as $s
      | all(["prepublish","preprepare","prepare","postprepare"][];
          ($s[.] // "") == "")' "$manifest" >/dev/null 2>&1; then
      # Publisher/local-source preparation does not run for a named registry
      # package. Require registry provenance before accepting its prebuilt
      # bytes; git/link/unknown sources may still need that preparation.
      key=${manifest#"$root/"}; key=${key%/package.json}
      jq -e --arg key "$key" '.packages[$key]
        | (.link != true)
          and (.resolved | type == "string" and startswith("https://registry.npmjs.org/"))
          and (.integrity | type == "string" and startswith("sha"))' \
        "$root/package-lock.json" >/dev/null 2>&1 || { rc=1; break; }
    fi
  done < "$manifests"
  rm -f "$manifests" || return 2
  return "$rc"
}

_aicoding_npm_entry_release_valid() {
  local root=$1 component=$2 command_name=$3 package=$4 version=$5
  local package_dir="$root/node_modules/$package" entry
  entry=$(jq -r --arg n "$command_name" \
    'if (.bin|type)=="string" then .bin else .bin[$n] // empty end' \
    "$package_dir/package.json" 2>/dev/null) || return 1
  case "$entry" in ''|/*|*'..'*) return 1 ;; esac
  jq -e --arg p "$package" --arg v "$version" '.name == $p and .version == $v' \
      "$package_dir/package.json" >/dev/null 2>&1 \
    && _aicoding_npm_lock_valid "$root/package-lock.json" "$package" "$version" \
    && _aicoding_npm_tree_ignores_scripts_safely "$root" \
    && [ -f "$package_dir/$entry" ] && [ ! -L "$package_dir/$entry" ] && [ -x "$package_dir/$entry" ] \
    && { [ "$component" != mcp-playwright ] || [ -x "$root/bin/playwright-mcp" ]; }
}

# Context7 and Playwright have safe version probes, while Firecrawl and Brave
# do not expose reliable version commands. Read retained package metadata for
# all exact MCP packages so validation follows one non-executing policy.
_aicoding_active_npm_entry_valid() {
  local component=$1 command_name=$2 package=$3 current version receipt browser missing rc=0
  current=$(readlink -f "$AICODING_DATA_DIR/current/$component" 2>/dev/null) || return 1
  case "$current" in "$AICODING_DATA_DIR/versions/$component/"*) ;; *) return 1 ;; esac
  version=${current##*/}
  receipt=$(jq -r --arg c "$component" '.components[$c].successful_version // empty' \
    "$AICODING_RESULTS_FILE" 2>/dev/null) || return 1
  [ "$receipt" = "$version" ] || return 1
  _aicoding_npm_entry_release_valid "$current" "$component" "$command_name" "$package" "$version" || return 1
  _aicoding_release_integrity_valid "$current" || return 1
  [ -x "$HOME/.local/bin/$command_name" ] || return 1
  if [ "$component" = mcp-playwright ]; then
    browser=$(_aicoding_playwright_browser_bin "$version") || return 1
    missing=$(_aicoding_playwright_missing_libs "$browser") || rc=$?
    [ "$rc" -eq 0 ] && [ -z "$missing" ] || return 1
  fi
}

_aicoding_missing_runtime_reason() {
  local runtime=$1
  if declare -F _sync_profile >/dev/null 2>&1 && [ "$(_sync_profile)" = container ]; then
    printf 'manual_rebuild_required_%s\n' "$runtime"
  else
    printf '%s_runtime_unavailable\n' "$runtime"
  fi
}

# MCP servers commonly do not support --version. Validate the exact installed
# package metadata and declared executable instead.
aicoding_update_npm_entry_component() {
  local component=$1 command_name=$2 package=$3 target stage final package_dir entry
  local minimum node_version relative_bin install_log failure_state failure_reason
  minimum=$(_aicoding_entry_min_node "$component")
  node_version=$(_aicoding_version_from_command node) || true
  if [ -n "$minimum" ] && ! _aicoding_version_at_least "$node_version" "$minimum"; then
    local node_reason=node_runtime_incompatible
    declare -F _sync_profile >/dev/null 2>&1 && [ "$(_sync_profile)" = container ] \
      && node_reason=$(_aicoding_missing_runtime_reason node)
    _aicoding_record_deferred "$component" blocked "" "$node_reason"
    return 1
  fi
  if ! command -v npm >/dev/null 2>&1; then
    _aicoding_record_deferred "$component" blocked "" "$(_aicoding_missing_runtime_reason npm)"
    return 1
  fi
  target=$(_aicoding_npm_target "$package") || true
  [[ "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] \
    || { aicoding_result_record "$component" failed "" target_version_unavailable; return 1; }
  final="$AICODING_DATA_DIR/versions/$component/$target"
  stage="$AICODING_DATA_DIR/versions/$component/.staging.$target.$$"
  package_dir="$stage/node_modules/$package"
  install_log="$stage/.npm-install.log"
  if ! rm -rf "$stage"; then
    aicoding_result_record "$component" failed "$target" stage_cleanup_failed
    return 1
  fi
  if ! mkdir -p "$(dirname "$stage")" "$stage"; then
    aicoding_result_record "$component" failed "$target" stage_prepare_failed
    return 1
  fi
  if ! printf '{"name":"aicoding-%s","private":true}\n' "$component" >"$stage/package.json"; then
    rm -rf "$stage"
    aicoding_result_record "$component" failed "$target" stage_metadata_write_failed
    return 1
  fi
  if ! HOME="$stage/home" XDG_CONFIG_HOME="$stage/home/.config" \
    XDG_DATA_HOME="$stage/home/.local/share" XDG_CACHE_HOME="$stage/home/.cache" \
    XDG_STATE_HOME="$stage/home/.local/state" NPM_CONFIG_CACHE="$stage/.npm-cache" \
    aicoding_progress_run "$component: downloading packages (timeout ${AICODING_VENDOR_TIMEOUT}s)" \
      _aicoding_progress_capture "$install_log" timeout "$AICODING_VENDOR_TIMEOUT" npm install --prefix "$stage" --ignore-scripts --omit=dev \
      --save-exact --engine-strict --no-audit --no-fund \
      "$package@$target" </dev/null; then
    failure_state=failed; failure_reason=stage_install_failed
    if grep -Eq 'EBADENGINE|Unsupported engine' "$install_log" 2>/dev/null; then
      failure_state=blocked; failure_reason=$(_aicoding_missing_runtime_reason node)
    fi
    rm -rf "$stage"
    aicoding_result_record "$component" "$failure_state" "$target" "$failure_reason"
    return 1
  fi
  rm -f "$install_log" \
    || { aicoding_result_record "$component" failed "$target" stage_cleanup_failed; return 1; }
  if ! rm -rf "$stage/home" "$stage/.npm-cache"; then
    aicoding_result_record "$component" failed "$target" stage_cleanup_failed
    return 1
  fi
  entry=$(jq -r --arg n "$command_name" 'if (.bin|type)=="string" then .bin else .bin[$n] // empty end' "$package_dir/package.json" 2>/dev/null)
  case "$entry" in ''|/*|*'..'*) rm -rf "$stage"; aicoding_result_record "$component" failed "$target" entrypoint_invalid; return 1 ;; esac
  local audit_rc=0
  _aicoding_npm_tree_ignores_scripts_safely "$stage" || audit_rc=$?
  if [ "$audit_rc" -ne 0 ]; then
    rm -rf "$stage" \
      || { aicoding_result_record "$component" failed "$target" stage_cleanup_failed; return 1; }
    if [ "$audit_rc" -eq 2 ]; then
      aicoding_result_record "$component" failed "$target" package_inventory_unavailable
    else
      _aicoding_record_deferred "$component" blocked "$target" lifecycle_scripts_required
    fi
    return 1
  fi
  jq -e --arg p "$package" --arg v "$target" '.name == $p and .version == $v' \
      "$package_dir/package.json" >/dev/null 2>&1 \
    && _aicoding_npm_lock_valid "$stage/package-lock.json" "$package" "$target" \
    && [ -f "$package_dir/$entry" ] && [ ! -L "$package_dir/$entry" ] && [ -x "$package_dir/$entry" ] \
    || { rm -rf "$stage"; aicoding_result_record "$component" failed "$target" staged_metadata_mismatch; return 1; }
  relative_bin="node_modules/$package/$entry"
  if [ "$component" = mcp-playwright ]; then
    mkdir -p "$stage/bin" \
      || { rm -rf "$stage"; aicoding_result_record "$component" failed "$target" wrapper_prepare_failed; return 1; }
    if ! {
      printf '#!/usr/bin/env bash\n'
      printf 'release=$(cd "$(dirname "$0")/.." && pwd -P) || exit 1\n'
      printf 'export PLAYWRIGHT_BROWSERS_PATH=%q\n' "$AICODING_DATA_DIR/browser-cache/mcp-playwright/$target"
      printf 'exec "$release/node_modules/@playwright/mcp/cli.js" "$@"\n'
    } > "$stage/bin/playwright-mcp"; then
      rm -rf "$stage"
      aicoding_result_record "$component" failed "$target" wrapper_write_failed
      return 1
    fi
    chmod 0755 "$stage/bin/playwright-mcp" \
      || { rm -rf "$stage"; aicoding_result_record "$component" failed "$target" wrapper_chmod_failed; return 1; }
    relative_bin=bin/playwright-mcp
  fi
  if ! _aicoding_release_integrity_write "$stage"; then
    rm -rf "$stage"
    aicoding_result_record "$component" failed "$target" stage_integrity_write_failed
    return 1
  fi
  if [ -d "$final" ]; then
    # Keep the first validated lock for this exact top-level version. A later
    # npm resolution may select different transitive bytes without any change
    # to the requested version; it must not replace or discredit the retained
    # immutable tree. Its own integrity receipt detects actual local changes.
    if ! _aicoding_npm_entry_release_valid "$final" "$component" "$command_name" "$package" "$target" \
        || ! _aicoding_release_integrity_valid "$final"; then
      rm -rf "$stage"
      aicoding_result_record "$component" failed "$target" existing_release_invalid
      return 1
    fi
    rm -rf "$stage" \
      || { aicoding_result_record "$component" failed "$target" stage_cleanup_failed; return 1; }
  else
    if ! mv "$stage" "$final"; then
      rm -rf "$stage"
      aicoding_result_record "$component" failed "$target" release_commit_failed
      return 1
    fi
    _aicoding_npm_entry_release_valid "$final" "$component" "$command_name" "$package" "$target" \
      && _aicoding_release_integrity_valid "$final" \
      || { aicoding_result_record "$component" failed "$target" committed_release_invalid; return 1; }
  fi
  [ "$component" != mcp-playwright ] \
    || _aicoding_prepare_playwright_browser "$component" "$target" "$final" || return 1
  _aicoding_activate_vendor_release "$component" "$target" "$command_name" "$relative_bin" \
    || { aicoding_result_record "$component" failed "$target" activation_failed; return 1; }
  # Activation is a complete package success even if a harness-specific
  # registration migration below is blocked by a user conflict or shared
  # consumer evidence. Keep its receipt truthful and independently usable.
  aicoding_result_record "$component" updated "$target" installed "$target" || return 1
  case "$component" in
    mcp-context7)
      _aicoding_reconcile_claude_mcp_registration context7 "$component" "$target" context7-mcp \
        || return 1 ;;
    mcp-playwright)
      _aicoding_reconcile_claude_mcp_registration playwright "$component" "$target" playwright-mcp --browser chromium \
        || return 1 ;;
  esac
}

# Anthropic's native installer accepts an exact version argument. Download the
# installer, run it with an isolated HOME, validate the staged binary, then
# copy only that binary into the immutable managed release.
aicoding_update_claude() {
  local installed target stage staged_home staged_bin final actual installer
  installed=$(_aicoding_version_from_command claude) || true
  target=$(_aicoding_npm_target @anthropic-ai/claude-code) || true
  if [[ ! "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
    aicoding_result_record claude failed "" target_version_unavailable
    return 1
  fi
  if [ "$installed" = "$target" ]; then
    aicoding_result_record claude current "$target" current "$installed"
    return 0
  fi
  stage="$AICODING_DATA_DIR/versions/claude/.staging.$target.$$"
  staged_home="$stage/home"
  installer="$stage/install.sh"
  final="$AICODING_DATA_DIR/versions/claude/$target"
  rm -rf "$stage"; mkdir -p "$stage"
  if ! timeout "$AICODING_VENDOR_TIMEOUT" curl -fsSL --max-time 30 https://claude.ai/install.sh >"$installer"; then
    rm -rf "$stage"; aicoding_result_record claude failed "$target" installer_download_failed; return 1
  fi
  if ! HOME="$staged_home" CLAUDE_CONFIG_DIR="$staged_home/.claude" \
      XDG_CONFIG_HOME="$staged_home/.config" XDG_DATA_HOME="$staged_home/.local/share" \
      XDG_CACHE_HOME="$staged_home/.cache" XDG_STATE_HOME="$staged_home/.local/state" \
      timeout "$AICODING_VENDOR_TIMEOUT" bash "$installer" "$target" </dev/null >/dev/null 2>&1; then
    rm -rf "$stage"; aicoding_result_record claude failed "$target" stage_install_failed; return 1
  fi
  staged_bin="$staged_home/.local/share/claude/versions/$target"
  [ -x "$staged_bin" ] || staged_bin="$staged_home/.local/bin/claude"
  actual=$(HOME="$staged_home" CLAUDE_CONFIG_DIR="$staged_home/.claude" \
    XDG_CONFIG_HOME="$staged_home/.config" XDG_DATA_HOME="$staged_home/.local/share" \
    XDG_CACHE_HOME="$staged_home/.cache" XDG_STATE_HOME="$staged_home/.local/state" \
    _aicoding_version_from_command "$staged_bin") || true
  if [ "$actual" != "$target" ]; then
    rm -rf "$stage"; aicoding_result_record claude failed "$target" staged_version_mismatch; return 1
  fi
  mkdir -p "$stage/release/bin"
  cp "$staged_bin" "$stage/release/bin/claude" && chmod +x "$stage/release/bin/claude" || {
    rm -rf "$stage"; aicoding_result_record claude failed "$target" stage_copy_failed; return 1;
  }
  if [ ! -d "$final" ]; then mv "$stage/release" "$final" || return 1; fi
  rm -rf "$stage"
  actual=$(_aicoding_version_from_command "$final/bin/claude") || true
  if [ "$actual" != "$target" ]; then
    aicoding_result_record claude failed "$target" existing_release_invalid; return 1
  fi
  if ! _aicoding_activate_vendor_release claude "$target" claude bin/claude; then
    aicoding_result_record claude failed "$target" activation_failed; return 1
  fi
  aicoding_result_record claude updated "$target" installed "$target"
}

aicoding_update_dvw() {
  local sha final adapter_rc=0
  sha=$(aicoding_select_ci_sha dvw) || { _aicoding_record_deferred dvw blocked "" ci_selection_unavailable; return 1; }
  final="$AICODING_DATA_DIR/sources/dvw/$sha"
  _aicoding_stage_git_source "${AICODING_DVW_REMOTE:-https://github.com/vossiman/dvw}" "$sha" "$final" \
    || { aicoding_result_record dvw failed "$sha" source_stage_failed; return 1; }
  if [ -f "$final/lib/managed-install.sh" ]; then
    timeout "$AICODING_VENDOR_TIMEOUT" bash -c '
      . "$1"
      declare -F dvw_managed_install >/dev/null 2>&1 || exit 127
      dvw_managed_install "$2" "$3"
    ' _ "$final/lib/managed-install.sh" "$final" "$sha" </dev/null || adapter_rc=$?
  elif [ -x "$final/dvw-install.sh" ]; then
    timeout "$AICODING_VENDOR_TIMEOUT" "$final/dvw-install.sh" \
      --unattended --source "$final" --version "$sha" </dev/null || adapter_rc=$?
  else
    _aicoding_record_deferred dvw blocked "$sha" managed_adapter_unavailable; return 1
  fi
  [ "$adapter_rc" -eq 0 ] \
    || { aicoding_result_record dvw failed "$sha" managed_install_failed; return 1; }
  aicoding_result_record dvw updated "$sha" installed "$sha"
}

aicoding_update_bw() {
  local sha source final stage script
  sha=$(aicoding_select_ci_sha bw-AICode) || { _aicoding_record_deferred bw-AICode blocked "" ci_selection_unavailable; return 1; }
  source="$AICODING_DATA_DIR/sources/bw-AICode/$sha"
  final="$AICODING_DATA_DIR/versions/bw-AICode/$sha"
  _aicoding_stage_git_source "${AICODING_BW_REMOTE:-https://github.com/vossiman/bw-AICode}" "$sha" "$source" \
    || { aicoding_result_record bw-AICode failed "$sha" source_stage_failed; return 1; }
  for script in claude-bw.sh opencode-bw.sh pi-bw.sh; do
    [ -x "$source/$script" ] && bash -n "$source/$script" || { aicoding_result_record bw-AICode failed "$sha" staged_validation_failed; return 1; }
  done
  if [ -d "$final" ]; then
    [ "$(cat "$final/.aicoding-version" 2>/dev/null)" = "$sha" ] \
      && [ -x "$final/bin/bw-docker-guard" ] \
      || { aicoding_result_record bw-AICode failed "$sha" existing_release_invalid; return 1; }
    for script in claude-bw.sh opencode-bw.sh pi-bw.sh; do
      [ -x "$final/$script" ] && bash -n "$final/$script" \
        || { aicoding_result_record bw-AICode failed "$sha" existing_release_invalid; return 1; }
    done
  else
    command -v go >/dev/null 2>&1 \
      || { _aicoding_record_deferred bw-AICode blocked "$sha" "$(_aicoding_missing_runtime_reason go)"; return 1; }
    (cd "$source" && timeout "$AICODING_VENDOR_TIMEOUT" go test ./... </dev/null >/dev/null 2>&1) \
      || { aicoding_result_record bw-AICode failed "$sha" tests_failed; return 1; }
    stage="$AICODING_DATA_DIR/versions/bw-AICode/.staging.$sha.$$"
    rm -rf "$stage"; mkdir -p "$stage/bin" || return 1
    cp -a "$source/claude-bw.sh" "$source/opencode-bw.sh" "$source/pi-bw.sh" \
      "$source/.aicoding-version" "$stage/" \
      || { rm -rf "$stage"; aicoding_result_record bw-AICode failed "$sha" stage_copy_failed; return 1; }
    (cd "$source" && timeout "$AICODING_VENDOR_TIMEOUT" go build -o "$stage/bin/bw-docker-guard" ./cmd/bw-docker-guard </dev/null) \
      || { rm -rf "$stage"; aicoding_result_record bw-AICode failed "$sha" build_failed; return 1; }
    [ -x "$stage/bin/bw-docker-guard" ] \
      || { rm -rf "$stage"; aicoding_result_record bw-AICode failed "$sha" staged_validation_failed; return 1; }
    mkdir -p "$(dirname "$final")" && mv "$stage" "$final" \
      || { rm -rf "$stage"; aicoding_result_record bw-AICode failed "$sha" activation_stage_failed; return 1; }
  fi
  _aicoding_activate_vendor_release bw-AICode "$sha" \
      claude-bw claude-bw.sh opencode-bw opencode-bw.sh pi-bw pi-bw.sh \
      bw-docker-guard bin/bw-docker-guard \
    || { aicoding_result_record bw-AICode failed "$sha" activation_failed; return 1; }
  aicoding_result_record bw-AICode updated "$sha" installed "$sha"
}

aicoding_update_component() {
  local AICODING_PROGRESS_COMPONENT=$1 component_rc=0 started=$SECONDS
  printf 'INFO: Updating %s\n' "$1" >&2
  _aicoding_update_component_impl "$@" || component_rc=$?
  printf 'INFO: %s update attempt finished (%ss, exit %s)\n' "$1" "$((SECONDS - started))" "$component_rc" >&2
  return "$component_rc"
}

_aicoding_update_component_impl() {
  case "$1" in
    codex) aicoding_update_npm_component codex codex @openai/codex ;;
    opencode) aicoding_update_npm_component opencode opencode opencode-ai ;;
    pi) aicoding_update_npm_component pi pi @mariozechner/pi-coding-agent ;;
    claude) aicoding_update_claude ;;
    cursor)
      . "${BASH_SOURCE[0]%/*}/update-cursor.sh"
      aicoding_update_cursor
      ;;
    dvw) aicoding_update_dvw ;;
    bw-AICode) aicoding_update_bw ;;
    mcp-firecrawl) aicoding_update_npm_entry_component mcp-firecrawl firecrawl-mcp firecrawl-mcp ;;
    mcp-brave) aicoding_update_npm_entry_component mcp-brave brave-search-mcp-server @brave/brave-search-mcp-server ;;
    mcp-context7) aicoding_update_npm_entry_component mcp-context7 context7-mcp @upstash/context7-mcp ;;
    mcp-playwright) aicoding_update_npm_entry_component mcp-playwright playwright-mcp @playwright/mcp ;;
    *) return 0 ;;
  esac
}

# A component adapter returns nonzero for both a genuine failed attempt and a
# conservative block. Classify the receipt it just wrote so callers can retry
# failures promptly while treating unavailable capabilities and preserved user
# conflicts as completed deferrals. Exact MCP registration has its own receipt
# and therefore participates in the same disposition as its package update.
_aicoding_component_attempt_deferred() {
  local component=$1
  [ "${AICODING_COMPONENT_ATTEMPT_DISPOSITION:-}" = deferred ] || return 1
  [ -f "$AICODING_RESULTS_FILE" ] || return 1
  jq -e --arg c "$component" '
    ([.components[$c].state]
      + (if $c == "mcp-context7" then [.components["mcp-registration-claude-context7"].state]
         elif $c == "mcp-playwright" then [.components["mcp-registration-claude-playwright"].state]
         else [] end)) as $states
    | any($states[]; . == "blocked" or . == "conflict")
      and (all($states[]; . != "failed"))
  ' "$AICODING_RESULTS_FILE" >/dev/null 2>&1
}

aicoding_update_installed_components() {
  [ "${AICODINGSETUP_SKIP_NETWORK:-}" != 1 ] || return 0
  local component component_rc rc=0
  # The scheduled aggregate may migrate exact MCP registrations after package
  # activation. Require the independently verified Claude update receipt for
  # those mutations; direct legacy component calls retain their existing API.
  local AICODING_REQUIRE_UPDATE_RECEIPT=1
  AICODING_UPDATE_DEFERRED=0
  while IFS= read -r component; do
    case "$component" in ''|aicoding) continue ;; esac
    component_rc=0
    AICODING_COMPONENT_ATTEMPT_DISPOSITION=
    aicoding_update_component "$component" || component_rc=$?
    if [ "$component_rc" -ne 0 ]; then
      if _aicoding_component_attempt_deferred "$component"; then
        AICODING_UPDATE_DEFERRED=1
      else
        rc=1
      fi
    fi
  done < <(aicoding_installed_components)
  return "$rc"
}
