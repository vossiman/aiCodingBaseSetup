# lib/sync.sh — the one routine that brings THIS container current.
# Steps: (1) auth plumbing [always], (2) blueprint config reconcile,
# (3) binary refresh [throttled]. Modes: --first (provision), --boot
# (non-interactive, throttled), default (interactive). Fail-open throughout.
# Sourced (no shebang / set -e); matches the lib/*.sh style.

: "${AICODING_BLUEPRINT_CLONE:=/tmp/aicoding}"
: "${AICODING_BLUEPRINT_REMOTE:=https://github.com/vossiman/aiCodingBaseSetup}"
: "${AICODING_UPDATE_TTL:=21600}"
: "${AICODING_UPDATE_STATE:=$HOME/.aicodingsetup/state/updates}"

# Seed GitHub's SSH host key so git-over-SSH (forwarded agent) works on this
# start. Fresh containers have an empty ~/.ssh/known_hosts, so the first push/pull
# dies with "Host key verification failed" before auth. install.sh seeds this on
# create; doing it here too means already-running containers self-heal on their
# next start without a rebuild. Fingerprint-verified (not TOFU), idempotent.
seed_github_known_host() {
  local expected="SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"  # GitHub's published ed25519 fingerprint
  local kh="$HOME/.ssh/known_hosts" tmp scanned
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"; touch "$kh"
  ssh-keygen -F github.com -f "$kh" >/dev/null 2>&1 && return 0
  tmp="$(mktemp)"
  if ! ssh-keyscan -t ed25519 github.com >"$tmp" 2>/dev/null || [[ ! -s "$tmp" ]]; then
    printf 'WARN: %s\n' "ssh-keyscan github.com failed (offline?) — git over SSH may prompt" >&2; rm -f "$tmp"; return 0
  fi
  scanned="$(ssh-keygen -lf "$tmp" | awk '{print $2}')"
  if [[ "$scanned" == "$expected" ]]; then
    cat "$tmp" >>"$kh"
  else
    printf 'WARN: %s\n' "github.com host-key fingerprint mismatch ($scanned) — NOT seeding" >&2
  fi
  rm -f "$tmp"
}

# Register gh as git's credential helper for github.com so HTTPS git auth
# works without prompting. The helper lives in the container-local ~/.gitconfig,
# which every rebuild wipes — until 2026-07 it had only ever been set by hand
# (2026-06-16 HTTPS switch), so rebuilt containers prompted "Username for
# 'https://github.com'". Boot shells are non-interactive and never source
# ~/.bashrc.d/aicoding-env.sh, so GH_TOKEN is absent and `gh auth setup-git`
# would refuse (no authenticated host) — source the secrets file first.
# Idempotent, fail-open.
ensure_gh_credential_helper() {
  command -v gh >/dev/null 2>&1 || return 0
  git config --global --get-all credential.https://github.com.helper 2>/dev/null \
    | grep -q 'gh auth git-credential' && return 0
  (
    if [[ -z "${GH_TOKEN:-}" && -r "$HOME/.aicodingsetup/.secrets.env" ]]; then
      set -a; . "$HOME/.aicodingsetup/.secrets.env"; set +a
    fi
    gh auth setup-git
  ) 2>/dev/null || printf 'WARN: %s\n' "gh auth setup-git failed — git over HTTPS may prompt for credentials" >&2
}

# Register the file-based GH_TOKEN fallback AFTER the gh helper: agent CLIs
# (codex) strip *TOKEN* env vars from spawned commands, so gh's env-based
# helper fails inside those sessions and git falls through to this one,
# which reads the token from ~/.aicodingsetup/.secrets.env. `!bash <path>`
# avoids depending on an executable bit the deploy pipeline doesn't set.
# Idempotent, fail-open. Must run after ensure_gh_credential_helper: `gh
# auth setup-git` resets the helper list, which would drop this entry.
ensure_git_credential_file_fallback() {
  git config --global --get-all credential.https://github.com.helper 2>/dev/null \
    | grep -q 'git-credential-aicoding' && return 0
  git config --global --add credential.https://github.com.helper \
    '!bash "$HOME/.local/bin/git-credential-aicoding"' 2>/dev/null \
    || printf 'WARN: %s\n' "could not register git-credential-aicoding fallback" >&2
}

