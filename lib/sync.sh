# lib/sync.sh — the one routine that brings THIS container current.
# Steps: (1) auth plumbing [always], (2) blueprint config reconcile,
# (3) binary refresh [throttled]. Modes: --first (provision), --boot
# (non-interactive, throttled), default (interactive). Fail-open throughout.
# Sourced (no shebang / set -e); matches the lib/*.sh style.

: "${AICODING_BLUEPRINT_CLONE:=/tmp/aicoding}"
: "${AICODING_BLUEPRINT_REMOTE:=https://github.com/vossiman/aiCodingBaseSetup}"
: "${AICODING_BLUEPRINT_LOCAL:=0}"
: "${AICODING_UPDATE_TTL:=21600}"
: "${AICODING_MANIFEST:=$HOME/.local/state/aicoding/manifest.json}"
# Container-local — must match bin/aicoding-status. ~/.aicodingsetup is a host
# bind mount shared by every container; keeping this cache there let one
# container's sync silence the update CTA in all the others.
: "${AICODING_UPDATE_STATE:=$HOME/.local/state/aicoding/updates}"

# Seed GitHub's SSH host key so git-over-SSH (forwarded agent) works on this
# start. Fresh containers have an empty ~/.ssh/known_hosts, so the first push/pull
# dies with "Host key verification failed" before auth. install.sh seeds this on
# create; doing it here too means already-running containers self-heal on their
# next start without a rebuild. Fingerprint-verified (not TOFU), idempotent.
# Uses header/ok/warn when install.sh has defined them; plain stderr otherwise.
seed_github_known_host() {
  local expected="SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"  # GitHub's published ed25519 fingerprint
  local kh="$HOME/.ssh/known_hosts" tmp scanned
  declare -F header >/dev/null && header "GitHub SSH host key"
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"; touch "$kh"
  if ssh-keygen -F github.com -f "$kh" >/dev/null 2>&1; then
    declare -F ok >/dev/null && ok "github.com already in known_hosts"
    return 0
  fi
  tmp="$(mktemp)"
  if ! ssh-keyscan -t ed25519 github.com >"$tmp" 2>/dev/null || [[ ! -s "$tmp" ]]; then
    if declare -F warn >/dev/null; then
      warn "ssh-keyscan github.com failed (offline?) — skipping; git over SSH may prompt"
    else
      printf 'WARN: %s\n' "ssh-keyscan github.com failed (offline?) — git over SSH may prompt" >&2
    fi
    rm -f "$tmp"; return 0
  fi
  scanned="$(ssh-keygen -lf "$tmp" | awk '{print $2}')"
  if [[ "$scanned" == "$expected" ]]; then
    cat "$tmp" >>"$kh"
    declare -F ok >/dev/null && ok "Seeded github.com ed25519 host key (fingerprint verified)"
  else
    if declare -F warn >/dev/null; then
      warn "github.com host-key fingerprint mismatch ($scanned) — NOT seeding"
    else
      printf 'WARN: %s\n' "github.com host-key fingerprint mismatch ($scanned) — NOT seeding" >&2
    fi
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

# _gh_auth_log — append a one-line reason to the boot-sync log.
#
# ensure_gh_stored_auth below is fail-open at five separate points, and until
# 2026-08-22 most of them returned 0 without saying anything. On a container
# that made the failure undiagnosable: configs/bash/boot-sync.sh, which owns
# ~/.cache/aicoding/boot-sync.log, is deployed on host-profile machines only,
# so the container's only attempt runs from on-start.sh, whose stderr goes to
# devpod's postStart output — which nobody reads. Three separate containers
# reached an agent with `gh auth status` reporting "not logged into any GitHub
# hosts" and no evidence of which branch had fired. Record every outcome,
# success included: "the boot sync skipped gh" and "the boot sync never ran"
# look identical otherwise. Fail-open itself — a log that cannot be written
# must never break a sync.
_gh_auth_log() {
  local log="${AICODING_BOOT_SYNC_LOG:-$HOME/.cache/aicoding/boot-sync.log}"
  mkdir -p "$(dirname "$log")" 2>/dev/null || return 0
  printf '%s ensure_gh_stored_auth: %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo -)" "$*" >> "$log" 2>/dev/null || true
  return 0
}

# ensure_gh_stored_auth — give gh its OWN stored credentials, so it no longer
# depends on GH_TOKEN being exported into every shell.
#
# Until 2026-08-21 the token was exported into every interactive shell
# (configs/bash/env.sh) precisely because it outranks ~/.config/gh/hosts.yml in
# gh's lookup order. That also meant any agent could read it with `printenv
# GH_TOKEN` — a leak path the file deny rules could not touch. Moving gh onto
# its own stored login lets us stop exporting the variable: git was never
# affected (it authenticates through git-credential-aicoding, which reads the
# secrets file directly), and hosts.yml is deny-listed in bw-deny-files.sh the
# same way .secrets.env is.
#
# ~/.config/gh is container-local and every rebuild wipes it, which is why this
# runs on each boot sync rather than once at install: the secrets file is the
# host bind mount, so re-establishing the login from it is cheap and idempotent.
# --insecure-storage forces the plaintext file instead of a system keyring,
# which headless containers do not have (the fragility the env var avoided).
# Fail-open: a failure here leaves gh unauthenticated, never breaks the sync.
ensure_gh_stored_auth() {
  command -v gh >/dev/null 2>&1 || { _gh_auth_log "skipped — gh is not installed"; return 0; }
  # `gh auth status` and `gh auth login` both talk to GitHub. Without this the
  # bats suite (which does NOT stub gh) made a network round trip per sync
  # test and slowed the run to a crawl — the guard every other network-touching
  # step here already carries.
  [ "${AICODINGSETUP_SKIP_NETWORK:-}" = 1 ] && return 0

  # Already logged in on gh's own credentials? Check with the environment
  # stripped, otherwise a still-exported GH_TOKEN masks the real state.
  env -u GH_TOKEN -u GITHUB_TOKEN gh auth status >/dev/null 2>&1 \
    && { _gh_auth_log "already authenticated — nothing to do"; return 0; }

  local secrets token
  secrets="${AICODING_SECRETS_FILE:-$HOME/.aicodingsetup/.secrets.env}"
  [ -r "$secrets" ] || { _gh_auth_log "skipped — secrets file not readable: $secrets"; return 0; }
  token=$(sed -n 's/^GH_TOKEN=//p' "$secrets" | tail -1)
  token=${token%\"}; token=${token#\"}
  token=${token%\'}; token=${token#\'}
  [ -n "$token" ] || { _gh_auth_log "skipped — no GH_TOKEN in $secrets"; return 0; }

  printf '%s' "$token" | env -u GH_TOKEN -u GITHUB_TOKEN \
    gh auth login --hostname github.com --with-token --insecure-storage >/dev/null 2>&1 \
    || { printf 'WARN: %s\n' "gh auth login --with-token failed — gh may be unauthenticated" >&2
         _gh_auth_log "gh auth login --with-token failed — gh is unauthenticated"; return 0; }

  if env -u GH_TOKEN -u GITHUB_TOKEN gh auth status >/dev/null 2>&1; then
    printf 'OK: %s\n' "gh authenticated from its own stored credentials (no GH_TOKEN needed)"
    _gh_auth_log "gh authenticated from its own stored credentials"
  else
    printf 'WARN: %s\n' "gh auth login reported success but gh is still unauthenticated" >&2
    _gh_auth_log "gh auth login reported success but gh is still unauthenticated"
  fi
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

# Rewrite SSH github origins under /workspaces to HTTPS. A container has no
# SSH key or agent for github (HTTPS-only auth since 2026-06), so a workspace
# cloned from an SSH URL fetches through devpod's client tunnel but every
# push dies with "Permission denied (publickey)" (foodbot-env 2026-08-21,
# MiniUndClaus 2026-08-25, ersteWorkshop 2026-08-30). Container profile only:
# host clones use SSH remotes deliberately. Origin only, top-level checkouts
# only. Idempotent, fail-open.
ensure_https_origin() {
  [ "$(_sync_profile)" != host ] || return 0
  local root="${AICODING_WORKSPACES_ROOT:-/workspaces}" repo url slug
  [ -d "$root" ] || return 0
  for repo in "$root"/*/; do
    [ -e "${repo}.git" ] || continue
    url=$(git -C "$repo" remote get-url origin 2>/dev/null) || continue
    case "$url" in
      git@github.com:*)       slug="${url#git@github.com:}" ;;
      ssh://git@github.com/*) slug="${url#ssh://git@github.com/}" ;;
      *) continue ;;
    esac
    slug="${slug%.git}"
    if git -C "$repo" remote set-url origin "https://github.com/${slug}.git" 2>/dev/null; then
      declare -F ok >/dev/null && ok "rewrote SSH origin to HTTPS in $repo (containers cannot push over SSH)"
    else
      printf 'WARN: %s\n' "could not rewrite SSH origin in $repo" >&2
    fi
  done
  return 0
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

# Scope Claude Code's agent/daemon runtime state per container. $HOME is a
# volume shared by every devpod container, so Claude Code's runtime registries
# (~/.claude/{jobs,sessions,daemon}) are visible machine-wide: the agents view
# (left arrow) lists every container's background agents — unswitchable, since
# their attach sockets live in the other container's /tmp — and concurrent
# daemons clobber each other's roster.json (anthropics/claude-code#15334).
# Redirect the three dirs through symlinks into a container-local base: all
# containers share the symlink, each resolves it to its own private storage.
# Root-level daemon.* files (daemon.lock etc.) stay shared BY DESIGN: the
# daemon rewrites them via rename, which silently replaces a file symlink with
# a regular shared file (verified on 2.1.226, 2026-08-08) — dir symlinks
# survive because writes land inside them. First conversion moves an existing
# real dir aside to <dir>.premigrate in the shared home; every container then
# adopts its own entries from that backup (a job is "ours" when its recorded
# cwd exists locally). The base dies with a container rebuild — correct, those
# agents' processes die too; transcripts stay in shared ~/.claude/projects.
ensure_claude_runtime_scope() {
  # Container profile only (deferred follow-up from #69's final review). The
  # whole premise above is several containers sharing ONE bind-mounted home; a
  # bare host has a single home and no sharing, so there is nothing to
  # de-conflict. Left ungated on a desktop with passwordless sudo this would
  # create /var/local/claude-runtime, move the user's live
  # ~/.claude/{jobs,sessions,daemon} aside to *.premigrate and symlink them
  # away — unrequested, and the "base dies with a container rebuild" cleanup
  # assumption inverts on a host, where nothing ever rebuilds it away.
  [ "$(_sync_profile)" != host ] || return 0
  local base="${AICODING_CLAUDE_RUNTIME_DIR:-/var/local/claude-runtime}"
  local d link backup entry cwd
  if [ ! -d "$base" ]; then
    mkdir -p "$base" 2>/dev/null || sudo -n mkdir -p "$base" 2>/dev/null || true
  fi
  [ -d "$base" ] || return 0
  [ -w "$base" ] || sudo -n chown "$(id -un):" "$base" 2>/dev/null || true
  [ -w "$base" ] || return 0
  mkdir -p "$HOME/.claude" 2>/dev/null || return 0
  for d in jobs sessions daemon; do
    link="$HOME/.claude/$d"
    mkdir -p "$base/$d" 2>/dev/null || continue
    [ -L "$link" ] && continue          # already scoped (this or another container)
    if [ -d "$link" ]; then             # first conversion on this shared home
      mv -T "$link" "$link.premigrate" 2>/dev/null || continue
    fi
    ln -sfn "$base/$d" "$link" 2>/dev/null \
      || printf 'WARN: %s\n' "could not symlink ~/.claude/$d to $base/$d" >&2
  done
  backup="$HOME/.claude/jobs.premigrate"
  if [ -d "$backup" ] && [ -d "$base/jobs" ] && command -v jq >/dev/null 2>&1; then
    for entry in "$backup"/*/; do
      [ -f "${entry}state.json" ] || continue
      cwd=$(jq -r '.cwd // empty' "${entry}state.json" 2>/dev/null)
      [ -n "$cwd" ] && [ -d "$cwd" ] || continue
      [ -e "$base/jobs/$(basename "$entry")" ] && continue
      mv "$entry" "$base/jobs/" 2>/dev/null || true
    done
    if [ -f "$backup/pins.json" ] && [ ! -e "$base/jobs/pins.json" ]; then
      cp "$backup/pins.json" "$base/jobs/" 2>/dev/null || true
    fi
  fi
  return 0
}

# Join the group that owns /dev/kvm so hardware acceleration (Android emulator,
# qemu) works without sudo. Devpods are privileged and already carry the host's
# /dev, but /dev/kvm is mode 0660 and group-owned by a HOST gid that has no
# matching entry in the container's /etc/group — so opening it fails for
# codespace despite the device being right there. The gid varies per host, so
# it is read from the device rather than hardcoded. Group membership is
# container state that dies with a rebuild: this belongs in plumbing (every
# boot), not install-time provisioning. Fail-open; a container whose host has
# no KVM simply skips.
# NOTE: membership only reaches NEW login sessions — the shell that ran this
# still lacks it, so the first boot after adoption needs a session restart.
# The deployment profile this sync is running under: `host` for bare-metal thin
# clients (the Mint desktop, jumpi), `container` for devpods. Guarded — an old
# blueprint clone may predate manifest_get_profile, and `container` is the safe
# default because it is what every pre-profile clone actually was.
#
# Plumbing steps that touch machine state MUST consult this. Unlike
# _sync_binaries, _sync_plumbing runs on EVERY profile, so a step that quietly
# reconfigures the box will do it to somebody's real desktop. Do not lean on a
# `sudo -n` failing to provide the gate — a desktop user may have passwordless
# sudo, and then it simply succeeds.
_sync_profile() {
  local p=${AICODING_PROFILE:-}
  if [ -z "$p" ] && command -v manifest_get_profile >/dev/null 2>&1; then
    p=$(manifest_get_profile)
  fi
  # aicoding_sync deliberately runs plumbing before reconcile sources
  # blueprint-deploy.sh. Read the manifest directly on that production call
  # path so a host is never briefly treated as a container. Old/pre-profile
  # manifests still keep the historical container default.
  if [ -z "$p" ] && command -v jq >/dev/null 2>&1 && [ -f "$AICODING_MANIFEST" ]; then
    p=$(jq -r '.profile // "container"' "$AICODING_MANIFEST" 2>/dev/null) || p=container
  fi
  case "$p" in host|container) ;; *) p=container ;; esac
  printf '%s\n' "$p"
}

ensure_kvm_group_access() {
  # Container profile only: /dev/kvm may well exist on a real desktop, but
  # joining a system group there is an unrequested privilege change, and the
  # core profile runs no emulator to need it.
  [ "$(_sync_profile)" != host ] || return 0
  local dev="${AICODING_KVM_DEVICE:-/dev/kvm}"
  [ -c "$dev" ] || return 0
  local gid name
  gid=$(stat -c %g "$dev" 2>/dev/null) || return 0
  [ -n "$gid" ] || return 0
  id -G 2>/dev/null | tr ' ' '\n' | grep -qx "$gid" && return 0   # already a member
  name=$(getent group "$gid" 2>/dev/null | cut -d: -f1)
  if [ -z "$name" ]; then
    # Prefer the conventional name; fall back when `kvm` is taken by another gid.
    name=kvm
    getent group kvm >/dev/null 2>&1 && name="kvm$gid"
    sudo -n groupadd -g "$gid" "$name" 2>/dev/null || return 0
  fi
  if sudo -n usermod -aG "$name" "$(id -un)" 2>/dev/null; then
    declare -F ok >/dev/null && ok "joined group $name (gid $gid) for /dev/kvm — restart the session to pick it up"
  fi
  return 0
}

_sync_plumbing() {            # never throttled — must be correct now
  command -v aicoding-ssh-agent-watch >/dev/null 2>&1 && aicoding-ssh-agent-watch --ensure 2>/dev/null || true
  # Clipboard-bridge X11 daemon (codex paste). Internally gated: no-op under
  # AICODINGSETUP_SKIP_NETWORK, outside containers, or without DISPLAY/uv.
  command -v clip-x11-bridge >/dev/null 2>&1 && clip-x11-bridge --ensure 2>/dev/null || true
  command -v seed_github_known_host >/dev/null 2>&1 && seed_github_known_host || true
  command -v ensure_gh_credential_helper >/dev/null 2>&1 && ensure_gh_credential_helper || true
  command -v ensure_gh_stored_auth >/dev/null 2>&1 && ensure_gh_stored_auth || true
  command -v ensure_git_credential_file_fallback >/dev/null 2>&1 && ensure_git_credential_file_fallback || true
  command -v ensure_https_origin >/dev/null 2>&1 && ensure_https_origin || true
  command -v ensure_agents_skills_symlink >/dev/null 2>&1 && ensure_agents_skills_symlink || true
  command -v ensure_claude_runtime_scope >/dev/null 2>&1 && ensure_claude_runtime_scope || true
  command -v ensure_kvm_group_access >/dev/null 2>&1 && ensure_kvm_group_access || true
}

# Return the provenance stored in manifest.json. A local source is deliberately
# distinguishable from a released remote blueprint even when both share HEAD.
blueprint_origin() {
  local path=${1:-$AICODING_BLUEPRINT_CLONE}
  if [[ "$AICODING_BLUEPRINT_LOCAL" == 1 ]]; then
    printf 'local:%s\n' "$path"
  else
    git -C "$path" remote get-url origin 2>/dev/null || echo unknown
  fi
}

# Report enough local-checkout identity to make an accidental source selection
# obvious. Read-only: no fetch, checkout, reset, or index mutation.
report_local_blueprint() {
  local branch commit dirty=""
  branch=$(git -C "$AICODING_BLUEPRINT_CLONE" symbolic-ref --quiet --short HEAD 2>/dev/null || echo detached)
  commit=$(git -C "$AICODING_BLUEPRINT_CLONE" rev-parse --short HEAD 2>/dev/null || echo unknown)
  [[ -n "$(git -C "$AICODING_BLUEPRINT_CLONE" status --porcelain 2>/dev/null)" ]] && dirty=", dirty"
  printf 'Blueprint source: local %s (branch %s, commit %s%s)\n' \
    "$AICODING_BLUEPRINT_CLONE" "$branch" "$commit" "$dirty"
}

# Bring the blueprint clone current. An explicit --blueprint local source is
# used verbatim and NEVER reaches the tracking-clone fetch/reset path. Otherwise
# clone if absent; fetch and
# hard-reset to origin/main — but ONLY for a throwaway tracking clone that's
# actually on `main`. The dev repo (used in tests and during development)
# lives on a feature branch and may be ahead of origin/main; resetting it
# would clobber working-tree state, so we leave non-main checkouts alone.
# Fetch failure (e.g. no origin remote in test fixtures) falls back to the
# cached clone — never resets. Fail-open throughout.
refresh_blueprint() {
  if [[ "$AICODING_BLUEPRINT_LOCAL" == 1 ]]; then
    if [[ ! -f "$AICODING_BLUEPRINT_CLONE/lib/blueprint-deploy.sh" ]]; then
      echo "invalid local blueprint: $AICODING_BLUEPRINT_CLONE" >&2
      return 2
    fi
    report_local_blueprint
    return 0
  fi
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

  refresh_blueprint || return $?

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
           drifted_and_updating restore new_file new_file_existing to_remove merge; do
    COUNT[$b]=0
  done
  for d in "${!BUCKETS[@]}"; do
    b=${BUCKETS[$d]}
    COUNT[$b]=$(( ${COUNT[$b]:-0} + 1 ))
  done

  if [[ "$mode" == dry-run ]]; then
    for b in up_to_date will_update will_update_owned drifted_but_aligned \
             drifted_and_updating restore new_file new_file_existing to_remove merge; do
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
        + COUNT[restore] + COUNT[new_file] + COUNT[new_file_existing] \
        + COUNT[to_remove] + COUNT[merge] == 0 )); then
    echo "Nothing to do."
    # Still advance the blueprint_commit stamp: the blueprint may have moved
    # without touching any managed file (lib/tests/bin-only changes). Leaving
    # the old commit recorded keeps aicoding-status on "behind" forever.
    if [ "$OLD_COMMIT" != "$NEW_COMMIT" ] && [ "$NEW_COMMIT" != unknown ]; then
      manifest_stage_begin
      local origin
      origin=$(blueprint_origin "$AICODING_BLUEPRINT_CLONE")
      # Stamps and drops the now-stale aicoding-status verdict together.
      manifest_stage_set_blueprint "$NEW_COMMIT" "$origin"
      manifest_stage_commit
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
    # new_file_existing, no to_remove) since boot runs unattended on every
    # container start — a personal file at a newly managed path must never be
    # replaced without a human in the loop.
    buckets="restore new_file will_update will_update_owned drifted_but_aligned merge"
  else
    # interactive / yes / first: full reconcile.
    buckets="restore new_file new_file_existing will_update will_update_owned drifted_but_aligned drifted_and_updating merge to_remove"
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
      new_file_existing)    echo "      new (existing file backed up): $d" ;;
      will_update)          echo "      updated: $d" ;;
      will_update_owned)    echo "      updated: $d" ;;
      drifted_and_updating) echo "      updated (with backup): $d" ;;
      merge)                echo "      merged: $d" ;;
      to_remove)            echo "      removed: $d" ;;
    esac
  done

  local origin
  origin=$(blueprint_origin "$AICODING_BLUEPRINT_CLONE")
  # Stamps the new commit and drops aicoding-status's cached `latest`, so the
  # next tick re-fetches instead of comparing against a pre-sync remote SHA
  # (see the helper's comment for why that drop still matters).
  manifest_stage_set_blueprint "$NEW_COMMIT" "$origin"

  manifest_stage_commit
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

  if (( COUNT[new_file_existing] > 0 )); then
    echo "  ${COUNT[new_file_existing]} newly managed       (your existing file will be backed up, then replaced):"
    for dest in "${!BUCKETS[@]}"; do
      [[ ${BUCKETS[$dest]} == new_file_existing ]] && echo "      $dest"
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

