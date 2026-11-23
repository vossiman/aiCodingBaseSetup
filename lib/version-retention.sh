# lib/version-retention.sh: host-only pruning of provably unused releases.
# A directory versions/<component>/<name> is removed only when every keep rule
# below has cleared it on every run for a whole observation window; anything
# unclear keeps it. Containers never prune: a rebuild wipes the tree anyway.
# Sourced; does not change shell options.
#
#   AICODING_RETENTION        unset|on (remove), preview (log only), off
#   AICODING_RETENTION_GRACE  seconds a version must stay unreferenced and
#                             unused before removal (default 7 days when
#                             unset; an empty value removes nothing)

: "${AICODING_DATA_DIR:=$HOME/.local/share/aicoding}"
: "${AICODING_STATE_DIR:=$HOME/.local/state/aicoding}"

_AICODING_RETENTION_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_AICODING_RETENTION_SEG='[A-Za-z0-9][A-Za-z0-9._+-]*'
_AICODING_RETENTION_MARKER='# Managed by aicoding immutable runtime.'

_aicoding_retention_say() { printf 'aicoding retention: %s\n' "$*"; }
_aicoding_retention_warn() { printf 'aicoding retention: WARN: %s\n' "$*" >&2; }

_aicoding_retention_safe() { [[ "$1" =~ ^${_AICODING_RETENTION_SEG}$ ]]; }

# A release name: a safe segment that is not a staging directory and not a
# release set aside by an in-place rebuild (aicoding_update_bw: <sha>.replaced.<pid>).
_aicoding_retention_release_name() {
  _aicoding_retention_safe "$1" || return 1
  case "$1" in *.staging.*|*.replaced.*) return 1 ;; esac
}

# The same host test as sync: an explicit host profile and no container runtime.
_aicoding_retention_is_host() (
  [ -f "$_AICODING_RETENTION_LIB/sync.sh" ] || exit 1
  . "$_AICODING_RETENTION_LIB/sync.sh" >/dev/null 2>&1 || exit 1
  declare -F _sync_profile >/dev/null && declare -F _sync_is_container_runtime >/dev/null || exit 1
  case "$(_sync_profile)" in host|minimal-pi) ;; *) exit 1 ;; esac
  if _sync_is_container_runtime; then exit 1; fi
  exit 0
)

_aicoding_retention_human() {
  awk -v k="$1" 'BEGIN {
    if (k >= 1048576) printf "%.1f GiB", k / 1048576
    else if (k >= 1024) printf "%.1f MiB", k / 1024
    else printf "%d KiB", k
  }'
}

_aicoding_retention_date() { date -d "@$1" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '@%s' "$1"; }

# Mark the version a canonical path lies inside; with a PID, record it as held.
_aicoding_retention_mark_path() {
  local path=$1 pid=${2:-} rest comp name
  case "$path" in "$_vroot"/*) ;; *) return 0 ;; esac
  rest=${path#"$_vroot"/}
  comp=${rest%%/*}
  name=${rest#*/}
  comp=${comp%% (deleted)}
  if [ -n "$pid" ]; then held[$pid]=1; held_comp[$pid/$comp]=1; fi
  # Directly inside versions/<component> (e.g. a cwd there): keep the component.
  if [ "$name" = "$rest" ] || [ -z "$name" ]; then keep_comp[$comp]=1; return 0; fi
  name=${name%%/*}
  name=${name%% (deleted)}
  used[$comp/$name]=1
}

# Mark every versions/<component>/<name> token in text read from stdin.
_aicoding_retention_mark_tokens() {
  local token rest
  while IFS= read -r token; do
    rest=${token#versions/}
    used[$rest]=1
  done
}

# Record in bad[] the PID each error line in FILE names; 1 if a line names none.
_aicoding_retention_attribute_errors() {
  local file=$1 line rest p
  [ -s "$file" ] || return 0
  while IFS= read -r line; do
    case "$line" in *"$proc/"[0-9]*) ;; *) return 1 ;; esac
    rest=${line#*"$proc/"}
    p=${rest%%[!0-9]*}
    [ -n "$p" ] || return 1
    bad[$p]=1
  done < "$file"
}

_aicoding_retention_glob_quote() {
  local s=${1//\\/\\\\}
  s=${s//\*/\\*}; s=${s//\?/\\?}; s=${s//\[/\\[}
  printf '%s' "$s"
}

# Interpreters whose first operand is the program they run.
_aicoding_retention_interpreter() {
  case "$1" in python|python3|node|nodejs|bash|sh|dash|perl|ruby|bun) return 0 ;; esac
  [[ "$1" =~ ^python3\.[0-9]+$ ]]
}

