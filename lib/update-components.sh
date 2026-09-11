# Installed-component discovery and safe staged vendor adapters. Sourced only.

: "${AICODING_STATE_DIR:=$HOME/.local/state/aicoding}"
: "${AICODING_DATA_DIR:=$HOME/.local/share/aicoding}"
: "${AICODING_VENDOR_TIMEOUT:=600}"

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
  printf 'aicoding\n'
  _aicoding_command_is_linux claude && printf 'claude\n'
  _aicoding_command_is_linux codex && printf 'codex\n'
  _aicoding_command_is_linux opencode && printf 'opencode\n'
  if _aicoding_command_is_linux agent || _aicoding_command_is_linux cursor-agent; then printf 'cursor\n'; fi
  _aicoding_command_is_linux pi && printf 'pi\n'
  _aicoding_command_is_linux dvw && printf 'dvw\n'
  _aicoding_command_is_linux firecrawl-mcp && printf 'mcp-firecrawl\n'
  _aicoding_command_is_linux brave-search-mcp-server && printf 'mcp-brave\n'
  if _aicoding_command_is_linux bw || _aicoding_command_is_linux claude-bw \
      || [ -d "${AICODING_VENDOR_DIR:-$AICODING_DATA_DIR/vendor}/bw-AICode/.git" ]; then
    printf 'bw-AICode\n'
  fi
}

_aicoding_version_from_command() {
  timeout "${AICODING_PROBE_TIMEOUT:-15}" "$1" --version </dev/null 2>/dev/null \
    | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?' | head -1
}

_aicoding_npm_target() {
  timeout "$AICODING_VENDOR_TIMEOUT" npm view "$1" version --json </dev/null 2>/dev/null \
    | jq -r 'if type == "array" then last else . end // empty' 2>/dev/null
}

_aicoding_version_at_least() {
  local actual=$1 required=$2
  [ -n "$actual" ] && [ "$(printf '%s\n%s\n' "$required" "$actual" | sort -V | head -1)" = "$required" ]
}

# Print a short result reason and return nonzero when an actionable managed
# config depends on a tool capability that is not installed and verified.
aicoding_config_is_compatible() {
  local dest=$1 command_name version
  case "$dest" in
    "$HOME/.codex/config.toml")
      _aicoding_exact_mcp_config_allows \
        || { echo mcp_exact_version_staging_unavailable; return 1; }
      _aicoding_update_receipt_allows codex || { echo codex_update_not_verified; return 1; }
      _aicoding_shared_consumers_allow codex 0.148.0 "$HOME/.codex" || { echo codex_shared_consumers_incompatible; return 1; }
      _aicoding_command_is_linux codex || { echo codex_not_installed; return 1; }
      version=$(_aicoding_version_from_command codex) || true
      _aicoding_version_at_least "$version" 0.148.0 || { echo codex_requires_0.148; return 1; }
      ;;
    "$HOME/.config/opencode/opencode.json")
      _aicoding_exact_mcp_config_allows \
        || { echo mcp_exact_version_staging_unavailable; return 1; }
      _aicoding_update_receipt_allows opencode || { echo opencode_update_not_verified; return 1; }
      _aicoding_shared_consumers_allow opencode "" "$HOME/.config/opencode" || { echo opencode_shared_consumers_incompatible; return 1; }
      _aicoding_command_is_linux opencode || { echo opencode_not_installed; return 1; }
      timeout "${AICODING_PROBE_TIMEOUT:-15}" opencode debug config </dev/null >/dev/null 2>&1 \
        || { echo opencode_config_probe_failed; return 1; }
      ;;
    "$HOME/.cursor/mcp.json"|"$HOME/.cursor/cli-config.json"|"$HOME/.cursor/hooks.json")
      _aicoding_exact_mcp_config_allows \
        || { echo mcp_exact_version_staging_unavailable; return 1; }
      _aicoding_update_receipt_allows cursor || { echo cursor_update_not_verified; return 1; }
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
      _aicoding_exact_mcp_config_allows \
        || { echo mcp_exact_version_staging_unavailable; return 1; }
      _aicoding_update_receipt_allows claude || { echo claude_update_not_verified; return 1; }
      _aicoding_shared_consumers_allow claude "" "$HOME/.claude" || { echo claude_shared_consumers_incompatible; return 1; }
      _aicoding_command_is_linux claude || { echo claude_not_installed; return 1; }
      timeout "${AICODING_PROBE_TIMEOUT:-15}" claude --version </dev/null >/dev/null 2>&1 \
        || { echo claude_config_probe_failed; return 1; }
      ;;
  esac
  return 0
}