# Codex has no self-update subcommand; a refresh means re-running the
# official installer. Version-gate against the npm registry (same release
# channel as the installer) so the ~258MB download only happens on a real
# version change. Abnormal outcomes print ERROR to stderr but return 0 —
# sync/boot must never break on a stale codex.
# Spec: docs/superpowers/specs/2026-08-09-codex-self-update-design.md
_update_codex() {
  command -v codex >/dev/null 2>&1 || return 0
  [ "${AICODINGSETUP_SKIP_NETWORK:-}" = 1 ] && return 0
  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: codex update check failed (curl/jq missing) — codex may be stale" >&2
    return 0
  fi
  local installed latest
  installed=$(codex --version 2>/dev/null | awk '{print $NF}') || true
  latest=$(curl -fsSL --max-time 10 \
    https://registry.npmjs.org/@openai/codex/latest 2>/dev/null \
    | jq -r '.version // empty' 2>/dev/null) || true
  if [ -z "$installed" ] || [ -z "$latest" ]; then
    echo "ERROR: codex update check failed (installed='${installed:-?}' latest='${latest:-?}') — codex may be stale" >&2
    return 0
  fi
  [ "$installed" = "$latest" ] && return 0
  # CODEX_NON_INTERACTIVE=1: upstream grew y/N prompts that read /dev/tty.
  # Subshell with pipefail so a failed curl doesn't vanish behind sh
  # succeeding on empty stdin.
  if ! (set -o pipefail; curl -fsSL --max-time 600 https://chatgpt.com/codex/install.sh \
      | CODEX_NON_INTERACTIVE=1 sh >/dev/null 2>&1); then
    echo "ERROR: codex update failed — still at $installed" >&2
    return 0
  fi
  # Force-link over the baked seed. ensure_codex's probe links only when
  # ~/.local/bin/codex is absent, which would leave the stale image seed
  # shadowing the update. ~/.codex is the shared host mount, so the new
  # binary reaches every container and survives recreates.
  # Two drop-paths, newest first: upstream moved to a versioned
  # packages/standalone layout behind a `current` symlink; ~/.codex/bin is
  # the older flat one. Probing only the old path silently did nothing.
  local cand
  for cand in "$HOME/.codex/packages/standalone/current/bin/codex" \
              "$HOME/.codex/bin/codex"; do
    [ -x "$cand" ] || continue
    mkdir -p "$HOME/.local/bin"
    ln -sf "$cand" "$HOME/.local/bin/codex"
    break
  done
  local now
  now=$(codex --version 2>/dev/null | awk '{print $NF}') || true
  if [ "$now" != "$latest" ]; then
    echo "ERROR: codex updated but version is still ${now:-unknown} (expected $latest)" >&2
  fi
  return 0
}

