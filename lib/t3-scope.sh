# /proc helpers. Builtins only (read, mapfile) so a scan forks nothing and a
# sample every second stays cheap. A stat line is "pid (comm) state ppid pgrp
# session ..."; comm may hold spaces, so fields are split after the last ")".

t3_stat() {
  local line rest
  read -r line 2>/dev/null < "/proc/$1/stat" || return 1
  rest=${line##*) }
  read -r -a _t3f <<< "$rest"
  T3S_PPID=${_t3f[1]} T3S_SID=${_t3f[3]} T3S_START=${_t3f[19]}
  T3S_CPU=$(( _t3f[11] + _t3f[12] + _t3f[13] + _t3f[14] ))
}

t3_proc_env_has() {
  local -a e; local x
  mapfile -d '' -t e 2>/dev/null < "/proc/$1/environ" || return 1
  for x in "${e[@]}"; do [ "$x" = "$2" ] && return 0; done
  return 1
}

t3_proc_env_value() {
  local -a e; local x
  mapfile -d '' -t e 2>/dev/null < "/proc/$1/environ" || return 1
  for x in "${e[@]}"; do [ "${x%%=*}" = "$2" ] && { printf '%s\n' "${x#*=}"; return 0; }; done
  return 1
}

# comm, except for node and bun launchers, where the script name says more.
t3_proc_name() {
  local comm; local -a a
  read -r comm 2>/dev/null < "/proc/$1/comm" || return 1
  case "$comm" in
    node|bun|MainThread)
      mapfile -d '' -t a 2>/dev/null < "/proc/$1/cmdline"
      [ -n "${a[1]:-}" ] && { printf '%s\n' "${a[1]##*/}"; return 0; } ;;
  esac
  printf '%s\n' "$comm"
}

# Scope: descendants of the supervisor, members of its session, and anything
# carrying its owner token; then everything below those. The supervisor, this
# shell and T3_SCOPE_EXCLUDE are left out.
t3_scope() {
  local super=$1 sid=$2 token=$3 p changed x
  local -A parent=() in=() skip=()
  local -a all=()
  skip[$super]=1; skip[$$]=1; skip[$BASHPID]=1
  for x in ${T3_SCOPE_EXCLUDE:-}; do skip[$x]=1; done
  for p in /proc/[0-9]*; do
    p=${p#/proc/}
    t3_stat "$p" || continue
    all+=("$p"); parent[$p]=$T3S_PPID
    if [ -n "$sid" ] && [ "$T3S_SID" = "$sid" ]; then in[$p]=1
    elif [ -n "$token" ] && t3_proc_env_has "$p" "T3_AICODING_OWNER=$token"; then in[$p]=1
    fi
  done
  in[$super]=1
  changed=1
  while [ "$changed" = 1 ]; do
    changed=0
    for p in "${all[@]}"; do
      [ -n "${in[$p]:-}" ] && continue
      if [ -n "${in[${parent[$p]}]:-}" ]; then in[$p]=1; changed=1; fi
    done
  done
  T3_SCOPE=()
  for p in "${all[@]}"; do
    [ -n "${in[$p]:-}" ] && [ -z "${skip[$p]:-}" ] && T3_SCOPE+=("$p")
  done
}
