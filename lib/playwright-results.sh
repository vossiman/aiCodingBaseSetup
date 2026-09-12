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

# Optional fifth argument is version evidence from this same staging attempt,
# carried across activation so committing a receipt does not run a second probe.
_aicoding_playwright_record() {
  local state=$1 target=${2:-} reason=$3 bin=${4:-} version=${5:-} last=${AICODING_COMPONENT_LAST_RESULT:-} rc=0
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
  aicoding_result_record playwright-chromium "$state" "$target" "$reason" "$version" || rc=$?
  # Existing callers use the package's last-result identity for dispositions.
  AICODING_COMPONENT_LAST_RESULT=$last
  return "$rc"
}

_aicoding_playwright_active_target() {
  local data=${AICODING_DATA_DIR:-$HOME/.local/share/aicoding} current
  current=$(readlink -f "$data/current/mcp-playwright" 2>/dev/null) || return 0
  case "$current" in "$data/versions/mcp-playwright/"*) printf '%s\n' "${current##*/}" ;; esac
}