# Codex ships TWO binaries per release: `codex` and the Code Mode sidecar
# `codex-code-mode-host`. Upstream symlinks ~/.local/bin/codex into the
# release dir and never links the sidecar on Linux — codex resolves it as a
# sibling of its own resolved path. The image can't keep that layout
# (~/.codex is a host bind mount at runtime, so baked content is invisible),
# so image/Dockerfile flattens the symlink into a plain copy — and copying
# `codex` alone strands the sidecar. codex 0.147.0 made features.code_mode_host
# stable/default-on, turning the gap into "Code Mode is unavailable ... host
# executable was not found" with Code Mode failing closed (2026-08-12).
# Re-pair the two next to the flattened binary. Idempotent, no network,
# fail-open: a broken Code Mode must never break sync.
_ensure_codex_code_mode_host() {
  local bin="$HOME/.local/bin/codex" host="$HOME/.local/bin/codex-code-mode-host"
  [ -x "$bin" ] || return 0
  # A symlinked codex resolves its own sibling — upstream's layout. Drop the
  # flat copy the seed needed: 49MB codex no longer consults (verified
  # 2026-08-12 on a real container — symlinked codex, no sidecar in
  # ~/.local/bin, Code Mode silent). Upstream prunes its own equivalent the
  # same way. Only ever a plain file we placed; a symlink there is someone
  # else's and stays.
  if [ -L "$bin" ]; then
    if [ -f "$host" ] && [ ! -L "$host" ]; then rm -f "$host"; fi
    return 0
  fi
  local version src
  version=$("$bin" --version 2>/dev/null | awk '{print $NF}') || true
  [ -n "$version" ] || return 0
  # Version-matched only: a sidecar from another release is not a fix.
  for src in "$HOME"/.codex/packages/standalone/releases/"$version"-*/bin/codex-code-mode-host; do
    [ -x "$src" ] || continue
    cmp -s "$src" "$host" 2>/dev/null && return 0
    if cp -f "$src" "$host.tmp.$$" 2>/dev/null && chmod +x "$host.tmp.$$" 2>/dev/null \
       && mv -f "$host.tmp.$$" "$host" 2>/dev/null; then
      return 0
    fi
    rm -f "$host.tmp.$$"
    echo "ERROR: could not install codex-code-mode-host — codex Code Mode will fail closed" >&2
    return 0
  done
  [ -x "$host" ] && return 0
  # No release tree yet (fresh container, mount not populated): the next
  # _update_codex installs one. Only complain when a tree exists but lacks
  # this version — that is the real drift.
  [ -d "$HOME/.codex/packages/standalone/releases" ] || return 0
  echo "ERROR: no codex-code-mode-host for codex $version under ~/.codex/packages/standalone/releases — Code Mode will fail closed" >&2
  return 0
}

