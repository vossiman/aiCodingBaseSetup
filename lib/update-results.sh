# Atomic component result records for unattended updates. Sourced only.

: "${AICODING_STATE_DIR:=$HOME/.local/state/aicoding}"
: "${AICODING_RESULTS_FILE:=$AICODING_STATE_DIR/update-results.json}"

_aicoding_result_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# aicoding_result_record COMPONENT STATE TARGET REASON [SUCCESS_VERSION]
aicoding_result_record() {
  local component=${1:-} state=${2:-} target=${3:-} reason=${4:-} success=${5:-}
  [[ "$component" =~ ^[A-Za-z0-9._-]+$ ]] || return 2
  case "$state" in updated|current|conflict|blocked|failed) ;; *) return 2 ;; esac
  [[ "$reason" != *$'\n'* && ${#reason} -le 200 ]] || return 2
  case "$state" in
    updated|current) [ -n "$success" ] || return 2 ;;
    *) success= ;;
  esac

  local dir lock now old tmp fd
  dir=$(dirname "$AICODING_RESULTS_FILE")
  mkdir -p "$dir" || return 1
  lock="$dir/.update-results.lock"
  exec {fd}>"$lock" || return 1
  flock "$fd" || { exec {fd}>&-; return 1; }
  now=$(_aicoding_result_now)
  if [ -f "$AICODING_RESULTS_FILE" ] && jq -e '.schema == 1 and (.components | type == "object")' "$AICODING_RESULTS_FILE" >/dev/null 2>&1; then
    old=$(cat "$AICODING_RESULTS_FILE")
  else
    old='{"schema":1,"components":{}}'
  fi
  tmp=$(mktemp "$dir/.update-results.XXXXXX") || { exec {fd}>&-; return 1; }
  if [ -n "$success" ]; then
    printf '%s' "$old" | jq \
      --arg c "$component" --arg t "$now" --arg s "$state" \
      --arg target "$target" --arg reason "$reason" --arg success "$success" \
      '.attempted_at=$t | .components[$c] = ((.components[$c] // {}) + {
        attempted_at:$t, successful_version:$success, target_version:($target|if .=="" then null else . end),
        state:$s, reason:$reason, succeeded_at:$t
      })' >"$tmp" || { rm -f "$tmp"; exec {fd}>&-; return 1; }
  else
    printf '%s' "$old" | jq \
      --arg c "$component" --arg t "$now" --arg s "$state" \
      --arg target "$target" --arg reason "$reason" \
      '.attempted_at=$t | .components[$c] = ((.components[$c] // {
        successful_version:null, succeeded_at:null
      }) + {
        attempted_at:$t, target_version:($target|if .=="" then null else . end),
        state:$s, reason:$reason
      })' >"$tmp" || { rm -f "$tmp"; exec {fd}>&-; return 1; }
  fi
  chmod 0600 "$tmp" 2>/dev/null || true
  local mv_rc=0
  mv -f "$tmp" "$AICODING_RESULTS_FILE" || mv_rc=$?
  [ "$mv_rc" -eq 0 ] || rm -f "$tmp"
  exec {fd}>&-
  return "$mv_rc"
}
