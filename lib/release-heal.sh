# lib/release-heal.sh: heal aicoding releases whose digest broke only because
# Python bytecode was written into them after staging.
# Sourced by lib/blueprint-deploy.sh, which calls
# aicoding_heal_release_bytecode_when_staging at its own source time.
#
# Before PR #187, kanban-work let Python write lib/kanban_work/__pycache__
# into the active release. That breaks the release digest, and the old
# activation code then refuses to move away from the corrupt current release.
# Old code runs new code only one way: _sync_capture_generated_provenance
# sources the newly staged clone's lib/blueprint-deploy.sh (with
# AICODING_BLUEPRINT_CLONE set to that clone) before activation validates the
# current release. So the heal runs in exactly that staging context and never
# for ordinary sourcing (reconcile, --dry-run, install).
#
# The repo tracks some bytecode (tools/render-debug/__pycache__), which the
# digest covers. So a __pycache__ directory is removed only when it is newer
# than the release digest AND the digest matches once those directories are
# left out. Symlinks are never followed. Removing bytecode under a running
# Python is harmless: the import system ignores failures to write its cache.

# _aicoding_release_digest_matches RELEASE [DIR...]: the recorded digest
# matches the release tree with the given directories left out. Same recipe
# as _aicoding_runtime_tree_digest_impl (lib/runtime.sh).
_aicoding_release_digest_matches() {
  local release=$1 digest=$1/.aicoding-tree.sha256 expected actual dir
  local -a excludes=()
  shift
  [ -f "$digest" ] && [ ! -L "$digest" ] || return 1
  expected=$(cat "$digest" 2>/dev/null) || return 1
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
  for dir in "$@"; do excludes+=("--exclude=.${dir#"$release"}"); done
  actual=$(
    set -o pipefail
    tar -C "$release" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
      --format=gnu --exclude='./.aicoding-tree.sha256' \
      --anchored --no-wildcards ${excludes[@]+"${excludes[@]}"} -cf - . 2>/dev/null \
      | sha256sum | awk '{print $1}'
  ) || return 1
  [ "$actual" = "$expected" ]
}

# _aicoding_heal_release_bytecode_pass VERSIONS_DIR: one heal over every
# release under VERSIONS_DIR/<component>/<version>. Silent; returns 0.
_aicoding_heal_release_bytecode_pass() {
  local versions=$1 release dir
  local -a stale=()
  [ -d "$versions" ] && [ ! -L "$versions" ] || return 0
  while IFS= read -r -d '' release; do
    [ -f "$release/.aicoding-tree.sha256" ] && [ ! -L "$release/.aicoding-tree.sha256" ] || continue
    stale=()
    while IFS= read -r -d '' dir; do
      stale+=("$dir")
    done < <(find "$release" -type d -name __pycache__ -prune \
      -newer "$release/.aicoding-tree.sha256" -print0 2>/dev/null)
    [ "${#stale[@]}" -gt 0 ] || continue
    _aicoding_release_digest_matches "$release" "${stale[@]}" || continue
    rm -rf -- "${stale[@]}" 2>/dev/null || true
  done < <(find "$versions" -mindepth 2 -maxdepth 2 -type d ! -name '.*' -print0 2>/dev/null)
  return 0
}

