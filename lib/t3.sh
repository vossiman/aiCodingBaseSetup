#!/usr/bin/env bash
# Per-container T3 Code tooling. Sourced by bin/t3-*; never executed.
# State lives on the host (~/devpod/t3-envs, mounted at ~/.t3-envs), one
# folder per devpod workspace, so identity and login survive rebuilds.
# Spec: devMachine docs/superpowers/specs/2026-09-29-t3-per-container-design.md

T3_LIB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
T3_ENVS_ROOT="${T3_ENVS_ROOT:-$HOME/.t3-envs}"
T3_RUNTIME_ROOT="${T3_RUNTIME_ROOT:-$HOME/.local/share/t3-runtime}"
T3_MIGRATE_DIR="${T3_MIGRATE_DIR:-$HOME/.aicodingsetup/t3-migrate}"
T3_QUIET_SECONDS="${T3_QUIET_SECONDS:-3600}"
T3_IDLE_WINDOW="${T3_IDLE_WINDOW:-60}"
T3_IDLE_CPU_TICKS="${T3_IDLE_CPU_TICKS:-$(getconf CLK_TCK 2>/dev/null || echo 100)}"
T3_READY_TIMEOUT="${T3_READY_TIMEOUT:-90}"
T3_READY_SETTLE="${T3_READY_SETTLE:-30}"
T3_STOP_GRACE="${T3_STOP_GRACE:-30}"
T3_CONTROL_WAIT="${T3_CONTROL_WAIT:-60}"
T3_BOOT_RETRY_INTERVAL="${T3_BOOT_RETRY_INTERVAL:-30}"
T3_BOOT_RETRY_MAX="${T3_BOOT_RETRY_MAX:-60}"
T3_NPM_INSTALL_TIMEOUT="${T3_NPM_INSTALL_TIMEOUT:-300}"
T3_NPM_VIEW_TIMEOUT="${T3_NPM_VIEW_TIMEOUT:-30}"
export PYTHONDONTWRITEBYTECODE=1

t3_die() { printf 't3: %s\n' "$*" >&2; exit 1; }
t3_say() { printf 't3: %s\n' "$*" >&2; }

t3_valid_version() { [[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
t3_parse_version() { grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1; }
t3_version_lt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

t3_key() {
  local key="${DEVPOD_WORKSPACE_ID:-}"
  [[ "$key" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
    || t3_die "DEVPOD_WORKSPACE_ID is unset or not a safe name; t3 tools run only inside a devpod container"
  printf '%s\n' "$key"
}

# The containing mount must be the t3-envs bind, on a real disk, writable.
t3_check_mount() {
  local want line target fstype probe
  want=$(readlink -f "$T3_ENVS_ROOT" 2>/dev/null) || want=""
  line=$(findmnt -n -o TARGET,FSTYPE -T "$1" 2>/dev/null) || line=""
  read -r target fstype <<< "$line"
  if [ -z "$want" ] || [ ! -d "$T3_ENVS_ROOT" ] \
      || [ "$(readlink -f "$target" 2>/dev/null)" != "$want" ]; then
    t3_die "$T3_ENVS_ROOT is not a host mount. Add the t3-envs mount to this project's devcontainer.json, then rebuild."
  fi
  case "$fstype" in
    tmpfs|overlay) t3_die "$T3_ENVS_ROOT is on $fstype, not a host bind mount; state would not survive a rebuild" ;;
  esac
  probe=$(mktemp "$1/.t3-write-probe.XXXXXX" 2>/dev/null) \
    || t3_die "$1 is not writable. On the host: chown your user on ~/devpod/t3-envs"
  rm -f "$probe"
}

t3_env() {
  T3_KEY=$(t3_key) || exit 1
  t3_check_mount "$T3_ENVS_ROOT"
  export T3CODE_HOME="$T3_ENVS_ROOT/$T3_KEY"
  T3_STATE="$T3CODE_HOME/aicoding"
  mkdir -p "$T3_STATE" || t3_die "cannot create $T3_STATE"
  t3_check_mount "$T3CODE_HOME"
  t3_say "state: $T3CODE_HOME"
}

t3_write_file() {
  local tmp
  tmp=$(mktemp "$(dirname "$1")/.$(basename "$1").XXXXXX") || return 1
  if printf '%s\n' "$2" > "$tmp"; then mv -f "$tmp" "$1"; else rm -f "$tmp"; return 1; fi
}

t3_json_get() { jq -r "$2 // empty" "$1" 2>/dev/null; }

t3_mode() {
  local m
  m=$(t3_json_get "$T3_STATE/version.json" .mode)
  case "$m" in latest|held) printf '%s\n' "$m" ;; esac
}

t3_selected_version() {
  local v
  v=$(t3_json_get "$T3_STATE/version.json" .version)
  t3_valid_version "$v" && printf '%s\n' "$v"
}

t3_write_version() {
  t3_write_file "$T3_STATE/version.json" "$(jq -cn --arg m "$1" --arg v "$2" '{mode: $m, version: $v}')"
}

t3_auto_on() { [ -e "$T3_STATE/auto" ]; }

t3_set_up() {
  local want have
  want=$(cat "$T3_STATE/setup-done" 2>/dev/null) || return 1
  have=$(cat "$T3CODE_HOME/userdata/environment-id" 2>/dev/null) || return 1
  [ -n "$want" ] && [ "$want" = "$have" ]
}

t3_record() {
  t3_write_file "$T3_STATE/last-result.json" "$(jq -cn --arg op "$1" --arg outcome "$2" \
    --arg reason "$3" --arg detail "${4:-}" --arg at "$(date -u +%FT%TZ)" \
    '{at: $at, op: $op, outcome: $outcome, reason: $reason, detail: $detail}')"
}

# fd 8 is the control lock for the whole command. Every mutating entry point
# takes it exactly once; internal steps assume the caller holds it.
t3_control_lock() {
  exec 8>>"$T3_STATE/control.lock" || t3_die "cannot open $T3_STATE/control.lock"
  flock -w "${1:-$T3_CONTROL_WAIT}" 8 || return 1
  t3_write_file "$T3_STATE/control.holder" "$$ ${0##*/} $(date -u +%FT%TZ)"
}

t3_recover_if_needed() {
  declare -F t3_journal_recover >/dev/null || return 0
  t3_journal_recover
}

t3_entry() {
  t3_env
  t3_control_lock \
    || t3_die "another t3 command holds the control lock: $(cat "$T3_STATE/control.holder" 2>/dev/null)"
  t3_recover_if_needed
}

for _t3f in "$T3_LIB_DIR"/t3-*.sh; do
  [ -f "$_t3f" ] && . "$_t3f"
done
unset _t3f
