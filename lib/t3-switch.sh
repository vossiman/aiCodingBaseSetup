# Version switching (spec: Switching versions). A journal (switch.json) exists
# only while files may be inconsistent; every entry point finishes it first.

T3_BACKUP_FILES="state.sqlite state.sqlite-wal state.sqlite-shm settings.json environment-id"

t3_journal_file() { printf '%s\n' "$T3_STATE/switch.json"; }

t3_journal_set() {
  local j
  j=$(t3_journal_file)
  t3_write_file "$j" "$(jq -c --arg k "$1" --argjson v "$2" '.[$k] = $v' "$j")"
}

t3_attention() {
  t3_write_file "$T3_STATE/attention" "$1"
  t3_record switch failed attention "$1"
}

# Taken with the server stopped. The database copy is verified on a scratch
# copy so the backup itself stays exactly as taken.
t3_backup() {
  local u="$T3CODE_HOME/userdata" d=$1 f
  (umask 077; mkdir -p "$d") || return 1
  chmod 700 "$d"
  for f in $T3_BACKUP_FILES; do
    [ -e "$u/$f" ] && { cp -a "$u/$f" "$d/$f" || return 1; }
  done
  [ -d "$u/secrets" ] && { cp -a "$u/secrets" "$d/secrets" || return 1; }
  [ -f "$d/state.sqlite" ] || return 0
  python3 -B - "$d" <<'PY'
import os, shutil, sqlite3, sys, tempfile
src = sys.argv[1]
with tempfile.TemporaryDirectory() as t:
    for n in ("state.sqlite", "state.sqlite-wal"):
        if os.path.exists(os.path.join(src, n)):
            shutil.copy2(os.path.join(src, n), t)
    ok = sqlite3.connect(os.path.join(t, "state.sqlite")).execute("PRAGMA integrity_check").fetchone()[0]
    sys.exit(0 if ok == "ok" else 1)
PY
}

