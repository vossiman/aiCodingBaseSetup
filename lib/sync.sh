# lib/sync.sh — the one routine that brings THIS container current.
# Steps: (1) auth plumbing [always], (2) blueprint config reconcile,
# (3) binary refresh [throttled]. Modes: --first (provision), --boot
# (non-interactive, throttled), default (interactive). Fail-open throughout.
# Sourced (no shebang / set -e); matches the lib/*.sh style.

: "${AICODING_BLUEPRINT_CLONE:=/tmp/aicoding}"
: "${AICODING_UPDATE_TTL:=21600}"
: "${AICODING_UPDATE_STATE:=$HOME/.aicodingsetup/state/updates}"

_sync_plumbing() {            # never throttled — must be correct now
  command -v aicoding-ssh-agent-watch >/dev/null 2>&1 && aicoding-ssh-agent-watch --ensure 2>/dev/null || true
  command -v seed_github_known_host >/dev/null 2>&1 && seed_github_known_host || true
}

_sync_config() {              # config reconcile via the deploy engine
  # No blueprint clone yet (e.g. first boot before bootstrap) → nothing to
  # reconcile; degrade quietly rather than erroring. Also explicit about
  # fail-open in case a caller ever sources us under `set -e`.
  [ -f "$AICODING_BLUEPRINT_CLONE/lib/blueprint-deploy.sh" ] || return 0
  . "$AICODING_BLUEPRINT_CLONE/lib/blueprint-deploy.sh"
  command -v load_secrets_env >/dev/null 2>&1 && load_secrets_env || true
  [ -f "$AICODING_MANIFEST" ] || return 0
  declare -gA BUCKETS FILE_MODE FILE_SOURCE
  export AICODING_BLUEPRINT_CLONE
  classify_managed_files
  local d
  for d in "${!BUCKETS[@]}"; do
    if [[ "${BUCKETS[$d]}" == drifted_and_updating ]] && _is_owned_overwrite "$d"; then
      BUCKETS[$d]=will_update_owned
    fi
  done
  manifest_stage_begin
  apply_managed_buckets "restore new_file will_update will_update_owned drifted_but_aligned merge"
  manifest_stage_set_top blueprint_commit "$(git -C "$AICODING_BLUEPRINT_CLONE" rev-parse HEAD 2>/dev/null || echo unknown)"
  manifest_stage_commit
}

_sync_binaries() {            # throttled network refresh
  command -v claude   >/dev/null 2>&1 && { claude update    || true; }
  command -v opencode >/dev/null 2>&1 && { opencode upgrade || true; }
  if command -v agent >/dev/null 2>&1; then agent update || true
  elif command -v cursor-agent >/dev/null 2>&1; then cursor-agent update || true; fi
}

# Returns 0 if the binary-refresh throttle window is still fresh.
_sync_binaries_fresh() {
  [ -n "$(find "$AICODING_UPDATE_STATE/.binaries.stamp" -newermt "-${AICODING_UPDATE_TTL} seconds" 2>/dev/null)" ]
}
_sync_binaries_stamp() {
  mkdir -p "$AICODING_UPDATE_STATE"; : > "$AICODING_UPDATE_STATE/.binaries.stamp"
}

aicoding_sync() {
  local mode=interactive
  case "${1:-}" in --first) mode=first ;; --boot) mode=boot ;; "" ) ;; *) mode=interactive ;; esac
  _sync_plumbing
  _sync_config
  # Only --boot throttles binary refresh; --first and interactive always refresh
  # (the boot path is the only one that runs unattended on every container start).
  if [ "$mode" = boot ] && _sync_binaries_fresh; then :; else _sync_binaries; _sync_binaries_stamp; fi
  return 0
}