# Expose Claude skills to codex via the Agent Skills standard location.
# Cursor already scans ~/.claude/skills for compatibility, but codex only
# reads ~/.agents/skills (plus repo-level .agents/skills) — one symlink
# makes ~/.claude/skills the single source of truth for all three CLIs.
# ~/.agents is container-local (not a bind mount), so this must be
# re-ensured on every boot. A real (non-symlink) ~/.agents/skills dir is
# the user's own adoption of the standard — leave it untouched.
ensure_agents_skills_symlink() {
  local link="$HOME/.agents/skills" target="$HOME/.claude/skills"
  [ -L "$link" ] && return 0
  [ -e "$link" ] && return 0
  mkdir -p "$HOME/.agents" 2>/dev/null || return 0
  ln -s "$target" "$link" 2>/dev/null \
    || printf 'WARN: %s\n' "could not create ~/.agents/skills symlink" >&2
}

_sync_plumbing() {            # never throttled — must be correct now
  command -v aicoding-ssh-agent-watch >/dev/null 2>&1 && aicoding-ssh-agent-watch --ensure 2>/dev/null || true
  command -v seed_github_known_host >/dev/null 2>&1 && seed_github_known_host || true
  command -v ensure_gh_credential_helper >/dev/null 2>&1 && ensure_gh_credential_helper || true
  command -v ensure_git_credential_file_fallback >/dev/null 2>&1 && ensure_git_credential_file_fallback || true
  command -v ensure_agents_skills_symlink >/dev/null 2>&1 && ensure_agents_skills_symlink || true
}

