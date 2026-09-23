# lib/provision-scheduled.sh - additive system provisioning for the scheduled
# pass. Sourced only. Everything here installs what is missing and swaps
# binaries atomically; it never stops a process, never deletes outside its own
# temp and state files, and never prompts.

declare -F info >/dev/null 2>&1 || info() { printf 'INFO: %s\n' "$*"; }
declare -F ok >/dev/null 2>&1 || ok() { printf '  OK: %s\n' "$*"; }
declare -F warn >/dev/null 2>&1 || warn() { printf 'WARN: %s\n' "$*" >&2; }
declare -F err >/dev/null 2>&1 || err() { printf 'ERROR: %s\n' "$*" >&2; }

. "$(dirname "${BASH_SOURCE[0]}")/provision-system.sh"

AICODING_SYSTEM_APT_PACKAGES=(git git-lfs jq bubblewrap ripgrep parallel kitty-terminfo gh)

aicoding_system_provision_descriptor() {
  printf 'schema=1\n'
  printf 'apt=%s\n' "${AICODING_SYSTEM_APT_PACKAGES[*]}"
  printf 'tmux=%s\n' "$AICODING_TMUX_COMMIT_PIN"
  printf 'uv=if-missing\n'
  printf 'frogmouth=uv-tool python3.12\n'
  printf 'go=if-missing\n'
}

aicoding_system_provision_digest() {
  aicoding_system_provision_descriptor | sha256sum | cut -c1-64
}

_sched_package_present() {
  local dir
  case "$1" in
    bubblewrap) command -v bwrap >/dev/null 2>&1 ;;
    ripgrep) command -v rg >/dev/null 2>&1 ;;
    parallel) parallel --version 2>/dev/null | head -1 | grep -q "GNU parallel" ;;
    kitty-terminfo)
      for dir in ${AICODING_TERMINFO_DIRS:-/usr/share/terminfo /etc/terminfo}; do
        [ -e "$dir/x/xterm-kitty" ] && return 0
      done
      return 1 ;;
    *) command -v "$1" >/dev/null 2>&1 ;;
  esac
}

_sched_tmux_current() {
  local marker="${AICODING_TMUX_COMMIT_FILE:-/usr/local/share/aicoding/tmux-commit}" installed=""
  [ -r "$marker" ] && read -r installed < "$marker"
  [ "$installed" = "$AICODING_TMUX_COMMIT_PIN" ]
}

_sched_uv_bin() {
  if [ -x "$HOME/.local/bin/uv" ]; then printf '%s\n' "$HOME/.local/bin/uv"; return 0; fi
  command -v uv 2>/dev/null
}

_sched_pending_actions() {
  local pkg prefix="${AICODING_SYSTEM_PREFIX:-/usr/local}"
  for pkg in "${AICODING_SYSTEM_APT_PACKAGES[@]}"; do
    _sched_package_present "$pkg" || printf 'apt:%s\n' "$pkg"
  done
  _sched_tmux_current || printf 'tmux\n'
  _sched_uv_bin >/dev/null || printf 'uv\n'
  [ -x "$prefix/bin/frogmouth" ] || printf 'frogmouth\n'
  [ -x "${AICODING_GO_ROOT:-/usr/local/go}/bin/go" ] || command -v go >/dev/null 2>&1 || printf 'go\n'
  return 0
}

# First reason wins; later steps must not overwrite the cause of a failure.
_sched_note_reason() {
  [ -n "${_SCHED_REASON_FILE:-}" ] || return 0
  [ -s "$_SCHED_REASON_FILE" ] || printf '%s\n' "$1" > "$_SCHED_REASON_FILE"
}

# Non-interactive, bounded apt. No source-file cleanup, unlike apt_install.
_sched_apt_install() {
  command -v apt-get >/dev/null 2>&1 || { _sched_note_reason apt_unavailable; return 3; }
  local -a opts=(
    -o Acquire::http::Timeout=10
    -o Acquire::https::Timeout=10
    -o Acquire::Retries=1
    -o DPkg::Lock::Timeout=120
  )
  local errf rc=0
  errf=$(mktemp "${TMPDIR:-/tmp}/aicoding-apt.XXXXXX") || return 1
  timeout --kill-after=30 900 sudo -n apt-get "${opts[@]}" update -qq </dev/null >/dev/null 2>"$errf" || rc=$?
  if [ "$rc" -ne 0 ] && grep -qE 'Could not get lock|Unable to acquire the dpkg frontend lock|Unable to lock directory' "$errf"; then
    rm -f "$errf"; _sched_note_reason apt_lock_busy; return 3
  fi
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    rm -f "$errf"; _sched_note_reason apt_timeout; return 1
  fi
  rc=0
  timeout --kill-after=30 900 sudo -n env DEBIAN_FRONTEND=noninteractive \
    apt-get "${opts[@]}" install -y --no-install-recommends "$@" </dev/null >/dev/null 2>"$errf" || rc=$?
  if [ "$rc" -eq 0 ]; then rm -f "$errf"; return 0; fi
  if grep -qE 'Could not get lock|Unable to acquire the dpkg frontend lock|Unable to lock directory' "$errf"; then
    rm -f "$errf"; _sched_note_reason apt_lock_busy; return 3
  fi
  rm -f "$errf"
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then _sched_note_reason apt_timeout; else _sched_note_reason apt_install_failed; fi
  return 1
}

