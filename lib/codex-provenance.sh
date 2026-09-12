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

# Older installers created machine-owned state with the caller's umask (often
# 002). Privatize that directory before it contains provenance evidence. Walk
# through directory descriptors with O_NOFOLLOW, then chmod the verified owned
# descriptor: neither a foreign directory nor a symlink target is modified.
_codex_provenance_private_state() {
  python3 - "$1" <<'PYTHON'
import os, pathlib, stat, sys
fd=None
try:
    p=pathlib.Path(sys.argv[1]).absolute()
    flags=os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW|os.O_CLOEXEC
    fd=os.open('/', flags)
    for part in p.parts[1:]:
        try:
            child=os.open(part, flags, dir_fd=fd)
        except FileNotFoundError:
            sys.exit(0) # Missing state will be created privately by the caller.
        os.close(fd)
        fd=child
    info=os.fstat(fd)
    if info.st_uid != os.getuid() or not stat.S_ISDIR(info.st_mode):
        raise ValueError()
    if stat.S_IMODE(info.st_mode) != 0o700:
        os.fchmod(fd, 0o700)
except (OSError, ValueError):
    sys.exit(1)
finally:
    if fd is not None: os.close(fd)
PYTHON
}

# Reject links along the requested path and mutable/shared cache contents.
# Ordinary ancestors (e.g. /tmp) need not be private; the evidence directory is.
_codex_provenance_paths_safe() {
  python3 - "$1" <<'PY'
import os, pathlib, stat, sys
p=pathlib.Path(sys.argv[1]).absolute()
try:
    for parent in [p,*p.parents]:
        if parent.is_symlink(): raise ValueError()
    # The immediate state directory must not let another user replace the cache.
    if p.parent.exists():
        s=p.parent.stat()
        if s.st_uid != os.getuid() or s.st_mode & 0o022: raise ValueError()
    def fail_walk(error):
        raise error
    if p.exists():
        for root, dirs, files in os.walk(p, followlinks=False, onerror=fail_walk):
            for item in [root]+[os.path.join(root,n) for n in dirs+files]:
                s=os.lstat(item)
                if s.st_uid != os.getuid() or s.st_mode & 0o022: raise ValueError()
                if not (stat.S_ISREG(s.st_mode) or stat.S_ISDIR(s.st_mode)): raise ValueError()
except (OSError,ValueError):
    sys.exit(1)
PY
}

_codex_provenance_cache_safe() {
  local cache=$1 key origin
  [ -d "$cache" ] && [ ! -L "$cache" ] || return 1
  for key in shallow info/grafts objects/info/alternates objects/info/http-alternates; do
    [ ! -e "$cache/$key" ] && [ ! -L "$cache/$key" ] || return 1
  done
  [ "$(_codex_provenance_git --git-dir="$cache" rev-parse --is-bare-repository 2>/dev/null)" = true ] || return 1
  origin=$(_codex_provenance_git --git-dir="$cache" config --local --no-includes --get-all remote.origin.url) || return 1
  [ "$origin" = https://github.com/vossiman/aiCodingBaseSetup ] || return 1
  while IFS= read -r key; do
    case "$key" in core.repositoryformatversion|core.filemode|core.bare|core.logallrefupdates|remote.origin.url|remote.origin.fetch) ;;
      *) return 1 ;;
    esac
  done < <(_codex_provenance_git --git-dir="$cache" config --local --no-includes --name-only --list)
  [ -z "$(_codex_provenance_git --git-dir="$cache" for-each-ref --format='%(refname)' refs/replace/)" ] || return 1
  _codex_provenance_git --git-dir="$cache" fsck --full --no-reflogs >/dev/null 2>&1
}

_codex_provenance_cached() {
  local cache=$1 sha=$2 resolved
  resolved=$(_codex_provenance_git --git-dir="$cache" rev-parse --verify "refs/aicoding/qualified/$sha^{commit}" 2>/dev/null) || return 1
  [ "$resolved" = "$sha" ]
}

_codex_provenance_prepare_impl() (
  umask 077
  local sha=$1 parent=$2 cache="$2/aicoding.git" lock_fd stage="" rc
  _codex_provenance_private_state "${parent%/*}" || return 3
  _codex_provenance_paths_safe "$parent" || return 3
  if [ -e "$cache" ]; then
    _codex_provenance_cache_safe "$cache" || return 3
    _codex_provenance_cached "$cache" "$sha" && return 0
  fi
  [ "${AICODINGSETUP_SKIP_NETWORK:-0}" != 1 ] || return 2
  mkdir -p "$parent" || return 3
  _codex_provenance_paths_safe "$parent" || return 3
  exec {lock_fd}>>"$parent/lock" || return 3
  flock -w 60 "$lock_fd" || return 2
  # Revalidate after the lock: another writer may have populated the cache.
  _codex_provenance_paths_safe "$parent" || return 3
  if [ -e "$cache" ]; then
    _codex_provenance_cache_safe "$cache" || return 3
    _codex_provenance_cached "$cache" "$sha" && return 0
  fi
  . "$_CODEX_PROVENANCE_LIB/update-progress.sh" || return 2
  aicoding_progress_run 'codex: qualifying provenance release' _codex_provenance_qualify "$sha" || return 2
  if [ ! -d "$cache" ]; then
    stage=$(mktemp -d "$parent/.staging.XXXXXX") || return 3
    trap '[ -z "$stage" ] || rm -rf -- "$stage"' EXIT
    _codex_provenance_git init --bare "$stage" >/dev/null 2>&1 || return 3
    _codex_provenance_git --git-dir="$stage" remote add origin https://github.com/vossiman/aiCodingBaseSetup || return 3
  else
    stage=$cache
  fi
  # Fixed public HTTPS origin: no caller-selected remote, URL rewriting, or hooks.
  aicoding_progress_run 'codex: downloading provenance (timeout 120s)' \
    _codex_provenance_fetch "$stage" "$sha" || return 2
  _codex_provenance_cache_safe "$stage" || return 3
  _codex_provenance_git --git-dir="$stage" cat-file -e "$sha^{commit}" || return 2
  _codex_provenance_git --git-dir="$stage" update-ref "refs/aicoding/qualified/$sha" "$sha" || return 3
  if [ "$stage" != "$cache" ]; then
    mv -T -- "$stage" "$cache" || return 3
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

_codex_provenance_prepare() {
  local sha=$1 rc=0 parent="${AICODING_STATE_DIR:-$HOME/.local/state/aicoding}/code-provenance"
  CODEX_PROVENANCE_GIT="" CODEX_PROVENANCE_ERROR=""
  if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then CODEX_PROVENANCE_ERROR=invalid_blueprint_release; return 1; fi
  _codex_provenance_prepare_impl "$sha" "$parent" || rc=$?
  case "$rc" in
    0) CODEX_PROVENANCE_GIT="$parent/aicoding.git"; return 0 ;;
    3) CODEX_PROVENANCE_ERROR=invalid_provenance_cache ;;
    *) CODEX_PROVENANCE_ERROR=revision_unavailable ;;
  esac
  return 1
}