t3_prune_backups() {
  local d
  ls -1dt "$T3_STATE/backups"/*/ 2>/dev/null | tail -n +4 | while IFS= read -r d; do rm -rf "$d"; done
}

# Restore transaction (spec table). Paths carry the journal id so a retry
# never collides with an earlier attempt; the state on disk decides where to
# continue. Returns 2 when the combination is not one the table covers.
t3_restore() {
  local j=$1 b=$2 base=$T3CODE_HOME f
  local st="$base/userdata.restore-$1" old="$base/userdata.old-$1" mk="$base/userdata.restore-$1.complete"
  if [ "$(t3_json_get "$(t3_journal_file)" .restored)" = true ]; then
    rm -rf "$old"; rm -f "$mk"; return 0
  fi
  if [ -d "$st" ] && ! grep -qxF "$j" "$mk" 2>/dev/null; then rm -rf "$st"; rm -f "$mk"; fi
  if [ ! -d "$st" ] && [ ! -f "$mk" ]; then
    [ -d "$base/userdata" ] || return 2
    cp -a "$base/userdata" "$st" || return 1
    for f in $T3_BACKUP_FILES; do
      if [ -e "$b/$f" ]; then cp -a "$b/$f" "$st/$f" || return 1
      else case "$f" in state.sqlite-wal|state.sqlite-shm) rm -f "$st/$f" ;; esac
      fi
    done
    if [ -d "$b/secrets" ]; then rm -rf "$st/secrets" && cp -a "$b/secrets" "$st/secrets" || return 1; fi
    sync
    t3_write_file "$mk" "$j" || return 1
  fi
  if [ -d "$st" ] && [ -d "$base/userdata" ]; then mv "$base/userdata" "$old" || return 1; fi
  if [ -d "$st" ] && [ ! -d "$base/userdata" ]; then mv "$st" "$base/userdata" || return 1; fi
  [ -d "$base/userdata" ] && [ ! -d "$st" ] || return 2
  t3_journal_set restored true || return 1
  rm -rf "$old"; rm -f "$mk"
}

t3_switch_commit_tail() {
  local j
  j=$(t3_journal_file)
  t3_write_file "$T3_STATE/version.json" "$(jq -c .new "$j")" || return 1
  rm -f "$T3_STATE/pending.json"
  rm -f "$j"
  t3_prune_backups
}

t3_switch_abort_tail() {
  local j
  j=$(t3_journal_file)
  [ "$(t3_json_get "$j" .kind)" = candidate ] && rm -f "$T3_STATE/pending.json"
  rm -f "$j"
}

t3_journal_recover() {
  local j phase id b oldv rc
  j=$(t3_journal_file)
  [ -f "$T3_STATE/attention" ] \
    && t3_die "a previous switch needs manual attention: $(cat "$T3_STATE/attention"). See docs/t3.md, section Recovery."
  [ -f "$j" ] || return 0
  phase=$(t3_json_get "$j" .phase); id=$(t3_json_get "$j" .id); b=$(t3_json_get "$j" .backup)
  case "$phase" in
    committed) t3_say "finishing a committed switch"; t3_switch_commit_tail; return 0 ;;
    rolled-back) t3_switch_abort_tail; return 0 ;;
  esac
  t3_say "rolling back an interrupted switch (phase $phase)"
  t3_stop_server || t3_die "cannot stop the server to recover the interrupted switch"
  if [ "$phase" = starting-target ] || [ "$phase" = rolling-back ]; then
    t3_restore "$id" "$b"; rc=$?
    if [ "$rc" -ne 0 ]; then
      t3_attention "restore from $b did not complete (journal $id)"
      t3_die "the interrupted switch needs manual attention; see t3-status and docs/t3.md"
    fi
  fi
  t3_write_file "$T3_STATE/version.json" "$(jq -c .old "$j")"
  t3_switch_abort_tail
  oldv=$(t3_selected_version)
  if [ -f "$T3_STATE/enabled" ] && ! t3_running && t3_set_up; then
    t3_start_version "$oldv" || t3_record start failed not_ready "$oldv after recovery"
  fi
}

t3_switch() {
  local target=$1 mode=$2 kind=$3 oldv old id b rc
  oldv=$(t3_selected_version); old=$(cat "$T3_STATE/version.json")
  t3_install "$target" || { t3_record switch failed install_failed "$target"; return 1; }
  id="$(date +%s)-$$"
  b="$T3_STATE/backups/$oldv-$(date -u +%Y%m%dT%H%M%SZ)"
  t3_write_file "$(t3_journal_file)" "$(jq -cn --arg id "$id" --argjson old "$old" --arg m "$mode" \
    --arg v "$target" --arg b "$b" --arg k "$kind" \
    '{id: $id, old: $old, new: {mode: $m, version: $v}, backup: $b, kind: $k, phase: "stopping"}')" || return 1
  if ! t3_stop_server; then
    t3_journal_set phase '"rolled-back"'; t3_switch_abort_tail
    t3_record switch failed stop_failed "$target"
    return 1
  fi
  if ! t3_backup "$b"; then
    rm -rf "$b"
    t3_journal_set phase '"rolled-back"'; t3_switch_abort_tail
    t3_start_version "$oldv" || t3_record start failed not_ready "$oldv after a failed backup"
    t3_record switch failed backup_failed "$target"
    return 1
  fi
  t3_journal_set phase '"backed-up"'
  t3_journal_set phase '"starting-target"'
  t3_start_version "$target"; rc=$?
  if [ "$rc" = 0 ]; then
    t3_journal_set phase '"committed"'
    t3_switch_commit_tail
    t3_record switch ok switched "$oldv -> $target"
    t3_say "now on t3 $target (backup in $b)"
    return 0
  fi
  if [ "$rc" = 2 ]; then
    t3_attention "t3 $target is running but not ready and could not be stopped; nothing was restored (journal $id)"
    return 1
  fi
  t3_journal_set phase '"rolling-back"'
  if ! t3_restore "$id" "$b"; then
    t3_attention "rollback to $oldv could not restore $b (journal $id)"
    return 1
  fi
  t3_journal_set phase '"rolled-back"'; t3_switch_abort_tail
  if t3_start_version "$oldv"; then
    t3_record switch failed switch_failed "$target did not become ready; back on $oldv"
  else
    t3_record switch failed attention "$target did not become ready and $oldv did not start again"
  fi
  return 1
}

# Called by t3-start. Returns 0 when it already started a server.
t3_pending_apply() {
  local p="$T3_STATE/pending.json" cand base
  [ -f "$p" ] || return 1
  cand=$(t3_json_get "$p" .candidate); base=$(t3_json_get "$p" .base)
  if [ "$(t3_mode)" != latest ] || ! t3_auto_on || [ "$base" != "$(t3_selected_version)" ] \
      || ! t3_valid_version "$cand"; then
    rm -f "$p"; return 1
  fi
  if ! t3_idle_db 12; then
    t3_say "keeping t3 $(t3_selected_version) for now ($T3_BUSY); $cand stays pending"
    return 1
  fi
  t3_switch "$cand" latest candidate || true
  [ -f "$T3_STATE/attention" ] && t3_die "needs attention: $(cat "$T3_STATE/attention"); see t3-status"
  if t3_running; then t3_write_file "$T3_STATE/enabled" on; return 0; fi
  return 1
}

t3_cmd_update() {
  local yes=0 latest_only=0 target="" mode cur was_running=0 a
  local -a orig=("$@")
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes) yes=1 ;;
      --latest) latest_only=1 ;;
      --scheduled) shift; t3_cmd_scheduled "$@"; return ;;
      -*) t3_die "usage: t3-update [VERSION] [--yes] | t3-update --latest" ;;
      *) target=$1 ;;
    esac
    shift
  done
  t3_wait_detached_parent
  t3_entry
  t3_set_up || t3_die "not set up; run t3-setup or t3-adopt"
  if [ "$latest_only" = 1 ]; then
    t3_write_version latest "$(t3_selected_version)"
    rm -f "$T3_STATE/pending.json"
    t3_say "following new releases again; the next updater pass picks them up"
    return 0
  fi
  if [ -n "$target" ]; then
    t3_valid_version "$target" || t3_die "not a version: $target"
    mode=held
  else
    target=$(t3_latest) || t3_die "cannot resolve the newest t3 from npm"
    mode=latest
  fi
  cur=$(t3_selected_version)
  if [ "$target" = "$cur" ]; then
    t3_write_version "$mode" "$cur"; rm -f "$T3_STATE/pending.json"
    t3_say "already on t3 $cur ($mode)"
    return 0
  fi
  t3_version_lt "$target" "$cur" \
    && t3_say "warning: $target is older than $cur; an older t3 may not read a database a newer one migrated. A backup is taken first."
  if t3_running; then
    was_running=1
    t3_workloads
    if [ ${#T3_BUSY_LIST[@]} -gt 0 ] && [ "$yes" = 0 ]; then
      t3_say "work in progress: ${T3_BUSY_LIST[*]}"
      if [ -t 0 ] && [ -t 2 ]; then
        read -r -p "t3: restarting interrupts it. Continue? [y/N] " a
        [ "$a" = y ] || [ "$a" = Y ] || t3_die "cancelled"
      else
        t3_die "work in progress; pass --yes to interrupt it"
      fi
    fi
  fi
  t3_detach_if_in_scope "${orig[@]}" --yes
  t3_switch "$target" "$mode" manual || exit 1
  if [ "$was_running" = 0 ] && [ ! -f "$T3_STATE/enabled" ]; then t3_stop_server; fi
}

t3_cmd_auto() {
  case "${1:-}" in on|off) ;; *) t3_die "usage: t3-auto on|off" ;; esac
  t3_entry
  if [ "$1" = on ]; then t3_write_file "$T3_STATE/auto" on; else rm -f "$T3_STATE/auto"; fi
  rm -f "$T3_STATE/pending.json"
  t3_say "automatic restarts are $1 for $T3_KEY"
}
