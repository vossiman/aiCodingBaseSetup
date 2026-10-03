# Project folders are container-local and die with a rebuild, while t3's
# project catalogue survives on the mount. projects.tsv (path TAB origin)
# remembers each project's remote, so a missing folder can be cloned back.

T3_CLONE_TIMEOUT="${T3_CLONE_TIMEOUT:-300}"

# Never fails: a project that cannot come back is reported, not fatal.
t3_projects_restore() {
  local f="$T3_STATE/projects.tsv" p url list out="" db="$T3CODE_HOME/userdata/state.sqlite"
  local -a roots=()
  local -A remote=()
  [ -f "$db" ] || return 0
  # A failed read must not look like "no projects": that would wipe the record.
  list=$(python3 -B "$T3_LIB_DIR/t3_projects.py" "$db" 2>/dev/null) || return 0
  [ -n "$list" ] && mapfile -t roots <<< "$list"
  if [ -f "$f" ]; then
    while IFS=$'\t' read -r p url; do [ -n "$p" ] && [ -n "$url" ] && remote[$p]=$url; done < "$f"
  fi
  for p in "${roots[@]}"; do
    if [ ! -e "$p" ]; then
      url=${remote[$p]:-}
      if [ -z "$url" ]; then
        t3_say "project missing, no remote recorded: $p"
      elif mkdir -p "$(dirname "$p")" \
          && GIT_TERMINAL_PROMPT=0 timeout "$T3_CLONE_TIMEOUT" git clone -q "$url" "$p" </dev/null >&2; then
        t3_say "project restored: $p"
      else
        t3_say "project missing, clone of $url failed: $p"
      fi
    fi
    url=${remote[$p]:-}
    if [ "$(git -C "$p" rev-parse --show-toplevel 2>/dev/null)" = "$(readlink -f "$p")" ]; then
      url=$(git -C "$p" remote get-url origin 2>/dev/null) || url=${remote[$p]:-}
    fi
    [ -n "$url" ] && out+="$p"$'\t'"$url"$'\n'
  done
  out=${out%$'\n'}
  if [ -z "$out" ]; then rm -f "$f"
  elif [ "$out" != "$(cat "$f" 2>/dev/null)" ]; then t3_write_file "$f" "$out" || true
  fi
  return 0
}

t3_cmd_projects() {
  [ $# -eq 0 ] || t3_die "usage: t3-projects"
  t3_entry
  t3_projects_restore
  [ -s "$T3_STATE/projects.tsv" ] && cat "$T3_STATE/projects.tsv"
  return 0
}
