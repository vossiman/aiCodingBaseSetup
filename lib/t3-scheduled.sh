# The updater's t3 step (spec: Automatic update, Eligibility). Prints one
# line: result <state> <reason> <version|-> <detail|->. Everything else goes
# to stderr, which the updater appends to its t3 log.

t3_cmd_scheduled() {
  local cur latest
  t3_env
  [ -f "$T3_STATE/enabled" ] || { echo "result current t3_not_enabled - -"; return 0; }
  t3_control_lock || { echo "result blocked t3_lock_busy - control-lock-held"; return 1; }
  t3_recover_if_needed
  t3_set_up || { echo "result blocked t3_not_set_up - -"; return 1; }
  cur=$(t3_selected_version)
  if [ "$(t3_mode)" = held ]; then echo "result current t3_held $cur -"; return 0; fi
  latest=$(t3_latest) || { echo "result blocked t3_npm_unavailable $cur -"; return 1; }
  if ! t3_version_lt "$cur" "$latest"; then echo "result current t3_current $cur -"; return 0; fi
  t3_install "$latest" || { echo "result failed t3_install_failed $latest npm-install-failed"; return 1; }
  if ! t3_running; then
    t3_write_file "$T3_STATE/pending.json" "$(jq -cn --arg c "$latest" --arg b "$cur" '{candidate: $c, base: $b}')"
    echo "result current t3_candidate_pending $cur candidate=$latest"
    return 0
  fi
  t3_auto_on || { echo "result blocked t3_auto_off $cur available=$latest"; return 1; }
  if ! t3_idle_full; then echo "result blocked t3_idle_wait $cur $T3_BUSY"; return 1; fi
  if t3_switch "$latest" latest scheduled; then echo "result updated t3_switched $latest -"; return 0; fi
  echo "result failed t3_switch_failed $latest $(t3_json_get "$T3_STATE/last-result.json" .detail)"
  return 1
}
