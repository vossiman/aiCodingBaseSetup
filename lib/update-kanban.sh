# Immutable git/uv adapter for the Kanban-owned MCP controller. Functions are
# resolved when invoked after update-components.sh has loaded its shared helpers.

_aicoding_kanban_pinned_revision() {
  local root revision_file revision
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || return 1
  revision_file="$root/configs/versions/kanban-mcp.rev"
  revision=$(cat "$revision_file" 2>/dev/null) || return 1
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || return 1
  [ "$(wc -l < "$revision_file")" -eq 1 ] || return 1
  printf '%s\n' "$revision"
}

_aicoding_kanban_metadata_version() {
  local release=$1 python="$release/.venv/bin/python"
  [ -x "$python" ] || return 1
  "$python" -c 'from importlib.metadata import version; print(version("kanban"))' \
    </dev/null 2>/dev/null
}

_aicoding_kanban_controller_valid() {
  local controller=$1 release=$2 metadata output errors rc=0
  [ -x "$controller" ] || return 1
  metadata=$(_aicoding_kanban_metadata_version "$release") || return 1
  [[ "$metadata" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+.-][0-9A-Za-z.-]+)?$ ]] || return 1
  output=$(mktemp) || return 1
  errors=$(mktemp) || { rm -f "$output"; return 1; }
  "$controller" --version >"$output" 2>"$errors" || rc=$?
  if [ "$rc" -ne 0 ] || [ -s "$errors" ] \
      || ! python3 - "$output" "$metadata" <<'PY'
import pathlib
import sys

actual = pathlib.Path(sys.argv[1]).read_bytes()
expected = f"kanban-mcp {sys.argv[2]}\n".encode()
raise SystemExit(0 if actual == expected else 1)
PY
  then
    rm -f "$output" "$errors"
    return 1
  fi
  : >"$output"; : >"$errors"; rc=0
  "$controller" --instructions >"$output" 2>"$errors" || rc=$?
  [ "$rc" -eq 0 ] && [ -s "$output" ] && [ ! -s "$errors" ]
  rc=$?
  rm -f "$output" "$errors"
  return "$rc"
}

_aicoding_kanban_release_valid() {
  local release=$1 revision=$2
  [ -d "$release" ] && [ ! -L "$release" ] \
    && [ "$(cat "$release/.aicoding-version" 2>/dev/null)" = "$revision" ] \
    && _aicoding_release_integrity_valid "$release" \
    && _aicoding_kanban_controller_valid "$release/.venv/bin/kanban-mcp" "$release"
}

_aicoding_active_kanban_mcp_valid() {
  local revision=${1:-} release current launcher
  [ -n "$revision" ] || revision=$(_aicoding_kanban_pinned_revision) || return 1
  release="$AICODING_DATA_DIR/versions/mcp-kanban/$revision"
  current="$AICODING_DATA_DIR/current/mcp-kanban"
  launcher="$HOME/.local/bin/kanban-mcp"
  _aicoding_kanban_release_valid "$release" "$revision" \
    && [ -L "$current" ] \
    && [ "$(readlink "$current" 2>/dev/null)" = "../versions/mcp-kanban/$revision" ] \
    && _aicoding_kanban_controller_valid "$launcher" "$release"
}

_aicoding_finish_kanban_mcp_release() {
  local revision=$1 release=$2 state=updated reason=installed
  if _aicoding_active_kanban_mcp_valid "$revision"; then
    state=current
    reason=current
  else
    _aicoding_activate_vendor_release mcp-kanban "$revision" \
        kanban-mcp .venv/bin/kanban-mcp \
      || { aicoding_result_record mcp-kanban failed "$revision" activation_failed; return 1; }
    _aicoding_active_kanban_mcp_valid "$revision" \
      || { aicoding_result_record mcp-kanban failed "$revision" active_controller_invalid; return 1; }
  fi
  aicoding_result_record mcp-kanban "$state" "$revision" "$reason" "$revision" || return 1
  _aicoding_reconcile_claude_mcp_registration \
    kanban mcp-kanban "$revision" kanban-mcp
}