_sync_binaries() {            # throttled network refresh
  # Header per pass-through updater so error text is attributable — Cursor's
  # binary is named `agent`, so its errors read as someone else's without one
  # (2026-08-12: "[unauthenticated]" mistaken for codex). _update_codex needs
  # no header: silent on success, self-labeled ERROR lines otherwise.
  # Host profile (bare-metal thin clients): claude is the only CLI the
  # core profile installs, so it's the only one to refresh.
  local profile; profile=$(_sync_profile)
  command -v claude   >/dev/null 2>&1 && { echo "--- claude update ---";    claude update    || true; }
  if [ "$profile" != host ]; then
    command -v opencode >/dev/null 2>&1 && { echo "--- opencode upgrade ---"; opencode upgrade || true; }
    if command -v agent >/dev/null 2>&1; then
      echo "--- cursor (agent update) ---"; agent update || true
    elif command -v cursor-agent >/dev/null 2>&1; then
      echo "--- cursor (cursor-agent update) ---"; cursor-agent update || true
    fi
    _update_codex || true
    # After the version gate, not inside it: the pairing can be broken while
    # codex is perfectly up to date (that is exactly how the image seed ships).
    _ensure_codex_code_mode_host || true
  fi
}

# Reconcile machine state that isn't a managed file: MCP registrations,
# marketplace plugins, npm MCP packages, retired-shim cleanup. Shares
# lib/provision.sh with install.sh so both converge the same set; prefers
# the refreshed clone's copy so a manual sync runs the latest definitions.
# Fail-open throughout — every provision function warns instead of failing.
_sync_provision() {
  # The sync mode reaches ensure_codex_managed_hooks through this variable:
  # on --boot it must never prompt for a sudo password (nothing can answer)
  # and must not re-warn on every container start.
  AICODING_SYNC_MODE="${1:-}"

  local blueprint_lib=""
  if [ -f "$AICODING_BLUEPRINT_CLONE/lib/provision.sh" ]; then
    blueprint_lib="$AICODING_BLUEPRINT_CLONE/lib"
  elif [ -n "${SCRIPT_DIR:-}" ] && [ -f "$SCRIPT_DIR/lib/provision.sh" ]; then
    blueprint_lib="$SCRIPT_DIR/lib"
  else
    return 0
  fi
  . "$blueprint_lib/provision.sh"
  command -v load_secrets_env >/dev/null 2>&1 && load_secrets_env || true
  install_mcp_packages   || true
  install_claude_mcps    || true
  install_claude_plugins || true
  remove_deprecated_shims || true

  # Codex's managed hook is install-time work, but syncing it here too is what
  # makes an existing machine self-heal: in a container (passwordless sudo) it
  # lands silently on the next boot instead of waiting for someone to re-run
  # the installer. provision.sh does not pull in provision-system.sh, so source
  # it directly — guarded, since a partial blueprint clone may not carry it.
  if [ -f "$blueprint_lib/provision-system.sh" ]; then
    . "$blueprint_lib/provision-system.sh" >/dev/null 2>&1 || true
    command -v ensure_codex_managed_hooks >/dev/null 2>&1 \
      && ensure_codex_managed_hooks || true
  fi

  # dvw-probe's symlink is otherwise only created by install.sh at container
  # creation. The catalog service execs it inside the container through the
  # docker proxy, so it must self-heal here too: a restart that wipes the
  # tmpfs blueprint clone (or drops the ~/.local/bin entry) would otherwise
  # strand it until someone re-runs install.sh by hand. provision-integrations.sh
  # expects SCRIPT_DIR to point at the blueprint root (it derives bin/ paths
  # from it); set it locally rather than relying on install.sh having run in
  # this process.
  if [ -f "$blueprint_lib/provision-integrations.sh" ]; then
    local SCRIPT_DIR; SCRIPT_DIR="$(dirname "$blueprint_lib")"
    . "$blueprint_lib/provision-integrations.sh"
    install_dvw_probe_symlink || true
  fi
  return 0
}

