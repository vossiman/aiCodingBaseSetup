# lib/version-retention.sh: host-only pruning of provably unused releases.
# A directory versions/<component>/<name> is removed only when every keep rule
# below clears it; anything unclear keeps it. Containers never prune: a
# rebuild wipes the tree anyway. Sourced; does not change shell options.
#
#   AICODING_RETENTION        unset|on (remove), preview (log only), off
#   AICODING_RETENTION_GRACE  seconds a version must be untouched (default 1 day)

: "${AICODING_DATA_DIR:=$HOME/.local/share/aicoding}"
: "${AICODING_STATE_DIR:=$HOME/.local/state/aicoding}"

_AICODING_RETENTION_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_AICODING_RETENTION_SEG='[A-Za-z0-9][A-Za-z0-9._+-]*'

_aicoding_retention_say() { printf 'aicoding retention: %s\n' "$*"; }
_aicoding_retention_warn() { printf 'aicoding retention: WARN: %s\n' "$*" >&2; }

_aicoding_retention_safe() { [[ "$1" =~ ^${_AICODING_RETENTION_SEG}$ ]]; }

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

# Mark the version that a canonical path lies inside (needs _vroot, used, keep_comp).
_aicoding_retention_mark_path() {
  local path=$1 rest comp name
  case "$path" in "$_vroot"/*) ;; *) return 0 ;; esac
  rest=${path#"$_vroot"/}
  comp=${rest%%/*}
  name=${rest#*/}
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

# One find pass over /proc for cwd, exe and descriptors, one grep pass over
# maps. Like t3_open_under: our own entries prove each scan started, an end
# marker that it finished. Returns 1 when completeness cannot be proven.
_aicoding_retention_scan_proc() {
  local me=$BASHPID p path target line end=aicoding-retention-scan-end
  local self_fd=0 fd_ended=0 self_map=0 map_ended=0
  local -a starts=() maps=()
  for p in /proc/[0-9]*; do
    [ -O "$p" ] || continue
    starts+=("$p/fd" "$p/cwd" "$p/exe")
    maps+=("$p/maps")
  done
  [ "${#starts[@]}" -gt 0 ] || return 1
  while IFS= read -r -d '' path && IFS= read -r -d '' target; do
    [ "$path" = "$end" ] && { fd_ended=1; continue; }
    p=${path#/proc/}; p=${p%%/*}
    [ "$p" = "$me" ] && self_fd=1
    [ -n "$target" ] && _aicoding_retention_mark_path "$target"
  done < <(s=0; find "${starts[@]}" -maxdepth 1 -printf '%p\0%l\0' 2>/dev/null || s=$?
           [ "$s" -lt 126 ] && printf '%s\0\0' "$end")
  while IFS= read -r line; do
    [ "$line" = "$end" ] && { map_ended=1; continue; }
    case "$line" in "/proc/$me/maps:"*'[stack]'*) self_map=1 ;; esac
    case "$line" in *" $_vroot/"*) _aicoding_retention_mark_path "$_vroot/${line#*" $_vroot/"}" ;; esac
  done < <(s=0; grep -H -F -e "$_vroot/" -e '[stack]' -- "${maps[@]}" 2>/dev/null || s=$?
           [ "$s" -lt 126 ] && printf '%s\n' "$end")
  [ "$self_fd" = 1 ] && [ "$fd_ended" = 1 ] && [ "$self_map" = 1 ] && [ "$map_ended" = 1 ] || return 1
  _aicoding_retention_scan_hidden
}

# The scans above cannot see a same-user process whose exe link is unreadable
# (non-dumpable, or /proc/<pid> owned by root). Such a process fails the run
# when its command line names a managed path or cannot be read. Needs data.
_aicoding_retention_scan_hidden() {
  # Test-only override of the proc root; the scans above always use /proc.
  local proc=${_AICODING_RETENTION_PROC:-/proc}
  local end=aicoding-retention-scan-end line p uid path target arg m comm hit rc=0
  local st_ended=0
  local -a status_files=() mine=() args=() managed=()
  local -A readable=()
  for m in "$AICODING_DATA_DIR" "$data" "$HOME/.local/bin" "$(readlink -e -- "$HOME/.local/bin" 2>/dev/null)"; do
    [ -n "$m" ] || continue
    while [ "${m%/}" != "$m" ]; do m=${m%/}; done
    managed+=("$m")
  done
  status_files=("$proc"/[0-9]*/status)
  [ "${#status_files[@]}" -gt 0 ] && [ -e "${status_files[0]}" ] || return 1
  # status is world-readable even when the rest of /proc/<pid> is not.
  while IFS= read -r line; do
    [ "$line" = "$end" ] && { st_ended=1; continue; }
    p=${line%/status:Uid:*}
    [[ "${p##*/}" =~ ^[0-9]+$ ]] || continue
    read -r uid _ <<< "${line#*/status:Uid:}"
    [ "$uid" = "$UID" ] && mine+=("$p")
  done < <(s=0; grep -H -m1 '^Uid:' -- "${status_files[@]}" 2>/dev/null || s=$?
           [ "$s" -lt 126 ] && printf '%s\n' "$end")
  [ "$st_ended" = 1 ] || return 1
  [ "${#mine[@]}" -gt 0 ] || return 0
  # An entry missing from this listing counts as unreadable, which fails closed.
  while IFS= read -r -d '' path && IFS= read -r -d '' target; do
    [ -n "$target" ] && readable[${path%/exe}]=1
  done < <(find "${mine[@]/%//exe}" -maxdepth 0 -printf '%p\0%l\0' 2>/dev/null)
  for p in "${mine[@]}"; do
    [ -z "${readable[$p]:-}" ] || continue
    hit=
    if ! mapfile -d '' -t args 2>/dev/null < "$p/cmdline"; then
      # A process that exited meanwhile uses nothing.
      [ -e "$p" ] || continue
      hit="its command line cannot be read"
    else
      for arg in "${args[@]}"; do
        for m in "${managed[@]}"; do
          case "$arg" in *"$m/"*|*"$m") hit="runs from a managed path"; break 2 ;; esac
        done
      done
    fi
    [ -n "$hit" ] || continue
    comm=
    IFS= read -r comm 2>/dev/null < "$p/comm" || true
    comm=${comm//[![:print:]]/?}
    _aicoding_retention_warn "process ${p##*/} (${comm:-?}) cannot be inspected and $hit; nothing removed"
    rc=1
  done
  return "$rc"
}

