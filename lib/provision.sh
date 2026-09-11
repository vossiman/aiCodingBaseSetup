# lib/provision.sh — machine-state provisioning shared by install.sh and
# aicoding-sync: MCP server registration, marketplace plugins, and the npm
# packages backing stdio MCPs. Interactive installs remain fail-open; sync
# aggregates known failures so it cannot stamp partial provisioning complete.
# Sourced (no shebang / set -e); matches lib/*.sh.

# Managed component lists (also used for unmanaged component detection).
MANAGED_MCPS=("firecrawl" "brave-search" "context7" "playwright" "logfire" "memory-router")
MANAGED_PLUGINS=(
  "superpowers@claude-plugins-official"
  "frontend-design@claude-plugins-official"
  "playwright@claude-plugins-official"
  "code-simplifier@claude-plugins-official"
  "skill-creator@claude-plugins-official"
  "code-review@claude-plugins-official"
  "claude-code-setup@claude-plugins-official"
  "pyright-lsp@claude-plugins-official"
  "context7@claude-plugins-official"
)

# Plugins we used to manage and now actively remove. The logfire plugin's
# bundled MCP server hardcodes the US-region URL with no way to repoint or
# individually disable it — useless against our EU-only Logfire account, and
# it nags "needs authentication" forever. The EU hosted MCP is registered at
# user scope in install_claude_mcps instead.
RETIRED_PLUGINS=(
  "logfire@claude-plugins-official"
)

# Logging fallbacks — install.sh defines colored variants; sync.sh doesn't,
# so plain-echo versions fill in. declare -F (not command -v) so a same-named
# binary on PATH (e.g. texinfo's `info`) can't satisfy the check.
declare -F info   >/dev/null || info()   { echo "INFO: $*"; }
declare -F ok     >/dev/null || ok()     { echo "  OK: $*"; }
declare -F warn   >/dev/null || warn()   { echo "WARN: $*"; }
declare -F header >/dev/null || header() { echo "=== $* ==="; }
declare -F err    >/dev/null || err()    { echo "ERROR: $*"; }

# Installers remain fail-open for people running install.sh. Unattended sync
# needs truthful aggregate status, so known failures propagate in that mode.
_provision_soft_failure() { [ -z "${AICODING_SYNC_MODE:-}" ]; }

# Scheduled calls are closed-stdin and bounded. Interactive install.sh keeps
# the upstream command behavior because a person can answer its prompts.
_provision_run() {
  if [ -n "${AICODING_SYNC_MODE:-}" ]; then
    timeout "${AICODING_PROVISION_TIMEOUT:-120}" "$@" </dev/null
  else
    "$@"
  fi
}

_provision_record_blocked() {
  command -v aicoding_result_record >/dev/null 2>&1 \
    && aicoding_result_record "$1" blocked "" "$2" || true
}

_provision_ensure_update_components() {
  declare -F aicoding_update_component >/dev/null 2>&1 && return 0
  local root=${SCRIPT_DIR:-${BLUEPRINT_ROOT:-}}
  [ -n "$root" ] && [ -f "$root/lib/update-results.sh" ] && [ -f "$root/lib/update-components.sh" ] || return 1
  . "$root/lib/update-results.sh"
  . "$root/lib/update-components.sh"
}

_provision_reconcile_exact_mcp() {
  local name=$1 component=$2 launcher=$3; shift 3
  _provision_ensure_update_components || return 1
  local version state
  [ -f "$AICODING_RESULTS_FILE" ] || { _provision_record_blocked "$component" exact_package_not_staged; return 1; }
  state=$(jq -r --arg c "$component" '.components[$c].state // empty' "$AICODING_RESULTS_FILE" 2>/dev/null)
  version=$(jq -r --arg c "$component" '.components[$c].successful_version // .components[$c].target_version // empty' "$AICODING_RESULTS_FILE" 2>/dev/null)
  case "$state" in current|updated) ;; *) _provision_record_blocked "$component" exact_package_not_staged; return 1 ;; esac
  _aicoding_reconcile_claude_mcp_registration "$name" "$component" "$version" "$launcher" "$@" || return 1
}

_provision_reconcile_selected_exact_mcp() {
  local name=$1
  if [ -n "${AICODING_SYNC_MODE:-}" ]; then
    _provision_ensure_update_components || return 1
    _aicoding_claude_mcp_selected "$name" || return 0
  fi
  _provision_reconcile_exact_mcp "$@"
}

