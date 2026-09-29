# One-time move of a container-local ~/.t3 onto the t3-envs mount (spec:
# t3-migrate). Export runs in the old container, before the rebuild that adds
# the mount, so it is the one command that does not need the mount.

t3_migrate_require_persistent() {
  local parent target
  parent=$(dirname "$T3_MIGRATE_DIR")
  target=$(findmnt -n -o TARGET -T "$parent" 2>/dev/null) || target=""
  [ -n "$target" ] && [ "$(readlink -f "$target")" = "$(readlink -f "$parent")" ] \
    || t3_die "$parent is not a host bind mount; the archive would not survive the rebuild"
}

t3_migrate_lock() {
  (umask 077; mkdir -p "$T3_MIGRATE_DIR") || t3_die "cannot create $T3_MIGRATE_DIR"
  exec 7>>"$T3_MIGRATE_DIR/$1.lock" || t3_die "cannot open the migration lock"
  flock -w "$T3_CONTROL_WAIT" 7 || t3_die "another t3-migrate holds $T3_MIGRATE_DIR/$1.lock"
}

t3_legacy_servers() {
  local p home; local -a a
  T3_LEGACY=()
  for p in /proc/[0-9]*; do
    p=${p#/proc/}
    [ -O "/proc/$p" ] || continue
    mapfile -d '' -t a 2>/dev/null < "/proc/$p/cmdline" || continue
    [[ " ${a[*]} " == *" serve "* ]] || continue
    case "${a[0]##*/}" in
      t3) ;;
      node) case "${a[1]:-}" in */t3|*/t3.js) ;; *) continue ;; esac ;;
      *) continue ;;
    esac
    home=$(t3_proc_env_value "$p" T3CODE_HOME) || home=""
    if [ -z "$home" ]; then
      # t3's default is the server's own $HOME/.t3, not the caller's
      home=$(t3_proc_env_value "$p" HOME) || continue
      home="$home/.t3"
    fi
    [ "$(readlink -f "$home")" = "$1" ] && T3_LEGACY+=("$p")
  done
}

t3_legacy_version() {
  local exe; local -a a
  mapfile -d '' -t a 2>/dev/null < "/proc/$1/cmdline" || return 1
  exe=$(readlink "/proc/$1/exe" 2>/dev/null) || exe=""
  if [ "${a[0]##*/}" = t3 ] && [ -x "${a[0]}" ]; then "${a[0]}" --version 2>/dev/null | t3_parse_version
  elif [ "${exe##*/}" = t3 ]; then "$exe" --version 2>/dev/null | t3_parse_version
  elif [ "${exe##*/}" = node ] && [ -f "${a[1]:-}" ]; then "$exe" "${a[1]}" --version 2>/dev/null | t3_parse_version
  fi
}

