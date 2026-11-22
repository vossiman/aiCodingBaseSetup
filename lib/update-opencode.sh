# OpenCode v2 from the anomalyco/opencode GitHub releases. The repo also
# publishes v1 and other tools there, and its "latest" flag can point at v1,
# so the target is the highest plain v2.x.y tag that is neither a draft nor a
# prerelease. Every archive is checked against the release's SHA256SUMS.
# The binary lives at node_modules/.bin/opencode, the path the npm v1 releases
# used. lib/runtime.sh only publishes a changed launcher whose executable also
# exists in the old release, so keeping the path lets an active v1 release
# hand over to v2.
AICODING_OPENCODE_BIN=node_modules/.bin/opencode
AICODING_OPENCODE_RELEASES_API=${AICODING_OPENCODE_RELEASES_API:-https://api.github.com/repos/anomalyco/opencode/releases?per_page=100}
AICODING_OPENCODE_DOWNLOAD_BASE=${AICODING_OPENCODE_DOWNLOAD_BASE:-https://github.com/anomalyco/opencode/releases/download}

# Follows the Link header for at most AICODING_OPENCODE_MAX_PAGES pages, and
# only to further api.github.com pages.
_aicoding_opencode_target() (
  set -o pipefail
  local url=$AICODING_OPENCODE_RELEASES_API page=0 tags="" headers body next
  headers=$(mktemp) && body=$(mktemp) || exit 1
  trap 'rm -f "$headers" "$body"' EXIT
  while [ -n "$url" ] && [ "$page" -lt "${AICODING_OPENCODE_MAX_PAGES:-5}" ]; do
    page=$((page + 1))
    timeout "$AICODING_VENDOR_TIMEOUT" curl -fsSL --proto '=https' --proto-redir '=https' \
      --max-time "$AICODING_VENDOR_TIMEOUT" -D "$headers" -o "$body" "$url" </dev/null 2>/dev/null || exit 1
    tags+=$(jq -r '.[] | select((.draft | not) and (.prerelease | not)) | .tag_name' "$body" 2>/dev/null)$'\n' || exit 1
    next=$(tr -d '\r' < "$headers" | grep -i '^link:' | sed 's/^[Ll][Ii][Nn][Kk]:[[:space:]]*//' | tr ',' '\n' \
      | sed -n 's/^[[:space:]]*<\(https:\/\/api\.github\.com\/[^>]*\)>;[[:space:]]*rel="next".*/\1/p' | head -n 1)
    url=$next
  done
  printf '%s' "$tags" | grep -E '^v2\.[0-9]+\.[0-9]+$' | sed 's/^v//' | sort -V | tail -n 1 | grep -E '^2\.[0-9]+\.[0-9]+$'
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

# A failed download keeps curl's last error lines in the diagnostics log that
# archive_download_failed points to.
_aicoding_opencode_download() {
  local log="$AICODING_STATE_DIR/diagnostics/opencode-download.log" err
  mkdir -p "${log%/*}" || return 1
  err=$(mktemp) || return 1
  if aicoding_progress_run "opencode: downloading $2 (timeout ${AICODING_VENDOR_TIMEOUT}s)" \
      _aicoding_progress_capture "$err" timeout "$AICODING_VENDOR_TIMEOUT" \
      curl -fsSL --proto '=https' --proto-redir '=https' --max-time "$AICODING_VENDOR_TIMEOUT" \
      -o "$3" "$AICODING_OPENCODE_DOWNLOAD_BASE/v$1/$2" </dev/null; then
    rm -f "$err"; return 0
  fi
  { printf '%s opencode v%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2"; tail -c 2000 "$err"; } > "$log"
  rm -f "$err"
  return 1
}

_aicoding_opencode_checksum_ok() {
  local sums=$1 asset=$2 archive=$3 expected actual
  # No regex intervals: older mawk does not support {64}.
  expected=$(awk -v a="$asset" '$2 == a && length($1) == 64 && $1 !~ /[^0-9a-f]/ { print $1; n++ } END { if (n != 1) exit 1 }' "$sums") \
    || return 1
  actual=$(sha256sum "$archive" | cut -d' ' -f1) || return 1
  [ "$actual" = "$expected" ]
}

# The release archive holds one regular file, `opencode`, at its root. The
# only other entry tolerated is a root directory marker (`.` or `./`) that
# really is a directory, as some tar builds emit; every other entry (links,
# directories, other names, a second copy) is refused unextracted. The file
# is written to DEST/node_modules/.bin/opencode.
_aicoding_opencode_extract() {
  timeout "$AICODING_VENDOR_TIMEOUT" python3 - "$1" "$2" <<'PY'
import pathlib,shutil,sys,tarfile
archive,dest=sys.argv[1:]
try:
    with tarfile.open(archive, 'r:gz') as tar:
        members=[]
        for m in tar.getmembers():
            if m.name in ('.', './'):
                if not m.isdir(): raise ValueError('root marker')
                continue
            members.append(m)
        if len(members)!=1 or not members[0].isfile(): raise ValueError('layout')
        member=members[0]
        if pathlib.PurePosixPath(member.name).parts not in (('opencode',),('.','opencode')): raise ValueError('name')
        if member.size>2*1024**3: raise ValueError('size')
        target=pathlib.Path(dest)/'node_modules'/'.bin'/'opencode'
        target.parent.mkdir(parents=True, exist_ok=True)
        with tar.extractfile(member) as source, target.open('xb') as output:
            shutil.copyfileobj(source,output)
        target.chmod(0o755)
except (OSError,ValueError,tarfile.TarError):
    sys.exit(1)
PY
}

_aicoding_opencode_probe() {
  local release=$1 probe_home=$2 actual
  local bin="$release/$AICODING_OPENCODE_BIN"
  [ -f "$bin" ] && [ ! -L "$bin" ] && [ -x "$bin" ] || return 1
  mkdir -p "$probe_home" || return 1
  actual=$(HOME="$probe_home" XDG_CONFIG_HOME="$probe_home/.config" \
    XDG_DATA_HOME="$probe_home/.local/share" XDG_CACHE_HOME="$probe_home/.cache" \
    XDG_STATE_HOME="$probe_home/.local/state" \
    _aicoding_version_from_command "$bin") || return 1
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
  _aicoding_activate_vendor_release opencode "$target" opencode "$AICODING_OPENCODE_BIN" \
    || { aicoding_result_record opencode failed "$target" activation_failed; return 1; }
  aicoding_result_record opencode "$state" "$target" verified "$target"
}