_aicoding_exact_mcp_config_allows() {
  [ "${AICODING_REQUIRE_UPDATE_RECEIPT:-0}" != 1 ] \
    || [ "${AICODING_EXACT_MCP_CONFIG_READY:-0}" = 1 ]
}

# Print the canonical root only when a destination belongs to a configured or
# directly mounted shared config root. A directory merely living under HOME is
# local. OpenCode's shared runtime root does not make ~/.config/opencode shared.
# C may supply colon-separated canonical roots with AICODING_SHARED_CONFIG_ROOTS.
aicoding_config_shared_root() {
  local dest=$1 candidate="" physical mount_target
  local -a configured=()
  case "$dest" in
    "$HOME/.claude"|"$HOME/.claude/"*) candidate="$HOME/.claude" ;;
    "$HOME/.codex"|"$HOME/.codex/"*) candidate="$HOME/.codex" ;;
    "$HOME/.cursor"|"$HOME/.cursor/"*) candidate="$HOME/.cursor" ;;
    "$HOME/.local/share/opencode"|"$HOME/.local/share/opencode/"*)
      candidate="$HOME/.local/share/opencode" ;;
    *) return 1 ;;
  esac
  physical=$(readlink -f "$candidate" 2>/dev/null) || return 1
  IFS=: read -ra configured <<< "${AICODING_SHARED_CONFIG_ROOTS:-}"
  local root
  for root in "${configured[@]}"; do
    [ -n "$root" ] || continue
    [ "$(readlink -f "$root" 2>/dev/null)" = "$physical" ] && { printf '%s\n' "$physical"; return 0; }
  done
  command -v findmnt >/dev/null 2>&1 || return 1
  mount_target=$(findmnt -T "$physical" -n -o TARGET 2>/dev/null) || return 1
  [ "$(readlink -f "$mount_target" 2>/dev/null)" = "$physical" ] || return 1
  printf '%s\n' "$physical"
}

aicoding_config_is_shared() { aicoding_config_shared_root "$1" >/dev/null; }