ensure_frogmouth() {
  local prefix="${AICODING_SYSTEM_PREFIX:-/usr/local}" opt="${AICODING_UV_OPT_DIR:-/opt/uv}" uv
  [ -x "$prefix/bin/frogmouth" ] && return 0
  uv=$(_sched_uv_bin) || { warn "frogmouth: uv is missing"; return 1; }
  # Same layout as image/Dockerfile: root-owned /opt/uv, not the uv bind mount.
  $SUDO env UV_PYTHON_INSTALL_DIR="$opt/python" UV_TOOL_DIR="$opt/tools" UV_TOOL_BIN_DIR="$prefix/bin" \
    "$uv" tool install --python 3.12 frogmouth </dev/null || return 1
  [ -x "$prefix/bin/frogmouth" ]
}

# Run one function in a fresh shell under a hard time limit. timeout signals
# its own process group, so a hung make or curl dies with it.
_sched_bounded() {
  local secs=$1 fn=$2
  (
    export -f "$fn" _sched_apt_install _sched_note_reason _sched_uv_bin info ok warn err
    export SUDO _SCHED_REASON_FILE AICODING_TMUX_COMMIT_PIN AICODING_TMUX_COMMIT_FILE \
      AICODING_TMUX_PREFIX AICODING_SYSTEM_PREFIX AICODING_UV_OPT_DIR TMPDIR
    export AICODING_TMUX_STRICT=1 AICODING_TMUX_APT_FN=_sched_apt_install \
      AICODING_TMUX_BUILD_JOBS=2 AICODING_TMUX_LOW_PRIORITY=1
    # The orchestrator already decided network use is allowed.
    export AICODINGSETUP_SKIP_NETWORK=
    # The uv installer edits shell rc files unless told not to; the managed
    # bashrc block already puts ~/.local/bin on PATH.
    export UV_NO_MODIFY_PATH=1
    timeout --kill-after=30 "$secs" bash -c "$fn"
  )
}

# $1: newline-separated output of _sched_pending_actions.
ensure_system_packages_scheduled() {
  local pending=$1 action rc worst=0
  local -a apt_pkgs=()
  local SUDO="sudo -n"
  while IFS= read -r action; do
    case "$action" in apt:*) apt_pkgs+=("${action#apt:}") ;; esac
  done <<< "$pending"
  if [ "${#apt_pkgs[@]}" -gt 0 ]; then
    rc=0; _sched_apt_install "${apt_pkgs[@]}" || rc=$?
    _sched_merge_rc "$rc" apt_install_failed; worst=$?
  fi
  while IFS= read -r action; do
    case "$action" in
      tmux) rc=0; _sched_bounded 1800 ensure_tmux || rc=$?; _sched_merge_rc "$rc" tmux_build_failed "$worst"; worst=$? ;;
      uv) rc=0; _sched_bounded 600 ensure_uv || rc=$?; _sched_merge_rc "$rc" uv_install_failed "$worst"; worst=$? ;;
      frogmouth) rc=0; _sched_bounded 900 ensure_frogmouth || rc=$?; _sched_merge_rc "$rc" frogmouth_install_failed "$worst"; worst=$? ;;
      go) rc=0; _sched_bounded 600 ensure_go || rc=$?; _sched_merge_rc "$rc" go_install_failed "$worst"; worst=$? ;;
    esac
  done <<< "$pending"
  return "$worst"
}

# Combine a step status into the running worst status: failed (1) beats
# blocked (3) beats ok (0). Timeouts (124, 137) count as failed.
_sched_merge_rc() {
  local rc=$1 reason=$2 worst=${3:-0}
  case "$rc" in
    0) return "$worst" ;;
    3) _sched_note_reason "$reason"; [ "$worst" -eq 1 ] && return 1; return 3 ;;
    124|137) _sched_note_reason "${reason%_failed}_timeout"; return 1 ;;
    *) _sched_note_reason "$reason"; return 1 ;;
  esac
}

aicoding_run_system_provision() {
  if [ "${AICODINGSETUP_SKIP_NETWORK:-}" = 1 ] && [ "${AICODING_SYSTEM_PROVISION_RUN_OFFLINE:-0}" != 1 ]; then
    return 0
  fi
  local digest recorded pending rc=0 reason
  digest=$(aicoding_system_provision_digest) || return 1
  recorded=$(jq -r '.components["provision-system"].successful_version // empty' "$AICODING_RESULTS_FILE" 2>/dev/null || true)
  [ "$recorded" = "$digest" ] && return 0
  pending=$(_sched_pending_actions)
  if [ -z "$pending" ]; then
    aicoding_result_record provision-system current "$digest" verified "$digest"
    return $?
  fi
  if ! timeout --kill-after=5 15 sudo -n true </dev/null >/dev/null 2>&1; then
    aicoding_result_record provision-system blocked "$digest" sudo_unavailable || true
    return 3
  fi
  mkdir -p "$AICODING_STATE_DIR" || return 1
  _SCHED_REASON_FILE=$(mktemp "$AICODING_STATE_DIR/.provision-system-reason.XXXXXX") || return 1
  ensure_system_packages_scheduled "$pending" || rc=$?
  reason=$(head -1 "$_SCHED_REASON_FILE" 2>/dev/null || true)
  rm -f "$_SCHED_REASON_FILE"
  _SCHED_REASON_FILE=
  if [ "$rc" -eq 0 ]; then
    pending=$(_sched_pending_actions)
    if [ -z "$pending" ]; then
      aicoding_result_record provision-system updated "$digest" installed "$digest"
      return $?
    fi
    reason="verification_failed:$(printf '%s' "$pending" | tr '\n' ',' | cut -c1-150)"
    aicoding_result_record provision-system failed "$digest" "$reason" || true
    return 1
  fi
  if [ "$rc" -eq 3 ]; then
    aicoding_result_record provision-system blocked "$digest" "${reason:-system_provision_blocked}" || true
    return 3
  fi
  aicoding_result_record provision-system failed "$digest" "${reason:-system_provision_failed}" || true
  return 1
}