# Stage both exact MCP packages without running the broader installer. C calls
# this before first config deployment; --register-claude additionally creates
# or migrates the user-scope Claude registrations and their separate receipts.
aicoding_prepare_exact_mcps() {
  local register_claude=0 component rc=0
  case "${1:-}" in
    '') ;;
    --register-claude) register_claude=1; shift ;;
    *) return 2 ;;
  esac
  [ "$#" -eq 0 ] || return 2
  [ "${AICODINGSETUP_SKIP_NETWORK:-0}" != 1 ] || return 0
  _provision_ensure_update_components || {
    _provision_record_blocked mcp-context7 staged_updater_unavailable
    _provision_record_blocked mcp-playwright staged_updater_unavailable
    return 1
  }
  for component in mcp-context7 mcp-playwright; do
    if [ "$register_claude" -eq 1 ]; then
      AICODING_MCP_REGISTRATION_FORCE=1 aicoding_update_component "$component" || rc=1
    else
      AICODING_MCP_REGISTRATION_DISABLE=1 aicoding_update_component "$component" || rc=1
    fi
  done
  return "$rc"
}

# Provisioning mutates tool-owned user state, so scheduled calls re-check the
# tool receipt, local capability, and any shared-root inventory even when no
# managed config file happened to be actionable in this pass.
_provision_tool_ready() {
  local component=$1 command_name=$2 minimum=${3:-} root=${4:-} version
  [ -z "${AICODING_SYNC_MODE:-}" ] && return 0
  _provision_ensure_update_components || return 1
  _aicoding_update_receipt_allows "$component" || { _provision_record_blocked "provision-$component" "${component}_update_not_verified"; return 1; }
  _aicoding_command_is_linux "$command_name" || { _provision_record_blocked "provision-$component" "${component}_not_installed"; return 1; }
  version=$(_aicoding_version_from_command "$command_name") || true
  [ -n "$version" ] || { _provision_record_blocked "provision-$component" "${component}_version_unavailable"; return 1; }
  [ -z "$minimum" ] || _aicoding_version_at_least "$version" "$minimum" \
    || { _provision_record_blocked "provision-$component" "${component}_runtime_incompatible"; return 1; }
  _aicoding_shared_consumers_allow "$component" "$minimum" "$root" \
    || { _provision_record_blocked "provision-$component" "${component}_shared_consumers_incompatible"; return 1; }
}

# --- MCP npm packages ---
# Install MCP server binaries that aren't run via npx
install_mcp_packages() {
  header "MCP npm packages"

  if [ -n "${AICODING_SYNC_MODE:-}" ]; then
    info "Installed MCP packages are reconciled by the staged component updater"
    return 0
  fi

  [ "${AICODINGSETUP_SKIP_NETWORK:-0}" != 1 ] || return 0
  if _provision_ensure_update_components; then
    local component rc=0
    for component in mcp-firecrawl mcp-brave; do
      aicoding_update_component "$component" || rc=1
    done
    aicoding_prepare_exact_mcps || rc=1
    [ "$rc" -eq 0 ] || { _provision_soft_failure; return $?; }
    return 0
  fi
  warn "Staged MCP updater unavailable; global package replacement was not attempted"
  _provision_soft_failure; return $?
}

# Per-server fingerprint of the extra `claude mcp add` args (headers). The
# CLI can't read headers back, so this sha256 (non-secret) is the only way to
# notice a rotated/missing credential at an unchanged URL and re-register.
: "${AICODING_MCP_STATE:=$HOME/.local/state/aicoding/mcp-fingerprints}"

