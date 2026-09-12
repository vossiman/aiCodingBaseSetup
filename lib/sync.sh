# lib/sync.sh — the one routine that brings THIS container current.
# Steps: (1) auth plumbing [always], (2) blueprint config reconcile,
# (3) binary refresh [throttled]. Modes: --first (provision), --boot
# (non-interactive, throttled), default (interactive). Independent components
# continue after a failure; the aggregate status remains nonzero.
# Sourced (no shebang / set -e); matches the lib/*.sh style.

: "${AICODING_BLUEPRINT_CLONE:=${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
: "${AICODING_BLUEPRINT_REMOTE:=https://github.com/vossiman/aiCodingBaseSetup}"
: "${AICODING_BLUEPRINT_LOCAL:=0}"
: "${AICODING_UPDATE_TTL:=21600}"
: "${AICODING_STATE_DIR:=$HOME/.local/state/aicoding}"
: "${AICODING_MANIFEST:=$HOME/.local/state/aicoding/manifest.json}"
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
  if [ -z "$p" ] && command -v jq >/dev/null 2>&1 \
      && [ -f "$AICODING_STATE_DIR/component-selection.json" ]; then
    p=$(jq -r '.profile // empty' "$AICODING_STATE_DIR/component-selection.json" 2>/dev/null) || p=
  fi
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
  case "$p" in host|container|minimal-pi) ;; *) p=container ;; esac
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

_sync_validate_blueprint_release() {
  local root=$1 sha=$2 file
  [ "$(cat "$root/.aicoding-version" 2>/dev/null)" = "$sha" ] || return 1
  [ "$(cat "$root/.aicoding-bootstrap-version" 2>/dev/null)" = 1 ] || return 1
  for file in bin/aicoding-sync lib/sync.sh lib/blueprint-deploy.sh lib/update-results.sh lib/update-components.sh; do
    [ -f "$root/$file" ] && bash -n "$root/$file" || return 1
  done
  [ -x "$root/bin/aicoding-sync" ]
}

