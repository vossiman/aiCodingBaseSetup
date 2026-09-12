# Exact Cursor CLI archives, using the URL published by the official installer.
# The installer is read as data only: never execute its mutations of ~/.local/bin.
_aicoding_cursor_target() (
  set -o pipefail
  timeout "$AICODING_VENDOR_TIMEOUT" curl -fsSL --proto '=https' --proto-redir '=https' \
    --max-time "$AICODING_VENDOR_TIMEOUT" https://cursor.com/install </dev/null 2>/dev/null \
    | python3 -c 'import re,sys
text=sys.stdin.read()
versions=set(re.findall(r"https://downloads[.]cursor[.]com/lab/([0-9]{4}[.][0-9]{2}[.][0-9]{2}-[0-9a-f]{7,40})/", text))
if len(versions)!=1: sys.exit(1)
print(versions.pop())'
)

# The vendor Linux archive currently contains directories and regular files.
# Reject links, special files and escaping/duplicate paths before extracting;
# do not let a changed archive write outside the fresh staging directory.
_aicoding_cursor_extract() {
  timeout "$AICODING_VENDOR_TIMEOUT" python3 - "$1" "$2" <<'PY'
import pathlib,sys,tarfile
archive,dest=sys.argv[1:]
try:
    with tarfile.open(archive, 'r:gz') as tar:
        members=tar.getmembers()
        seen=set()
        total=0
        for member in members:
            path=pathlib.PurePosixPath(member.name)
            if path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0]!='dist-package':
                raise ValueError('path')
            if not (member.isfile() or member.isdir()) or member.name in seen:
                raise ValueError('type or duplicate')
            seen.add(member.name)
            total+=member.size
            if total>2*1024**3 or len(seen)>100000: raise ValueError('size')
        for member in members:
            parts=pathlib.PurePosixPath(member.name).parts[1:]
            if not parts: continue
            target=pathlib.Path(dest).joinpath(*parts)
            if member.isdir(): target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with tar.extractfile(member) as source, target.open('xb') as output:
                    import shutil
                    shutil.copyfileobj(source,output)
                target.chmod(member.mode & 0o777)
except (OSError,ValueError,tarfile.TarError):
    sys.exit(1)
PY
}

_aicoding_cursor_probe() {
  local release=$1 probe_home=$2 actual
  [ -f "$release/cursor-agent" ] && [ ! -L "$release/cursor-agent" ] \
    && [ -x "$release/cursor-agent" ] || return 1
  mkdir -p "$probe_home" || return 1
  actual=$(HOME="$probe_home" XDG_CONFIG_HOME="$probe_home/.config" \
    XDG_DATA_HOME="$probe_home/.local/share" XDG_CACHE_HOME="$probe_home/.cache" \
    XDG_STATE_HOME="$probe_home/.local/state" NODE_COMPILE_CACHE="$probe_home/.cache/node" \
    timeout "${AICODING_PROBE_TIMEOUT:-15}" "$release/cursor-agent" --version </dev/null 2>/dev/null) || return 1
  [ "$actual" = "$3" ]
}

aicoding_update_cursor() {
  local target arch final work state=updated
  if [ "${AICODINGSETUP_SKIP_NETWORK:-0}" = 1 ]; then
    _aicoding_record_deferred cursor blocked "" network_disabled
    return 1
  fi
  case "$(uname -s):$(uname -m)" in
    Linux:x86_64|Linux:amd64) arch=x64 ;;
    Linux:aarch64|Linux:arm64) arch=arm64 ;;
    *) _aicoding_record_deferred cursor blocked "" unsupported_platform; return 1 ;;
  esac
  command -v python3 >/dev/null 2>&1 \
    || { _aicoding_record_deferred cursor blocked "" python_runtime_unavailable; return 1; }
  target=$(aicoding_progress_run "cursor: resolving release (timeout ${AICODING_VENDOR_TIMEOUT}s)" _aicoding_cursor_target) \
    || { aicoding_result_record cursor failed "" target_version_unavailable; return 1; }
  final="$AICODING_DATA_DIR/versions/cursor/$target"
  mkdir -p "$AICODING_DATA_DIR/versions/cursor" || return 1
  work=$(mktemp -d "$AICODING_DATA_DIR/versions/cursor/.staging.$target.XXXXXX") || return 1
  if [ -e "$final" ]; then
    if ! _aicoding_release_integrity_valid "$final" \
        || ! _aicoding_cursor_probe "$final" "$work/home" "$target"; then
      rm -rf "$work"; aicoding_result_record cursor failed "$target" existing_release_invalid; return 1
    fi
    state=current
  else
    if ! aicoding_progress_run "cursor: downloading runtime (timeout ${AICODING_VENDOR_TIMEOUT}s)" _aicoding_progress_capture /dev/null timeout "$AICODING_VENDOR_TIMEOUT" curl -fsSL --proto '=https' --proto-redir '=https' \
        --max-time "$AICODING_VENDOR_TIMEOUT" \
        -o "$work/archive.tar.gz" "https://downloads.cursor.com/lab/$target/linux/$arch/agent-cli-package.tar.gz" \
        </dev/null; then
      rm -rf "$work"; aicoding_result_record cursor failed "$target" archive_download_failed; return 1
    fi
    if ! mkdir -p "$work/release" || ! aicoding_progress_run "cursor: extracting runtime (timeout ${AICODING_VENDOR_TIMEOUT}s)" _aicoding_cursor_extract "$work/archive.tar.gz" "$work/release"; then
      rm -rf "$work"; aicoding_result_record cursor failed "$target" archive_invalid; return 1
    fi
    if ! _aicoding_cursor_probe "$work/release" "$work/home" "$target"; then
      rm -rf "$work"; aicoding_result_record cursor failed "$target" staged_version_mismatch; return 1
    fi
    if ! _aicoding_release_integrity_write "$work/release" || ! mv -T "$work/release" "$final"; then
      rm -rf "$work"; aicoding_result_record cursor failed "$target" stage_commit_failed; return 1
    fi
  fi
  rm -rf "$work" || return 1
  _aicoding_activate_vendor_release cursor "$target" agent cursor-agent cursor-agent cursor-agent \
    || { aicoding_result_record cursor failed "$target" activation_failed; return 1; }
  aicoding_result_record cursor "$state" "$target" verified "$target"
}