# ensure_http_mcp <name> <url> [extra `claude mcp add` args...] — register an
# HTTP MCP at user scope, healing drift: `claude mcp add` refuses to touch
# an existing name, so a server whose URL moved (e.g. memory-router
# localhost→vossisrv, #85) or whose token rotated would otherwise stay stale
# forever with this function reporting success. Compare the registered URL
# and the stored args fingerprint first; remove + re-add on mismatch, and
# verify the re-add actually landed by reading the URL back — a swallowed
# remove failure must surface as WARN, not "already configured" (#91 review).
ensure_http_mcp() {
  local name="$1" url="$2"; shift 2
  local fp=""
  (( $# )) && fp="$(printf '%s\n' "$@" | sha256sum | awk '{print $1}')"
  local fp_file="$AICODING_MCP_STATE/$name.sha256" stored=""
  [[ -f "$fp_file" ]] && stored="$(cat "$fp_file" 2>/dev/null)" || true
  # `|| true`: a failing `claude mcp get` (server missing, CLI broken) must
  # stay fail-open under install.sh's set -e/pipefail — empty means "not
  # registered", and the add path below reports any real trouble.
  local current
  current="$(_provision_run claude mcp get "$name" 2>/dev/null | sed -n 's/^ *URL: //p' | head -n1)" || true
  if [[ -n "$current" ]]; then
    if [[ "$current" == "$url" && "$stored" == "$fp" ]]; then
      ok "$name MCP already configured"
      return
    fi
    if [[ "$current" != "$url" ]]; then
      info "$name MCP URL drifted ($current -> $url) — re-registering"
    else
      info "$name MCP connection args changed — re-registering"
    fi
    if ! _provision_run claude mcp remove -s user "$name" 2>/dev/null; then
      warn "$name MCP: failed to remove stale registration — still at $current"
      _provision_soft_failure; return $?
    fi
  fi
  if _provision_run claude mcp add --transport http -s user "$name" "$url" "$@" 2>/dev/null; then
    # Read back and verify: an add that "succeeded" against a lingering old
    # registration would otherwise report a config that isn't there.
    local after
    after="$(_provision_run claude mcp get "$name" 2>/dev/null | sed -n 's/^ *URL: //p' | head -n1)" || true
    if [[ "$after" == "$url" ]]; then
      mkdir -p "$AICODING_MCP_STATE" 2>/dev/null || true
      printf '%s\n' "$fp" > "$fp_file" 2>/dev/null || true
      ok "$name MCP configured"
    else
      warn "$name MCP: registration did not verify (URL is '${after:-none}', wanted $url)"
      _provision_soft_failure; return $?
    fi
  else
    warn "$name MCP may need manual setup"
    _provision_soft_failure; return $?
  fi
}

# --- Claude Code MCPs ---
install_claude_mcps() {
  header "Claude Code MCPs"

  if ! command -v claude &>/dev/null; then
    warn "Claude Code CLI not found — skipping MCP installation"
    return 0
  fi

  _provision_tool_ready claude claude "" "$HOME/.claude" || {
    warn "Claude MCP provisioning deferred until its update and shared consumers are verified"
    _provision_soft_failure; return $?
  }

  local rc=0

  # firecrawl
  if [[ -n "${FIRECRAWL_API_KEY:-}" ]]; then
    if _provision_run claude mcp add firecrawl -s user -e "FIRECRAWL_API_KEY=${FIRECRAWL_API_KEY}" -- firecrawl-mcp 2>/dev/null; then
      ok "firecrawl MCP configured"
    elif _provision_run claude mcp get firecrawl &>/dev/null; then
      ok "firecrawl MCP already configured"
    else
      warn "firecrawl MCP may need manual setup"
      rc=1
    fi
  else
    warn "Skipping firecrawl MCP — no API key"
  fi

  # brave-search
  if [[ -n "${BRAVE_API_KEY:-}" ]]; then
    if _provision_run claude mcp add brave-search -s user -e "BRAVE_API_KEY=${BRAVE_API_KEY}" -- brave-search-mcp-server 2>/dev/null; then
      ok "brave-search MCP configured"
    elif _provision_run claude mcp get brave-search &>/dev/null; then
      ok "brave-search MCP already configured"
    else
      warn "brave-search MCP may need manual setup"
      rc=1
    fi
  else
    warn "Skipping brave-search MCP — no API key"
  fi

  local registration_force=0
  [ -n "${AICODING_SYNC_MODE:-}" ] || registration_force=1
  AICODING_MCP_REGISTRATION_FORCE=$registration_force \
    _provision_reconcile_selected_exact_mcp context7 mcp-context7 context7-mcp \
    && ok "context7 MCP exact registration reconciled when selected" || rc=1
  AICODING_MCP_REGISTRATION_FORCE=$registration_force \
    _provision_reconcile_selected_exact_mcp playwright mcp-playwright playwright-mcp --browser chromium \
    && ok "playwright MCP exact registration reconciled when selected" || rc=1

  # logfire — hosted MCP, EU region. The logfire plugin hardcodes the US URL
  # in its bundled .mcp.json (no env override); its README tells EU users to
  # register a user-scope entry at the EU endpoint instead. The plugin's US
  # server stays unauthenticated. Auth: run /mcp once (OAuth).
  ensure_http_mcp logfire https://logfire-eu.pydantic.dev/mcp || rc=1

  # memory-router — the central memory-lanes retrieval router on vossisrv
  # (the memory_search tool). HTTP MCP with bearer auth; the token is a
  # shared secret from ~/.aicodingsetup/.secrets.env, so no token means no
  # server.
  if [[ -n "${MEMORY_ROUTER_TOKEN:-}" ]]; then
    ensure_http_mcp memory-router http://10.0.0.249:8091/mcp \
      -H "Authorization: Bearer ${MEMORY_ROUTER_TOKEN}" || rc=1
  else
    warn "memory-router MCP skipped (MEMORY_ROUTER_TOKEN not set)"
  fi
  [ "$rc" -eq 0 ] || { _provision_soft_failure; return $?; }
}

# --- Claude Code marketplace plugins ---
install_claude_plugins() {
  header "Claude Code Plugins"

  if ! command -v claude &>/dev/null; then
    warn "Claude Code CLI not found — skipping plugin installation"
    return 0
  fi

  _provision_tool_ready claude claude "" "$HOME/.claude" || {
    warn "Claude plugin provisioning deferred until its update and shared consumers are verified"
    _provision_soft_failure; return $?
  }

  local plugin rc=0
  for plugin in "${MANAGED_PLUGINS[@]}"; do
    case "$plugin" in
      playwright@*)
        if _provision_reconcile_selected_exact_mcp playwright mcp-playwright playwright-mcp --browser chromium; then
          ok "$plugin skipped; exact MCP is absent or its stable registration verified"
        else
          warn "$plugin refresh skipped; exact MCP registration unavailable"
          rc=1
        fi
        continue ;;
      context7@*)
        if _provision_reconcile_selected_exact_mcp context7 mcp-context7 context7-mcp; then
          ok "$plugin skipped; exact MCP is absent or its stable registration verified"
        else
          warn "$plugin refresh skipped; exact MCP registration unavailable"
          rc=1
        fi
        continue ;;
    esac
    # Try install first; if already installed, try update
    if _provision_run claude plugin install "$plugin" 2>/dev/null; then
      ok "Installed $plugin"
    elif _provision_run claude plugin update "$plugin" 2>/dev/null; then
      ok "Updated $plugin"
    else
      warn "$plugin could not be installed or updated"
      rc=1
    fi
  done
  for plugin in "${RETIRED_PLUGINS[@]}"; do
    if _provision_run claude plugin uninstall "$plugin" 2>/dev/null; then
      ok "Removed retired plugin $plugin"
    fi
  done
  [ "$rc" -eq 0 ] || { _provision_soft_failure; return $?; }
}

