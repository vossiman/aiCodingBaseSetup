# lib/runtime.sh — immutable release staging and stable command activation.
# Sourced by installers and update adapters; intentionally does not change
# shell options because callers use both strict and non-strict modes.

: "${AICODING_DATA_DIR:=$HOME/.local/share/aicoding}"
: "${AICODING_STATE_DIR:=$HOME/.local/state/aicoding}"

_aicoding_runtime_safe_segment() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]
}

_aicoding_runtime_tree_digest() {
  local root=$1
  (
    set -o pipefail
    tar -C "$root" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
      --format=gnu --exclude='./.aicoding-tree.sha256' -cf - . \
      | sha256sum | awk '{print $1}'
  )
}

_aicoding_runtime_validate_release_path() {
  local release=$1 version=$2 expected actual link
  [ -d "$release" ] && [ ! -L "$release" ] || return 1
  # Source snapshots carry a digest and may not retain links to mutable
  # resources outside the release. Vendor adapters validate their own older
  # package trees, whose package-local links remain compatible here.
  if [ -e "$release/.aicoding-tree.sha256" ]; then
    [ -f "$release/.aicoding-tree.sha256" ] && [ ! -L "$release/.aicoding-tree.sha256" ] || return 1
    link=$(find "$release" -type l -print -quit) || return 1
    [ -z "$link" ] || return 1
  fi
  # A present identity marker is authoritative. Vendor releases predating it
  # remain compatible with their adapter-specific validator.
  if [ -e "$release/.aicoding-version" ]; then
    [ -f "$release/.aicoding-version" ] && [ ! -L "$release/.aicoding-version" ] || return 1
    [ "$(cat "$release/.aicoding-version" 2>/dev/null)" = "$version" ] || return 1
  fi
  if [ -e "$release/.aicoding-tree.sha256" ]; then
    expected=$(cat "$release/.aicoding-tree.sha256" 2>/dev/null) || return 1
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
    actual=$(_aicoding_runtime_tree_digest "$release") || return 1
    [ "$actual" = "$expected" ] || return 1
  fi
}

_aicoding_runtime_validate_release() {
  local component=$1 version=$2 release
  _aicoding_runtime_safe_segment "$component" || return 2
  _aicoding_runtime_safe_segment "$version" || return 2
  release="$AICODING_DATA_DIR/versions/$component/$version"
  _aicoding_runtime_validate_release_path "$release" "$version"
}

_aicoding_runtime_copy_source() {
  local source=$1 stage=$2
  (
    set -o pipefail
    tar -C "$source" --exclude='./.git' -cf - . | tar -C "$stage" -xf -
  )
}

_aicoding_runtime_publish_release() { mv -T -- "$1" "$2"; }

