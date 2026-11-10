# Chromium has a separate lifecycle from its associated Playwright MCP package.
# Keep browser receipts usable by both staged updates and standalone provisioning.
# Exit-zero unrecognized output is an unknown version; nonzero/timeout is a
# failed executable probe and must never become a successful browser receipt.
_aicoding_playwright_version() {
  local output
  output=$(timeout "${AICODING_PROBE_TIMEOUT:-15}" "$1" --version </dev/null 2>/dev/null) || return 1
  if [[ "$output" =~ ^(Chromium|Google\ Chrome|Google\ Chrome\ for\ Testing|Chrome\ Headless\ Shell)[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
  else
    printf '%s\n' unknown
  fi
}

_aicoding_playwright_install_log() {
  printf '%s\n' "${AICODING_STATE_DIR:-$HOME/.local/state/aicoding}/playwright-install.log"
}

# _aicoding_playwright_install_run CLI CACHE: install the exact browser, keeping
# the vendor output in a private file that the summary keeps as the install log
# only when this run downloaded or failed, so reconciling a cached browser does
# not erase the last failure. Playwright restarts a whole file when its
# connection is idle for 30 s, so a stalling route needs a longer idle limit and
# more time than a package step.
_aicoding_playwright_install_run() {
  local cli=$1 cache=$2 log
  log=$(_aicoding_playwright_install_log).new
  { mkdir -p "${log%/*}" && : >"$log" && chmod 0600 "$log"; } 2>/dev/null || log=/dev/null
  PLAYWRIGHT_BROWSERS_PATH="$cache" \
    PLAYWRIGHT_DOWNLOAD_CONNECTION_TIMEOUT="${PLAYWRIGHT_DOWNLOAD_CONNECTION_TIMEOUT:-120000}" \
    timeout "${AICODING_BROWSER_TIMEOUT:-1800}" "$cli" install-browser --no-remove chromium </dev/null >"$log" 2>&1
}

# _aicoding_playwright_install_summary RC SECONDS: read the install log into
# _AICODING_PLAYWRIGHT_DOWNLOAD_SECONDS/_RESTARTS (set only when something was
# downloaded) and, for a failure, _AICODING_PLAYWRIGHT_DETAIL. The next browser
# record consumes them.
_aicoding_playwright_install_summary() {
  local rc=$1 seconds=$2 log new text="" started="" total=0 unique=0 restarts=0 errors="" error="" detail
  _AICODING_PLAYWRIGHT_DOWNLOAD_SECONDS=
  _AICODING_PLAYWRIGHT_DOWNLOAD_RESTARTS=
  _AICODING_PLAYWRIGHT_DETAIL=
  log=$(_aicoding_playwright_install_log)
  new=$log.new
  [ ! -r "$new" ] || text=$(tr '\r' '\n' <"$new" 2>/dev/null | sed -e $'s/\033\\[[0-9;]*m//g' -e 's#://[^/@[:space:]]*@#://#g') || text=""
  started=$(printf '%s\n' "$text" | sed -n 's/^\(Downloading .*\) from .*/\1/p') || started=""
  if [ -e "$new" ]; then
    if [ "$rc" -ne 0 ] || [ -n "$started" ]; then
      mv -f "$new" "$log" 2>/dev/null || true
    else
      rm -f "$new" 2>/dev/null || true
    fi
  fi
  if [ -n "$started" ]; then
    total=$(printf '%s\n' "$started" | wc -l)
    unique=$(printf '%s\n' "$started" | sort -u | wc -l)
    restarts=$((total - unique))
    _AICODING_PLAYWRIGHT_DOWNLOAD_SECONDS=$seconds
    _AICODING_PLAYWRIGHT_DOWNLOAD_RESTARTS=$restarts
  fi
  if [ "$rc" -eq 0 ]; then
    if [ -n "$started" ] && { [ "$seconds" -ge 300 ] || [ "$restarts" -gt 0 ]; }; then
      printf 'WARN: playwright: Chromium download was slow (%ss, %s restarted transfers)\n' "$seconds" "$restarts" >&2
    fi
    return 0
  fi
  case "$rc" in
    124|137) detail="timed out after ${seconds}s" ;;
    *) detail="exit $rc after ${seconds}s" ;;
  esac
  [ -z "$started" ] || detail="$detail, $restarts restarted transfers"
  # The CLI ends with generic wrappers; the transfer error before them is the cause.
  errors=$(printf '%s\n' "$text" | grep -E '^(Error|Failed)') || errors=""
  error=$(printf '%s\n' "$errors" | grep -Ev '^(Failed to install browsers|Error: Failed to download |Error: Download failure, code=)' | tail -n 1) || error=""
  [ -n "$error" ] || error=$(printf '%s\n' "$errors" | tail -n 1)
  [ -z "$error" ] || detail="$detail; $error"
  _AICODING_PLAYWRIGHT_DETAIL=$detail
}

# Optional fifth argument is version evidence from this same staging attempt,
# carried across activation so committing a receipt does not run a second probe.
_aicoding_playwright_record() {
  local state=$1 target=${2:-} reason=$3 bin=${4:-} version=${5:-} last=${AICODING_COMPONENT_LAST_RESULT:-} rc=0 detail=
  if ! declare -F aicoding_result_record >/dev/null 2>&1; then
    . "$(dirname "${BASH_SOURCE[0]}")/update-results.sh" || return 1
  fi
  [ -z "$target" ] || target="mcp-playwright@$target"
  case "$state" in
    current|updated)
      if [ -z "$version" ] && ! version=$(_aicoding_playwright_version "$bin"); then
        state=failed
        reason=browser_version_probe_failed
        rc=1
      elif [ "$version" = unknown ]; then
        reason=browser_ready_version_unavailable
      fi
      ;;
  esac
  [ "$reason" != browser_install_failed ] || detail=${_AICODING_PLAYWRIGHT_DETAIL:-}
  aicoding_result_record playwright-chromium "$state" "$target" "$reason" "$version" "$detail" || rc=$?
  if [ -n "${_AICODING_PLAYWRIGHT_DOWNLOAD_SECONDS:-}" ]; then
    aicoding_result_download playwright-chromium "$_AICODING_PLAYWRIGHT_DOWNLOAD_SECONDS" \
      "${_AICODING_PLAYWRIGHT_DOWNLOAD_RESTARTS:-0}" || true
  fi
  _AICODING_PLAYWRIGHT_DOWNLOAD_SECONDS=
  _AICODING_PLAYWRIGHT_DOWNLOAD_RESTARTS=
  _AICODING_PLAYWRIGHT_DETAIL=
  # Existing callers use the package's last-result identity for dispositions.
  AICODING_COMPONENT_LAST_RESULT=$last
  return "$rc"
}

_aicoding_playwright_active_target() {
  local data=${AICODING_DATA_DIR:-$HOME/.local/share/aicoding} current
  current=$(readlink -f "$data/current/mcp-playwright" 2>/dev/null) || return 0
  case "$current" in "$data/versions/mcp-playwright/"*) printf '%s\n' "${current##*/}" ;; esac
}