# --- Retired CLI shims ---
# aicoding-update and update-status were back-compat symlinks for one release;
# sweep them off existing machines. (install.sh no longer creates them.)
remove_deprecated_shims() {
  rm -f "$HOME/.local/bin/aicoding-update" "$HOME/.local/bin/update-status"
}

# --- Codex marketplace plugins ---
# Use the native catalog, not Claude's versioned plugin cache. Repeated add
# refreshes the installed version and enables it (verified on codex 0.148+).
install_codex_plugins() {
  [[ "${AICODINGSETUP_SKIP_NETWORK:-0}" == 1 ]] && return 0
  command -v codex >/dev/null 2>&1 || return 0
  _provision_tool_ready codex codex 0.148.0 "${CODEX_HOME:-$HOME/.codex}" || {
    warn "Codex plugin provisioning deferred until its update and shared consumers are verified"
    _provision_soft_failure; return $?
  }
  header "Codex Plugins"
  local plugin="superpowers@openai-curated-remote" installed result package link old
  local codex_home="${CODEX_HOME:-$HOME/.codex}"
  if ! result=$(_provision_run codex plugin add "$plugin" --json 2>/dev/null); then
    warn "Could not install/update $plugin — retry with: codex plugin add $plugin"
    _provision_soft_failure; return $?
  fi
  installed=$(_provision_run codex plugin list --json 2>/dev/null) || installed=""
  if printf '%s' "$installed" | jq -e --arg id "$plugin" \
      '.installed[] | select(.pluginId == $id and .enabled == true)' >/dev/null 2>&1; then
    # Codex 0.153.4 can report remote plugins enabled while omitting their
    # skills from fresh sessions. Its legacy user skill root is still read.
    # Keep discovery Codex-only: ~/.agents/skills is shared with Claude, whose
    # native Superpowers plugin would otherwise be discovered twice.
    package=$(printf '%s' "$result" | jq -r '.installedPath // empty')
    case "$package" in
      "$codex_home"/plugins/cache/*/superpowers/*) ;;
      *) warn "$plugin returned an unexpected package path; discovery not linked"; _provision_soft_failure; return $? ;;
    esac
    [[ -f "$package/skills/using-superpowers/SKILL.md" ]] \
      || { warn "$plugin package has no using-superpowers skill"; _provision_soft_failure; return $?; }
    link="$codex_home/skills/superpowers"
    if [[ -e "$link" || -L "$link" ]]; then
      old=$(readlink "$link" 2>/dev/null) || old=""
      case "$old" in
        "$codex_home"/plugins/cache/*/superpowers/*/skills) ;;
        *) warn "$link is user-owned; leaving it untouched"; _provision_soft_failure; return $? ;;
      esac
    fi
    mkdir -p "$codex_home/skills" || { warn "Cannot create Codex skill directory"; _provision_soft_failure; return $?; }
    ln -sfn "$package/skills" "$link" || { warn "Cannot link Superpowers skills"; _provision_soft_failure; return $?; }
    ok "$plugin installed, enabled and linked for skill discovery"
  else
    warn "$plugin installation returned success but activation could not be verified"
    _provision_soft_failure; return $?
  fi
}