# aicoding_stage_source COMPONENT SOURCE VERSION
#
# Copy a caller-qualified source tree into its immutable version directory.
# The caller remains responsible for trust/CI selection. A content digest is
# stored so a reused source release cannot silently accept altered resources.
aicoding_stage_source() (
  [ "$#" -eq 3 ] || return 2
  local component=$1 source=$2 version=$3 final parent stage="" digest link
  _aicoding_runtime_safe_segment "$component" || return 2
  _aicoding_runtime_safe_segment "$version" || return 2
  [ -d "$source" ] || return 1
  [ "$(cat "$source/.aicoding-version" 2>/dev/null)" = "$version" ] || return 1
  link=$(find "$source" -path "$source/.git" -prune -o -type l -print -quit) || return 1
  [ -z "$link" ] || return 1

  parent="$AICODING_DATA_DIR/versions/$component"
  final="$parent/$version"
  mkdir -p "$parent" || return 1
  if [ -e "$final" ] || [ -L "$final" ]; then
    _aicoding_runtime_validate_release "$component" "$version" || return $?
    [ -f "$final/.aicoding-tree.sha256" ] && [ ! -L "$final/.aicoding-tree.sha256" ]
    return $?
  fi

  stage=$(mktemp -d "$parent/.staging.$version.XXXXXX") || return 1
  _aicoding_runtime_stage_signal() {
    local signal=$1 code=$2 retained=""
    trap - TERM INT HUP
    if ! rm -rf -- "$stage"; then retained=$stage; fi
    printf 'aicoding runtime: staging interrupted by %s\n' "$signal" >&2
    [ -z "$retained" ] || printf 'aicoding runtime: unpublished staging tree retained at %s\n' "$retained" >&2
    exit "$code"
  }
  trap '_aicoding_runtime_stage_signal TERM 143' TERM
  trap '_aicoding_runtime_stage_signal INT 130' INT
  trap '_aicoding_runtime_stage_signal HUP 129' HUP

  if ! _aicoding_runtime_copy_source "$source" "$stage"; then
    trap - TERM INT HUP
    rm -rf -- "$stage" 2>/dev/null || true
    return 1
  fi
  if ! printf '%s\n' "$version" > "$stage/.aicoding-version"; then
    trap - TERM INT HUP
    rm -rf -- "$stage" 2>/dev/null || true
    return 1
  fi
  digest=$(_aicoding_runtime_tree_digest "$stage") || {
    trap - TERM INT HUP
    rm -rf -- "$stage" 2>/dev/null || true
    return 1
  }
  if ! printf '%s\n' "$digest" > "$stage/.aicoding-tree.sha256" \
      || ! _aicoding_runtime_validate_release_path "$stage" "$version"; then
    trap - TERM INT HUP
    rm -rf -- "$stage" 2>/dev/null || true
    return 1
  fi
  # Catch a selected source replaced while it was being copied.
  if [ "$(cat "$source/.aicoding-version" 2>/dev/null)" != "$version" ]; then
    trap - TERM INT HUP
    rm -rf -- "$stage" 2>/dev/null || true
    return 1
  fi
  if ! _aicoding_runtime_publish_release "$stage" "$final"; then
    rm -rf -- "$stage" 2>/dev/null || true
    stage=""
    trap - TERM INT HUP
    # A concurrent publisher may have won. It is reusable only if it validates.
    _aicoding_runtime_validate_release "$component" "$version" \
      && [ -f "$final/.aicoding-tree.sha256" ] && [ ! -L "$final/.aicoding-tree.sha256" ]
    return $?
  fi
  stage=""
  trap - TERM INT HUP
  if ! _aicoding_runtime_validate_release "$component" "$version"; then
    rm -rf -- "$final" 2>/dev/null || true
    return 1
  fi
)

_aicoding_runtime_write_wrapper() {
  local output=$1 current=$2 relative=$3 quoted_current quoted_relative
  printf -v quoted_current '%q' "$current"
  printf -v quoted_relative '%q' "$relative"
  {
    printf '%s\n' '#!/usr/bin/env bash' '# Managed by aicoding immutable runtime.'
    printf 'current=%s\nrelative=%s\n' "$quoted_current" "$quoted_relative"
    printf '%s\n' \
      'release=$(readlink -f -- "$current") || exit 1' \
      '[ -x "$release/$relative" ] || exit 1' \
      'exec "$release/$relative" "$@"'
  } > "$output" || return 1
  chmod 0755 "$output"
}

