# lib/sync.sh — the one routine that brings THIS container current.
# Steps: (1) auth plumbing [always], (2) blueprint config reconcile,
# (3) binary refresh [throttled]. Config applies the same in every mode;
# --boot throttles binaries, --dry-run writes nothing. Independent components
# continue after a failure; the aggregate status remains nonzero.
# Sourced (no shebang / set -e); matches the lib/*.sh style.

: "${AICODING_BLUEPRINT_CLONE:=${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
: "${AICODING_BLUEPRINT_REMOTE:=https://github.com/vossiman/aiCodingBaseSetup}"
: "${AICODING_BLUEPRINT_LOCAL:=0}"
: "${AICODING_UPDATE_TTL:=21600}"
: "${AICODING_STATE_DIR:=$HOME/.local/state/aicoding}"
# Container-local — must match bin/aicoding-status. ~/.aicodingsetup is a host
# bind mount shared by every container; keeping this cache there let one
# container's sync silence the update CTA in all the others.
: "${AICODING_UPDATE_STATE:=$HOME/.local/state/aicoding/updates}"

_sync_source_update_libraries() {
  local root=${1:-${SCRIPT_DIR:-}}
  [ -n "$root" ] || return 0
  [ -f "$root/lib/update-results.sh" ] && . "$root/lib/update-results.sh"
  [ -f "$root/lib/update-components.sh" ] && . "$root/lib/update-components.sh"
  [ -f "$root/lib/ci-selector.sh" ] && . "$root/lib/ci-selector.sh"
  [ -f "$root/lib/runtime.sh" ] && . "$root/lib/runtime.sh"
}

_sync_blueprint_version() {
  local root=${1:-$AICODING_BLUEPRINT_CLONE} marker
  marker=$(cat "$root/.aicoding-version" 2>/dev/null || true)
  if [[ "$marker" =~ ^[0-9a-f]{40}$ ]]; then printf '%s\n' "$marker"; return 0; fi
  git -C "$root" rev-parse HEAD 2>/dev/null
}

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
# The deployment profile this sync runs under: `host` for bare-metal thin
# clients (the Mint desktop, jumpi), `container` for devpods. Plumbing steps
# that touch machine state MUST consult this: _sync_plumbing runs on every
# profile, and a desktop user may have passwordless sudo.
# Read before blueprint-deploy.sh is sourced, so it reads the files directly.
_sync_explicit_profile() {
  local p=${AICODING_PROFILE:-}
  if [ -z "$p" ] && command -v jq >/dev/null 2>&1 \
      && [ -f "$AICODING_STATE_DIR/component-selection.json" ]; then
    p=$(jq -r '.profile // empty' "$AICODING_STATE_DIR/component-selection.json" 2>/dev/null) || p=
  fi
  [ -n "$p" ] || p=$(cat "$AICODING_STATE_DIR/profile" 2>/dev/null) || p=
  printf '%s\n' "$p"
}

_sync_profile() {
  local p
  p=$(_sync_explicit_profile)
  case "$p" in host|container|minimal-pi) ;; *) p=container ;; esac
  printf '%s\n' "$p"
}

# A legacy host with no recorded profile must never run step 5's apt
# installs or tmux build, so the container default alone does not count.
_sync_explicit_container_profile() {
  [ "$(_sync_explicit_profile)" = container ]
}

# Mirrors the container test in detect_environment() (lib/provision-system.sh).
# Kept in sync by hand rather than sourcing that file here, which would print
# its own INFO line and run its install-helper side effects. Tests force the
# answer with AICODING_CONTAINER_RUNTIME=0|1; production never sets it.
_sync_is_container_runtime() {
  if [ -n "${AICODING_CONTAINER_RUNTIME:-}" ]; then
    [ "$AICODING_CONTAINER_RUNTIME" = 1 ]
    return
  fi
  [ -f /.dockerenv ] || [ -f /run/.containerenv ] \
    || [ -n "${REMOTE_CONTAINERS:-}" ] || [ -n "${DEVCONTAINER:-}" ] \
    || [ -n "${CODESPACES:-}" ]
}