# Legacy stop: no supervisor exists, so identify each server by pid and start
# time, signal it and its descendants, and re-verify before any SIGKILL.
t3_legacy_stop() {
  local p q i alive
  local -A start=() parent=()
  local -a all=()
  T3_LEGACY_VERSION=""
  t3_legacy_servers "$1"
  [ ${#T3_LEGACY[@]} -eq 0 ] && return 0
  T3_LEGACY_VERSION=$(t3_legacy_version "${T3_LEGACY[0]}")
  for p in /proc/[0-9]*; do p=${p#/proc/}; t3_stat "$p" && parent[$p]=$T3S_PPID; done
  for p in "${!parent[@]}"; do
    q=$p
    while [ -n "$q" ] && [ "$q" != 1 ] && [ "$q" != 0 ]; do
      if [[ " ${T3_LEGACY[*]} " == *" $q "* ]]; then all+=("$p"); break; fi
      q=${parent[$q]:-}
    done
  done
  for p in "${all[@]}"; do t3_stat "$p" && start[$p]=$T3S_START; done
  t3_say "stopping the hand-started t3 server: ${!start[*]}"
  for p in "${!start[@]}"; do kill -TERM "$p" 2>/dev/null; done
  for ((i = 0; i < T3_STOP_GRACE * 10; i++)); do
    alive=0
    for p in "${!start[@]}"; do t3_stat "$p" && [ "$T3S_START" = "${start[$p]}" ] && alive=1; done
    [ "$alive" = 0 ] && return 0
    sleep 0.1
  done
  for p in "${!start[@]}"; do t3_stat "$p" && [ "$T3S_START" = "${start[$p]}" ] && kill -KILL "$p" 2>/dev/null; done
  sleep 0.5
}

t3_open_under() {
  local p fd t
  T3_OPEN=()
  for p in /proc/[0-9]*; do
    p=${p#/proc/}
    [ -O "/proc/$p" ] || continue
    for fd in "/proc/$p"/fd/*; do
      t=$(readlink "$fd" 2>/dev/null) || continue
      case "$t" in "$1"/*) T3_OPEN+=("$p"); break ;; esac
    done
  done
}

t3_migrate_export() {
  local src="$HOME/.t3" ver="" key arc man tmp sha
  while [ $# -gt 0 ]; do
    case "$1" in
      --source) src=${2:?}; shift 2 ;;
      --version) ver=${2:?}; shift 2 ;;
      *) t3_die "usage: t3-migrate --export [--source DIR] [--version X]" ;;
    esac
  done
  key=$(t3_key) || exit 1
  src=$(readlink -f "$src") || t3_die "no such directory: $src"
  [ -s "$src/userdata/environment-id" ] || t3_die "$src has no userdata/environment-id; nothing to export"
  t3_migrate_require_persistent
  t3_migrate_lock "$key"
  t3_legacy_stop "$src"
  [ -n "$ver" ] || ver=$T3_LEGACY_VERSION
  t3_valid_version "$ver" || t3_die "cannot tell which t3 version ran on $src; pass --version X"
  t3_open_under "$src"
  [ ${#T3_OPEN[@]} -eq 0 ] || t3_die "processes still have files under $src open: ${T3_OPEN[*]}. Stop them by hand, then retry."
  arc="$T3_MIGRATE_DIR/$key.tgz"; man="$T3_MIGRATE_DIR/$key.json"
  tmp=$(umask 077; mktemp "$T3_MIGRATE_DIR/.$key.XXXXXX") || t3_die "cannot create a temp file"
  (umask 077; tar -C "$src" -czf "$tmp" .) || { rm -f "$tmp"; t3_die "archiving $src failed"; }
  mv -f "$tmp" "$arc"
  sha=$(sha256sum "$arc" | cut -d' ' -f1)
  t3_write_file "$man" "$(jq -cn --arg e "$(cat "$src/userdata/environment-id")" --arg w "$key" \
    --arg v "$ver" --arg s "$sha" '{environment_id: $e, workspace: $w, version: $v, sha256: $s}')"
  chmod 600 "$man"
  t3_open_under "$src"
  if [ ${#T3_OPEN[@]} -gt 0 ]; then
    rm -f "$arc" "$man"
    t3_die "a process opened files under $src while archiving (${T3_OPEN[*]}); archive deleted"
  fi
  t3_say "exported $src (environment $(cat "$src/userdata/environment-id"), t3 $ver) to $arc"
  t3_say "next: rebuild this workspace, then run t3-migrate --restore in the new container"
}

t3_migrate_restore() {
  local key man arc st e
  key=$(t3_key) || exit 1
  man="$T3_MIGRATE_DIR/$key.json"; arc="$T3_MIGRATE_DIR/$key.tgz"
  [ -f "$man" ] && [ -f "$arc" ] || t3_die "no export for $key in $T3_MIGRATE_DIR"
  t3_migrate_lock "$key"
  t3_env
  t3_control_lock || t3_die "another t3 command holds the control lock"
  t3_recover_if_needed
  { [ -d "$T3CODE_HOME/userdata" ] || [ -f "$T3_STATE/setup-done" ]; } \
    && t3_die "$T3CODE_HOME already holds t3 state; refusing to overwrite it"
  [ "$(sha256sum "$arc" | cut -d' ' -f1)" = "$(t3_json_get "$man" .sha256)" ] \
    || t3_die "archive checksum mismatch; the export is damaged"
  st="$T3_ENVS_ROOT/$key.restore"
  rm -rf "$st"; mkdir -p "$st"
  tar -C "$st" -xzf "$arc" || t3_die "unpacking the archive failed"
  rm -rf "$st/aicoding"
  rm -f "$st/userdata/server-runtime.json" "$st"/userdata/*.lock
  [ "$(cat "$st/userdata/environment-id" 2>/dev/null)" = "$(t3_json_get "$man" .environment_id)" ] \
    || t3_die "the environment-id in the archive does not match the manifest"
  for e in "$T3CODE_HOME"/* "$T3CODE_HOME"/.[!.]*; do
    [ -e "$e" ] || continue
    [ "${e##*/}" = aicoding ] && continue
    rm -rf "$e"
  done
  for e in "$st"/* "$st"/.[!.]*; do
    [ -e "$e" ] || continue
    [ "${e##*/}" = userdata ] && continue
    mv "$e" "$T3CODE_HOME/" || t3_die "cannot move $e into place"
  done
  mv "$st/userdata" "$T3CODE_HOME/userdata" || t3_die "cannot move userdata into place"
  rmdir "$st" 2>/dev/null || rm -rf "$st"
  t3_adopt_core "$(t3_json_get "$man" .version)" \
    || t3_die "restored, but adopt failed. Fix the cause, then run t3-adopt --version $(t3_json_get "$man" .version) and t3-start"
  t3_write_file "$T3_STATE/enabled" on
  t3_start_selected
  t3_say "restored and started. Check the phone shows the same computer, then run t3-migrate --confirm"
}

t3_migrate_confirm() {
  local key
  key=$(t3_key) || exit 1
  t3_migrate_lock "$key"
  rm -f "$T3_MIGRATE_DIR/$key.tgz" "$T3_MIGRATE_DIR/$key.json"
  t3_say "deleted the export archive for $key"
}

t3_cmd_migrate() {
  case "${1:-}" in
    --export) shift; t3_migrate_export "$@" ;;
    --restore) t3_migrate_restore ;;
    --confirm) t3_migrate_confirm ;;
    *) t3_die "usage: t3-migrate --export [--source DIR] [--version X] | --restore | --confirm" ;;
  esac
}