# Bring the blueprint clone current. Clone if absent; otherwise fetch and
# hard-reset to origin/main — but ONLY for a throwaway tracking clone that's
# actually on `main`. The dev repo (used in tests and during development)
# lives on a feature branch and may be ahead of origin/main; resetting it
# would clobber working-tree state, so we leave non-main checkouts alone.
# Fetch failure (e.g. no origin remote in test fixtures) falls back to the
# cached clone — never resets. Fail-open throughout.
refresh_blueprint() {
  if [[ -d "$AICODING_BLUEPRINT_CLONE/.git" ]]; then
    if git -C "$AICODING_BLUEPRINT_CLONE" fetch --quiet origin 2>/dev/null; then
      local branch
      branch=$(git -C "$AICODING_BLUEPRINT_CLONE" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
      if [[ "$branch" == main ]]; then
        git -C "$AICODING_BLUEPRINT_CLONE" reset --hard --quiet origin/main 2>/dev/null || true
      fi
    else
      echo "could not fetch blueprint — using cached clone" >&2
    fi
  elif [[ ! -d "$AICODING_BLUEPRINT_CLONE" ]]; then
    git clone --quiet "$AICODING_BLUEPRINT_REMOTE" "$AICODING_BLUEPRINT_CLONE" || true
  fi
}

# Config reconcile: classify managed files, preview/prompt/apply per mode,
# stamp the manifest. Ported from the old aicoding-update CLI and folded in.
# $1 = mode: boot | first | dry-run | yes | interactive.
# Returns 1 only in the no-manifest manual-error case (interactive/dry-run/yes);
# returns 0 everywhere else.
_sync_reconcile() {
  local mode=$1

  refresh_blueprint

  [ -f "$AICODING_BLUEPRINT_CLONE/lib/blueprint-deploy.sh" ] || return 0
  . "$AICODING_BLUEPRINT_CLONE/lib/blueprint-deploy.sh"
  command -v load_secrets_env >/dev/null 2>&1 && load_secrets_env || true

  if [[ ! -f "$AICODING_MANIFEST" ]]; then
    case "$mode" in
      boot|first) return 0 ;;  # nothing provisioned yet — tolerate
      *)
        echo "aicoding-sync: no manifest at $AICODING_MANIFEST" >&2
        echo "Run install.sh first to provision this container." >&2
        return 1
        ;;
    esac
  fi

  manifest_check_schema

  local OLD_COMMIT NEW_COMMIT
  OLD_COMMIT=$(jq -r '.blueprint_commit // "unknown"' "$AICODING_MANIFEST")
  # Full SHA, matching install.sh. aicoding-status compares the first 12 chars
  # of this against `git ls-remote`'s full SHA; a 7-char `--short` would never
  # match, leaving the ⬆ badge stuck "behind" even right after a sync.
  NEW_COMMIT=$(git -C "$AICODING_BLUEPRINT_CLONE" rev-parse HEAD 2>/dev/null || echo unknown)
  echo "Blueprint: ${OLD_COMMIT:0:7} -> ${NEW_COMMIT:0:7}"

  declare -gA BUCKETS FILE_MODE FILE_SOURCE
  export AICODING_BLUEPRINT_CLONE
  classify_managed_files

  # Re-bucket owned overwrites: a drifted-but-blueprint-owned file is ours to
  # update without a "needs your decision" prompt.
  local d
  for d in "${!BUCKETS[@]}"; do
    if [[ "${BUCKETS[$d]}" == drifted_and_updating ]] && _is_owned_overwrite "$d"; then
      BUCKETS[$d]=will_update_owned
    fi
  done

  declare -A COUNT
  local b
  for b in up_to_date will_update will_update_owned drifted_but_aligned \
           drifted_and_updating restore new_file to_remove merge; do
    COUNT[$b]=0
  done
  for d in "${!BUCKETS[@]}"; do
    b=${BUCKETS[$d]}
    COUNT[$b]=$(( ${COUNT[$b]:-0} + 1 ))
  done

  if [[ "$mode" == dry-run ]]; then
    for b in up_to_date will_update will_update_owned drifted_but_aligned \
             drifted_and_updating restore new_file to_remove merge; do
      echo "  ${COUNT[$b]} $b"
    done
    return 0
  fi

  # Interactive preview (default mode only): counts + inline diffs.
  if [[ "$mode" == interactive ]]; then
    _sync_print_summary
  fi

  # Nothing actionable across every apply bucket?
  # drifted_but_aligned (on-disk already matches blueprint; only a stale manifest
  # hash) and up_to_date are NOT actionable, so they're excluded here — otherwise
  # a pure manifest-hash refresh would wrongly trigger an Apply? prompt.
  if (( COUNT[will_update] + COUNT[will_update_owned] + COUNT[drifted_and_updating] \
        + COUNT[restore] + COUNT[new_file] + COUNT[to_remove] + COUNT[merge] == 0 )); then
    echo "Nothing to do."
    # Still advance the blueprint_commit stamp: the blueprint may have moved
    # without touching any managed file (lib/tests/bin-only changes). Leaving
    # the old commit recorded keeps aicoding-status on "behind" forever.
    if [ "$OLD_COMMIT" != "$NEW_COMMIT" ] && [ "$NEW_COMMIT" != unknown ]; then
      manifest_stage_begin
      manifest_stage_set_top blueprint_commit "$NEW_COMMIT"
      local origin
      origin=$(git -C "$AICODING_BLUEPRINT_CLONE" remote get-url origin 2>/dev/null || echo unknown)
      manifest_stage_set_top blueprint_origin "$origin"
      manifest_stage_commit
      rm -f "$AICODING_UPDATE_STATE"/*.json 2>/dev/null || true
    fi
    return 0
  fi

  if [[ "$mode" == interactive ]]; then
    printf 'Apply? [y/N] '
    local answer
    read -r answer
    case "$answer" in
      y|Y|yes) ;;
      *) echo "Aborted."; return 0 ;;
    esac
  fi

  manifest_stage_begin

  local buckets
  if [[ "$mode" == boot ]]; then
    # Conservative on boot: preserve user edits (no drifted_and_updating, no
    # to_remove) since boot runs unattended on every container start.
    buckets="restore new_file will_update will_update_owned drifted_but_aligned merge"
  else
    # interactive / yes / first: full reconcile.
    buckets="restore new_file will_update will_update_owned drifted_but_aligned drifted_and_updating merge to_remove"
  fi
  apply_managed_buckets "$buckets"

  # Per-bucket announcements (interactive output, not deploy behavior). Only
  # report buckets that were actually in the applied set for this mode.
  local bucket
  for d in "${!BUCKETS[@]}"; do
    bucket=${BUCKETS[$d]}
    case " $buckets " in *" $bucket "*) ;; *) continue ;; esac
    case "$bucket" in
      restore)              echo "      restored: $d" ;;
      new_file)             echo "      new: $d" ;;
      will_update)          echo "      updated: $d" ;;
      will_update_owned)    echo "      updated: $d" ;;
      drifted_and_updating) echo "      updated (with backup): $d" ;;
      merge)                echo "      merged: $d" ;;
      to_remove)            echo "      removed: $d" ;;
    esac
  done

  manifest_stage_set_top blueprint_commit "$NEW_COMMIT"
  local origin
  origin=$(git -C "$AICODING_BLUEPRINT_CLONE" remote get-url origin 2>/dev/null || echo unknown)
  manifest_stage_set_top blueprint_origin "$origin"

  manifest_stage_commit

  # We just advanced the installed blueprint commit, so aicoding-status's cached
  # behind-main verdict is now stale. Drop the cache so the next tmux/login
  # refresh re-checks (detached, ≤ one status-interval) instead of showing a
  # phantom ⬆aicoding badge for up to the 6h TTL. Removing the JSON also busts
  # _cache_fresh, so that refresh actually runs rather than short-circuiting.
  # No network here; fail-open.
  if [ "$OLD_COMMIT" != "$NEW_COMMIT" ]; then
    rm -f "$AICODING_UPDATE_STATE"/*.json 2>/dev/null || true
  fi
  return 0
}

# Interactive summary: tally + inline `diff -u` per drifted_and_updating file.
# Reads the COUNT / BUCKETS / FILE_MODE / FILE_SOURCE state from the caller.
_sync_print_summary() {
  echo
  echo "  ${COUNT[up_to_date]} up to date"

  if (( COUNT[will_update] > 0 )); then
    echo "  ${COUNT[will_update]} will update         (no drift):"
    for dest in "${!BUCKETS[@]}"; do
      [[ ${BUCKETS[$dest]} == will_update ]] && echo "      $dest"
    done
  fi

  if (( COUNT[will_update_owned] > 0 )); then
    echo "  ${COUNT[will_update_owned]} will update (owned) (blueprint-owned, will refresh):"
    for dest in "${!BUCKETS[@]}"; do
      [[ ${BUCKETS[$dest]} == will_update_owned ]] && echo "      $dest"
    done
  fi

  if (( COUNT[restore] > 0 )); then
    echo "  ${COUNT[restore]} restore             (file missing, will be restored from blueprint):"
    for dest in "${!BUCKETS[@]}"; do
      [[ ${BUCKETS[$dest]} == restore ]] && echo "      $dest"
    done
  fi

  if (( COUNT[drifted_and_updating] > 0 )); then
    echo "  ${COUNT[drifted_and_updating]} needs your decision (you've modified, blueprint also changed):"
    for dest in "${!BUCKETS[@]}"; do
      [[ ${BUCKETS[$dest]} != drifted_and_updating ]] && continue
      echo "      $dest"
      if [[ "${FILE_MODE[$dest]:-overwrite}" != "marker_block" ]]; then
        local src="$AICODING_BLUEPRINT_CLONE/${FILE_SOURCE[$dest]}"
        diff -u --label "your version" --label "blueprint version" "$dest" "$src" 2>/dev/null \
          | sed 's/^/        /' || true
      fi
    done
  fi

  if (( COUNT[to_remove] > 0 )); then
    echo "  ${COUNT[to_remove]} to remove           (no longer in blueprint):"
    for dest in "${!BUCKETS[@]}"; do
      [[ ${BUCKETS[$dest]} == to_remove ]] && echo "      $dest"
    done
  fi

  if (( COUNT[new_file] > 0 )); then
    echo "  ${COUNT[new_file]} new files           (will be deployed):"
    for dest in "${!BUCKETS[@]}"; do
      [[ ${BUCKETS[$dest]} == new_file ]] && echo "      $dest"
    done
  fi

  if (( COUNT[merge] > 0 )); then
    echo "  ${COUNT[merge]} merge target(s)     (will re-merge, additions preserved):"
    for dest in "${!BUCKETS[@]}"; do
      [[ ${BUCKETS[$dest]} == merge ]] && echo "      $dest"
    done
  fi

  echo
}

_sync_binaries() {            # throttled network refresh
  command -v claude   >/dev/null 2>&1 && { claude update    || true; }
  command -v opencode >/dev/null 2>&1 && { opencode upgrade || true; }
  if command -v agent >/dev/null 2>&1; then agent update || true
  elif command -v cursor-agent >/dev/null 2>&1; then cursor-agent update || true; fi
}

# Reconcile machine state that isn't a managed file: MCP registrations,
# marketplace plugins, npm MCP packages, retired-shim cleanup. Shares
# lib/provision.sh with install.sh so both converge the same set; prefers
# the refreshed clone's copy so a manual sync runs the latest definitions.
# Fail-open throughout — every provision function warns instead of failing.
_sync_provision() {
  if [ -f "$AICODING_BLUEPRINT_CLONE/lib/provision.sh" ]; then
    . "$AICODING_BLUEPRINT_CLONE/lib/provision.sh"
  elif [ -n "${SCRIPT_DIR:-}" ] && [ -f "$SCRIPT_DIR/lib/provision.sh" ]; then
    . "$SCRIPT_DIR/lib/provision.sh"
  else
    return 0
  fi
  command -v load_secrets_env >/dev/null 2>&1 && load_secrets_env || true
  install_mcp_packages   || true
  install_claude_mcps    || true
  install_claude_plugins || true
  remove_deprecated_shims || true
  return 0
}

# Returns 0 if the binary-refresh throttle window is still fresh.
_sync_binaries_fresh() {
  [ -n "$(find "$AICODING_UPDATE_STATE/.binaries.stamp" -newermt "-${AICODING_UPDATE_TTL} seconds" 2>/dev/null)" ]
}
_sync_binaries_stamp() {
  mkdir -p "$AICODING_UPDATE_STATE"; : > "$AICODING_UPDATE_STATE/.binaries.stamp"
}

aicoding_sync() {
  # Parse the FIRST recognized flag; no flag = interactive.
  local mode=interactive arg
  for arg in "$@"; do
    case "$arg" in
      --dry-run) mode=dry-run; break ;;
      --yes)     mode=yes;     break ;;
      --boot)    mode=boot;    break ;;
      --first)   mode=first;   break ;;
    esac
  done

  # 1. Plumbing — always correct now, but write nothing under --dry-run.
  [ "$mode" != dry-run ] && _sync_plumbing

  # 2. Reconcile (preview / prompt / apply per mode). The no-manifest manual
  #    error is the only nonzero return.
  _sync_reconcile "$mode" || return $?

  # 3. Binaries + machine-state provision (MCPs/plugins) — never under
  #    --dry-run. Only --boot throttles (it's the only path that runs
  #    unattended on every container start); both share one stamp.
  if [ "$mode" != dry-run ]; then
    if [ "$mode" = boot ] && _sync_binaries_fresh; then :; else
      _sync_binaries
      _sync_provision
      _sync_binaries_stamp
    fi
  fi
  return 0
}