# Set _belongs to the components a process's comm and argv name, and
# _belongs_known to those whose release the program itself names: the whole
# argv[0], or an interpreter's argv[1], is a canonical path inside it.
# EXE is the process's executable link, empty when it could not be read.
_aicoding_retention_belongs() {
  local comm=$1 exe=$2 arg d rest c base kind ebase= foreign=0 m prog=
  local re="^(${_AICODING_RETENTION_SEG})(/(${_AICODING_RETENTION_SEG}))?"
  local -A named_rel=() named_cur=()
  shift 2
  _belongs=""
  _belongs_known=""
  # Each occurrence counts on its own, so one argument can name several paths.
  for arg in "$@"; do
    for d in "${data_prefixes[@]}"; do
      for kind in current versions; do
        rest=$arg
        while [[ "$rest" == *"$d/$kind/"* ]]; do
          rest=${rest#*"$d/$kind/"}
          [[ "$rest" =~ $re ]] || continue
          c=${BASH_REMATCH[1]}
          _belongs+=" $c"
          # A path with . or .. segments may name another release than it seems
          # to; each entry of a : or , separated list counts as a path.
          case "${arg//[:,]//}" in */../*|*/./*|*/..|*/.) keep_comp[$c]=1 ;; esac
          [ "$kind" = versions ] || { named_cur[$c]=1; continue; }
          # A named release is used, whatever the process holds open.
          [ -z "${BASH_REMATCH[3]}" ] || used[$c/${BASH_REMATCH[3]}]=1
        done
      done
    done
  done
  if [ "$#" -gt 0 ]; then
    prog=$1
    if _aicoding_retention_interpreter "${1##*/}"; then prog=${2:-}; fi
    case "$prog" in */../*|*/./*|*/..|*/.) prog= ;; esac
    for d in "${data_prefixes[@]}"; do
      [[ "$prog" == "$d/versions/"* ]] || continue
      rest=${prog#"$d/versions/"}
      [[ "$rest" =~ ^(${_AICODING_RETENTION_SEG})/${_AICODING_RETENTION_SEG}/. ]] && named_rel[${BASH_REMATCH[1]}]=1
    done
  fi
  for c in "${!named_rel[@]}"; do
    [ -n "${named_cur[$c]:-}" ] || _belongs_known+=" $c"
  done
  # An executable outside the managed trees with the matched name is another
  # program that only shares the launcher's name.
  exe=${exe% (deleted)}
  if [[ "$exe" == /* ]]; then
    foreign=1
    for m in "${managed[@]}"; do
      case "$exe" in "$m"/*|"$m") foreign=0 ;; esac
    done
    ebase=${exe##*/}
  fi
  if [ "$#" -gt 0 ]; then
    base=${1##*/}
    [ -z "${launcher_comp[$base]:-}" ] || { [ "$foreign" = 1 ] && [ "$ebase" = "$base" ]; } \
      || _belongs+="${launcher_comp[$base]}"
  fi
  [ -z "$comm" ] || [ -z "${comm_comp[$comm]:-}" ] || { [ "$foreign" = 1 ] && [ "${ebase:0:15}" = "$comm" ]; } \
    || _belongs+="${comm_comp[$comm]}"
  return 0
}

# Set _stat_state and _stat_start (field 22) from $proc/PID/stat; 1 if unreadable.
_aicoding_retention_stat() {
  local st= f
  { IFS= read -r -d '' st < "$proc/$1/stat"; } 2>/dev/null || :
  # The name in parentheses may contain anything, so parse after the last ')'.
  [[ "$st" == *')'* ]] || return 1
  read -r -a f <<< "${st##*)}"
  _stat_state=${f[0]:-}
  _stat_start=${f[19]:-}
  [ -n "$_stat_state" ] && [[ "$_stat_start" =~ ^[0-9]+$ ]]
}

# Batched status, find (exe, cwd, fd) and maps passes over the user's processes.
# Returns 1 when the scan is incomplete or an uninspectable process is relevant.
_aicoding_retention_scan_proc() {
  # Test-only override of the proc root for the whole process scan.
  local proc=${_AICODING_RETENTION_PROC:-/proc}
  # Bytes throughout: under UTF-8, read joins a line cut mid-character to the next.
  local LC_ALL=C
  local me=$BASHPID end=aicoding-retention-scan-end line rest p kind val uid euid
  local path target arg m c q i comm hit depth st_ended=0 fd_ended=0 map_ended=0 rc=0 _belongs _belongs_known
  local -a status_files=() mine=() starts=() maps=() args=() managed=()
  local -A ppid=() pstate=() pstart=() pname=() is_mine=() bad=() seen_exe=() seen_cwd=() exe_of=()
  local _stat_state _stat_start
  local -A belongs=() known=() inspected=() warned=()
  for m in "$AICODING_DATA_DIR" "$data" "$HOME/.local/bin" "$(readlink -e -- "$HOME/.local/bin" 2>/dev/null)"; do
    [ -n "$m" ] || continue
    while [[ "$m" == *//* ]]; do m=${m//\/\//\/}; done
    while [ "${m%/}" != "$m" ]; do m=${m%/}; done
    [ -n "$m" ] && managed+=("$m")
  done
  status_files=("$proc"/[0-9]*/status)
  [ "${#status_files[@]}" -gt 0 ] && [ -e "${status_files[0]}" ] || return 1
  # status is world-readable even when the rest of /proc/<pid> is not.
  : > "$_work/status.err"
  while IFS= read -r line; do
    [ "$line" = "$end" ] && { st_ended=1; continue; }
    rest=${line#"$proc"/}
    p=${rest%%/*}
    [[ "$p" =~ ^[0-9]+$ ]] || continue
    val=${rest#*/status:}
    case "$val" in
      Uid:*)
        read -r uid euid _ <<< "${val#Uid:}"
        if [ "$uid" = "$UID" ] || [ "$euid" = "$UID" ]; then is_mine[$p]=1; fi ;;
      PPid:*) read -r "ppid[$p]" <<< "${val#PPid:}" ;;
      State:*) read -r "pstate[$p]" _ <<< "${val#State:}" ;;
      Name:*) val=${val#Name:}; pname[$p]=${val#$'\t'} ;;
    esac
  done < <(s=0; LC_ALL=C grep -H -E '^(Name|State|PPid|Uid):' -- "${status_files[@]}" 2>"$_work/status.err" || s=$?
           [ "$s" -lt 126 ] && printf '%s\n' "$end")
  [ "$st_ended" = 1 ] || return 1
  _aicoding_retention_attribute_errors "$_work/status.err" || return 1
  # A status file that failed to read belongs to a process that must be gone.
  for p in "${!bad[@]}"; do
    [ ! -e "$proc/$p" ] || return 1
  done
  bad=()
  for p in "${!is_mine[@]}"; do
    case "${pstate[$p]:-}" in Z|X) continue ;; esac
    _aicoding_retention_stat "$p" && pstart[$p]=$_stat_start
    mine+=("$p")
    starts+=("$proc/$p/fd" "$proc/$p/cwd" "$proc/$p/exe")
    maps+=("$proc/$p/maps")
  done
  if [ "$proc" = /proc ]; then [ -n "${is_mine[$me]:-}" ] || return 1; fi
  [ "${#mine[@]}" -gt 0 ] || return 0

  # Only descriptors that point into versions/ are printed; there are many.
  local gproc gvroot
  gproc=$(_aicoding_retention_glob_quote "$proc")
  gvroot=$(_aicoding_retention_glob_quote "$_vroot")
  while IFS= read -r -d '' path && IFS= read -r -d '' target; do
    [ "$path" = "$end" ] && { fd_ended=1; continue; }
    rest=${path#"$proc"/}
    p=${rest%%/*}
    kind=${rest#*/}
    [ -n "$target" ] || continue
    case "$kind" in exe) seen_exe[$p]=1; exe_of[$p]=$target ;; cwd) seen_cwd[$p]=1 ;; esac
    case "$target" in "$_vroot"/*) _aicoding_retention_mark_path "$target" "$p" ;; esac
  done < <(s=0; LC_ALL=C find "${starts[@]}" -maxdepth 1 \
             \( ! -path "$gproc/*/fd/*" -o -lname "$gvroot/*" \) -printf '%p\0%l\0' 2>"$_work/find.err" || s=$?
           [ "$s" -lt 126 ] && printf '%s\0\0' "$end")
  [ "$fd_ended" = 1 ] || return 1
  _aicoding_retention_attribute_errors "$_work/find.err" || return 1
  local self_map=0
  while IFS= read -r line; do
    [ "$line" = "$end" ] && { map_ended=1; continue; }
    rest=${line#"$proc"/}
    p=${rest%%/*}
    [ "$p" != "$me" ] || case "$line" in *'[stack]'*) self_map=1 ;; esac
    case "$line" in *" $_vroot/"*) _aicoding_retention_mark_path "$_vroot/${line#*" $_vroot/"}" "$p" ;; esac
  done < <(s=0; LC_ALL=C grep -H -F -e "$_vroot/" -e '[stack]' -- "${maps[@]}" 2>"$_work/maps.err" || s=$?
           [ "$s" -lt 126 ] && printf '%s\n' "$end")
  [ "$map_ended" = 1 ] || return 1
  _aicoding_retention_attribute_errors "$_work/maps.err" || return 1
  # Our own entries prove each scan really ran over the live proc tree.
  if [ "$proc" = /proc ]; then
    [ -n "${seen_exe[$me]:-}" ] && [ -z "${bad[$me]:-}" ] && [ "$self_map" = 1 ] || return 1
  fi

  # Command lines: membership for every process, relevance for unreadable ones.
  local -A cmd_ok=() cmd_managed=()
  for p in "${mine[@]}"; do
    [ -z "${bad[$p]:-}" ] && [ -n "${seen_exe[$p]:-}" ] && [ -n "${seen_cwd[$p]:-}" ] && inspected[$p]=1
    args=()
    if mapfile -d '' -t args 2>/dev/null < "$proc/$p/cmdline"; then
      cmd_ok[$p]=1
      # a//b names a/b: collapse repeated separators before any match.
      for i in "${!args[@]}"; do
        while [[ "${args[$i]}" == *//* ]]; do args[$i]=${args[$i]//\/\//\/}; done
      done
      for arg in "${args[@]}"; do
        for m in "${managed[@]}"; do
          case "$arg" in *"$m/"*|*"$m") cmd_managed[$p]=1; break 2 ;; esac
        done
      done
    fi
    comm=${pname[$p]:-}
    _aicoding_retention_belongs "$comm" "${exe_of[$p]:-}" "${args[@]}"
    belongs[$p]=$_belongs
    known[$p]=$_belongs_known
  done

  for p in "${mine[@]}"; do
    [ -z "${inspected[$p]:-}" ] || continue
    # A process that exited meanwhile uses nothing.
    [ -e "$proc/$p" ] || continue
    hit=
    if [ -z "${cmd_ok[$p]:-}" ]; then
      hit="its command line cannot be read"
    elif [ -n "${cmd_managed[$p]:-}" ]; then
      hit="runs from a managed path"
    elif [ -n "${belongs[$p]}" ]; then
      hit="runs a managed launcher"
    else
      q=${ppid[$p]:-0}
      local -A walked=([$p]=1)
      for ((depth = 0; depth < 64; depth++)); do
        [[ "$q" =~ ^[1-9][0-9]*$ ]] && [ "$q" != 1 ] || break
        if [ -n "${walked[$q]:-}" ]; then
          hit="has a parent chain that loops"
          break
        fi
        walked[$q]=1
        if [ -n "${held[$q]:-}" ] || [ -n "${belongs[$q]:-}" ]; then
          hit="descends from a process that uses a managed release"
          break
        fi
        q=${ppid[$q]:-0}
      done
      unset walked
    fi
    [ -n "$hit" ] || continue
    comm=${pname[$p]:-?}
    _aicoding_retention_warn "process $p (${comm//[![:print:]]/?}) cannot be inspected and $hit; nothing removed"
    rc=1
  done
  [ "$rc" -eq 0 ] || return 1
  _aicoding_retention_scan_settled || return 1

  # Unknown-release rule: a process of component C that holds nothing of C,
  # unless its program is a path inside the physical release it runs.
  for p in "${mine[@]}"; do
    [ -n "${inspected[$p]:-}" ] && [ -n "${belongs[$p]}" ] || continue
    for c in ${belongs[$p]}; do
      [ -z "${held_comp[$p/$c]:-}" ] || continue
      case " ${known[$p]} " in *" $c "*) continue ;; esac
      keep_comp[$c]=1
      [ -n "${comp_known[$c]:-}" ] && [ -z "${warned[$p/$c]:-}" ] || continue
      warned[$p/$c]=1
      comm=${pname[$p]:-?}
      _aicoding_retention_say "process $p (${comm//[![:print:]]/?}) runs $c from a release it does not hold open; keeping every $c version"
    done
  done
  return 0
}

# One second listing of the process tree, after the scans (uses the scan's
# variables). A process that used a managed release and has exited, or a new
# child of one, may have carried a use past the snapshot: 1 in that case.
# Our own helper processes come and go and are ignored.
_aicoding_retention_scan_settled() {
  local p q depth path line pp
  local -A listed=() relevant=() now=()
  for path in "${status_files[@]}"; do
    p=${path#"$proc"/}; listed[${p%%/*}]=1
  done
  for p in "${mine[@]}"; do
    [ -n "${held[$p]:-}" ] || [ -n "${belongs[$p]:-}" ] || continue
    q=$p
    for ((depth = 0; depth < 64; depth++)); do
      [ "$q" != "$me" ] || continue 2
      q=${ppid[$q]:-0}
      [[ "$q" =~ ^[1-9][0-9]*$ ]] || break
    done
    relevant[$p]=1
  done
  [ "${#relevant[@]}" -gt 0 ] || return 0
  for path in "$proc"/[0-9]*; do now[${path##*/}]=1; done
  for p in "${!relevant[@]}"; do
    # A zombie, or a reused PID, may have handed its use to a reparented child.
    if [ -n "${now[$p]:-}" ] && [ -n "${pstart[$p]:-}" ] && _aicoding_retention_stat "$p" \
        && [ "$_stat_start" = "${pstart[$p]}" ]; then
      case "$_stat_state" in Z|X) ;; *) continue ;; esac
    fi
    _aicoding_retention_say "process $p, which used a managed release, exited or was replaced during the scan"
    return 1
  done
  for p in "${!now[@]}"; do
    [ -z "${listed[$p]:-}" ] || continue
    pp=
    while IFS= read -r line; do
      case "$line" in PPid:*) read -r pp <<< "${line#PPid:}"; break ;; esac
    done 2>/dev/null < "$proc/$p/status" || continue
    [ -n "$pp" ] && [ -n "${relevant[$pp]:-}" ] || continue
    _aicoding_retention_say "process $pp, which uses a managed release, started a child during the scan"
    return 1
  done
  return 0
}