aicoding_update_kanban_mcp() {
  local revision source release stage sync_log
  revision=$(_aicoding_kanban_pinned_revision) || {
    aicoding_result_record mcp-kanban failed "" pinned_revision_invalid
    return 1
  }
  if [[ ! "$revision" =~ ^[0-9a-f]{40}$ ]]; then
    aicoding_result_record mcp-kanban failed "$revision" pinned_revision_invalid
    return 1
  fi
  release="$AICODING_DATA_DIR/versions/mcp-kanban/$revision"
  if [ -d "$release" ]; then
    _aicoding_kanban_release_valid "$release" "$revision" || {
      aicoding_result_record mcp-kanban failed "$revision" existing_release_invalid
      return 1
    }
    printf 'INFO: mcp-kanban: reusing verified release %s\n' "$revision" >&2
    _aicoding_finish_kanban_mcp_release "$revision" "$release"
    return $?
  fi
  command -v uv >/dev/null 2>&1 || {
    _aicoding_record_deferred mcp-kanban blocked "$revision" "$(_aicoding_missing_runtime_reason uv)"
    return 1
  }
  source="$AICODING_DATA_DIR/sources/kanban/$revision"
  _aicoding_stage_git_source https://github.com/vossiman/kanban.git "$revision" "$source" || {
    aicoding_result_record mcp-kanban failed "$revision" source_stage_failed
    return 1
  }
  stage="$AICODING_DATA_DIR/versions/mcp-kanban/.staging.$revision.$$"
  sync_log="$stage/.uv-sync.log"
  rm -rf "$stage"
  mkdir -p "$stage" || {
    aicoding_result_record mcp-kanban failed "$revision" stage_prepare_failed
    return 1
  }
  cp -a "$source/." "$stage/" || {
    rm -rf "$stage"
    aicoding_result_record mcp-kanban failed "$revision" stage_copy_failed
    return 1
  }
  if ! (cd "$stage" && aicoding_progress_run \
      "mcp-kanban: creating relocatable environment (timeout ${AICODING_VENDOR_TIMEOUT}s)" \
      _aicoding_progress_capture "$sync_log" timeout "$AICODING_VENDOR_TIMEOUT" \
      uv venv --relocatable .venv </dev/null); then
    rm -rf "$stage"
    aicoding_result_record mcp-kanban failed "$revision" relocatable_venv_failed
    return 1
  fi
  if ! (cd "$stage" && aicoding_progress_run \
      "mcp-kanban: installing frozen environment (timeout ${AICODING_VENDOR_TIMEOUT}s)" \
      _aicoding_progress_capture "$sync_log" timeout "$AICODING_VENDOR_TIMEOUT" \
      env UV_NO_EDITABLE=1 uv sync --frozen --extra mcp --no-dev </dev/null); then
    rm -rf "$stage"
    aicoding_result_record mcp-kanban failed "$revision" frozen_sync_failed
    return 1
  fi
  rm -f "$sync_log" || {
    rm -rf "$stage"
    aicoding_result_record mcp-kanban failed "$revision" stage_cleanup_failed
    return 1
  }
  _aicoding_kanban_controller_valid "$stage/.venv/bin/kanban-mcp" "$stage" || {
    rm -rf "$stage"
    aicoding_result_record mcp-kanban failed "$revision" staged_controller_invalid
    return 1
  }
  _aicoding_release_integrity_write "$stage" || {
    rm -rf "$stage"
    aicoding_result_record mcp-kanban failed "$revision" stage_integrity_write_failed
    return 1
  }
  if ! mv "$stage" "$release"; then
    rm -rf "$stage"
    if ! _aicoding_kanban_release_valid "$release" "$revision"; then
      aicoding_result_record mcp-kanban failed "$revision" release_commit_failed
      return 1
    fi
  fi
  _aicoding_kanban_release_valid "$release" "$revision" || {
    aicoding_result_record mcp-kanban failed "$revision" committed_release_invalid
    return 1
  }
  _aicoding_finish_kanban_mcp_release "$revision" "$release"
}