# Preserve only the historical source bytes needed to prove that an owned
# generated file came from this repository. Selected releases stay Gitless,
# while provenance checks can still render an old version for the current
# HOME/profile before deciding an unattended overwrite is safe.
_sync_capture_generated_provenance() {
  local root=$1
  [ -d "$root/.git" ] || return 1
  (
    export AICODING_BLUEPRINT_CLONE="$root"
    . "$root/lib/blueprint-deploy.sh" || exit 1
    local provenance="$root/.aicoding-generated-provenance"
    local profile dest mode source commit count
    declare -A captured=()
    mkdir -p "$provenance" || exit 1
    for profile in container host; do
      while IFS='|' read -r dest mode source; do
        [ -n "$source" ] && _is_owned_overwrite "$dest" || continue
        [ -z "${captured[$source]:-}" ] || continue
        case "$source" in /*|*..*) exit 1 ;; esac
        captured[$source]=1
        mkdir -p "$provenance/$source" || exit 1
        count=0
        while IFS= read -r commit; do
          [ -n "$commit" ] || continue
          git -C "$root" show "$commit:$source" > "$provenance/$source/$commit" 2>/dev/null \
            || { rm -f "$provenance/$source/$commit"; exit 1; }
          count=$((count + 1))
        done < <(git -C "$root" log --format=%H --all -- "$source" 2>/dev/null)
        [ "$count" -gt 0 ] || exit 1
      done < <(AICODING_PROFILE="$profile" managed_inventory_overwrite)
    done
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
  aicoding_activate_version aicoding "$sha" || return 1
  printf '%s\n' "$final"
}

_sync_has_smart_errors() {
  local dest
  for dest in "${!BUCKETS[@]}"; do
    [[ ${BUCKETS[$dest]} == smart_error ]] && return 0
    if [[ -n "${SMART_APPLY_RESULT[$dest]:-}" ]] \
       && [[ $(printf '%s' "${SMART_APPLY_RESULT[$dest]}" | jq -r '.error != null') == true ]]; then
      return 0
    fi
  done
  return 1
}

# Value-free smart preview: only paths, operation names, and fixed diagnostic
# codes are public. Rendered/local TOML and receipt fingerprints stay private.
_sync_print_smart_details() {
  local dest plan code item path operation
  while IFS= read -r dest; do
    [[ -n "$dest" ]] || continue
    plan=${SMART_PLAN[$dest]:-}
    [[ -n "$plan" ]] || continue
    code=$(codex_smart_error_code "$plan")
    if [[ -n "$code" ]]; then
      printf '  ERROR: Codex config merge failed for %s (%s)\n' "$dest" "$code" >&2
      continue
    fi
    while IFS= read -r item; do
      [[ -n "$item" ]] || continue
      path=$(printf '%s' "$item" | codex_smart_path_text)
      operation=$(printf '%s' "$item" | jq -r '.operation')
      printf '      safe %s: %s :: %s\n' "$operation" "$dest" "$path"
    done < <(printf '%s' "$plan" | jq -c '.changes[]')
    while IFS= read -r item; do
      [[ -n "$item" ]] || continue
      path=$(printf '%s' "$item" | codex_smart_path_text)
      printf '      conflict (kept local): %s :: %s\n' "$dest" "$path"
    done < <(printf '%s' "$plan" | jq -c '.conflicts[]')
    while IFS= read -r item; do
      [[ -n "$item" ]] || continue
      path=$(printf '%s' "$item" | codex_smart_path_text)
      printf '      profile adoption notice (kept local): %s :: %s\n' "$dest" "$path"
    done < <(printf '%s' "$plan" | jq -c '.adoption_notices[]')
  done < <(printf '%s\n' "${!SMART_PLAN[@]}" | sort)
}

# Collect optional path-level conflict/adoption decisions after the existing
# overall apply confirmation. Empty input or EOF preserves local without
# acknowledging the incoming value; an explicit local choice acknowledges it.
_sync_collect_smart_decisions() {
  local dest plan item path_json path kind answer decisions
  for dest in "${!SMART_PLAN[@]}"; do
    plan=${SMART_PLAN[$dest]}
    decisions='[]'
    # Keep the plan stream on fd 3 so the nested prompt still reads the
    # caller's stdin. Redirecting the whole loop's stdin to jq would consume
    # the next JSON item (or EOF) as the user's answer.
    while IFS= read -r item <&3; do
      [[ -n "$item" ]] || continue
      path_json=$(printf '%s' "$item" | jq -c '.path')
      path=$(printf '%s' "$item" | codex_smart_path_text)
      kind=$(printf '%s' "$item" | jq -r '.kind')
      if [[ "$kind" == adoption ]]; then
        printf 'Codex profile adoption at %s :: %s — [l]ocal/[b]lueprint/[Enter skips]: ' "$dest" "$path"
      else
        printf 'Codex conflict at %s :: %s — [l]ocal/[b]lueprint/[Enter skips]: ' "$dest" "$path"
      fi
      if ! read -r answer; then
        [ -t 0 ] || echo
        break
      fi
      [ -t 0 ] || echo
      case "$answer" in
        l|L|local)
          decisions=$(printf '%s' "$decisions" \
            | jq --argjson path "$path_json" '. + [{path:$path,choice:"local"}]')
          ;;
        b|B|blueprint)
          decisions=$(printf '%s' "$decisions" \
            | jq --argjson path "$path_json" '. + [{path:$path,choice:"blueprint"}]')
          ;;
        *) : ;;
      esac
    done 3< <(printf '%s' "$plan" | jq -c \
      '(.conflicts[] | . + {kind:"conflict"}), (.adoption_notices[] | . + {kind:"adoption"})')
    SMART_DECISIONS[$dest]=$decisions
  done
}

# Config reconcile: classify managed files, preview/prompt/apply per mode,
# stamp the manifest. Ported from the old aicoding-update CLI and folded in.
# $1 = mode: boot | first | dry-run | yes | interactive.
# Returns nonzero for manual no-manifest and smart-merge errors. Boot/first
# remain fail-open so unattended maintenance continues.
_sync_reconcile() {
  local mode=$1
  declare -gA _SYNC_DEFERRED_PROVISION_COMPONENTS=()
  # Clear prior classifications before any early return. The caller uses this
  # snapshot to distinguish actual smart errors from ordinary reconcile
  # failures that must still abort before maintenance.
  declare -gA BUCKETS FILE_MODE FILE_SOURCE SMART_PLAN SMART_APPLY_RESULT SMART_DECISIONS
  BUCKETS=()
  FILE_MODE=()
  FILE_SOURCE=()
  SMART_PLAN=()
  SMART_APPLY_RESULT=()
  SMART_DECISIONS=()
  if _sync_color_on; then _SYNC_COLOR=1; else _SYNC_COLOR=0; fi

  # _sync_refresh_and_reexec already fetched in this process; a second fetch
  # would only cost network time.
  if [[ "${_SYNC_REFRESHED:-0}" != 1 ]]; then
    refresh_blueprint || return $?
  fi

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

  # Destination bytes and hashes are part of the write transaction. Acquire
  # physical shared-root locks before classification so no sibling can change
  # them between the decision and apply phases.
  if [ "$mode" != dry-run ]; then
    aicoding_shared_locks_acquire_managed_roots || {
      echo "aicoding-sync: shared configuration writer is busy" >&2
      return 1
    }
  fi

  local OLD_COMMIT NEW_COMMIT
  OLD_COMMIT=$(jq -r '.blueprint_commit // "unknown"' "$AICODING_MANIFEST")
  # Full SHA, matching install.sh. aicoding-status compares the first 12 chars
  # of this against `git ls-remote`'s full SHA; a 7-char `--short` would never
  # match, leaving the ⬆ badge stuck "behind" even right after a sync.
  NEW_COMMIT=$(_sync_blueprint_version "$AICODING_BLUEPRINT_CLONE" || echo unknown)
  echo "Blueprint: ${OLD_COMMIT:0:7} -> ${NEW_COMMIT:0:7}"

  declare -gA BUCKETS FILE_MODE FILE_SOURCE
  export AICODING_BLUEPRINT_CLONE
  classify_managed_files "$mode"

  # Re-bucket owned overwrites: a drifted-but-blueprint-owned file is ours to
  # update without a "needs your decision" prompt.
  local d
  for d in "${!BUCKETS[@]}"; do
    if [[ "${BUCKETS[$d]}" == drifted_and_updating ]] && _is_owned_overwrite "$d" \
        && owned_file_has_generated_provenance "$d" "${FILE_SOURCE[$d]}"; then
      BUCKETS[$d]=will_update_owned
    fi
  done

  local blocked_count=0 reason component
  local -A blocked_reasons=()
  if [ "$mode" != dry-run ] && command -v aicoding_config_is_compatible >/dev/null 2>&1; then
    export AICODING_REQUIRE_UPDATE_RECEIPT=1
    # The compatibility helper resolves each destination and treats confirmed
    # local roots as a no-op. Always request shared authorization here so a
    # manual/first pass cannot bypass fleet evidence for an actual shared root.
    export AICODING_REQUIRE_SHARED_COMPATIBILITY=1
    for d in "${!BUCKETS[@]}"; do
      case "${BUCKETS[$d]}" in
        restore|new_file|will_update|will_update_owned|drifted_but_aligned|merge|smart_update|smart_conflict) ;;
        smart_error)
          _SYNC_DEFERRED_PROVISION_COMPONENTS[codex]=1
          continue
          ;;
        *) continue ;;
      esac
      if ! reason=$(aicoding_config_is_compatible "$d"); then
        BUCKETS[$d]=blocked
        blocked_count=$((blocked_count + 1))
        component=$(_aicoding_config_component "$d")
        blocked_reasons[$component]=$reason
        case "$component" in
          config-*) _SYNC_DEFERRED_PROVISION_COMPONENTS[${component#config-}]=1 ;;
        esac
      fi
    done
    unset AICODING_REQUIRE_UPDATE_RECEIPT
    unset AICODING_REQUIRE_SHARED_COMPATIBILITY
    if command -v aicoding_result_record >/dev/null 2>&1; then
      for component in "${!blocked_reasons[@]}"; do
        aicoding_result_record "$component" blocked "$NEW_COMMIT" "${blocked_reasons[$component]}" || true
      done
    fi
  fi

  declare -A COUNT
  local b
  for b in up_to_date will_update will_update_owned drifted_but_aligned \
           drifted_and_updating restore new_file new_file_existing to_remove merge \
           smart_update smart_conflict smart_error smart_retired blocked; do
    COUNT[$b]=0
  done
  for d in "${!BUCKETS[@]}"; do
    b=${BUCKETS[$d]}
    COUNT[$b]=$(( ${COUNT[$b]:-0} + 1 ))
  done
  local conflict_count=0
  if [ "$mode" = boot ]; then
    conflict_count=$(( COUNT[drifted_and_updating] + COUNT[new_file_existing] + COUNT[to_remove] ))
  fi

  if [[ "$mode" == dry-run ]]; then
    for b in up_to_date will_update will_update_owned drifted_but_aligned \
             drifted_and_updating restore new_file new_file_existing to_remove merge \
             smart_update smart_conflict smart_error smart_retired blocked; do
      echo "  ${COUNT[$b]} $b"
    done
    _sync_print_smart_details
    _sync_has_smart_errors && return 1
    return 0
  fi

  # Interactive preview (default mode only): counts + inline diffs.
  if [[ "$mode" == interactive ]]; then
    _sync_print_summary
    _sync_print_smart_details
  else
    _sync_print_smart_details
  fi

  # Nothing actionable across every apply bucket?
  # drifted_but_aligned (on-disk already matches blueprint; only a stale manifest
  # hash) and up_to_date are NOT actionable, so they're excluded here — otherwise
  # a pure manifest-hash refresh would wrongly trigger an Apply? prompt.
  if (( COUNT[will_update] + COUNT[will_update_owned] + COUNT[drifted_and_updating] \
        + COUNT[restore] + COUNT[new_file] + COUNT[new_file_existing] \
        + COUNT[to_remove] + COUNT[merge] + COUNT[smart_update] \
        + COUNT[smart_conflict] + COUNT[smart_retired] == 0 )); then
    if (( COUNT[smart_error] > 0 )); then
      echo "No managed config changes applied."
    else
      echo "Nothing to do."
    fi
    # Still advance the blueprint_commit stamp: the blueprint may have moved
    # without touching any managed file (lib/tests/bin-only changes). Leaving
    # the old commit recorded keeps aicoding-status on "behind" forever.
    if _sync_has_smart_errors; then
      _SYNC_DEFERRED_PROVISION_COMPONENTS[codex]=1
      _SYNC_PASS_DEFERRED=1
      command -v aicoding_result_record >/dev/null 2>&1 \
        && aicoding_result_record config failed "$NEW_COMMIT" managed_config_apply_failed || true
      if [[ "$mode" != boot && "$mode" != first ]]; then return 1; fi
      return 0
    elif [ "$blocked_count" -gt 0 ]; then
      echo "$blocked_count managed config update(s) blocked by tool compatibility"
      command -v aicoding_result_record >/dev/null 2>&1 \
        && aicoding_result_record config blocked "$NEW_COMMIT" partial_config_blocked || true
      _SYNC_PASS_DEFERRED=1
      return 0
    elif [ "$OLD_COMMIT" != "$NEW_COMMIT" ] && [ "$NEW_COMMIT" != unknown ]; then
      manifest_stage_begin || return $?
      local origin
      origin=$(blueprint_origin "$AICODING_BLUEPRINT_CLONE")
      # Stamps and drops the now-stale aicoding-status verdict together.
      manifest_stage_set_blueprint "$NEW_COMMIT" "$origin" || return $?
      if ! manifest_stage_commit; then
        command -v aicoding_result_record >/dev/null 2>&1 \
          && aicoding_result_record config failed "$NEW_COMMIT" manifest_write_failed || true
        return 1
      fi
    fi
    command -v aicoding_result_record >/dev/null 2>&1 && [ "$NEW_COMMIT" != unknown ] \
      && aicoding_result_record config current "$NEW_COMMIT" applied "$NEW_COMMIT" || true
    return 0
  fi

  if [[ "$mode" == interactive ]]; then
    echo 'This choice only controls config changes; tool updates and provisioning continue either way.'
    printf 'Apply managed config changes? [y/N] '
    local answer
    read -r answer
    [ -t 0 ] || echo
    case "$answer" in
      y|Y|yes) ;;
      *)
        echo "Skipped managed config changes. Continuing the rest of sync."
        if _sync_has_smart_errors; then return 1; fi
        return 0
        ;;
    esac
    _sync_collect_smart_decisions
  fi

  manifest_stage_begin || return $?

  local buckets
  if [[ "$mode" == boot ]]; then
    # Conservative on boot: preserve user edits (no drifted_and_updating, no
    # new_file_existing, no to_remove) since boot runs unattended on every
    # container start — a personal file at a newly managed path must never be
    # replaced without a human in the loop.
    buckets="restore new_file will_update will_update_owned drifted_but_aligned merge smart_update smart_conflict smart_retired"
    if [ "$conflict_count" -gt 0 ]; then
      for d in "${!BUCKETS[@]}"; do
        case "${BUCKETS[$d]}" in
          drifted_and_updating|new_file_existing|to_remove)
            component=$(_aicoding_config_component "$d")
            case "$component" in
              config-*) _SYNC_DEFERRED_PROVISION_COMPONENTS[${component#config-}]=1 ;;
            esac
            report_managed_conflict "$d" "${BUCKETS[$d]}" ;;
        esac
      done
    fi
  else
    # interactive / yes / first: full reconcile.
    buckets="restore new_file new_file_existing will_update will_update_owned drifted_but_aligned drifted_and_updating merge to_remove smart_update smart_conflict smart_retired"
  fi
  # The receipt's diffs must be taken before apply: afterwards dest == source.
  local -A DIFFS=()
  local bucket
  if [[ "$mode" == interactive || "$mode" == yes ]]; then
    for d in "${!BUCKETS[@]}"; do
      bucket=${BUCKETS[$d]}
      case " $buckets " in *" $bucket "*) ;; *) continue ;; esac
      DIFFS[$d]=$(_sync_diff_for_bucket "$d" "$bucket")
    done
  fi

  local apply_rc=0 smart_error_count=0
  apply_managed_buckets "$buckets" "$mode" || apply_rc=1
  if [ "$apply_rc" -ne 0 ]; then
    for d in "${!APPLY_FAILURES[@]}"; do
      component=$(_aicoding_config_component "$d")
      case "$component" in
        config-*) _SYNC_DEFERRED_PROVISION_COMPONENTS[${component#config-}]=1 ;;
      esac
    done
  fi

  # The smart adapter reports value-safe failures in JSON so set -e callers
  # can continue unrelated work. Fold those results back into the shared
  # apply/deferred accounting before provisioning or result recording.
  for d in "${!SMART_PLAN[@]}"; do
    local smart_result smart_code
    case "${BUCKETS[$d]:-}" in
      smart_update|smart_conflict|smart_error) ;;
      *) continue ;;
    esac
    smart_result=${SMART_APPLY_RESULT[$d]:-${SMART_PLAN[$d]}}
    smart_code=$(codex_smart_error_code "$smart_result")
    if [[ -n "$smart_code" ]]; then
      APPLY_FAILURES[$d]=1
      smart_error_count=$((smart_error_count + 1))
      _SYNC_DEFERRED_PROVISION_COMPONENTS[codex]=1
    elif (( $(printf '%s' "$smart_result" | jq '.conflicts | length') > 0 )); then
      conflict_count=$((conflict_count + 1))
      _SYNC_DEFERRED_PROVISION_COMPONENTS[codex]=1
    fi
  done

  # Per-bucket announcements (interactive output, not deploy behavior). Only
  # report buckets that were actually in the applied set for this mode. Boot
  # and first-run output goes to logs nobody reads, so those stay one-liners.
  while IFS= read -r d; do
    bucket=${BUCKETS[$d]}
    case " $buckets " in *" $bucket "*) ;; *) continue ;; esac
    [[ "${FILE_MODE[$d]:-}" != toml_merge ]] || continue
    case "$bucket" in
      restore|new_file|new_file_existing|will_update|will_update_owned|drifted_and_updating|merge|to_remove) ;;
      *) continue ;;
    esac
    if [[ "$mode" == interactive || "$mode" == yes ]]; then
      _sync_change_report "$(_sync_bucket_verb "$bucket")" "$d" "${DIFFS[$d]:-}"
    else
      echo "      $(_sync_bucket_verb "$bucket"): $d"
    fi
  done < <(printf '%s\n' "${!BUCKETS[@]}" | sort)

  # Smart application results are intentionally not described as a complete
  # merge when conflicts remain, and never reuse the raw-diff reporter.
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    bucket=${BUCKETS[$d]}
    case " $buckets " in *" $bucket "*) ;; *) continue ;; esac
    if [[ "$bucket" == smart_retired ]]; then
      echo "      retired Codex management (config preserved): $d"
      continue
    fi
    [[ -n "${SMART_APPLY_RESULT[$d]:-}" ]] || continue
    local smart_result smart_code smart_config_changed smart_state_changed
    smart_result=${SMART_APPLY_RESULT[$d]}
    smart_code=$(codex_smart_error_code "$smart_result")
    smart_config_changed=$(printf '%s' "$smart_result" | jq -r '.config_changed')
    smart_state_changed=$(printf '%s' "$smart_result" | jq -r '.state_changed')
    if [[ -n "$smart_code" ]]; then
      printf '  ERROR: Codex config merge failed for %s (%s)\n' "$d" "$smart_code" >&2
    elif (( $(printf '%s' "$smart_result" | jq '.conflicts | length') > 0 )); then
      if [[ "$smart_config_changed" == true ]]; then
        echo "      applied safe Codex updates; conflicting settings kept local: $d"
      elif [[ "$smart_state_changed" == true ]]; then
        echo "      updated Codex merge state; conflicting settings kept local: $d"
      else
        echo "      conflicting Codex settings kept local; no updates applied: $d"
      fi
    elif [[ "$smart_config_changed" == true ]]; then
      echo "      merged Codex settings: $d"
    elif [[ "$smart_state_changed" == true ]]; then
      echo "      updated Codex merge state (config bytes preserved): $d"
    fi
  done < <(printf '%s\n' "${!BUCKETS[@]}" | sort)

  local origin
  origin=$(blueprint_origin "$AICODING_BLUEPRINT_CLONE")
  # Stamps the new commit and drops aicoding-status's cached `latest`, so the
  # next tick re-fetches instead of comparing against a pre-sync remote SHA
  # (see the helper's comment for why that drop still matters).
  if [ "$blocked_count" -eq 0 ] && [ "$conflict_count" -eq 0 ] \
      && [ "$smart_error_count" -eq 0 ] && [ "$apply_rc" -eq 0 ]; then
    if ! manifest_stage_set_blueprint "$NEW_COMMIT" "$origin"; then
      apply_rc=1
      _SYNC_DEFERRED_PROVISION_COMPONENTS[claude]=1
      _SYNC_DEFERRED_PROVISION_COMPONENTS[codex]=1
    fi
  fi

  local commit_rc=0
  manifest_stage_commit || commit_rc=1
  if [ "$commit_rc" -ne 0 ]; then
    _SYNC_DEFERRED_PROVISION_COMPONENTS[claude]=1
    _SYNC_DEFERRED_PROVISION_COMPONENTS[codex]=1
  fi
  if command -v aicoding_result_record >/dev/null 2>&1; then
    if [ "$commit_rc" -ne 0 ]; then
      aicoding_result_record config failed "$NEW_COMMIT" manifest_write_failed || true
    elif [ "$apply_rc" -ne 0 ] || [ "$smart_error_count" -gt 0 ]; then
      aicoding_result_record config failed "$NEW_COMMIT" managed_config_apply_failed || true
    elif [ "$conflict_count" -gt 0 ]; then
      aicoding_result_record config conflict "$NEW_COMMIT" managed_config_conflict || true
    elif [ "$blocked_count" -eq 0 ] && [ "$NEW_COMMIT" != unknown ]; then
      aicoding_result_record config current "$NEW_COMMIT" applied "$NEW_COMMIT" || true
    else
      aicoding_result_record config blocked "$NEW_COMMIT" partial_config_blocked || true
    fi
  fi
  if [ "$blocked_count" -gt 0 ] || [ "$conflict_count" -gt 0 ] \
      || [ "$smart_error_count" -gt 0 ]; then
    _SYNC_PASS_DEFERRED=1
  fi
  if [ "$smart_error_count" -gt 0 ] && [[ "$mode" != boot && "$mode" != first ]]; then
    return 1
  fi
  [ "$apply_rc" -eq 0 ] && [ "$commit_rc" -eq 0 ]
}

# --- Change report ----------------------------------------------------------
# One block per file: a double ruler, "verb: path" with the verb in the
# action's colour, the ruler again, then the diff indented. Colour only when
# stdout is a terminal (FORCE_COLOR=1 overrides, NO_COLOR wins), so boot logs
# and captured output stay plain.
# _sync_reconcile pins the answer in _SYNC_COLOR up front: the diff bodies are
# built inside command substitution, where stdout is a pipe and `-t 1` would
# say no even on a terminal.
_sync_color_on() {
  case "${_SYNC_COLOR:-}" in 1) return 0 ;; 0) return 1 ;; esac
  [ -z "${NO_COLOR:-}" ] || return 1
  [ -n "${FORCE_COLOR:-}" ] || [ -t 1 ]
}

_sync_verb_color() {
  case "$1" in
    new*|restored*|merged*) printf '32' ;;
    removed*)               printf '31' ;;
    *)                      printf '33' ;;
  esac
}

# _sync_change_report <verb> <dest> <diff-body>
_sync_change_report() {
  local verb=$1 dest=$2 body=$3 rule i=''
  for ((i=0; i<72; i++)); do rule+='═'; done
  if _sync_color_on; then
    printf '\e[36m%s\e[0m\n' "$rule"
    printf ' \e[1;%sm%s\e[0m: %s\n' "$(_sync_verb_color "$verb")" "$verb" "$dest"
    printf '\e[36m%s\e[0m\n' "$rule"
  else
    printf '%s\n %s: %s\n%s\n' "$rule" "$verb" "$dest" "$rule"
  fi
  [ -n "$body" ] && printf '%s\n' "$body" | sed 's/^/    /'
  echo
}

# _sync_diff_body <dest> <src> — hunks of dest -> src, src rendered exactly as
# deploy would write it (so {{HOME}} and friends never show as noise), then
# every secrets-file value scrubbed: a config file's on-disk copy carries the
# substituted credentials, and this output lands in transcripts.
# Verbatim (overwrite_raw) sources deploy unrendered and are compared unrendered.
_sync_diff_body() {
  local dest=$1 src=$2 file_mode=${3:-overwrite} rendered color=never rules secrets
  [ -f "$dest" ] && [ -f "$src" ] || return 0
  rendered=$(mktemp)
  if [ "$file_mode" != overwrite_raw ] && command -v _render_managed_source >/dev/null 2>&1; then
    _render_managed_source "$src" "$dest" "$rendered" 2>/dev/null || cp "$src" "$rendered"
  else
    cp "$src" "$rendered"
  fi
  _sync_color_on && color=always
  rules=''
  if [ -f "$AICODING_BLUEPRINT_CLONE/lib/redact-literal.sh" ]; then
    # shellcheck source=redact-literal.sh
    . "$AICODING_BLUEPRINT_CLONE/lib/redact-literal.sh"
    secrets="${AICODING_SECRETS_FILE:-$HOME/.aicodingsetup/.secrets.env}"
    if ! rules=$(redact_literal_rules transcript "$secrets"); then
      # Fail closed: a secrets file that cannot be turned into rules means
      # the diff cannot be scrubbed, so it is not shown at all.
      rm -f "$rendered"
      echo "(diff withheld: secrets file present but unreadable, so it cannot be scrubbed)"
      return 0
    fi
  fi
  git -c color.diff.new=green -c color.diff.old=red -c color.diff.frag=cyan \
    diff --no-index --color="$color" -- "$dest" "$rendered" 2>/dev/null \
    | tail -n +5 | sed -E -f <(printf '%s' "$rules")
  rm -f "$rendered"
  return 0
}

# _sync_diff_for_bucket <dest> <bucket> — the diff a bucket's report shows;
# empty for buckets with nothing to compare (new, restore, remove) and for
# marker blocks and merges, whose on-disk shape is not the source's.
_sync_diff_for_bucket() {
  local dest=$1 bucket=$2
  case "$bucket" in
    will_update|will_update_owned|drifted_and_updating|new_file_existing) ;;
    *) return 0 ;;
  esac
  [ "${FILE_MODE[$dest]:-overwrite}" != marker_block ] || return 0
  [ "${FILE_MODE[$dest]:-overwrite}" != toml_merge ] || return 0
  _sync_diff_body "$dest" "$AICODING_BLUEPRINT_CLONE/${FILE_SOURCE[$dest]}" "${FILE_MODE[$dest]:-overwrite}"
}

_sync_bucket_verb() {
  case "$1" in
    restore)              printf 'restored' ;;
    new_file)             printf 'new' ;;
    new_file_existing)    printf 'new (existing file backed up)' ;;
    will_update)          printf 'updated' ;;
    will_update_owned)    printf 'updated' ;;
    drifted_and_updating) printf 'updated (with backup)' ;;
    merge)                printf 'merged' ;;
    to_remove)            printf 'removed' ;;
  esac
}

# Interactive summary: tally + a change report per actionable file.
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

  if (( COUNT[smart_update] > 0 )); then
    echo "  ${COUNT[smart_update]} Codex smart update(s) (safe setting/receipt changes):"
    for dest in "${!BUCKETS[@]}"; do
      [[ ${BUCKETS[$dest]} == smart_update ]] && echo "      $dest"
    done
  fi

  if (( COUNT[smart_conflict] > 0 )); then
    echo "  ${COUNT[smart_conflict]} Codex config(s) with path-level choices (local preserved by default):"
    for dest in "${!BUCKETS[@]}"; do
      [[ ${BUCKETS[$dest]} == smart_conflict ]] && echo "      $dest"
    done
  fi

  if (( COUNT[smart_error] > 0 )); then
    echo "  ${COUNT[smart_error]} Codex smart merge error(s) (config preserved):"
    for dest in "${!BUCKETS[@]}"; do
      [[ ${BUCKETS[$dest]} == smart_error ]] && echo "      $dest"
    done
  fi

  if (( COUNT[smart_retired] > 0 )); then
    echo "  ${COUNT[smart_retired]} retired Codex target(s) (config and receipt preserved):"
    for dest in "${!BUCKETS[@]}"; do
      [[ ${BUCKETS[$dest]} == smart_retired ]] && echo "      $dest"
    done
  fi

  echo
  # One report per file that has something to read before "Apply?". Files
  # without a diff (new, restored, removed, merged) are covered by the tally.
  local body verb
  while IFS= read -r dest; do
    body=$(_sync_diff_for_bucket "$dest" "${BUCKETS[$dest]}")
    [ -n "$body" ] || continue
    case "${BUCKETS[$dest]}" in
      drifted_and_updating) verb="you edited, blueprint changed" ;;
      new_file_existing)    verb="will replace (backup kept)" ;;
      *)                    verb="will update" ;;
    esac
    _sync_change_report "$verb" "$dest" "$body"
  done < <(printf '%s\n' "${!BUCKETS[@]}" | sort)
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
  # Acquire independently as well: boot with no manifest or a busy/failed
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
    install_dvw_probe_symlink || rc=1
    # Same self-heal for the other agent-facing CLIs install.sh symlinks:
    # a ~/.local/bin that lost them, or predates one, otherwise only
    # recovers on a full aicoding-install. Container-only entries (clip
    # shims, ssh-agent watcher) stay out: they are profile-gated in
    # install.sh and this path runs on hosts too.
    install_agent_notify_symlink || rc=1
    install_update_status_symlink || rc=1
    install_kanban_post_symlink || rc=1
    install_measure_remote_symlink || rc=1
    install_dokploy_api_symlink || rc=1
    install_bugsink_api_symlink || rc=1
    install_kuma_admin_symlink || rc=1
    install_redact_transcript_symlink || rc=1
    install_redact_sessions_symlinks || rc=1
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
  for name in dvw-probe agent-notify aicoding-status kanban-post measure-remote \
              dokploy-api bugsink-api kuma-admin redact-transcript redact-sessions codex-turn-done; do
    source="$(dirname "$blueprint_lib")/bin/$name"
    dest="$HOME/.local/bin/$name"
    [ -f "$source" ] || continue
    _sync_provision_artifact_matches "$name" "$source" "$dest" || rc=1
  done
  if command -v _aicoding_command_is_linux >/dev/null 2>&1 \
      && _aicoding_command_is_linux codex 2>/dev/null; then
    local root="$(dirname "$blueprint_lib")" req_src req rendered hook
    req_src="$root/configs/codex/requirements.toml"
    req="${CODEX_MANAGED_DIR:-/etc/codex}/requirements.toml"
    if [ ! -f "$req_src" ]; then
      rc=1
    else
      rendered=$(sed "s|{{MANAGED_DIR}}|${CODEX_MANAGED_DIR:-/etc/codex}|g" "$req_src")
      [ -f "$req" ] && [ "$(cat "$req" 2>/dev/null)" = "$rendered" ] || rc=1
      for hook in bw-deny-files.sh redact-sessions-hook.sh redact-sessions-pending.sh \
                  memory-hint.sh check-archived-docs.sh agent-working.sh; do
        cmp -s "$root/configs/claude/hooks/$hook" "${CODEX_MANAGED_DIR:-/etc/codex}/hooks/$hook" || rc=1
      done
    fi
  fi

  target=$(_sync_blueprint_version "$(dirname "$blueprint_lib")" || echo unknown)
  [ "$target" != unknown ] || rc=1
  if [ "$rc" -eq 0 ] && [ "$provision_deferred" -eq 0 ]; then
    command -v manifest_stamp_provision >/dev/null 2>&1 && [ "$target" != unknown ] \
      && manifest_stamp_provision "$target"
    command -v aicoding_result_record >/dev/null 2>&1 \
      && aicoding_result_record provision current "$target" verified "$target" || true
  elif [ "$rc" -ne 0 ]; then
    command -v aicoding_result_record >/dev/null 2>&1 \
      && aicoding_result_record provision failed "$target" partial_provision_failure || true
  else
    _SYNC_PASS_DEFERRED=1
    command -v aicoding_result_record >/dev/null 2>&1 \
      && aicoding_result_record provision blocked "$target" preparation_deferred || true
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

# Replace this process only with the exact CI-qualified immutable release
# selected for the pass. A local --blueprint source is used verbatim. There is
# deliberately no legacy tracking-clone fetch/reset fallback.
_sync_refresh_and_reexec() {
  if [[ "$AICODING_BLUEPRINT_LOCAL" == 1 ]]; then refresh_blueprint; return $?; fi
  if [[ "${AICODING_SYNC_REEXECED:-0}" == 1 ]]; then _SYNC_REFRESHED=1; return 0; fi
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

  _sync_source_update_libraries "${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

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
  return "$overall_rc"
}