# Returns 0 if the binary-refresh throttle window is still fresh.
_sync_binaries_fresh() {
  [ -n "$(find "$AICODING_UPDATE_STATE/.binaries.stamp" -newermt "-${AICODING_UPDATE_TTL} seconds" 2>/dev/null)" ]
}
_sync_binaries_stamp() {
  mkdir -p "$AICODING_UPDATE_STATE"; : > "$AICODING_UPDATE_STATE/.binaries.stamp"
}

# Reconcile the workspace's .devcontainer/devcontainer.json image pin from
# the blueprint copy. The blueprint self-pins after every image publish
# (2026-08-09-auto-pin-image-digest-design.md); without this, the snapshot
# `dvw new` committed into the workspace repo goes stale and the ⬆rebuild
# badge's CTA recreates from the old pin. Working-tree edit ONLY — never
# commits or pushes; `devpod up --recreate` reads on-disk config, so the
# next dvw rebuild already uses the new pin and the commit rides the
# project's normal flow. Fail-open: warn + return 0, never break sync.
# Spec: docs/superpowers/specs/2026-08-09-sync-workspace-pin-design.md
_sync_devcontainer_pin() {
  local mode="${1:-}" top target bp_image cur_image old_d new_d
  top=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null) || return 0
  target="$top/.devcontainer/devcontainer.json"
  [ -f "$target" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  bp_image=$(jq -r '.image // empty' "$AICODING_BLUEPRINT_CLONE/devcontainer.json" 2>/dev/null) || true
  if [ -z "$bp_image" ]; then
    echo "WARN: blueprint devcontainer.json has no image — skipping pin sync" >&2
    return 0
  fi
  cur_image=$(jq -r '.image // empty' "$target" 2>/dev/null) || true
  case "$cur_image" in
    ghcr.io/vossiman/devbox-base@*) : ;;
    *) return 0 ;;   # custom or missing image — never stomp
  esac
  [ "$cur_image" = "$bp_image" ] && return 0
  old_d=$(printf '%s' "$cur_image" | sed -E 's/.*@sha256:([0-9a-f]{12}).*/\1/')
  new_d=$(printf '%s' "$bp_image"  | sed -E 's/.*@sha256:([0-9a-f]{12}).*/\1/')
  if [ "$mode" = dry-run ]; then
    echo "devcontainer pin: $old_d -> $new_d (dry run, not written)"
    return 0
  fi
  if ! sed -i -E "s|\"image\": \"[^\"]+\"|\"image\": \"${bp_image}\"|" "$target"; then
    echo "WARN: devcontainer pin sync failed for $target" >&2
    return 0
  fi
  echo "devcontainer pin: $old_d -> $new_d (commit at your convenience)"
  return 0
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

  # 2b. Workspace devcontainer pin — dry-run reports, other modes edit the
  #     working tree (never commits). Local file ops only, no throttle.
  _sync_devcontainer_pin "$mode" || true

  # 3. Binaries + machine-state provision (MCPs/plugins) — never under
  #    --dry-run. Only --boot throttles (it's the only path that runs
  #    unattended on every container start); both share one stamp.
  if [ "$mode" != dry-run ]; then
    if [ "$mode" = boot ] && _sync_binaries_fresh; then :; else
      _sync_binaries
      _sync_provision "$mode"
      _sync_binaries_stamp
    fi
  fi
  return 0
}
