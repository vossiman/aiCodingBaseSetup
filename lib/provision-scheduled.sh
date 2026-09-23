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