# Mark every release a link's resolution steps through, except the link's own
# release; walk_comps records what it touched. Returns 2 when a step is
# missing, with its path in walk_miss, 1 when the resolution cannot be
# followed for another reason.
_aicoding_retention_walk_link() {
  local link=$1 raw=$2 owner=$3 cur rest part nxt t r c n=0
  cur=${link%/*}
  rest=$raw
  [[ "$rest" != /* ]] || cur=
  while [ -n "$rest" ]; do
    part=${rest%%/*}
    if [[ "$rest" == */* ]]; then rest=${rest#*/}; else rest=; fi
    case "$part" in
      ''|.) continue ;;
      ..) cur=${cur%/*}; continue ;;
    esac
    nxt="$cur/$part"
    case "$nxt" in
      "$_vroot"/*/*)
        r=${nxt#"$_vroot"/}; c=${r%%/*}; r=${r#*/}; r=${r%%/*}
        walk_comps[$c]=1
        [ "$c/$r" = "$owner" ] || used[$c/$r]=1 ;;
      "$_vroot"/*) r=${nxt#"$_vroot"/}; walk_comps[$r]=1 ;;
    esac
    if [ -L "$nxt" ]; then
      n=$((n + 1))
      [ "$n" -le 40 ] || return 1
      if [ -n "${link_raw[$nxt]+x}" ]; then
        t=${link_raw[$nxt]}
      else
        t=$(readlink -- "$nxt" 2>/dev/null) || return 1
      fi
      [ -n "$t" ] || return 1
      [[ "$t" != /* ]] || cur=
      rest="$t${rest:+/$rest}"
      continue
    fi
    [ -e "$nxt" ] || { walk_miss=$nxt; return 2; }
    cur=$nxt
  done
  return 0
}

# Walk one link; when it cannot be followed, keep every component it touched.
# A link whose missing step lies inside its own release, whether its text is
# relative or absolute, cannot lead anywhere else and keeps nothing.
_aicoding_retention_follow_link() {
  local link=$1 raw=$2 owner=$3 rc=0 c walk_miss=
  walk_comps=()
  _aicoding_retention_walk_link "$link" "$raw" "$owner" || rc=$?
  walk_rc=$rc
  [ "$rc" -ne 0 ] || return 0
  if [ "$rc" -eq 2 ] && [ -n "$owner" ]; then
    case "$walk_miss" in "$_vroot/$owner"/*) return 0 ;; esac
  fi
  for c in "${!walk_comps[@]}"; do keep_comp[$c]=1; done
}

# Every symlink under DIR: each release its resolution steps through keeps that
# version, unless the link itself lives inside that same version. When a chain
# cannot be followed, every component it touched is kept. Returns 1 if the
# listing failed.
_aicoding_retention_scan_links() {
  local dir=$1 i owner rest comp name walk_rc
  local -a links=() raws=() pairs=() targets=()
  local -A link_raw=() walk_comps=()
  mapfile -d '' pairs < <(find "$dir" -type l -printf '%p\0%l\0' 2>/dev/null; printf 'rc=%s\0\0' "$?")
  [ "${#pairs[@]}" -ge 2 ] || return 1
  [ "${pairs[-2]}" = rc=0 ] || return 1
  for ((i = 0; i + 2 < ${#pairs[@]}; i += 2)); do
    links+=("${pairs[$i]}"); raws+=("${pairs[$((i + 1))]}")
    link_raw[${pairs[$i]}]=${pairs[$((i + 1))]}
  done
  [ "${#links[@]}" -gt 0 ] || return 0
  mapfile -t targets < <(printf '%s\0' "${links[@]}" | xargs -0 readlink -m -- 2>/dev/null; printf 'rc=%s\n' "$?")
  [ "${targets[-1]}" = rc=0 ] || return 1
  unset 'targets[-1]'
  # A newline in a path would misalign the two lists.
  [ "${#targets[@]}" -eq "${#links[@]}" ] || return 1
  for ((i = 0; i < ${#links[@]}; i++)); do
    owner=
    case "${links[$i]}" in
      "$_vroot"/*/*/*)
        rest=${links[$i]#"$_vroot"/}; comp=${rest%%/*}; name=${rest#*/}; name=${name%%/*}
        owner="$comp/$name" ;;
    esac
    _aicoding_retention_follow_link "${links[$i]}" "${raws[$i]}" "$owner"
    # Past a missing step, readlink -m only guesses; the walk already kept what it touched.
    [ "$walk_rc" -ne 2 ] || continue
    if [ -n "$owner" ]; then
      case "${targets[$i]}" in "$_vroot/$owner"|"$_vroot/$owner"/*) continue ;; esac
    fi
    _aicoding_retention_mark_path "${targets[$i]}"
  done
}

# Managed launchers and legacy links in ~/.local/bin; maps launcher names to
# components. Returns 1 on a read error.
_aicoding_retention_scan_bin() {
  local bin=$1 rc file line comp name walk_rc
  local -a files=() managed_files=() link_files=()
  local -A link_raw=() walk_comps=()
  [ -e "$bin" ] || [ -L "$bin" ] || return 0
  [[ "$bin" == /* ]] || return 1
  # Every release on the way to it keeps, not only the final directory.
  _aicoding_retention_follow_link "$bin" "$bin" ""
  # find does not descend into a symlinked start directory.
  bin=$(readlink -e -- "$bin") || return 1
  # The launcher directory itself may live inside a release.
  _aicoding_retention_mark_path "$bin"
  [ -d "$bin" ] || return 0
  _aicoding_retention_scan_links_bin "$bin" || return 1
  mapfile -d '' files < <(find "$bin" -type f -print0 2>/dev/null; printf 'rc=%s\0' "$?")
  [ "${files[-1]:-}" = rc=0 ] || return 1
  unset 'files[-1]'
  [ "$((${#files[@]} + ${#link_files[@]}))" -gt 0 ] || return 0
  rc=0
  # Regular files that links point to are read too, wherever they live.
  grep -aohE "versions/${_AICODING_RETENTION_SEG}/${_AICODING_RETENTION_SEG}" \
    -- "${files[@]}" "${link_files[@]}" > "$_work/bin-tokens" 2>/dev/null || rc=$?
  # 1 is "no match"; 2 is a file that could not be read.
  [ "$rc" -le 1 ] || return 1
  _aicoding_retention_mark_tokens < "$_work/bin-tokens"
  [ "${#files[@]}" -gt 0 ] || return 0
  rc=0
  mapfile -d '' managed_files < <(grep -lZxF -e "$_AICODING_RETENTION_MARKER" -- "${files[@]}" 2>/dev/null || rc=$?
                                  printf 'rc=%s\0' "$rc")
  [ "${managed_files[-1]:-}" = rc=0 ] || [ "${managed_files[-1]:-}" = rc=1 ] || return 1
  unset 'managed_files[-1]'
  [ "${#managed_files[@]}" -gt 0 ] || return 0
  while IFS= read -r -d '' file && IFS= read -r line; do
    [[ "$line" == current=*/current/* ]] || continue
    comp=${line##*/current/}
    comp=${comp%\'}; comp=${comp%\"}
    _aicoding_retention_safe "$comp" || continue
    _aicoding_retention_add_launcher "${file##*/}" "$comp"
  done < <(grep -HZ -m1 '^current=' -- "${managed_files[@]}" 2>/dev/null)
  return 0
}

