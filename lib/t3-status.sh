# t3-status: read-only, never takes a lock, so it works during a switch and
# while a journal needs attention.

t3_cmd_status() {
  local offline=0 v l
  [ "${1:-}" = --offline ] && offline=1
  t3_env 2>/dev/null
  echo "workspace:  $T3_KEY"
  echo "state:      $T3CODE_HOME"
  if t3_running; then
    echo "server:     running (supervisor $(t3_owner_field pid), t3 $(t3_owner_field version), since $(t3_owner_field started_at), container $(t3_owner_field container))"
  else
    echo "server:     not running"
    t3_orphans
    [ ${#T3_ORPHANS_TOKEN[@]} -gt 0 ] && echo "orphans:    ${T3_ORPHANS_TOKEN[*]} (t3-stop --orphans)"
    [ ${#T3_ORPHANS_SESSION[@]} -gt 0 ] && echo "session:    ${T3_ORPHANS_SESSION[*]} share the old session id; inspect by hand"
  fi
  echo "enabled:    $([ -f "$T3_STATE/enabled" ] && echo yes || echo no) (starts at boot)"
  echo "set up:     $(t3_set_up && echo yes || echo no)"
  echo "selected:   $(t3_mode) $(t3_selected_version)"
  echo "auto:       $(t3_auto_on && echo on || echo off)"
  [ -f "$T3_STATE/pending.json" ] && echo "pending:    $(jq -c . "$T3_STATE/pending.json")"
  [ -f "$T3_STATE/switch.json" ] && echo "switch:     interrupted at $(t3_json_get "$T3_STATE/switch.json" .phase); the next t3 command finishes it"
  [ -f "$T3_STATE/attention" ] && echo "ATTENTION:  $(cat "$T3_STATE/attention") (see docs/t3.md, Recovery)"
  if [ "$offline" = 0 ] && l=$(t3_latest); then echo "newest:     $l"; fi
  [ -f "$T3_STATE/last-result.json" ] \
    && echo "last:       $(jq -r '"\(.at) \(.op) \(.outcome) \(.reason) \(.detail)"' "$T3_STATE/last-result.json")"
  v=$(t3_selected_version) || true
  if [ -n "$v" ] && t3_installed "$v"; then
    echo "connect:"
    timeout 30 "$(t3_launcher "$v")" connect status 2>&1 | sed 's/^/  /'
  fi
}