# _aicoding_release_bytecode_healer DATA SHA PID SECONDS INTERVAL LOCK: keep
# healing until the staged SHA is active, or the staging process PID is gone
# and the current release validates, or SECONDS have passed. One instance at a
# time. Runs detached, so it first closes every inherited descriptor: sync
# holds lock descriptors, and command substitutions wait on their pipe.
_aicoding_release_bytecode_healer() {
  local data=$1 sha=$2 pid=$3 seconds=$4 interval=$5 lock=$6 fd current target
  local -a fds=()
  for fd in /proc/$BASHPID/fd/*; do fds+=("${fd##*/}"); done
  for fd in "${fds[@]}"; do
    case "$fd" in ''|*[!0-9]*) continue ;; esac
    [ "$fd" -gt 2 ] && eval "exec $fd>&-" 2>/dev/null
  done
  exec 9>>"$lock" || return 0
  flock -n 9 || return 0
  local end=$((SECONDS + seconds))
  while [ "$SECONDS" -lt "$end" ]; do
    [ -d "$data/versions" ] || return 0
    _aicoding_heal_release_bytecode_pass "$data/versions"
    current=$(readlink "$data/current/aicoding" 2>/dev/null) || current=
    [ "${current##*/}" = "$sha" ] && return 0
    if ! kill -0 "$pid" 2>/dev/null; then
      target=$(readlink -f -- "$data/current/aicoding" 2>/dev/null) \
        && _aicoding_release_digest_matches "$target" && return 0
    fi
    sleep "$interval" 2>/dev/null || return 0
  done
  return 0
}

# aicoding_heal_release_bytecode_when_staging LIB_DIR: LIB_DIR is the lib/
# directory of the blueprint-deploy.sh being sourced. Heals only when that
# blueprint is a fresh staging clone, i.e. it lives at
# <data>/source-staging/aicoding.<sha>.<pid>, has a .git directory, and is the
# AICODING_BLUEPRINT_CLONE of the sourcing shell. Then it heals once and
# starts a bounded detached healer that keeps the release clean through
# activation, because an old kanban-work hook can recreate the bytecode in
# between. Silent; returns 0; runs at most once per process.
aicoding_heal_release_bytecode_when_staging() {
  [ -z "${_AICODING_RELEASE_BYTECODE_HEALED:-}" ] || return 0
  _AICODING_RELEASE_BYTECODE_HEALED=1
  local lib_dir=$1 root clone data staging name sha pid state seconds interval
  root=$(cd -- "$lib_dir/.." 2>/dev/null && pwd -P) || return 0
  [ -n "${AICODING_BLUEPRINT_CLONE:-}" ] || return 0
  clone=$(cd -- "$AICODING_BLUEPRINT_CLONE" 2>/dev/null && pwd -P) || return 0
  [ "$clone" = "$root" ] && [ -d "$root/.git" ] || return 0
  data=${AICODING_DATA_DIR:-}
  if [ -z "$data" ]; then
    [ -n "${HOME:-}" ] || return 0
    data=$HOME/.local/share/aicoding
  fi
  staging=$(cd -- "$data/source-staging" 2>/dev/null && pwd -P) || return 0
  [ "${root%/*}" = "$staging" ] || return 0
  name=${root##*/}
  [[ "$name" =~ ^aicoding\.([0-9a-f]{40})\.([0-9]+)$ ]] || return 0
  sha=${BASH_REMATCH[1]} pid=${BASH_REMATCH[2]}
  [ -d "$data/versions" ] && [ ! -L "$data/versions" ] || return 0

  _aicoding_heal_release_bytecode_pass "$data/versions"

  seconds=${AICODING_RELEASE_HEALER_SECONDS:-180}
  interval=${AICODING_RELEASE_HEALER_INTERVAL:-0.5}
  [[ "$seconds" =~ ^[0-9]+$ ]] && [ "$seconds" -gt 0 ] || return 0
  command -v flock >/dev/null 2>&1 && command -v setsid >/dev/null 2>&1 || return 0
  state=${AICODING_STATE_DIR:-$HOME/.local/state/aicoding}
  mkdir -p "$state" 2>/dev/null || return 0
  # The healer body travels as text: the staging clone is deleted right
  # after staging, so the detached process cannot source this file later.
  setsid bash -c "$(declare -f _aicoding_release_digest_matches \
      _aicoding_heal_release_bytecode_pass _aicoding_release_bytecode_healer)
_aicoding_release_bytecode_healer \"\$@\"" _ \
    "$data" "$sha" "$pid" "$seconds" "$interval" "$state/release-bytecode-healer.lock" \
    </dev/null >/dev/null 2>&1 &
  return 0
}
