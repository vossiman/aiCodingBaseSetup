# Offline-readable Git evidence for Codex merges of Gitless source releases.
# The cache is locally attested after CI qualification; it is not a signature.
_CODEX_PROVENANCE_LIB="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

_codex_provenance_git() (
  local variable
  for variable in ${!GIT_@}; do unset "$variable"; done
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 GIT_NO_REPLACE_OBJECTS=1
  command git -c core.hooksPath=/dev/null -c protocol.file.allow=never -c protocol.ext.allow=never \
    -c transfer.fsckObjects=true -c fetch.fsckObjects=true "$@"
)

# Rejection reasons: each check that returns 3 names itself. Paths are the
# public provenance cache's own entries, relative to the evidence directory,
# or state ancestors with $HOME shortened to "~"; never file contents.
_codex_provenance_reject() {
  [ -n "${_CODEX_PROVENANCE_DETAIL_FILE:-}" ] || return 0
  printf '%s/%s\n' "$1" "${2:-unknown}" > "$_CODEX_PROVENANCE_DETAIL_FILE" 2>/dev/null || true
}

# Older installers created machine-owned state with the caller's umask (often
# 002). Privatize that directory before it contains provenance evidence. Walk
# through directory descriptors with O_NOFOLLOW, then chmod the verified owned
# descriptor: neither a foreign directory nor a symlink target is modified.
_codex_provenance_private_state() {
  python3 - "$1" <<'PYTHON'
import errno, os, pathlib, stat, sys
def show(path):
    home = os.path.expanduser("~")
    text = str(path)
    return "~" + text[len(home):] if home not in ("", "/") and (text == home or text.startswith(home + "/")) else text
def reject(reason):
    print(reason)
    sys.exit(1)
fd=None
p=pathlib.Path(sys.argv[1]).absolute()
current=pathlib.Path("/")
try:
    flags=os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW|os.O_CLOEXEC
    fd=os.open('/', flags)
    for part in p.parts[1:]:
        current=current / part
        try:
            child=os.open(part, flags, dir_fd=fd)
        except FileNotFoundError:
            sys.exit(0) # Missing state will be created privately by the caller.
        os.close(fd)
        fd=child
    info=os.fstat(fd)
    if info.st_uid != os.getuid():
        reject("state_dir_foreign_owner:" + show(p))
    if not stat.S_ISDIR(info.st_mode):
        reject("state_dir_not_directory:" + show(p))
    if stat.S_IMODE(info.st_mode) != 0o700:
        try:
            os.fchmod(fd, 0o700)
        except OSError as error:
            reject("state_dir_chmod_failed:" + errno.errorcode.get(error.errno, "EIO") + ":" + show(p))
except OSError as error:
    code = errno.errorcode.get(error.errno, "EIO")
    if error.errno == errno.ELOOP:
        kind = "state_path_symlink"
    elif error.errno == errno.ENOTDIR:
        kind = "state_path_symlink" if os.path.islink(str(current)) else "state_path_not_directory"
    else:
        kind = "state_path_open_failed:" + code
    reject(kind + ":" + show(current))
finally:
    if fd is not None: os.close(fd)
PYTHON
}

# Reject links along the requested path and mutable/shared cache contents.
# Ordinary ancestors (e.g. /tmp) need not be private; the evidence directory is.
_codex_provenance_paths_safe() {
  python3 - "$1" <<'PY'
import errno, os, pathlib, stat, sys
def show(path):
    home = os.path.expanduser("~")
    text = str(path)
    return "~" + text[len(home):] if home not in ("", "/") and (text == home or text.startswith(home + "/")) else text
def reject(reason):
    print(reason)
    sys.exit(1)
p=pathlib.Path(sys.argv[1]).absolute()
def rel(item):
    return os.path.relpath(item, str(p))
try:
    for parent in [p,*p.parents]:
        if parent.is_symlink(): reject("path_symlink:" + show(parent))
    # The immediate state directory must not let another user replace the cache.
    if p.parent.exists():
        s=p.parent.stat()
        if s.st_uid != os.getuid(): reject("state_dir_foreign_owner:" + show(p.parent))
        if s.st_mode & 0o022: reject("state_dir_writable:%04o:%s" % (stat.S_IMODE(s.st_mode), show(p.parent)))
    def fail_walk(error):
        raise error
    if p.exists():
        for root, dirs, files in os.walk(p, followlinks=False, onerror=fail_walk):
            for item in [root]+[os.path.join(root,n) for n in dirs+files]:
                try:
                    s=os.lstat(item)
                except OSError as error:
                    reject("cache_entry_vanished:" + errno.errorcode.get(error.errno, "EIO") + ":" + rel(item))
                if not (stat.S_ISREG(s.st_mode) or stat.S_ISDIR(s.st_mode)): reject("cache_entry_not_regular:" + rel(item))
                if s.st_uid != os.getuid(): reject("cache_entry_foreign_owner:" + rel(item))
                if s.st_mode & 0o022: reject("cache_entry_writable:%04o:%s" % (stat.S_IMODE(s.st_mode), rel(item)))
except OSError as error:
    where = rel(error.filename) if getattr(error, "filename", None) else "."
    reject("cache_walk_failed:" + errno.errorcode.get(error.errno, "EIO") + ":" + where)
PY
}