# comm is the first 15 bytes of the executable name.
_aicoding_retention_add_launcher() {
  local name=$1 comp=$2
  launcher_comp[$name]+=" $comp"
  # Bytes, not characters, as the kernel cuts it.
  local LC_ALL=C
  comm_comp[${name:0:15}]+=" $comp"
}

_aicoding_retention_scan_links_bin() {
  local bin=$1 path raw real rest
  local -A link_raw=() walk_comps=()
  while IFS= read -r -d '' path && IFS= read -r -d '' raw; do
    [ "$path" = aicoding-retention-scan-end ] && return 0
    # Every release on the way keeps, not only the final target.
    _aicoding_retention_follow_link "$path" "$raw" ""
    real=$(readlink -m -- "$path" 2>/dev/null)
    _aicoding_retention_mark_path "$real"
    [ ! -f "$real" ] || link_files+=("$real")
    case "$real" in
      "$_vroot"/*/*)
        rest=${real#"$_vroot"/}
        _aicoding_retention_safe "${rest%%/*}" && _aicoding_retention_add_launcher "${path##*/}" "${rest%%/*}" ;;
    esac
    _aicoding_retention_mark_tokens < <(printf '%s\n' "$raw" \
      | grep -aoE "versions/${_AICODING_RETENTION_SEG}/${_AICODING_RETENTION_SEG}")
  done < <(find "$bin" -type l -printf '%p\0%l\0' 2>/dev/null \
           && printf '%s\0\0' aicoding-retention-scan-end)
  return 1
}

# Mount points, still octal-escaped; same-filesystem bind mounts appear too.
_aicoding_retention_read_mounts() {
  local file=${_AICODING_RETENTION_PROC:-/proc}/self/mountinfo line mp
  mounts=()
  [ -r "$file" ] || return 1
  while IFS= read -r line; do
    read -r _ _ _ _ mp _ <<< "$line"
    [ -n "$mp" ] && mounts+=("$mp")
  done < "$file" || return 1
  [ "${#mounts[@]}" -gt 0 ]
}

# Is a mount point at or below DIR?
_aicoding_retention_has_mount() {
  local e=$1 mp
  e=${e//\\/\\134}; e=${e// /\\040}; e=${e//$'\t'/\\011}; e=${e//$'\n'/\\012}
  for mp in "${mounts[@]}"; do
    [ "$mp" = "$e" ] && return 0
    case "$mp" in "$e"/*) return 0 ;; esac
  done
  return 1
}

# A pointer is valid only when its own target (one readlink, not the resolved
# path) is exactly versions/<comp>/<name>, a real release directory.
_aicoding_retention_pointer_ok() {
  local comp=$1 link=$2 raw name= m
  [ -L "$link" ] && raw=$(readlink -- "$link") || return 1
  case "$raw" in "../versions/$comp/"*) name=${raw#"../versions/$comp/"} ;; esac
  for m in "${data_prefixes[@]}"; do
    case "$raw" in "$m/versions/$comp/"*) name=${raw#"$m/versions/$comp/"} ;; esac
  done
  _aicoding_retention_release_name "$name" || return 1
  [ -d "$_vroot/$comp/$name" ] && [ ! -L "$_vroot/$comp/$name" ]
}

# Remove one version: re-verify, rename into a dot-prefixed tombstone, delete.
# Returns 1 when nothing changed, 3 when the tombstone could not be deleted or
# a mount appeared in it, 4 when a mount point lies inside, 5 when a process
# holds a launcher lease.
_aicoding_retention_remove() {
  local comp=$1 name=$2 dir tomb real lfd rc
  dir="$_vroot/$comp/$name"
  _aicoding_retention_safe "$comp" && _aicoding_retention_safe "$name" || return 1
  [ -d "$_vroot/$comp" ] && [ ! -L "$_vroot/$comp" ] || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  real=$(readlink -e -- "$dir") || return 1
  [ "$real" = "$dir" ] || return 1
  # Held until the rename: no launcher can take a new lease meanwhile.
  { command exec {lfd}<"$dir"; } 2>/dev/null || return 1
  if ! flock -x -n "$lfd" 2>/dev/null; then
    exec {lfd}<&-
    return 5
  fi
  tomb=$(mktemp -d "$_vroot/$comp/.aicoding-retired.$name.XXXXXX" 2>/dev/null) || { exec {lfd}<&-; return 1; }
  # The mount table is read again right before the rename, and again before the delete.
  rc=0
  if ! _aicoding_retention_read_mounts; then rc=1
  elif _aicoding_retention_has_mount "$dir"; then rc=4
  elif ! mv -T -- "$dir" "$tomb/item" 2>/dev/null; then rc=1
  fi
  if [ "$rc" -ne 0 ]; then
    exec {lfd}<&-
    rmdir -- "$tomb" 2>/dev/null || true
    return "$rc"
  fi
  exec {lfd}<&-
  _retired_left=$tomb
  if ! _aicoding_retention_read_mounts; then
    _aicoding_retention_warn "cannot read the mount table; $tomb not deleted"
    return 3
  fi
  if _aicoding_retention_has_mount "$tomb"; then
    _aicoding_retention_warn "$tomb contains a mount point; not deleted"
    return 3
  fi
  _aicoding_retention_delete_tree "$tomb" || return 3
  _retired_left=
}

# 0 when no process holds a launcher lease on DIR, 1 when one does, 2 when
# DIR cannot be opened. The test lock is dropped again at once.
_aicoding_retention_lease_free() {
  local lfd rc=0
  { command exec {lfd}<"$1"; } 2>/dev/null || return 2
  flock -x -n "$lfd" 2>/dev/null || rc=1
  exec {lfd}<&-
  return "$rc"
}

# Is STAMP absent or a regular file? Anything else is left alone with a warning.
_aicoding_retention_stamp_plain() {
  { [ -e "$1" ] || [ -L "$1" ]; } || return 0
  [ -f "$1" ] && [ ! -L "$1" ] && return 0
  _aicoding_retention_warn "$1 is not a regular file; left in place, $2 kept"
  return 1
}

# Delete a stamp so the window starts again; 1 when the entry is not a regular
# file or cannot be deleted. A stamp that survives its reset would be trusted
# later, so its component (LABEL is component/version) is kept for this run.
_aicoding_retention_stamp_drop() {
  _aicoding_retention_stamp_plain "$1" "$2" || return 1
  rm -f -- "$1" 2>/dev/null && { [ ! -e "$1" ] && [ ! -L "$1" ]; } && return 0
  _aicoding_retention_warn "cannot delete $1; keeping every ${2%%/*} version this run"
  keep_comp[${2%%/*}]=1
  return 1
}

# Build caches can leave read-only directories; restore access to directories
# only, since a file may be hard-linked from outside the tree.
_aicoding_retention_delete_tree() {
  rm -rf --one-file-system -- "$1" 2>/dev/null && return 0
  find "$1" -xdev -type d ! -perm -u=rwx -exec chmod u+rwx -- {} \; 2>/dev/null || true
  rm -rf --one-file-system -- "$1" 2>/dev/null
}

_aicoding_retention_main() {
  # The default applies only when unset: an empty value is invalid.
  local mode=${AICODING_RETENTION:-on} grace=${AICODING_RETENTION_GRACE-604800}
  case "$mode" in
    off) return 0 ;;
    on|remove) mode=remove ;;
    preview) ;;
    *) _aicoding_retention_warn "unknown AICODING_RETENTION=$mode (use on, preview or off); nothing removed"; return 0 ;;
  esac
  if ! _aicoding_retention_is_host; then
    [ "$mode" != preview ] || _aicoding_retention_say "not a host; containers keep every staged version"
    return 0
  fi
  # Decimal only (a leading zero is not octal), at most ten years.
  [[ "$grace" =~ ^[0-9]+$ ]] && grace=${grace#"${grace%%[!0]*}"} && grace=${grace:-0} \
    && [ "${#grace}" -le 9 ] && [ "$((10#$grace))" -le 315360000 ] || {
    _aicoding_retention_warn "AICODING_RETENTION_GRACE must be whole seconds, at most 315360000; nothing removed"
    return 0
  }
  grace=$((10#$grace))
  [ -d "$AICODING_DATA_DIR/versions" ] || return 0
  shopt -u dotglob
  shopt -s nullglob

  # Without flock neither the update lock nor a launcher lease can be checked.
  if ! command -v flock >/dev/null 2>&1; then
    _aicoding_retention_warn "flock is not installed, so launcher leases cannot be checked; nothing removed"
    return 0
  fi

  # The whole-run update lock: no sync or install can activate meanwhile.
  local sync_fd
  mkdir -p "$AICODING_STATE_DIR" 2>/dev/null || true
  exec {sync_fd}>>"$AICODING_STATE_DIR/sync.lock" || { _aicoding_retention_warn "cannot open the update lock; nothing removed"; return 0; }
  if ! flock -n "$sync_fd"; then
    _aicoding_retention_say "an update is running; nothing removed this time"
    return 0
  fi

  local data _vroot cur_root prev_root
  data=$(readlink -e -- "$AICODING_DATA_DIR") || return 0
  _vroot="$data/versions"
  if [ -L "$_vroot" ] || [ ! -d "$_vroot" ]; then
    _aicoding_retention_warn "$_vroot is not a plain directory; nothing removed"
    return 0
  fi
  cur_root="$data/current"; prev_root="$data/previous"
  if [ -L "$cur_root" ] || [ ! -d "$cur_root" ]; then
    _aicoding_retention_warn "no plain current/ pointer directory; nothing removed"
    return 0
  fi
  if { [ -e "$prev_root" ] || [ -L "$prev_root" ]; } && { [ -L "$prev_root" ] || [ ! -d "$prev_root" ]; }; then
    _aicoding_retention_warn "previous/ is not a plain directory; nothing removed"
    return 0
  fi

  local -A used=() keep_comp=() comp_known=() held=() held_comp=() launcher_comp=() comm_comp=()
  local -a comps=() mounts=() data_prefixes=()
  local entry comp link lock fd _work m
  _work=$(mktemp -d) || return 0
  # shellcheck disable=SC2064
  trap "rm -rf -- $(printf '%q' "$_work")" EXIT
  for m in "$AICODING_DATA_DIR" "$data"; do
    while [[ "$m" == *//* ]]; do m=${m//\/\//\/}; done
    while [ "${m%/}" != "$m" ]; do m=${m%/}; done
    [ -n "$m" ] && data_prefixes+=("$m")
  done

  for entry in "$_vroot"/*; do
    comp=${entry##*/}
    [ -d "$entry" ] && [ ! -L "$entry" ] && _aicoding_retention_safe "$comp" || continue
    comps+=("$comp")
    comp_known[$comp]=1
    # Activation locks: a component being activated is left alone.
    for lock in "$AICODING_STATE_DIR/locks/$comp.lock" "$data/.$comp-install.lock"; do
      [ -e "$lock" ] || continue
      if ! exec {fd}>>"$lock" || ! flock -n "$fd"; then
        keep_comp[$comp]=1
      fi
    done
    # current/<component> must resolve to exactly one release of that component.
    _aicoding_retention_pointer_ok "$comp" "$cur_root/$comp" || keep_comp[$comp]=1
    link="$prev_root/$comp"
    if [ -e "$link" ] || [ -L "$link" ]; then
      _aicoding_retention_pointer_ok "$comp" "$link" || keep_comp[$comp]=1
    fi
  done
  [ "${#comps[@]}" -gt 0 ] || return 0

  # Every symlink under the data directory, current/ and previous/ included.
  if ! _aicoding_retention_scan_links "$data"; then
    _aicoding_retention_warn "cannot list every link under $data; nothing removed"
    return 0
  fi
  if ! _aicoding_retention_scan_bin "$HOME/.local/bin"; then
    _aicoding_retention_warn "cannot read every launcher in ~/.local/bin; nothing removed"
    return 0
  fi
  if ! _aicoding_retention_read_mounts; then
    _aicoding_retention_warn "cannot read the mount table; nothing removed"
    return 0
  fi
  if ! _aicoding_retention_scan_proc; then
    _aicoding_retention_warn "cannot prove that no running process uses a release; nothing removed"
    return 0
  fi

  # A stamp's mtime is the first run that saw the version as a candidate.
  # Stamp directories must be plain directories inside the resolved state dir.
  local state sroot sdir stamp first due
  local now name dir kib count=0 total=0 failed=0 waiting=0 _retired_left rc
  state=$(readlink -e -- "$AICODING_STATE_DIR") || { _aicoding_retention_warn "cannot resolve the state directory; nothing removed"; return 0; }
  sroot="$state/retention"
  if { [ -e "$sroot" ] || [ -L "$sroot" ]; } && { [ -L "$sroot" ] || [ ! -d "$sroot" ]; }; then
    _aicoding_retention_warn "$sroot is not a plain directory; nothing removed"
    return 0
  fi
  now=$(date +%s) || return 0
  for comp in "${comps[@]}"; do
    sdir="$sroot/$comp"
    if { [ -e "$sdir" ] || [ -L "$sdir" ]; } && { [ -L "$sdir" ] || [ ! -d "$sdir" ]; }; then
      _aicoding_retention_warn "$sdir is not a plain directory; keeping every $comp version"
      continue
    fi
    # Stamps that could not be reset are not trustworthy.
    if [ -d "$sdir" ] && { [ ! -w "$sdir" ] || [ ! -x "$sdir" ]; }; then
      _aicoding_retention_warn "$sdir cannot be written; keeping every $comp version"
      continue
    fi
    for dir in "$_vroot/$comp"/.aicoding-retired.*; do
      [ -d "$dir" ] && [ ! -L "$dir" ] || continue
      if [ -n "${keep_comp[$comp]:-}" ]; then continue; fi
      # A fresh table: a bind mount may have appeared since the first read.
      if ! _aicoding_retention_read_mounts; then
        _aicoding_retention_warn "cannot read the mount table; leftover $dir kept"
        continue
      fi
      if _aicoding_retention_has_mount "$dir"; then
        _aicoding_retention_warn "leftover $dir contains a mount point; kept"
        continue
      fi
      # Tombstones of an earlier interrupted removal are never valid releases.
      if [ "$mode" = preview ]; then
        _aicoding_retention_say "would delete leftover $dir"
      else
        _aicoding_retention_delete_tree "$dir" \
          || _aicoding_retention_warn "could not delete leftover $dir"
      fi
    done
    for dir in "$_vroot/$comp"/*; do
      name=${dir##*/}
      [ -d "$dir" ] && [ ! -L "$dir" ] || continue
      _aicoding_retention_safe "$name" || continue
      stamp="$sdir/$name"
      if [ -n "${keep_comp[$comp]:-}" ] || ! _aicoding_retention_release_name "$name" \
          || [ -n "${used[$comp/$name]:-}" ]; then
        [ "$mode" != remove ] || _aicoding_retention_stamp_drop "$stamp" "$comp/$name" || true
        continue
      fi
      if _aicoding_retention_has_mount "$dir"; then
        _aicoding_retention_warn "$comp/$name contains a mount point; kept"
        [ "$mode" != remove ] || _aicoding_retention_stamp_drop "$stamp" "$comp/$name" || true
        continue
      fi
      _aicoding_retention_stamp_plain "$stamp" "$comp/$name" || continue
      # A launcher-started process, or anything it forked, holds a shared lock.
      rc=0
      _aicoding_retention_lease_free "$dir" || rc=$?
      if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 1 ]; then
          _aicoding_retention_say "$comp/$name is held by a running process; kept"
        else
          _aicoding_retention_warn "cannot open $comp/$name to check its lease; kept"
        fi
        [ "$mode" != remove ] || _aicoding_retention_stamp_drop "$stamp" "$comp/$name" || true
        continue
      fi
      first=
      if [ -f "$stamp" ] && [ ! -L "$stamp" ]; then
        first=$(stat -c %Y -- "$stamp" 2>/dev/null) || first=
      fi
      # No stamp, or one from the future: the window starts now.
      if ! [[ "$first" =~ ^[0-9]+$ ]] || [ "$first" -gt "$now" ]; then
        first=$now
        if [ "$mode" = remove ]; then
          # noclobber creates the stamp exclusively, never through a planted link.
          { { [ -d "$sroot" ] || mkdir -m 0700 -- "$sroot"; } && [ ! -L "$sroot" ] \
              && { [ -d "$sdir" ] || mkdir -m 0700 -- "$sdir"; } && [ ! -L "$sdir" ] \
              && rm -f -- "$stamp" && (set -C; : > "$stamp"); } 2>/dev/null || {
            _aicoding_retention_warn "cannot record when $comp/$name was first seen unused; keeping every $comp version this run"
            keep_comp[$comp]=1
            continue
          }
        fi
      fi
      due=$((first + grace))
      kib=$(du -sk -- "$dir" 2>/dev/null | cut -f1)
      [[ "$kib" =~ ^[0-9]+$ ]] || kib=0
      if [ "$((now - first))" -lt "$grace" ]; then
        waiting=$((waiting + 1))
        _aicoding_retention_say "$comp/$name unused since $(_aicoding_retention_date "$first"); eligible for removal from $(_aicoding_retention_date "$due") ($(_aicoding_retention_human "$kib"))"
        continue
      fi
      if [ "$mode" = preview ]; then
        _aicoding_retention_say "would remove $comp/$name now ($(_aicoding_retention_human "$kib"))"
      else
        rc=0; _retired_left=
        _aicoding_retention_remove "$comp" "$name" || rc=$?
        case "$rc" in
          0) _aicoding_retention_say "removed $comp/$name ($(_aicoding_retention_human "$kib"))"
             _aicoding_retention_stamp_drop "$stamp" "$comp/$name" || true ;;
          3) _aicoding_retention_warn "removed $comp/$name from use, but could not delete all of $_retired_left"
             _aicoding_retention_stamp_drop "$stamp" "$comp/$name" || true
             failed=$((failed + 1)); continue ;;
          4) _aicoding_retention_warn "$comp/$name contains a mount point; kept"
             _aicoding_retention_stamp_drop "$stamp" "$comp/$name" || true
             continue ;;
          5) _aicoding_retention_say "$comp/$name is held by a running process; kept"
             _aicoding_retention_stamp_drop "$stamp" "$comp/$name" || true
             continue ;;
          *) _aicoding_retention_warn "could not remove $comp/$name; kept"
             failed=$((failed + 1)); continue ;;
        esac
      fi
      count=$((count + 1)); total=$((total + kib))
    done
  done

  # Stamps of versions that no longer exist: never through a symlink, and
  # only regular files named like a version.
  if [ "$mode" = remove ] && [ -d "$sroot" ] && [ ! -L "$sroot" ]; then
    for sdir in "$sroot"/*; do
      comp=${sdir##*/}
      [ -d "$sdir" ] && [ ! -L "$sdir" ] && _aicoding_retention_safe "$comp" || continue
      for stamp in "$sdir"/*; do
        name=${stamp##*/}
        [ -f "$stamp" ] && [ ! -L "$stamp" ] && _aicoding_retention_safe "$name" || continue
        [ -d "$_vroot/$comp/$name" ] && [ ! -L "$_vroot/$comp/$name" ] || rm -f -- "$stamp" 2>/dev/null || true
      done
      rmdir -- "$sdir" 2>/dev/null || true
    done
  fi

  local noun=versions
  [ "$count" -ne 1 ] || noun=version
  if [ "$mode" = preview ]; then
    _aicoding_retention_say "would remove $count unused $noun now, freeing $(_aicoding_retention_human "$total"); $waiting more still in their observation window"
  else
    _aicoding_retention_say "removed $count unused $noun, freed $(_aicoding_retention_human "$total"); $waiting more still in their observation window"
  fi
  [ "$failed" -eq 0 ] || _aicoding_retention_warn "$failed version(s) could not be removed"
  return 0
}

# aicoding_version_retention: run the retention step. Never fails the caller.
aicoding_version_retention() {
  ( _aicoding_retention_main ) || true
  return 0
}