_aicoding_runtime_restore_path() {
  local snapshot=$1 destination=$2 existed=$3 parent restore_dir
  if [ "$existed" -ne 1 ]; then
    rm -f -- "$destination"
    return $?
  fi
  parent=${destination%/*}
  restore_dir=$(mktemp -d "$parent/.aicoding-restore.XXXXXX") || return 1
  if ! cp -a --no-dereference -- "$snapshot" "$restore_dir/item"; then
    rm -rf -- "$restore_dir" 2>/dev/null || true
    return 1
  fi
  if ! mv -Tf -- "$restore_dir/item" "$destination"; then
    rm -rf -- "$restore_dir" 2>/dev/null || true
    return 1
  fi
  rmdir -- "$restore_dir"
}

_aicoding_runtime_commit_path() {
  local source=$1 destination=$2 parent base publish_dir
  parent=${destination%/*}
  base=${destination##*/}
  publish_dir=$(mktemp -d "$parent/.${base}.publish.XXXXXX") || return 1
  _aicoding_runtime_pending_temp=$publish_dir
  if ! cp -a --no-dereference -- "$source" "$publish_dir/item"; then
    rm -rf -- "$publish_dir" 2>/dev/null || true
    _aicoding_runtime_pending_temp=""
    return 1
  fi
  if ! mv -Tf -- "$publish_dir/item" "$destination"; then
    rm -rf -- "$publish_dir" 2>/dev/null || true
    _aicoding_runtime_pending_temp=""
    return 1
  fi
  if ! rmdir -- "$publish_dir"; then
    _aicoding_runtime_pending_temp=$publish_dir
    return 1
  fi
  _aicoding_runtime_pending_temp=""
}

_aicoding_runtime_switch_link() {
  local root=$1 name=$2 target=$3 temporary
  temporary=$(mktemp -d "$root/.${name}.link.XXXXXX") || return 1
  _aicoding_runtime_pending_temp=$temporary
  if ! ln -s -- "$target" "$temporary/item"; then
    rm -rf -- "$temporary" 2>/dev/null || true
    _aicoding_runtime_pending_temp=""
    return 1
  fi
  if ! mv -Tf -- "$temporary/item" "$root/$name"; then
    rm -rf -- "$temporary" 2>/dev/null || true
    _aicoding_runtime_pending_temp=""
    return 1
  fi
  if ! rmdir -- "$temporary"; then return 1; fi
  _aicoding_runtime_pending_temp=""
}

_aicoding_runtime_commit_wrapper() { _aicoding_runtime_commit_path "$1" "$2"; }
_aicoding_runtime_commit_backup() { _aicoding_runtime_commit_path "$1" "$2"; }
_aicoding_runtime_commit_previous() { _aicoding_runtime_switch_link "$1" "$2" "$3"; }
_aicoding_runtime_commit_current() { _aicoding_runtime_switch_link "$1" "$2" "$3"; }

_aicoding_runtime_release_target() {
  local component=$1 link=$2 target version
  [ -L "$link" ] || return 1
  target=$(readlink -- "$link") || return 1
  case "$target" in
    "../versions/$component/"*) version=${target#"../versions/$component/"} ;;
    *) return 1 ;;
  esac
  _aicoding_runtime_safe_segment "$version" || return 1
  [ "$target" = "../versions/$component/$version" ] || return 1
  _aicoding_runtime_validate_release "$component" "$version" || return 1
  printf '%s\n' "$target"
}