# A scheduler may publish non-secret consumer capability evidence in the
# shared aicodingsetup mount. Until every known consumer opts in, changing
# version-dependent shared settings is unsafe and remains deferred.
_aicoding_shared_consumers_allow() {
  local component=$1 minimum=${2:-} destination=${3:-} registry shared_root
  registry=${AICODING_SHARED_CONSUMERS_FILE:-$HOME/.aicodingsetup/consumer-versions.json}
  [ "${AICODING_REQUIRE_SHARED_COMPATIBILITY:-0}" != 1 ] && return 0
  shared_root=$(aicoding_config_shared_root "$destination") || return 0
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

_aicoding_activate_vendor_release() {
  local component=$1 version=$2; shift 2
  [ "$#" -ge 2 ] && [ $(( $# % 2 )) -eq 0 ] || return 2
  local current_root="$AICODING_DATA_DIR/current" previous_root="$AICODING_DATA_DIR/previous"
  local release="$AICODING_DATA_DIR/versions/$component/$version"
  mkdir -p "$current_root" "$previous_root" "$HOME/.local/bin" || return 1
  [ ! -e "$current_root/$component" ] || [ -L "$current_root/$component" ] || return 1

  local transaction="$HOME/.local/bin/.aicoding-activate-${component}.$$"
  rm -rf "$transaction"; mkdir -m 0700 "$transaction" || return 1
  local -a launchers=() existed=() backups=()
  local launcher relative_bin dest backup i=0
  while [ "$#" -gt 0 ]; do
    launcher=$1; relative_bin=$2; shift 2
    [ -x "$release/$relative_bin" ] || { rm -rf "$transaction"; return 1; }
    launchers+=("$launcher"); existed+=(0); backups+=("")
    dest="$HOME/.local/bin/$launcher"; backup="$dest.pre-aicoding"
    cat >"$transaction/new.$i" <<EOF
#!/usr/bin/env bash
# Managed by aicoding staged updater.
release=\$(readlink -f "$AICODING_DATA_DIR/current/$component") || exit 1
exec "\$release/$relative_bin" "\$@"
EOF
    chmod 0755 "$transaction/new.$i" || { rm -rf "$transaction"; return 1; }
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      existed[$i]=1
      cp -a --no-dereference "$dest" "$transaction/old.$i" \
        || { rm -rf "$transaction"; return 1; }
      if ! grep -qF 'Managed by aicoding staged updater.' "$dest" 2>/dev/null; then
        backups[$i]="$backup"
        if [ -e "$backup" ] || [ -L "$backup" ]; then rm -rf "$transaction"; return 1; fi
        cp -a --no-dereference "$dest" "$backup" \
          || { rm -rf "$transaction"; return 1; }
      fi
    fi
    i=$((i + 1))
  done

  local tmp_link="$current_root/.${component}.new.$$" old="" failure=0
  [ -L "$current_root/$component" ] && old=$(readlink "$current_root/$component")
  ln -s "../versions/$component/$version" "$tmp_link" || failure=1
  if [ "$failure" -eq 0 ]; then
    mv -Tf "$tmp_link" "$current_root/$component" || failure=$?
  fi
  if [ "$failure" -eq 0 ]; then
    for ((i=0; i<${#launchers[@]}; i++)); do
      dest="$HOME/.local/bin/${launchers[$i]}"
      mv -Tf "$transaction/new.$i" "$dest" || { failure=$?; break; }
    done
  fi
  if [ "$failure" -eq 0 ] && [ -n "$old" ]; then
    local previous_tmp="$previous_root/.${component}.new.$$"
    ln -s "$old" "$previous_tmp" && mv -Tf "$previous_tmp" "$previous_root/$component" \
      || failure=$?
  fi

  if [ "$failure" -ne 0 ]; then
    rm -f "$tmp_link"
    for ((i=0; i<${#launchers[@]}; i++)); do
      dest="$HOME/.local/bin/${launchers[$i]}"
      rm -f "$dest"
      [ "${existed[$i]}" -eq 0 ] \
        || cp -a --no-dereference "$transaction/old.$i" "$dest" 2>/dev/null || true
      [ -z "${backups[$i]}" ] || rm -f "${backups[$i]}"
    done
    rm -f "$current_root/$component"
    [ -z "$old" ] || ln -s "$old" "$current_root/$component" || true
    rm -rf "$transaction"
    return "$failure"
  fi
  rm -rf "$transaction"
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
    if [ "$component" != codex ] || {
      local active_codex
      active_codex=$(readlink -f "$(command -v codex)" 2>/dev/null || true)
      [ -x "$(dirname "$active_codex")/codex-code-mode-host" ]
    }; then
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
      timeout "$AICODING_VENDOR_TIMEOUT" npm install --prefix "$stage" --no-audit --no-fund \
        "$package@$target" </dev/null >/dev/null 2>&1; then
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

# MCP servers commonly do not support --version. Validate the exact installed
# package metadata and declared executable instead.
aicoding_update_npm_entry_component() {
  local component=$1 command_name=$2 package=$3 target stage final package_dir actual entry
  target=$(_aicoding_npm_target "$package") || true
  [[ "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] \
    || { aicoding_result_record "$component" failed "" target_version_unavailable; return 1; }
  final="$AICODING_DATA_DIR/versions/$component/$target"
  stage="$AICODING_DATA_DIR/versions/$component/.staging.$target.$$"
  package_dir="$stage/node_modules/$package"
  rm -rf "$stage"; mkdir -p "$(dirname "$stage")"
  HOME="$stage/home" XDG_CONFIG_HOME="$stage/home/.config" \
    XDG_DATA_HOME="$stage/home/.local/share" XDG_CACHE_HOME="$stage/home/.cache" \
    XDG_STATE_HOME="$stage/home/.local/state" NPM_CONFIG_CACHE="$stage/.npm-cache" \
    timeout "$AICODING_VENDOR_TIMEOUT" npm install --prefix "$stage" --ignore-scripts --no-audit --no-fund \
      "$package@$target" </dev/null >/dev/null 2>&1 \
    || { rm -rf "$stage"; aicoding_result_record "$component" failed "$target" stage_install_failed; return 1; }
  rm -rf "$stage/home" "$stage/.npm-cache"
  actual=$(jq -r '.version // empty' "$package_dir/package.json" 2>/dev/null)
  entry=$(jq -r --arg n "$command_name" 'if (.bin|type)=="string" then .bin else .bin[$n] // empty end' "$package_dir/package.json" 2>/dev/null)
  case "$entry" in ''|/*|*'..'*) rm -rf "$stage"; aicoding_result_record "$component" failed "$target" entrypoint_invalid; return 1 ;; esac
  [ "$actual" = "$target" ] && [ -x "$package_dir/$entry" ] \
    || { rm -rf "$stage"; aicoding_result_record "$component" failed "$target" staged_metadata_mismatch; return 1; }
  if [ -d "$final" ]; then
    rm -rf "$stage"
    package_dir="$final/node_modules/$package"
    [ "$(jq -r '.version // empty' "$package_dir/package.json" 2>/dev/null)" = "$target" ] \
      && [ -x "$package_dir/$entry" ] \
      || { aicoding_result_record "$component" failed "$target" existing_release_invalid; return 1; }
  else
    mv "$stage" "$final" || return 1
  fi
  _aicoding_activate_vendor_release "$component" "$target" "$command_name" "node_modules/$package/$entry" \
    || { aicoding_result_record "$component" failed "$target" activation_failed; return 1; }
  aicoding_result_record "$component" updated "$target" installed "$target"
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
  sha=$(aicoding_select_ci_sha dvw) || { aicoding_result_record dvw blocked "" ci_selection_unavailable; return 1; }
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
    aicoding_result_record dvw blocked "$sha" managed_adapter_unavailable; return 1
  fi
  [ "$adapter_rc" -eq 0 ] \
    || { aicoding_result_record dvw failed "$sha" managed_install_failed; return 1; }
  aicoding_result_record dvw updated "$sha" installed "$sha"
}

aicoding_update_bw() {
  local sha source final stage script
  sha=$(aicoding_select_ci_sha bw-AICode) || { aicoding_result_record bw-AICode blocked "" ci_selection_unavailable; return 1; }
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
    command -v go >/dev/null 2>&1 || { aicoding_result_record bw-AICode blocked "$sha" go_unavailable; return 1; }
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
  case "$1" in
    codex) aicoding_update_npm_component codex codex @openai/codex ;;
    opencode) aicoding_update_npm_component opencode opencode opencode-ai ;;
    pi) aicoding_update_npm_component pi pi @mariozechner/pi-coding-agent ;;
    claude) aicoding_update_claude ;;
    cursor)
      aicoding_result_record cursor blocked "" versioned_staging_unavailable
      return 1
      ;;
    dvw) aicoding_update_dvw ;;
    bw-AICode) aicoding_update_bw ;;
    mcp-firecrawl) aicoding_update_npm_entry_component mcp-firecrawl firecrawl-mcp firecrawl-mcp ;;
    mcp-brave) aicoding_update_npm_entry_component mcp-brave brave-search-mcp-server @brave/brave-search-mcp-server ;;
    *) return 0 ;;
  esac
}

aicoding_update_installed_components() {
  [ "${AICODINGSETUP_SKIP_NETWORK:-}" != 1 ] || return 0
  local component rc=0
  while IFS= read -r component; do
    case "$component" in ''|aicoding) continue ;; esac
    aicoding_update_component "$component" || rc=1
  done < <(aicoding_installed_components)
  return "$rc"
}