# Step 5's gate (aicoding_sync, below): the profile must say container and
# either something names it explicitly or the runtime looks like a container.
_sync_system_provision_allowed() {
  [ "$(_sync_profile)" = container ] || return 1
  _sync_explicit_container_profile || _sync_is_container_runtime
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

# devbox-base images built 2026-09-09..2026-09-25 baked a root-owned uv cache
# into the user's home, which breaks every uv call made as the user. Only that
# exact path is repaired: a configurable one could aim a root `chown -R` at
# anything.
ensure_uv_cache_ownership() {
  [ "$(_sync_profile)" != host ] || return 0
  local dir="$HOME/.cache/uv" foreign rc=0
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  [ "$(readlink -f "$dir")" = "$(readlink -f "$HOME")/.cache/uv" ] || return 0
  foreign=$(find "$dir" ! -user "$(id -u)" -print -quit 2>/dev/null) || rc=$?
  [ -z "$foreign" ] && [ "$rc" -eq 0 ] && return 0
  if sudo -n chown -R -P "$(id -u):$(id -g)" "$dir" 2>/dev/null; then
    declare -F ok >/dev/null && ok "took ownership of $dir (was partly owned by another user)"
  else
    echo "WARN: $dir is partly owned by another user and sudo is unavailable; uv will fail until it is chowned" >&2
  fi
  return 0
}

_sync_plumbing() {            # never throttled — must be correct now
  # First: later steps (clip-x11-bridge) start through `uv run`.
  command -v ensure_uv_cache_ownership >/dev/null 2>&1 && ensure_uv_cache_ownership || true
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

_sync_validate_blueprint_release() {
  local root=$1 sha=$2 file
  [ "$(cat "$root/.aicoding-version" 2>/dev/null)" = "$sha" ] || return 1
  [ "$(cat "$root/.aicoding-bootstrap-version" 2>/dev/null)" = 1 ] || return 1
  for file in bin/aicoding-sync lib/sigchld.sh lib/sync.sh lib/blueprint-deploy.sh lib/update-results.sh lib/update-components.sh; do
    [ -f "$root/$file" ] && bash -n "$root/$file" || return 1
  done
  [ -x "$root/bin/aicoding-sync" ]
}

# Selected releases stay Gitless, so keep the historical bytes of every
# retired source: retirement deletes a file only when it still equals one.
_sync_capture_generated_provenance() {
  local root=$1
  [ -d "$root/.git" ] || return 1
  (
    export AICODING_BLUEPRINT_CLONE="$root"
    . "$root/lib/blueprint-deploy.sh" || exit 1
    local provenance="$root/.aicoding-generated-provenance" rel source commit
    mkdir -p "$provenance" || exit 1
    while IFS=$'\t' read -r rel source; do
      case "$source" in ''|/*|*..*) exit 1 ;; esac
      mkdir -p "$provenance/$source" || exit 1
      while IFS= read -r commit; do
        [ -n "$commit" ] || continue
        git -C "$root" show "$commit:$source" > "$provenance/$source/$commit" 2>/dev/null \
          || rm -f "$provenance/$source/$commit"
      done < <(git -C "$root" log --format=%H --all -- "$source" 2>/dev/null)
    done < <(managed_retired_files)
  )
}

_sync_stage_selected_blueprint() {
  local sha=$1 final sync_root
  if ! declare -F aicoding_stage_source >/dev/null 2>&1; then
    sync_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || return 1
    . "$sync_root/lib/runtime.sh" || return 1
  fi
  final="$AICODING_DATA_DIR/versions/aicoding/$sha"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 2
  if [ -d "$final" ]; then
    _sync_validate_blueprint_release "$final" "$sha" || return 1
  else
    local stage="$AICODING_DATA_DIR/source-staging/aicoding.$sha.$$"
    mkdir -p "$(dirname "$stage")"; rm -rf "$stage"
    aicoding_progress_run "blueprint: downloading source (timeout ${AICODING_VENDOR_TIMEOUT:-600}s)" _aicoding_progress_capture /dev/null timeout "${AICODING_VENDOR_TIMEOUT:-600}" git clone --quiet --no-checkout "$AICODING_BLUEPRINT_REMOTE" "$stage" || { rm -rf "$stage"; return 1; }
    aicoding_progress_run "blueprint: extracting source (timeout ${AICODING_VENDOR_TIMEOUT:-600}s)" _aicoding_progress_capture /dev/null timeout "${AICODING_VENDOR_TIMEOUT:-600}" git -C "$stage" checkout --quiet --detach "$sha" || { rm -rf "$stage"; return 1; }
    [ "$(git -C "$stage" rev-parse HEAD 2>/dev/null)" = "$sha" ] || { rm -rf "$stage"; return 1; }
    _sync_capture_generated_provenance "$stage" || { rm -rf "$stage"; return 1; }
    rm -rf "$stage/.git"
    printf '%s\n' "$sha" > "$stage/.aicoding-version"
    _sync_validate_blueprint_release "$stage" "$sha" || { rm -rf "$stage"; return 1; }
    aicoding_stage_source aicoding "$stage" "$sha" || { rm -rf "$stage"; return 1; }
    rm -rf "$stage" || return 1
  fi
  # Same stable launchers as aicoding-install. Passing them on every sync is
  # what converges an old layout (launchers symlinked into a tracking clone,
  # no aicoding-auto-update) without a manual reinstall. Activation replaces
  # a symlinked launcher atomically and never writes through the link.
  aicoding_activate_version aicoding "$sha" "${_SYNC_STABLE_LAUNCHERS[@]}" || return 1
  printf '%s\n' "$final"
}

# Launcher/relative-executable pairs, identical to bin/aicoding-install.
_SYNC_STABLE_LAUNCHERS=(
  aicoding-sync bin/aicoding-sync aicoding-install bin/aicoding-install
  aicoding-status bin/aicoding-status aicoding-select bin/aicoding-select
  aicoding-auto-update bin/aicoding-auto-update
)

# Legacy code (a tracking clone or an older release) stages and activates the
# selected release without launchers, then re-executes it. Reconcile the
# stable launchers from the running release itself. Cheap when they already
# match: no activation, so no release digest is recomputed.
_sync_reconcile_running_launchers() {
  local root sha release current i launcher relative expected result=0 sync_root
  root=$(readlink -f -- "${AICODING_BLUEPRINT_CLONE:-}" 2>/dev/null) || return 0
  sha=$(cat "$root/.aicoding-version" 2>/dev/null) || return 0
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 0
  release=$(readlink -f -- "$AICODING_DATA_DIR/versions/aicoding/$sha" 2>/dev/null) || return 0
  [ "$root" = "$release" ] || return 0
  if ! declare -F aicoding_activate_version >/dev/null 2>&1; then
    sync_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || return 1
    . "$sync_root/lib/runtime.sh" || return 1
  fi
  current="$AICODING_DATA_DIR/current/aicoding"
  if [ "$(readlink -- "$current" 2>/dev/null)" = "../versions/aicoding/$sha" ]; then
    expected=$(mktemp) || return 1
    for ((i=0; i<${#_SYNC_STABLE_LAUNCHERS[@]}; i+=2)); do
      launcher=${_SYNC_STABLE_LAUNCHERS[$i]}; relative=${_SYNC_STABLE_LAUNCHERS[$((i + 1))]}
      if [ -L "$HOME/.local/bin/$launcher" ] \
          || ! _aicoding_runtime_write_wrapper "$expected" "$current" "$relative" \
          || ! cmp -s -- "$expected" "$HOME/.local/bin/$launcher"; then
        result=1
        break
      fi
    done
    rm -f -- "$expected"
    [ "$result" -eq 1 ] || return 0
  fi
  aicoding_activate_version aicoding "$sha" "${_SYNC_STABLE_LAUNCHERS[@]}" || {
    echo "aicoding-sync: could not reconcile stable launchers for ${sha:0:7}" >&2
    return 1
  }
}

# Which harness preparations deferred provisioning, so a blocked provision
# record names its cause.
_sync_provision_deferral_detail() {
  local keys
  keys=$(printf '%s\n' "${!_SYNC_DEFERRED_PROVISION_COMPONENTS[@]}" | sed '/^$/d' | sort | paste -sd, -)
  [[ -n "$keys" ]] && printf 'deferred by %s\n' "$keys"
  return 0
}

_sync_config_gate() {
  command -v aicoding_config_is_compatible >/dev/null 2>&1 || return 0
  AICODING_REQUIRE_UPDATE_RECEIPT=1 aicoding_config_is_compatible "$1"
}

# Record every config component from the outcome of all destinations it owns.
# The worst outcome wins: failed > malformed > blocked > current.
_sync_record_config_results() {
  local target=$1 d component result rank worst=1
  local -A ranks=() reasons=() details=() present=()
  for d in "${!MANAGED_RESULT[@]}"; do
    component=$(_aicoding_config_component "$d" 2>/dev/null || echo config)
    result=${MANAGED_RESULT[$d]}
    [[ "$result" == absent ]] || present[$component]=1
    case "$result" in
      failed) rank=4 ;;
      malformed) rank=3 ;;
      blocked:*) rank=2 ;;
      *) rank=1 ;;
    esac
    # A newer release owns the shared roots, so this one also leaves that
    # harness's shared plugins and MCP registrations alone.
    if [[ "$result" == held && "$component" == config-* ]]; then
      _SYNC_DEFERRED_PROVISION_COMPONENTS[${component#config-}]=1
    fi
    if (( rank > worst )); then worst=$rank; fi
    if [[ ( "$rank" == 2 || "$rank" == 4 ) && "$component" == config-* ]]; then
      _SYNC_DEFERRED_PROVISION_COMPONENTS[${component#config-}]=1
    fi
    # An MCP staging wait never hides another destination's actionable reason.
    if (( rank < ${ranks[$component]:-0} )); then continue; fi
    if (( rank == ${ranks[$component]:-0} )); then
      [[ "$rank" == 2 && "${reasons[$component]}" == mcp_exact_version_staging_unavailable \
        && "$result" != blocked:mcp_exact_version_staging_unavailable ]] || continue
    fi
    ranks[$component]=$rank
    if [[ "$result" == blocked:* ]]; then
      reasons[$component]=${result#blocked:}
      details[$component]=
      if [[ "${reasons[$component]}" == mcp_exact_version_staging_unavailable ]]; then
        details[$component]=$(aicoding_exact_mcp_config_cause "$d" 2>/dev/null) || true
      fi
    fi
  done
  if (( worst == 2 || worst == 4 )); then _SYNC_PASS_DEFERRED=1; fi
  command -v aicoding_result_record >/dev/null 2>&1 && [ "$target" != unknown ] || return 0
  for component in "${!ranks[@]}"; do
    [[ "$component" == config-* ]] || continue
    case "${ranks[$component]}" in
      1)
        if [[ -n "${present[$component]:-}" ]]; then
          aicoding_result_record "$component" current "$target" reconciliation_verified "$target"
        else
          aicoding_result_record "$component" current "$target" harness_not_installed "$target"
        fi ;;
      2) aicoding_result_record "$component" blocked "$target" "${reasons[$component]}" "" "${details[$component]}" ;;
      3) aicoding_result_record "$component" blocked "$target" managed_config_malformed ;;
      4) aicoding_result_record "$component" failed "$target" managed_config_apply_failed ;;
    esac || true
  done
  case "$worst" in
    1) aicoding_result_record config current "$target" applied "$target" ;;
    2) aicoding_result_record config blocked "$target" partial_config_blocked ;;
    3) aicoding_result_record config blocked "$target" managed_config_malformed ;;
    4) aicoding_result_record config failed "$target" managed_config_apply_failed ;;
  esac || true
}

# Bring managed config to the blueprint's state (lib/blueprint-deploy.sh's
# four rules). Every mode applies the same way; --dry-run only reports.
_sync_reconcile() {
  local mode=$1 old new rc=0
  declare -gA _SYNC_DEFERRED_PROVISION_COMPONENTS=() MANAGED_RESULT=()
  if [[ "${_SYNC_REFRESHED:-0}" != 1 ]]; then
    refresh_blueprint || return $?
  fi
  [ -f "$AICODING_BLUEPRINT_CLONE/lib/blueprint-deploy.sh" ] || return 0
  . "$AICODING_BLUEPRINT_CLONE/lib/blueprint-deploy.sh"
  load_secrets_env
  old=$(aicoding_stamp_read blueprint_commit)
  new=$(_sync_blueprint_version "$AICODING_BLUEPRINT_CLONE" || echo unknown)
  echo "Blueprint: ${old:0:7} -> ${new:0:7}"
  if [ "$mode" = dry-run ]; then
    managed_config_apply --dry-run
    return
  fi
  aicoding_shared_locks_acquire_managed_roots || {
    echo "aicoding-sync: shared configuration writer is busy" >&2
    return 1
  }
  MANAGED_CONFIG_GATE=_sync_config_gate managed_config_apply || rc=1
  _sync_record_config_results "$new"
  if [ "$rc" -eq 0 ] && [ "${#_SYNC_DEFERRED_PROVISION_COMPONENTS[@]}" -eq 0 ]; then
    aicoding_stamp_blueprint "$new"
    aicoding_remove_legacy_state
  fi
  return "$rc"
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

  local blueprint_lib="" rc=0 target SCRIPT_DIR provision_deferred=0 step_rc
  _AICODING_PREPARATION_DEFERRED=0
  declare -p _SYNC_DEFERRED_PROVISION_COMPONENTS >/dev/null 2>&1 \
    || declare -gA _SYNC_DEFERRED_PROVISION_COMPONENTS=()
  if [ -f "$AICODING_BLUEPRINT_CLONE/lib/provision.sh" ]; then
    blueprint_lib="$AICODING_BLUEPRINT_CLONE/lib"
  elif [ -n "${SCRIPT_DIR:-}" ] && [ -f "$SCRIPT_DIR/lib/provision.sh" ]; then
    blueprint_lib="$SCRIPT_DIR/lib"
  else
    return 0
  fi
  SCRIPT_DIR="$(dirname "$blueprint_lib")"
  . "$blueprint_lib/provision.sh"
  command -v load_secrets_env >/dev/null 2>&1 && load_secrets_env || true

  # Reconcile normally holds these descriptors through the rest of the pass.
  # Acquire independently as well: a busy or failed
  # reconcile still reaches provisioning so unrelated local repairs can run.
  if ! command -v aicoding_shared_locks_acquire_managed_roots >/dev/null 2>&1 \
      && [ -f "$blueprint_lib/blueprint-deploy.sh" ]; then
    . "$blueprint_lib/blueprint-deploy.sh"
  fi
  local shared_config_ready=1
  if command -v aicoding_shared_locks_acquire_managed_roots >/dev/null 2>&1 \
      && ! aicoding_shared_locks_acquire_managed_roots; then
    echo "aicoding-sync: shared configuration writer is busy; deferring shared provisioning" >&2
    shared_config_ready=0
    provision_deferred=1
  fi

  step_rc=0; _AICODING_PREPARATION_DEFERRED=0
  install_mcp_packages || step_rc=$?
  [ "${_AICODING_PREPARATION_DEFERRED:-0}" -eq 1 ] && provision_deferred=1
  case "$step_rc" in
    0) ;;
    3) provision_deferred=1 ;;
    *) rc=1 ;;
  esac
  local claude_installed=0
  if command -v _aicoding_command_is_linux >/dev/null 2>&1; then
    _aicoding_command_is_linux claude && claude_installed=1
  elif command -v claude >/dev/null 2>&1; then
    claude_installed=1
  fi
  if [ "$claude_installed" -eq 1 ] && [ "$shared_config_ready" -eq 1 ] \
      && [ -z "${_SYNC_DEFERRED_PROVISION_COMPONENTS[claude]:-}" ]; then
    step_rc=0; _AICODING_PREPARATION_DEFERRED=0
    install_claude_mcps || step_rc=$?
    if [ "$step_rc" -ne 0 ]; then
      if [ "$step_rc" -eq 3 ]; then provision_deferred=1; else rc=1; fi
    fi
    step_rc=0; _AICODING_PREPARATION_DEFERRED=0
    install_claude_plugins || step_rc=$?
    if [ "$step_rc" -ne 0 ]; then
      if [ "$step_rc" -eq 3 ]; then provision_deferred=1; else rc=1; fi
    fi
  elif [ "$claude_installed" -eq 1 ] \
      && { [ "$shared_config_ready" -eq 0 ] \
        || [ -n "${_SYNC_DEFERRED_PROVISION_COMPONENTS[claude]:-}" ]; }; then
    provision_deferred=1
  fi
  if [ "$shared_config_ready" -eq 1 ] \
      && [ -z "${_SYNC_DEFERRED_PROVISION_COMPONENTS[codex]:-}" ]; then
    step_rc=0; _AICODING_PREPARATION_DEFERRED=0
    install_codex_plugins || step_rc=$?
    if [ "$step_rc" -ne 0 ]; then
      if [ "$step_rc" -eq 3 ]; then provision_deferred=1; else rc=1; fi
    fi
  elif command -v codex >/dev/null 2>&1; then
    provision_deferred=1
  fi
  remove_deprecated_shims || rc=1

  # Codex's managed hook is install-time work, but syncing it here too is what
  # makes an existing machine self-heal: in a container (passwordless sudo) it
  # lands silently on the next boot instead of waiting for someone to re-run
  # the installer. provision.sh does not pull in provision-system.sh, so source
  # it directly — guarded, since a partial blueprint clone may not carry it.
  if [ -f "$blueprint_lib/provision-system.sh" ]; then
    . "$blueprint_lib/provision-system.sh" >/dev/null 2>&1 || true
    command -v ensure_codex_managed_hooks >/dev/null 2>&1 \
      && ensure_codex_managed_hooks || rc=1
    # @playwright/mcp@latest can require a newer Chromium after an update.
    # Reconcile existing machines too, rather than waiting for a rebuild.
    if command -v ensure_playwright_browsers >/dev/null 2>&1; then
      step_rc=0
      ensure_playwright_browsers || step_rc=$?
      case "$step_rc" in
        0) ;;
        3) provision_deferred=1 ;;
        *) rc=1 ;;
      esac
    fi
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
    . "$blueprint_lib/provision-integrations.sh"
    declare -F aicoding_ui_group >/dev/null && aicoding_ui_group "Command-line tools"
    install_dvw_probe_symlink || rc=1
    # Same self-heal for the other agent-facing CLIs install.sh symlinks:
    # a ~/.local/bin that lost them, or predates one, otherwise only
    # recovers on a full aicoding-install. Container-only entries (clip
    # shims, ssh-agent watcher) stay out: they are profile-gated in
    # install.sh and this path runs on hosts too.
    install_agent_notify_symlink || rc=1
    install_update_status_symlink || rc=1
    install_kanban_post_symlink || rc=1
    install_kanban_work_symlink || rc=1
    install_t3_symlinks || rc=1
    install_measure_remote_symlink || rc=1
    install_dokploy_api_symlink || rc=1
    install_bugsink_api_symlink || rc=1
    install_aicoding_root_install_symlink || rc=1
    install_kuma_admin_symlink || rc=1
    install_redact_transcript_symlink || rc=1
    install_redact_sessions_symlinks || rc=1
    declare -F aicoding_ui_group_end >/dev/null && aicoding_ui_group_end
    # install.sh enrolls the scheduler at install time. Legacy installs never
    # did, and activation above only now gave them the launcher, so a sync
    # converges enrollment the same way. Idempotent; skipped offline.
    # Never from a sync the scheduler itself started: a detached enrollment
    # can switch backends and TERM the fallback worker that is still waiting
    # on this sync, leaving neither timer nor worker. AICODING_AUTO_UPDATE_RUN
    # marks the updater's sync; AICODING_AUTO_UPDATE_SOURCE also covers older
    # fallback workers and the systemd unit, which predate that marker.
    if [ -x "$HOME/.local/bin/aicoding-auto-update" ] \
        && [ "${AICODING_AUTO_UPDATE_RUN:-}" != 1 ] \
        && [ -z "${AICODING_AUTO_UPDATE_SOURCE:-}" ]; then
      ensure_aicoding_auto_update || rc=1
    fi
    # A sync is one of the documented recovery triggers for transcripts a
    # crashed session left behind. Synchronous and bounded: a detached sweep
    # would outlive the sync and keep writing state into a HOME the caller
    # (the bats suite, say) is already tearing down. Boot has its own
    # detached sweep in on-start.sh, gated by AICODINGSETUP_SKIP_NETWORK.
    if [ "${AICODING_SYNC_MODE:-}" != boot ] && [ -x "$HOME/.local/bin/redact-sessions" ]; then
      timeout 120 "$HOME/.local/bin/redact-sessions" --sweep >/dev/null 2>&1 || true
    fi
  fi

  # Provision functions historically warn and return success, so verify their
  # concrete local artifacts before writing a success stamp. Optional sources
  # that are absent from this blueprint are excluded.
  local name source dest
  for name in dvw-probe agent-notify aicoding-status kanban-post kanban-work measure-remote \
              dokploy-api bugsink-api aicoding-root-install kuma-admin redact-transcript redact-sessions codex-turn-done \
              t3-setup t3-adopt t3-start t3-stop t3-update t3-auto t3-status t3-migrate t3-projects; do
    source="$(dirname "$blueprint_lib")/bin/$name"
    dest="$HOME/.local/bin/$name"
    [ -f "$source" ] || continue
    _sync_provision_artifact_matches "$name" "$source" "$dest" || rc=1
  done
  if command -v _aicoding_command_is_linux >/dev/null 2>&1 \
      && _aicoding_command_is_linux codex 2>/dev/null; then
    declare -F codex_managed_state >/dev/null \
      || . "$blueprint_lib/codex-managed.sh" 2>/dev/null || true
    if ! declare -F codex_managed_state >/dev/null \
        || ! codex_managed_state "$(dirname "$blueprint_lib")"; then
      # A drift the hook step left on purpose waits for (or asks for) the host
      # root runner; any other drift is a real provisioning failure.
      case "${codex_managed_defer_reason:-}" in
        root_runner_pending|root_runner_not_installed|root_runner_failed)
          provision_deferred=1
          _SYNC_DEFERRED_PROVISION_COMPONENTS[root-runner]=1
          command -v aicoding_result_record >/dev/null 2>&1 \
            && aicoding_result_record root-runner blocked \
              "$(_sync_blueprint_version "$(dirname "$blueprint_lib")" || true)" "$codex_managed_defer_reason" || true
          ;;
        *) rc=1 ;;
      esac
    elif jq -e '.components["root-runner"].state == "blocked"' \
        "$AICODING_RESULTS_FILE" >/dev/null 2>&1; then
      command -v aicoding_result_record >/dev/null 2>&1 \
        && aicoding_result_record root-runner current "" codex_managed_current \
          "$(_sync_blueprint_version "$(dirname "$blueprint_lib")" || echo unknown)" || true
    fi
  fi

  # A receipt alone cannot prove that a Python entry point survived the
  # staging-to-release move or that a retained release remains intact. Verify
  # the physical Kanban release and stable launcher before stamping provision.
  local kanban_pin_file="$(dirname "$blueprint_lib")/configs/versions/kanban-mcp.rev"
  if [ -f "$kanban_pin_file" ]; then
    local kanban_revision= kanban_state=
    if ! _provision_ensure_update_components \
        || ! kanban_revision=$(_aicoding_kanban_pinned_revision); then
      rc=1
    elif ! _aicoding_active_kanban_mcp_valid "$kanban_revision"; then
      kanban_state=$(jq -r '.components["mcp-kanban"].state // empty' \
        "$AICODING_RESULTS_FILE" 2>/dev/null) || kanban_state=
      case "$kanban_state" in
        current|updated)
          rc=1
          command -v aicoding_result_record >/dev/null 2>&1 \
            && aicoding_result_record mcp-kanban failed "$kanban_revision" \
              active_controller_invalid || true
          ;;
        *)
          provision_deferred=1
          _provision_record_blocked mcp-kanban exact_package_not_staged
          ;;
      esac
    fi
  fi

  target=$(_sync_blueprint_version "$(dirname "$blueprint_lib")" || echo unknown)
  [ "$target" != unknown ] || rc=1
  if [ "$rc" -eq 0 ] && [ "$provision_deferred" -eq 0 ]; then
    command -v aicoding_stamp_write >/dev/null 2>&1 && [ "$target" != unknown ] \
      && aicoding_stamp_write provision_commit "$target"
    command -v aicoding_result_record >/dev/null 2>&1 \
      && aicoding_result_record provision current "$target" verified "$target" || true
  elif [ "$rc" -ne 0 ]; then
    command -v aicoding_result_record >/dev/null 2>&1 \
      && aicoding_result_record provision failed "$target" partial_provision_failure || true
  else
    _SYNC_PASS_DEFERRED=1
    command -v aicoding_result_record >/dev/null 2>&1 \
      && aicoding_result_record provision blocked "$target" preparation_deferred "" \
        "$(_sync_provision_deferral_detail)" || true
  fi
  return "$rc"
}

_sync_provision_artifact_matches() {
  local name=$1 source=$2 dest=$3 current active expected result=1
  if [ -L "$dest" ] \
      && [ "$(readlink -f "$dest" 2>/dev/null)" = "$(readlink -f "$source" 2>/dev/null)" ]; then
    return 0
  fi
  # aicoding-status is enrolled as a stable regular-file wrapper. Validate it
  # byte-for-byte with the runtime writer and require its current pointer to
  # select the same physical source checked by this provision pass.
  [ "$name" = aicoding-status ] || return 1
  [ -f "$dest" ] && [ -x "$dest" ] || return 1
  current="${AICODING_DATA_DIR:-$HOME/.local/share/aicoding}/current/aicoding"
  [ -L "$current" ] || return 1
  active=$(readlink -f -- "$current" 2>/dev/null) || return 1
  [ "$active/bin/aicoding-status" = "$(readlink -f -- "$source" 2>/dev/null)" ] || return 1
  declare -F _aicoding_runtime_write_wrapper >/dev/null 2>&1 || return 1
  expected=$(mktemp) || return 1
  if _aicoding_runtime_write_wrapper "$expected" "$current" bin/aicoding-status \
      && cmp -s -- "$expected" "$dest"; then
    result=0
  fi
  rm -f -- "$expected" || return 1
  return "$result"
}

# Returns 0 if the binary-refresh throttle window is still fresh.
_sync_binaries_fresh() {
  [ -n "$(find "$AICODING_UPDATE_STATE/.binaries.stamp" -newermt "-${AICODING_UPDATE_TTL} seconds" 2>/dev/null)" ]
}
_sync_binaries_stamp() {
  mkdir -p "$AICODING_UPDATE_STATE"; : > "$AICODING_UPDATE_STATE/.binaries.stamp"
}

# Replace this process only with the exact CI-qualified immutable release
# selected for the pass. A local --blueprint source is used verbatim. There is
# deliberately no legacy tracking-clone fetch/reset fallback.
_sync_refresh_and_reexec() {
  if [[ "$AICODING_BLUEPRINT_LOCAL" == 1 ]]; then refresh_blueprint; return $?; fi
  if [[ "${AICODING_SYNC_REEXECED:-0}" == 1 ]]; then
    _SYNC_REFRESHED=1
    _sync_reconcile_running_launchers
    return $?
  fi
  if [ -n "${AICODING_SELECTED_AICODING_SHA:-}" ]; then
    local selected_root
    selected_root=$(_sync_stage_selected_blueprint "$AICODING_SELECTED_AICODING_SHA") || return 1
    echo "Staged CI-qualified blueprint ${AICODING_SELECTED_AICODING_SHA:0:7}"
    AICODING_BLUEPRINT_CLONE="$selected_root" AICODING_SYNC_REEXECED=1 _SYNC_REFRESHED=1 \
      exec bash "$selected_root/bin/aicoding-sync" "$@"
  fi
  _SYNC_REFRESHED=1
  return 0
}

# Additive system packages (fixed apt list, tmux pin, frogmouth, go, uv).
# Container profile only: hosts never ran install-time system provisioning.
_sync_system_provision() {
  local lib=""
  if [ -f "${AICODING_BLUEPRINT_CLONE:-}/lib/provision-scheduled.sh" ]; then
    lib="$AICODING_BLUEPRINT_CLONE/lib/provision-scheduled.sh"
  elif [ -n "${SCRIPT_DIR:-}" ] && [ -f "$SCRIPT_DIR/lib/provision-scheduled.sh" ]; then
    lib="$SCRIPT_DIR/lib/provision-scheduled.sh"
  else
    return 0
  fi
  . "$lib" >/dev/null || return 1
  aicoding_run_system_provision
}

aicoding_sync() {
  # Parse the FIRST recognized flag. --yes is kept for old callers.
  local mode=default arg
  for arg in "$@"; do
    [ "$arg" = --full ] && export AICODING_SYNC_FULL=1
  done
  for arg in "$@"; do
    case "$arg" in
      --dry-run) mode=dry-run; break ;;
      --yes)     mode=yes;     break ;;
      --boot)    mode=boot;    break ;;
      --first)   mode=first;   break ;;
    esac
  done

  _sync_source_update_libraries "${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  declare -F aicoding_ui_begin >/dev/null && aicoding_ui_begin

  # An unattended pass advances only to an exact main SHA whose required CI
  # succeeded. Selection failure keeps the existing installation active.
  local overall_rc=0 selected="${AICODING_SELECTED_AICODING_SHA:-}"
  _SYNC_PASS_DEFERRED=0
  if [ "$mode" != dry-run ] && [ "$AICODING_BLUEPRINT_LOCAL" != 1 ] \
      && [ "${AICODING_SYNC_REEXECED:-0}" != 1 ] \
      && [ "${AICODINGSETUP_SKIP_NETWORK:-}" != 1 ] \
      && command -v aicoding_select_ci_sha >/dev/null 2>&1; then
    selected=$(aicoding_select_ci_sha aicoding) || true
    if [ -n "$selected" ]; then
      export AICODING_SELECTED_AICODING_SHA=$selected
    else
      command -v aicoding_result_record >/dev/null 2>&1 \
        && aicoding_result_record aicoding blocked "" ci_selection_unavailable || true
      overall_rc=1
      _SYNC_REFRESHED=1
    fi
  fi

  # 0. Bring the clone current and, if it moved, hand over to its code.
  if [ "$overall_rc" -eq 0 ]; then
    _sync_refresh_and_reexec "$@" || overall_rc=1
  fi

  if [ -f "$AICODING_BLUEPRINT_CLONE/lib/blueprint-deploy.sh" ]; then
    . "$AICODING_BLUEPRINT_CLONE/lib/blueprint-deploy.sh"
    [ "$mode" = dry-run ] || aicoding_migrate_legacy_state
  fi
  local profile
  profile=$(_sync_profile)

  # 1. Plumbing — always correct now, but write nothing under --dry-run.
  [ "$mode" != dry-run ] && [ "$profile" != minimal-pi ] && _sync_plumbing

  # 2. Update installed binaries first so dependent config can use the actual
  #    component outcome from this pass.
  #    --dry-run. Only --boot throttles (it's the only path that runs
  #    unattended on every container start); both share one stamp.
  if [ "$mode" != dry-run ]; then
    if [ "$mode" = boot ] && _sync_binaries_fresh; then :; else
      if [ "${AICODINGSETUP_SKIP_NETWORK:-}" != 1 ] \
          && command -v aicoding_update_installed_components >/dev/null 2>&1; then
        if ! aicoding_update_installed_components; then
          overall_rc=1
        elif [ "${AICODING_UPDATE_DEFERRED:-0}" -eq 1 ]; then
          _SYNC_PASS_DEFERRED=1
        fi
      fi
    fi
  fi
  # 3. Reconcile config after tool outcomes. Unrelated compatible config still
  #    advances when one component is blocked.
  if [ "$profile" != minimal-pi ]; then
    _sync_reconcile "$mode" || overall_rc=1
  fi

  # 4. Reconcile machine-state integrations, then stamp only when verified.
  if [ "$mode" != dry-run ] && [ "$profile" != minimal-pi ]; then
    if _sync_provision "$mode"; then
      _sync_binaries_stamp
    else
      overall_rc=1
    fi
  elif [ "$mode" != dry-run ] && [ "$overall_rc" -eq 0 ]; then
    _sync_binaries_stamp
  fi

  # 5. Additive system provisioning. Never stops processes; see
  #    lib/provision-scheduled.sh.
  if [ "$mode" != dry-run ] && _sync_system_provision_allowed; then
    local system_rc=0
    # A tmux build can take minutes; other containers must be able to update
    # shared config meanwhile.
    declare -F aicoding_shared_locks_release >/dev/null 2>&1 && aicoding_shared_locks_release
    _sync_system_provision || system_rc=$?
    case "$system_rc" in
      0) ;;
      3) _SYNC_PASS_DEFERRED=1 ;;
      *) overall_rc=1 ;;
    esac
  fi
  if [ "$mode" = boot ] && command -v aicoding_result_record >/dev/null 2>&1 && [ -n "$selected" ]; then
    local active
    active=$(_sync_blueprint_version "$AICODING_BLUEPRINT_CLONE" || true)
    if [ "$active" = "$selected" ]; then
      aicoding_result_record aicoding current "$selected" applied "$selected" || overall_rc=1
    else
      aicoding_result_record aicoding failed "$selected" activation_failed || true
      overall_rc=1
    fi
  fi
  if [ "$overall_rc" -eq 0 ] && [ "${_SYNC_PASS_DEFERRED:-0}" -eq 1 ]; then
    echo 'aicoding-sync: completed with deferrals'
  fi
  declare -F aicoding_ui_summary >/dev/null && aicoding_ui_summary "$overall_rc"
  return "$overall_rc"
}