_aicoding_runtime_validate_executable() {
  local release=$1 relative=$2 release_real resolved
  [ -x "$release/$relative" ] || return 1
  release_real=$(readlink -f -- "$release") || return 1
  resolved=$(readlink -f -- "$release/$relative") || return 1
  case "$resolved" in "$release_real"/*) return 0 ;; *) return 1 ;; esac
}

# aicoding_activate_version COMPONENT VERSION [LAUNCHER RELATIVE_BIN ...]
#
# Every relative executable is checked before any live path changes. The
# A first legacy enrollment publishes current before replacing its launcher.
# A managed upgrade prepares previous and changed wrappers before publishing
# current as its final fallible activation operation. Wrappers resolve current
# once and exec a physical script, keeping sibling resources version-stable.
aicoding_activate_version() (
  [ "$#" -ge 2 ] || return 2
  local component=$1 version=$2
  shift 2
  [ $(( $# % 2 )) -eq 0 ] || return 2
  _aicoding_runtime_validate_release "$component" "$version" || return $?

  local release="$AICODING_DATA_DIR/versions/$component/$version"
  local current_root="$AICODING_DATA_DIR/current"
  local previous_root="$AICODING_DATA_DIR/previous"
  local bin_root="$HOME/.local/bin"
  local recovery_root="$AICODING_STATE_DIR/activation-recovery"
  local lock_root="$AICODING_STATE_DIR/locks"
  mkdir -p "$current_root" "$previous_root" "$bin_root" "$recovery_root" "$lock_root" || return 1

  local lock_fd
  exec {lock_fd}>"$lock_root/$component.lock" || return 1
  flock "$lock_fd" || { exec {lock_fd}>&-; return 1; }

  local transaction
  transaction=$(mktemp -d "$recovery_root/.${component}.${version}.XXXXXX") || {
    exec {lock_fd}>&-
    return 1
  }

  local current="$current_root/$component" previous="$previous_root/$component"
  local current_existed=0 previous_existed=0 old_target="" desired_target="../versions/$component/$version"
  local current_touched=0 previous_touched=0 activation_started=0
  local _aicoding_runtime_pending_temp=""
  local -a launchers=() relatives=() launcher_existed=() launcher_changed=() launcher_touched=() backup_created=()
  local launcher relative dest backup i=0 j duplicate

  _aicoding_runtime_activation_rollback() {
    local rollback_failed=0 rollback_i
    trap - TERM INT HUP
    if [ -n "$_aicoding_runtime_pending_temp" ]; then
      rm -rf -- "$_aicoding_runtime_pending_temp" 2>/dev/null || rollback_failed=1
      _aicoding_runtime_pending_temp=""
    fi
    rm -rf -- "$current_root/.${component}.link."* "$previous_root/.${component}.link."* 2>/dev/null || true
    if [ "$current_touched" -eq 1 ]; then
      _aicoding_runtime_restore_path "$transaction/current" "$current" "$current_existed" || rollback_failed=1
    fi
    for ((rollback_i=0; rollback_i<${#launchers[@]}; rollback_i++)); do
      if [ "${launcher_touched[$rollback_i]:-0}" -eq 1 ]; then
        _aicoding_runtime_restore_path "$transaction/launcher.$rollback_i" \
          "$bin_root/${launchers[$rollback_i]}" "${launcher_existed[$rollback_i]}" || rollback_failed=1
      fi
      if [ "${backup_created[$rollback_i]:-0}" -eq 1 ]; then
        rm -f -- "$bin_root/${launchers[$rollback_i]}.pre-aicoding" || rollback_failed=1
      fi
    done
    if [ "$previous_touched" -eq 1 ]; then
      _aicoding_runtime_restore_path "$transaction/previous" "$previous" "$previous_existed" || rollback_failed=1
    fi
    if [ "$rollback_failed" -eq 0 ]; then
      rm -rf -- "$transaction" || {
        printf 'aicoding runtime: rollback complete; recovery cleanup failed at %s\n' "$transaction" >&2
        rollback_failed=1
      }
    fi
    if [ "$rollback_failed" -ne 0 ]; then
      printf 'aicoding runtime: rollback incomplete; recovery retained at %s\n' "$transaction" >&2
    fi
    return "$rollback_failed"
  }

  _aicoding_runtime_activation_signal() {
    local signal=$1 code=$2
    trap - TERM INT HUP
    if [ "$activation_started" -eq 1 ]; then
      _aicoding_runtime_activation_rollback || true
    else
      rm -rf -- "$transaction" 2>/dev/null || \
        printf 'aicoding runtime: unpublished activation preparation retained at %s\n' "$transaction" >&2
    fi
    printf 'aicoding runtime: activation interrupted by %s\n' "$signal" >&2
    exec {lock_fd}>&-
    exit "$code"
  }
  trap '_aicoding_runtime_activation_signal TERM 143' TERM
  trap '_aicoding_runtime_activation_signal INT 130' INT
  trap '_aicoding_runtime_activation_signal HUP 129' HUP

  if [ -e "$current" ] || [ -L "$current" ]; then
    old_target=$(_aicoding_runtime_release_target "$component" "$current") || {
      trap - TERM INT HUP
      rm -rf -- "$transaction" 2>/dev/null || true
      exec {lock_fd}>&-
      return 1
    }
    current_existed=1
    if ! cp -a --no-dereference -- "$current" "$transaction/current"; then
      trap - TERM INT HUP
      rm -rf -- "$transaction" 2>/dev/null || true
      exec {lock_fd}>&-
      return 1
    fi
  fi
  if [ -e "$previous" ] || [ -L "$previous" ]; then
    [ -L "$previous" ] || {
      trap - TERM INT HUP
      rm -rf -- "$transaction" 2>/dev/null || true
      exec {lock_fd}>&-
      return 1
    }
    previous_existed=1
    if ! cp -a --no-dereference -- "$previous" "$transaction/previous"; then
      trap - TERM INT HUP
      rm -rf -- "$transaction" 2>/dev/null || true
      exec {lock_fd}>&-
      return 1
    fi
  fi

  while [ "$#" -gt 0 ]; do
    launcher=$1; relative=$2; shift 2
    if ! _aicoding_runtime_safe_segment "$launcher"; then
      trap - TERM INT HUP; rm -rf -- "$transaction" 2>/dev/null || true; exec {lock_fd}>&-; return 2
    fi
    case "$relative" in
      ''|/*|*'..'*) trap - TERM INT HUP; rm -rf -- "$transaction" 2>/dev/null || true; exec {lock_fd}>&-; return 2 ;;
    esac
    duplicate=0
    for ((j=0; j<${#launchers[@]}; j++)); do
      [ "${launchers[$j]}" = "$launcher" ] && duplicate=1
    done
    if [ "$duplicate" -eq 1 ]; then
      trap - TERM INT HUP; rm -rf -- "$transaction" 2>/dev/null || true; exec {lock_fd}>&-; return 2
    fi
    if ! _aicoding_runtime_validate_executable "$release" "$relative"; then
      trap - TERM INT HUP; rm -rf -- "$transaction" 2>/dev/null || true; exec {lock_fd}>&-; return 1
    fi
    launchers+=("$launcher"); relatives+=("$relative"); launcher_existed+=(0)
    launcher_changed+=(1); launcher_touched+=(0); backup_created+=(0)
    if ! _aicoding_runtime_write_wrapper "$transaction/new.$i" "$current" "$relative"; then
      trap - TERM INT HUP; rm -rf -- "$transaction" 2>/dev/null || true; exec {lock_fd}>&-; return 1
    fi
    dest="$bin_root/$launcher"
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      if [ ! -f "$dest" ] || [ ! -x "$dest" ]; then
        trap - TERM INT HUP; rm -rf -- "$transaction" 2>/dev/null || true; exec {lock_fd}>&-; return 1
      fi
      launcher_existed[$i]=1
      if ! cp -a --no-dereference -- "$dest" "$transaction/launcher.$i"; then
        trap - TERM INT HUP; rm -rf -- "$transaction" 2>/dev/null || true; exec {lock_fd}>&-; return 1
      fi
      if cmp -s -- "$transaction/new.$i" "$dest"; then launcher_changed[$i]=0; fi
      if ! grep -qF '# Managed by aicoding immutable runtime.' "$dest" 2>/dev/null; then
        backup="$dest.pre-aicoding"
        if [ ! -e "$backup" ] && [ ! -L "$backup" ]; then
          if ! cp -a --no-dereference -- "$dest" "$transaction/legacy.$i"; then
            trap - TERM INT HUP; rm -rf -- "$transaction" 2>/dev/null || true; exec {lock_fd}>&-; return 1
          fi
        fi
      fi
    fi
    i=$((i + 1))
  done

  # A changed wrapper must remain runnable against the old release until the
  # managed current pointer is switched as the final activation operation.
  if [ "$current_existed" -eq 1 ] && [ "$old_target" != "$desired_target" ]; then
    local old_release="$AICODING_DATA_DIR/${old_target#../}"
    for ((i=0; i<${#launchers[@]}; i++)); do
      if [ "${launcher_changed[$i]}" -eq 1 ] \
          && ! _aicoding_runtime_validate_executable "$old_release" "${relatives[$i]}"; then
        trap - TERM INT HUP; rm -rf -- "$transaction" 2>/dev/null || true; exec {lock_fd}>&-; return 1
      fi
    done
  fi

  activation_started=1
  # Persist legacy recovery copies atomically before changing launchers.
  for ((i=0; i<${#launchers[@]}; i++)); do
    if [ -e "$transaction/legacy.$i" ]; then
      backup="$bin_root/${launchers[$i]}.pre-aicoding"
      backup_created[$i]=1
      if ! _aicoding_runtime_commit_backup "$transaction/legacy.$i" "$backup"; then
        _aicoding_runtime_activation_rollback || true
        exec {lock_fd}>&-
        return 1
      fi
    fi
  done

  if [ "$current_existed" -eq 1 ] && [ "$old_target" != "$desired_target" ]; then
    previous_touched=1
    if ! _aicoding_runtime_commit_previous "$previous_root" "$component" "$old_target"; then
      _aicoding_runtime_activation_rollback || true
      exec {lock_fd}>&-
      return 1
    fi
    for ((i=0; i<${#launchers[@]}; i++)); do
      [ "${launcher_changed[$i]}" -eq 1 ] || continue
      launcher_touched[$i]=1
      if ! _aicoding_runtime_commit_wrapper "$transaction/new.$i" "$bin_root/${launchers[$i]}"; then
        _aicoding_runtime_activation_rollback || true
        exec {lock_fd}>&-
        return 1
      fi
    done
    if ! _aicoding_runtime_validate_release "$component" "$version"; then
      _aicoding_runtime_activation_rollback || true
      exec {lock_fd}>&-
      return 1
    fi
    for ((i=0; i<${#launchers[@]}; i++)); do
      if ! _aicoding_runtime_validate_executable "$release" "${relatives[$i]}"; then
        _aicoding_runtime_activation_rollback || true
        exec {lock_fd}>&-
        return 1
      fi
    done
    current_touched=1
    if ! _aicoding_runtime_commit_current "$current_root" "$component" "$desired_target"; then
      _aicoding_runtime_activation_rollback || true
      exec {lock_fd}>&-
      return 1
    fi
  elif [ "$current_existed" -eq 0 ]; then
    if ! _aicoding_runtime_validate_release "$component" "$version"; then
      _aicoding_runtime_activation_rollback || true
      exec {lock_fd}>&-
      return 1
    fi
    current_touched=1
    if ! _aicoding_runtime_commit_current "$current_root" "$component" "$desired_target"; then
      _aicoding_runtime_activation_rollback || true
      exec {lock_fd}>&-
      return 1
    fi
    for ((i=0; i<${#launchers[@]}; i++)); do
      [ "${launcher_changed[$i]}" -eq 1 ] || continue
      launcher_touched[$i]=1
      if ! _aicoding_runtime_commit_wrapper "$transaction/new.$i" "$bin_root/${launchers[$i]}"; then
        _aicoding_runtime_activation_rollback || true
        exec {lock_fd}>&-
        return 1
      fi
    done
  else
    # Reconcile launchers for an already-active release without moving either
    # version pointer.
    for ((i=0; i<${#launchers[@]}; i++)); do
      [ "${launcher_changed[$i]}" -eq 1 ] || continue
      launcher_touched[$i]=1
      if ! _aicoding_runtime_commit_wrapper "$transaction/new.$i" "$bin_root/${launchers[$i]}"; then
        _aicoding_runtime_activation_rollback || true
        exec {lock_fd}>&-
        return 1
      fi
    done
  fi

  trap - TERM INT HUP
  if ! rm -rf -- "$transaction"; then
    printf 'aicoding runtime: activation succeeded; recovery cleanup failed at %s\n' "$transaction" >&2
  fi
  exec {lock_fd}>&-
  return 0
)
