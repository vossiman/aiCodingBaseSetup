# OpenCode v2 from the anomalyco/opencode GitHub releases. The repo also
# publishes v1 and other tools there, and its "latest" flag can point at v1,
# so the target is the highest plain v2.x.y tag that is neither a draft nor a
# prerelease. Every archive is checked against the release's SHA256SUMS.
AICODING_OPENCODE_RELEASES_API=${AICODING_OPENCODE_RELEASES_API:-https://api.github.com/repos/anomalyco/opencode/releases?per_page=100}
AICODING_OPENCODE_DOWNLOAD_BASE=${AICODING_OPENCODE_DOWNLOAD_BASE:-https://github.com/anomalyco/opencode/releases/download}

_aicoding_opencode_target() (
  set -o pipefail
  timeout "$AICODING_VENDOR_TIMEOUT" curl -fsSL --proto '=https' --proto-redir '=https' \
    --max-time "$AICODING_VENDOR_TIMEOUT" "$AICODING_OPENCODE_RELEASES_API" </dev/null 2>/dev/null \
    | jq -r '.[] | select((.draft | not) and (.prerelease | not)) | .tag_name
             | select(test("^v2\\.[0-9]+\\.[0-9]+$")) | ltrimstr("v")' 2>/dev/null \
    | sort -V | tail -n 1 | grep -E '^2\.[0-9]+\.[0-9]+$'
)

# glibc builds by default; musl hosts get the musl build, and x64 CPUs
# without AVX2 the baseline build.
_aicoding_opencode_asset() {
  local arch libc="" baseline=""
  case "$(uname -s):$(uname -m)" in
    Linux:x86_64|Linux:amd64) arch=x64 ;;
    Linux:aarch64|Linux:arm64) arch=arm64 ;;
    *) return 1 ;;
  esac
  compgen -G "${AICODING_OPENCODE_MUSL_GLOB:-/lib/ld-musl-*}" >/dev/null && libc=-musl
  if [ "$arch" = x64 ] && ! grep -qw avx2 "${AICODING_OPENCODE_CPUINFO:-/proc/cpuinfo}" 2>/dev/null; then
    baseline=-baseline
  fi
  printf 'opencode-linux-%s%s%s.tar.gz\n' "$arch" "$baseline" "$libc"
}

_aicoding_opencode_download() {
  aicoding_progress_run "opencode: downloading $2 (timeout ${AICODING_VENDOR_TIMEOUT}s)" \
    _aicoding_progress_capture /dev/null timeout "$AICODING_VENDOR_TIMEOUT" \
    curl -fsSL --proto '=https' --proto-redir '=https' --max-time "$AICODING_VENDOR_TIMEOUT" \
    -o "$3" "$AICODING_OPENCODE_DOWNLOAD_BASE/v$1/$2" </dev/null
}

_aicoding_opencode_checksum_ok() {
  local sums=$1 asset=$2 archive=$3 expected actual
  expected=$(awk -v a="$asset" '$2 == a && $1 ~ /^[0-9a-f]{64}$/ { print $1; n++ } END { if (n != 1) exit 1 }' "$sums") \
    || return 1
  actual=$(sha256sum "$archive" | cut -d' ' -f1) || return 1
  [ "$actual" = "$expected" ]
}

# The release archive holds one regular file, `opencode`, at its root.
# Anything else (links, directories, other names) is refused unextracted.
_aicoding_opencode_extract() {
  timeout "$AICODING_VENDOR_TIMEOUT" python3 - "$1" "$2" <<'PY'
import pathlib,shutil,sys,tarfile
archive,dest=sys.argv[1:]
try:
    with tarfile.open(archive, 'r:gz') as tar:
        members=[m for m in tar.getmembers() if m.name not in ('.', './')]
        if len(members)!=1 or not members[0].isfile(): raise ValueError('layout')
        member=members[0]
        if pathlib.PurePosixPath(member.name).parts not in (('opencode',),('.','opencode')): raise ValueError('name')
        if member.size>2*1024**3: raise ValueError('size')
        target=pathlib.Path(dest)/'opencode'
        with tar.extractfile(member) as source, target.open('xb') as output:
            shutil.copyfileobj(source,output)
        target.chmod(0o755)
except (OSError,ValueError,tarfile.TarError):
    sys.exit(1)
PY
}