# Every symlink under DIR: its resolved target keeps a version, unless the link
# itself lives inside that same version. Returns 1 if the listing failed.
_aicoding_retention_scan_links() {
  local dir=$1 i owner rest comp name
  local -a links=() targets=()
  mapfile -d '' links < <(find "$dir" -type l -print0 2>/dev/null; printf 'rc=%s\0' "$?")
  [ "${#links[@]}" -gt 0 ] || return 1
  [ "${links[-1]}" = rc=0 ] || return 1
  unset 'links[-1]'
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
    if [ -n "$owner" ]; then
      case "${targets[$i]}" in "$_vroot/$owner"|"$_vroot/$owner"/*) continue ;; esac
    fi
    _aicoding_retention_mark_path "${targets[$i]}"
  done
}

# Managed launchers and legacy links in ~/.local/bin. Returns 1 on a read error.
_aicoding_retention_scan_bin() {
  local bin=$1 rc
  local -a files=()
  [ -e "$bin" ] || [ -L "$bin" ] || return 0
  # find does not descend into a symlinked start directory.
  bin=$(readlink -e -- "$bin") || return 1
  [ -d "$bin" ] || return 0
  _aicoding_retention_scan_links_bin "$bin" || return 1
  mapfile -d '' files < <(find "$bin" -type f -print0 2>/dev/null; printf 'rc=%s\0' "$?")
  [ "${files[-1]:-}" = rc=0 ] || return 1
  unset 'files[-1]'
  [ "${#files[@]}" -gt 0 ] || return 0
  rc=0
  grep -aohE "versions/${_AICODING_RETENTION_SEG}/${_AICODING_RETENTION_SEG}" \
    -- "${files[@]}" > "$_work/bin-tokens" 2>/dev/null || rc=$?
  # 1 is "no match"; 2 is a file that could not be read.
  [ "$rc" -le 1 ] || return 1
  _aicoding_retention_mark_tokens < "$_work/bin-tokens"
}

_aicoding_retention_scan_links_bin() {
  local bin=$1 path raw
  while IFS= read -r -d '' path && IFS= read -r -d '' raw; do
    [ "$path" = aicoding-retention-scan-end ] && return 0
    _aicoding_retention_mark_path "$(readlink -m -- "$path" 2>/dev/null)"
    _aicoding_retention_mark_tokens < <(printf '%s\n' "$raw" \
      | grep -aoE "versions/${_AICODING_RETENTION_SEG}/${_AICODING_RETENTION_SEG}")
  done < <(find "$bin" -type l -printf '%p\0%l\0' 2>/dev/null \
           && printf '%s\0\0' aicoding-retention-scan-end)
  return 1
}

# Remove one version: re-verify, rename into a dot-prefixed tombstone, delete.
# Returns 1 when nothing changed, 3 when the tombstone could not be deleted.
_aicoding_retention_remove() {
  local comp=$1 name=$2 dir tomb real
  dir="$_vroot/$comp/$name"
  _aicoding_retention_safe "$comp" && _aicoding_retention_safe "$name" || return 1
  [ -d "$_vroot/$comp" ] && [ ! -L "$_vroot/$comp" ] || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  real=$(readlink -e -- "$dir") || return 1
  [ "$real" = "$dir" ] || return 1
  tomb=$(mktemp -d "$_vroot/$comp/.aicoding-retired.$name.XXXXXX" 2>/dev/null) || return 1
  if ! mv -T -- "$dir" "$tomb/item" 2>/dev/null; then
    rmdir -- "$tomb" 2>/dev/null || true
    return 1
  fi
  _aicoding_retention_delete_tree "$tomb" || { _retired_left=$tomb; return 3; }
}

# Build caches can leave read-only directories; restore write access first.
_aicoding_retention_delete_tree() {
  rm -rf -- "$1" 2>/dev/null && return 0
  chmod -R u+w -- "$1" 2>/dev/null || true
  rm -rf -- "$1" 2>/dev/null
}

_aicoding_retention_main() {
  local mode=${AICODING_RETENTION:-on} grace=${AICODING_RETENTION_GRACE:-86400}
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
  [[ "$grace" =~ ^[0-9]+$ ]] || {
    _aicoding_retention_warn "AICODING_RETENTION_GRACE must be whole seconds; nothing removed"
    return 0
  }
  [ -d "$AICODING_DATA_DIR/versions" ] || return 0
  shopt -u dotglob
  shopt -s nullglob

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

  local -A used=() keep_comp=()
  local -a comps=()
  local entry comp target link lock fd _work
  _work=$(mktemp -d) || return 0
  # shellcheck disable=SC2064
  trap "rm -rf -- $(printf '%q' "$_work")" EXIT

  for entry in "$_vroot"/*; do
    comp=${entry##*/}
    [ -d "$entry" ] && [ ! -L "$entry" ] && _aicoding_retention_safe "$comp" || continue
    comps+=("$comp")
    # Activation locks: a component being activated is left alone.
    for lock in "$AICODING_STATE_DIR/locks/$comp.lock" "$data/.$comp-install.lock"; do
      [ -e "$lock" ] || continue
      if ! exec {fd}>>"$lock" || ! flock -n "$fd"; then
        keep_comp[$comp]=1
      fi
    done
    # current/<component> must resolve to a release of that component.
    link="$cur_root/$comp"
    if [ -L "$link" ] && target=$(readlink -e -- "$link") && [ -d "$target" ]; then
      case "$target" in "$_vroot/$comp"/*) ;; *) keep_comp[$comp]=1 ;; esac
    else
      keep_comp[$comp]=1
    fi
    link="$prev_root/$comp"
    if [ -e "$link" ] || [ -L "$link" ]; then
      if ! { [ -L "$link" ] && target=$(readlink -e -- "$link") && [ -d "$target" ]; }; then
        keep_comp[$comp]=1
      fi
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
  if ! _aicoding_retention_scan_proc; then
    _aicoding_retention_warn "cannot prove the /proc scan of running processes is complete; nothing removed"
    return 0
  fi

  local now name dir stamps newest kib count=0 total=0 failed=0 _retired_left rc
  now=$(date +%s) || return 0
  for comp in "${comps[@]}"; do
    [ -z "${keep_comp[$comp]:-}" ] || continue
    if [ "$mode" = remove ]; then
      # Tombstones of an earlier interrupted removal are never valid releases.
      for dir in "$_vroot/$comp"/.aicoding-retired.*; do
        [ -d "$dir" ] && [ ! -L "$dir" ] || continue
        _aicoding_retention_delete_tree "$dir" \
          || _aicoding_retention_warn "could not delete leftover $dir"
      done
    fi
    for dir in "$_vroot/$comp"/*; do
      name=${dir##*/}
      [ -d "$dir" ] && [ ! -L "$dir" ] || continue
      _aicoding_retention_safe "$name" || continue
      case "$name" in *.staging.*) continue ;; esac
      [ -z "${used[$comp/$name]:-}" ] || continue
      stamps=$(stat -c '%Y %Z' -- "$dir" 2>/dev/null) || continue
      newest=${stamps% *}
      [ "${stamps#* }" -le "$newest" ] || newest=${stamps#* }
      [ $((now - newest)) -ge "$grace" ] || continue
      kib=$(du -sk -- "$dir" 2>/dev/null | cut -f1)
      [[ "$kib" =~ ^[0-9]+$ ]] || kib=0
      if [ "$mode" = preview ]; then
        _aicoding_retention_say "would remove $comp/$name ($(_aicoding_retention_human "$kib"))"
      else
        rc=0; _retired_left=
        _aicoding_retention_remove "$comp" "$name" || rc=$?
        case "$rc" in
          0) _aicoding_retention_say "removed $comp/$name ($(_aicoding_retention_human "$kib"))" ;;
          3) _aicoding_retention_warn "removed $comp/$name from use, but could not delete all of $_retired_left"
             failed=$((failed + 1)); continue ;;
          *) _aicoding_retention_warn "could not remove $comp/$name; kept"
             failed=$((failed + 1)); continue ;;
        esac
      fi
      count=$((count + 1)); total=$((total + kib))
    done
  done

  local noun=versions
  [ "$count" -ne 1 ] || noun=version
  if [ "$mode" = preview ]; then
    _aicoding_retention_say "would remove $count unused $noun, freeing $(_aicoding_retention_human "$total")"
  else
    _aicoding_retention_say "removed $count unused $noun, freed $(_aicoding_retention_human "$total")"
  fi
  [ "$failed" -eq 0 ] || _aicoding_retention_warn "$failed version(s) could not be removed"
  return 0
}

# aicoding_version_retention: run the retention step. Never fails the caller.
aicoding_version_retention() {
  ( _aicoding_retention_main ) || true
  return 0
}