# Prints a rejection detail on stdout and returns 1 when the cache is unsafe.
# Details are not result reasons, so they use printf, not the scanned echo form.
_codex_provenance_cache_safe() {
  local cache=$1 key origin fsck_rc=0 fsck_first cache_abs
  if [ -L "$cache" ]; then printf '%s\n' cache_symlink; return 1; fi
  if [ ! -d "$cache" ]; then printf '%s\n' cache_not_directory; return 1; fi
  for key in shallow info/grafts objects/info/alternates objects/info/http-alternates; do
    if [ -e "$cache/$key" ] || [ -L "$cache/$key" ]; then printf '%s\n' "graph_override:$key"; return 1; fi
  done
  if [ "$(_codex_provenance_git --git-dir="$cache" rev-parse --is-bare-repository 2>/dev/null)" != true ]; then
    printf '%s\n' not_bare_repository; return 1
  fi
  origin=$(_codex_provenance_git --git-dir="$cache" config --local --no-includes --get-all remote.origin.url) \
    || { printf '%s\n' origin_unreadable; return 1; }
  [ "$origin" = https://github.com/vossiman/aiCodingBaseSetup ] || { printf '%s\n' origin_mismatch; return 1; }
  while IFS= read -r key; do
    case "$key" in core.repositoryformatversion|core.filemode|core.bare|core.logallrefupdates|remote.origin.url|remote.origin.fetch) ;;
      *) printf 'unexpected_config_key:%s\n' "${key//[^A-Za-z0-9._-]/?}"; return 1 ;;
    esac
  done < <(_codex_provenance_git --git-dir="$cache" config --local --no-includes --name-only --list)
  if [ -n "$(_codex_provenance_git --git-dir="$cache" for-each-ref --format='%(refname)' refs/replace/)" ]; then
    printf '%s\n' replace_refs_present; return 1
  fi
  fsck_first=$(_codex_provenance_git --git-dir="$cache" fsck --full --no-reflogs 2>&1 >/dev/null) || fsck_rc=$?
  if [ "$fsck_rc" -ne 0 ]; then
    fsck_first=$(printf '%s\n' "$fsck_first" | grep -m1 -E '^(error|fatal|missing|broken)' || printf '%s\n' "$fsck_first" | head -n1)
    # Git names objects by absolute path; keep only the cache-relative part.
    cache_abs=$(cd -- "$cache" 2>/dev/null && pwd -P) || cache_abs=$cache
    fsck_first=${fsck_first//"$cache_abs/"/}
    fsck_first=${fsck_first//"$cache/"/}
    fsck_first=${fsck_first//"$cache_abs"/.}
    fsck_first=${fsck_first//"$cache"/.}
    [ -z "${HOME:-}" ] || [ "$HOME" = / ] || fsck_first=${fsck_first//"$HOME"/\~}
    fsck_first=${fsck_first//[^A-Za-z0-9 ._:\/~-]/?}
    printf 'fsck_failed:%s:%s\n' "$fsck_rc" "${fsck_first:0:120}"
    return 1
  fi
}

_codex_provenance_cached() {
  local cache=$1 sha=$2 resolved
  resolved=$(_codex_provenance_git --git-dir="$cache" rev-parse --verify "refs/aicoding/qualified/$sha^{commit}" 2>/dev/null) || return 1
  [ "$resolved" = "$sha" ]
}

# Stages in rejection reasons: "initial" runs unlocked before any network use,
# "locked" after taking the cache lock, "fetched" after downloading evidence.
_codex_provenance_prepare_impl() (
  umask 077
  local sha=$1 parent=$2 cache="$2/aicoding.git" lock_fd stage="" rc reason
  reason=$(_codex_provenance_private_state "${parent%/*}") || { _codex_provenance_reject initial "$reason"; return 3; }
  reason=$(_codex_provenance_paths_safe "$parent") || { _codex_provenance_reject initial "$reason"; return 3; }
  if [ -e "$cache" ]; then
    reason=$(_codex_provenance_cache_safe "$cache") || { _codex_provenance_reject initial "$reason"; return 3; }
    _codex_provenance_cached "$cache" "$sha" && return 0
  fi
  [ "${AICODINGSETUP_SKIP_NETWORK:-0}" != 1 ] || return 2
  mkdir -p "$parent" || { _codex_provenance_reject initial mkdir_failed; return 3; }
  reason=$(_codex_provenance_paths_safe "$parent") || { _codex_provenance_reject initial "$reason"; return 3; }
  exec {lock_fd}>>"$parent/lock" || { _codex_provenance_reject initial lock_open_failed; return 3; }
  flock -w 60 "$lock_fd" || return 2
  # Revalidate after the lock: another writer may have populated the cache.
  reason=$(_codex_provenance_paths_safe "$parent") || { _codex_provenance_reject locked "$reason"; return 3; }
  if [ -e "$cache" ]; then
    reason=$(_codex_provenance_cache_safe "$cache") || { _codex_provenance_reject locked "$reason"; return 3; }
    _codex_provenance_cached "$cache" "$sha" && return 0
  fi
  . "$_CODEX_PROVENANCE_LIB/update-progress.sh" || return 2
  aicoding_progress_run 'codex: qualifying provenance release' _codex_provenance_qualify "$sha" || return 2
  if [ ! -d "$cache" ]; then
    stage=$(mktemp -d "$parent/.staging.XXXXXX") || { _codex_provenance_reject locked staging_create_failed; return 3; }
    trap '[ -z "$stage" ] || rm -rf -- "$stage"' EXIT
    _codex_provenance_git init --bare "$stage" >/dev/null 2>&1 || { _codex_provenance_reject locked staging_init_failed; return 3; }
    _codex_provenance_git --git-dir="$stage" remote add origin https://github.com/vossiman/aiCodingBaseSetup \
      || { _codex_provenance_reject locked staging_init_failed; return 3; }
  else
    stage=$cache
  fi
  # Fixed public HTTPS origin: no caller-selected remote, URL rewriting, or hooks.
  aicoding_progress_run 'codex: downloading provenance (timeout 120s)' \
    _codex_provenance_fetch "$stage" "$sha" || return 2
  reason=$(_codex_provenance_cache_safe "$stage") || { _codex_provenance_reject fetched "$reason"; return 3; }
  _codex_provenance_git --git-dir="$stage" cat-file -e "$sha^{commit}" || return 2
  _codex_provenance_git --git-dir="$stage" update-ref "refs/aicoding/qualified/$sha" "$sha" \
    || { _codex_provenance_reject fetched update_ref_failed; return 3; }
  if [ "$stage" != "$cache" ]; then
    mv -T -- "$stage" "$cache" || { _codex_provenance_reject fetched publish_failed; return 3; }
    stage=""
  fi
  trap - EXIT
)

_codex_provenance_qualify() (
  . "$_CODEX_PROVENANCE_LIB/ci-selector.sh" || return 2
  aicoding_ci_qualified aicoding "$1"
)

_codex_provenance_fetch() (
  local variable
  for variable in ${!GIT_@}; do unset "$variable"; done
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 GIT_NO_REPLACE_OBJECTS=1
  command timeout --foreground 120 git -c core.hooksPath=/dev/null -c protocol.file.allow=never \
    -c protocol.ext.allow=never -c transfer.fsckObjects=true -c fetch.fsckObjects=true \
    --git-dir="$1" fetch --quiet --no-tags https://github.com/vossiman/aiCodingBaseSetup "$2" </dev/null >/dev/null 2>&1
)

# Sets CODEX_PROVENANCE_ERROR (stable code) and CODEX_PROVENANCE_DETAIL
# ("<stage>/<check>[:<facts>]") on failure. The detail is empty when the
# failing step has no finer diagnosis (e.g. network or lock timeouts).
_codex_provenance_prepare() {
  local sha=$1 rc=0 parent="${AICODING_STATE_DIR:-$HOME/.local/state/aicoding}/code-provenance" detail_file=""
  CODEX_PROVENANCE_GIT="" CODEX_PROVENANCE_ERROR="" CODEX_PROVENANCE_DETAIL=""
  if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then CODEX_PROVENANCE_ERROR=invalid_blueprint_release; return 1; fi
  detail_file=$(mktemp "${TMPDIR:-/tmp}/aicoding-provenance-detail.XXXXXX" 2>/dev/null) || detail_file=""
  _CODEX_PROVENANCE_DETAIL_FILE=$detail_file _codex_provenance_prepare_impl "$sha" "$parent" || rc=$?
  if [ -n "$detail_file" ]; then
    CODEX_PROVENANCE_DETAIL=$(head -c 200 "$detail_file" 2>/dev/null | tr -d '\n')
    rm -f -- "$detail_file"
  fi
  case "$rc" in
    0) CODEX_PROVENANCE_GIT="$parent/aicoding.git"; CODEX_PROVENANCE_DETAIL=""; return 0 ;;
    3) CODEX_PROVENANCE_ERROR=invalid_provenance_cache ;;
    *) CODEX_PROVENANCE_ERROR=revision_unavailable ;;
  esac
  return 1
}