_aicoding_opencode_probe() {
  local release=$1 probe_home=$2 actual
  [ -f "$release/opencode" ] && [ ! -L "$release/opencode" ] && [ -x "$release/opencode" ] || return 1
  mkdir -p "$probe_home" || return 1
  actual=$(HOME="$probe_home" XDG_CONFIG_HOME="$probe_home/.config" \
    XDG_DATA_HOME="$probe_home/.local/share" XDG_CACHE_HOME="$probe_home/.cache" \
    XDG_STATE_HOME="$probe_home/.local/state" \
    _aicoding_version_from_command "$release/opencode") || return 1
  [ "$actual" = "$3" ]
}

aicoding_update_opencode() {
  local target asset final work state=updated
  if [ "${AICODINGSETUP_SKIP_NETWORK:-0}" = 1 ]; then
    _aicoding_record_deferred opencode blocked "" network_disabled
    return 1
  fi
  asset=$(_aicoding_opencode_asset) \
    || { _aicoding_record_deferred opencode blocked "" unsupported_platform; return 1; }
  command -v python3 >/dev/null 2>&1 \
    || { _aicoding_record_deferred opencode blocked "" python_runtime_unavailable; return 1; }
  target=$(aicoding_progress_run "opencode: resolving release (timeout ${AICODING_VENDOR_TIMEOUT}s)" _aicoding_opencode_target) \
    || { aicoding_result_record opencode failed "" target_version_unavailable; return 1; }
  final="$AICODING_DATA_DIR/versions/opencode/$target"
  mkdir -p "$AICODING_DATA_DIR/versions/opencode" || return 1
  work=$(mktemp -d "$AICODING_DATA_DIR/versions/opencode/.staging.$target.XXXXXX") || return 1
  if [ -e "$final" ]; then
    if ! _aicoding_release_integrity_valid "$final" \
        || ! _aicoding_opencode_probe "$final" "$work/home" "$target"; then
      rm -rf "$work"; aicoding_result_record opencode failed "$target" existing_release_invalid; return 1
    fi
    state=current
  else
    if ! _aicoding_opencode_download "$target" SHA256SUMS "$work/SHA256SUMS" \
        || ! _aicoding_opencode_download "$target" "$asset" "$work/archive.tar.gz"; then
      rm -rf "$work"; aicoding_result_record opencode failed "$target" archive_download_failed; return 1
    fi
    if ! _aicoding_opencode_checksum_ok "$work/SHA256SUMS" "$asset" "$work/archive.tar.gz"; then
      rm -rf "$work"; aicoding_result_record opencode failed "$target" archive_checksum_mismatch; return 1
    fi
    if ! mkdir -p "$work/release" || ! aicoding_progress_run "opencode: extracting runtime (timeout ${AICODING_VENDOR_TIMEOUT}s)" _aicoding_opencode_extract "$work/archive.tar.gz" "$work/release"; then
      rm -rf "$work"; aicoding_result_record opencode failed "$target" archive_invalid; return 1
    fi
    if ! _aicoding_opencode_probe "$work/release" "$work/home" "$target"; then
      rm -rf "$work"; aicoding_result_record opencode failed "$target" staged_version_mismatch; return 1
    fi
    if ! _aicoding_release_integrity_write "$work/release" || ! mv -T "$work/release" "$final"; then
      rm -rf "$work"; aicoding_result_record opencode failed "$target" stage_commit_failed; return 1
    fi
  fi
  rm -rf "$work" || return 1
  _aicoding_activate_vendor_release opencode "$target" opencode opencode \
    || { aicoding_result_record opencode failed "$target" activation_failed; return 1; }
  aicoding_result_record opencode "$state" "$target" verified "$target"
}
