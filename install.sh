#!/usr/bin/env bash
set -euo pipefail
set -E
_CURRENT_STEP="(startup)"
trap '_rc=$?; printf "INSTALL FAILED  step=%s  line=%s\n" "$_CURRENT_STEP" "$LINENO" >&2; exit "$_rc"' ERR

# ============================================================================
# AI Coding Base Setup — Installer/Updater
# Configures Claude Code and opencode with shared MCPs, skills, hooks, plugins
# Supports: Linux, WSL (bash only — run install.ps1 on Windows)
# ============================================================================

# Microsoft's devcontainer universal images ship `/etc/profile` sourcing
# `/usr/local/nvs/nvs.sh` (and `/etc/bash.bashrc` sourcing `nvm.sh`), which
# `export -f` multi-line `nvs`/`nvsudo`/`nvm` bash functions. Some layer in
# the devpod/docker-exec/su chain truncates multi-line BASH_FUNC env values
# to one line — known issue, see VSCode #3928 and vscode-remote-release
# #9457. Every child bash that inherits the truncated env then errors with
# `syntax error: unexpected end of file` on import.
#
# Failed-import env vars can't be removed from inside bash:
#   - `unset -f nvs` is a no-op because the function was never defined
#   - `unset 'BASH_FUNC_nvs%%'` silently fails because `%%` is not a valid
#     identifier, so bash refuses to unset it
# Only `env -u` at the process boundary actually strips them. Self-reexec.
if [[ "${_AICODINGSETUP_NVS_STRIPPED:-}" != 1 ]]; then
  exec env -u 'BASH_FUNC_nvs%%' -u 'BASH_FUNC_nvsudo%%' -u 'BASH_FUNC_nvm%%' \
    _AICODINGSETUP_NVS_STRIPPED=1 bash "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Shared deployment library — used by both install.sh and aicoding-sync.
. "$SCRIPT_DIR/lib/blueprint-deploy.sh"

# Managed file inventory + marker-block content live in lib/blueprint-deploy.sh
# (managed_inventory_overwrite, managed_inventory_merge, managed_bashrc_*).
# Cache the marker strings once; the body is re-emitted on each deploy.
BASHRC_BLOCK_START="$(managed_marker_block_start)"
BASHRC_BLOCK_END="$(managed_marker_block_end)"

CLAUDE_DIR="$HOME/.claude"
OPENCODE_DIR="$HOME/.config/opencode"
SECRETS_DIR="$HOME/.aicodingsetup"
SECRETS_FILE="$SECRETS_DIR/.secrets.env"

# deploy_all_managed_files — wraps every managed-file deployment in a single
# manifest staging session. Skill files are enumerated from MANAGED_SKILLS.
deploy_all_managed_files() {
  manifest_stage_begin

  local entry dest mode source
  while IFS='|' read -r dest mode source; do
    [[ -z "$dest" ]] && continue
    if [[ -f "$SCRIPT_DIR/$source" ]]; then
      deploy_overwrite_file_substituted "$SCRIPT_DIR/$source" "$dest" "$source"
      ok "deployed $dest"
    else
      warn "missing source in blueprint: $source — skipping $dest"
    fi
  done < <(managed_inventory_overwrite)

  while IFS='|' read -r dest mode source; do
    [[ -z "$dest" ]] && continue
    if [[ -f "$SCRIPT_DIR/$source" ]]; then
      mkdir -p "$(dirname "$dest")"
      [[ -f "$dest" ]] || echo '{}' > "$dest"
      deploy_merge_file_substituted "$SCRIPT_DIR/$source" "$dest" "$source"
      ok "merged $dest"
    fi
  done < <(managed_inventory_merge)

  # ~/.bashrc managed block.
  deploy_marker_block "$HOME/.bashrc" "$(managed_bashrc_block_body)" \
    "$BASHRC_BLOCK_START" "$BASHRC_BLOCK_END"
  ok "managed block written to ~/.bashrc"

  # Skills — dynamic enumeration.
  mkdir -p "$CLAUDE_DIR/skills"
  local skill_dir skill_name src_skill dest_dir dest_skill
  for skill_dir in "$SCRIPT_DIR/skills"/*/; do
    [[ ! -d "$skill_dir" ]] && continue
    skill_name=$(basename "$skill_dir")
    src_skill="$skill_dir/SKILL.md"
    dest_dir="$CLAUDE_DIR/skills/$skill_name"
    dest_skill="$dest_dir/SKILL.md"
    [[ ! -f "$src_skill" ]] && { warn "no SKILL.md in $skill_dir"; continue; }
    mkdir -p "$dest_dir"
    deploy_overwrite_file_substituted "$src_skill" "$dest_skill" "skills/$skill_name/SKILL.md"
    ok "skill $skill_name installed"
  done

  # Slash commands — dynamic enumeration, parallel to skills.
  mkdir -p "$CLAUDE_DIR/commands"
  local cmd_file cmd_name
  for cmd_file in "$SCRIPT_DIR/commands"/*.md; do
    [[ ! -f "$cmd_file" ]] && continue
    cmd_name=$(basename "$cmd_file")
    deploy_overwrite_file_substituted "$cmd_file" "$CLAUDE_DIR/commands/$cmd_name" "commands/$cmd_name"
    ok "command $cmd_name installed"
  done

  # Record blueprint origin/commit metadata at the top of the manifest.
  local commit origin
  commit=$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
  origin=$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || echo unknown)
  manifest_stage_set_top blueprint_commit "$commit"
  manifest_stage_set_top blueprint_origin "$origin"

  manifest_stage_commit
}

# Managed component lists (used for unmanaged component detection).
# MANAGED_MCPS / MANAGED_PLUGINS live in lib/provision.sh (sourced below,
# after the colored loggers are defined) — shared with aicoding-sync so both
# reconcile the same MCP/plugin set.
MANAGED_HOOKS=("custom-statusline.js" "bw-deny-files.sh" "check-archived-docs.sh")
MANAGED_SKILLS=("cloudflare-browser")

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()  { echo -e "${BLUE}INFO:${NC} $*"; }
ok()    { echo -e "${GREEN}  OK:${NC} $*"; }
warn()  { echo -e "${YELLOW}WARN:${NC} $*"; }
err()   { echo -e "${RED}ERROR:${NC} $*"; }
header(){
  _CURRENT_STEP="$*"
  echo -e "\n${GREEN}=== $* ===${NC}"
}

# MCP/plugin provisioning — shared with aicoding-sync. Sourced after the
# colored loggers so its plain-echo fallbacks don't kick in here.
. "$SCRIPT_DIR/lib/provision.sh"

# --- Environment Detection ---
detect_environment() {
  if [[ -f /.dockerenv ]] || [[ -f /run/.containerenv ]] \
     || [[ -n "${REMOTE_CONTAINERS:-}" ]] || [[ -n "${DEVCONTAINER:-}" ]] \
     || [[ -n "${CODESPACES:-}" ]]; then
    echo "container"
    return
  fi
  local kernel
  kernel="$(uname -r 2>/dev/null || echo "")"
  if [[ "$kernel" == *microsoft* || "$kernel" == *Microsoft* ]]; then
    echo "wsl"
  else
    echo "linux"
  fi
}

ENV_TYPE="$(detect_environment)"
info "Detected environment: $ENV_TYPE"

# --- Install helpers (used by auto-install in container mode) ---
SUDO=""
if [[ "$(id -u)" -ne 0 ]] && command -v sudo &>/dev/null; then
  SUDO="sudo"
fi

apt_install() {
  if ! command -v apt-get &>/dev/null; then
    err "apt-get not available — cannot auto-install: $*"
    return 1
  fi
  drop_broken_apt_sources
  # Tolerate a non-zero update exit — third-party repos that we don't manage
  # may still fail on stale GPG keys; we've cleaned the known offenders.
  $SUDO apt-get update -qq || warn "apt-get update had issues — continuing"
  # Use `env` after sudo so DEBIAN_FRONTEND survives sudo's env_reset and
  # debconf doesn't fall back to Dialog/Readline/Teletype frontends.
  $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

# Universal:2 ships an apt source for dl.yarnpkg.com with a stale GPG key
# (NO_PUBKEY 62D54FD4003F6525) that spams errors on every apt-get update.
# We don't use yarn from apt; drop the source the first time we hit it.
drop_broken_apt_sources() {
  local list
  list="$(grep -lrF 'dl.yarnpkg.com' /etc/apt/sources.list.d/ 2>/dev/null)" || true
  if [[ -n "$list" ]]; then
    info "Removing broken yarn apt source"
    $SUDO rm -f $list
  fi
}

# Universal:2 and :6 source /usr/local/nvs/nvs.sh from /etc/profile, which
# defines and `export -f`s multi-line nvs/nvsudo functions. Bash's env
# serialization truncates the bodies, so every child shell forked by a
# login shell errors with "syntax error: unexpected end of file" on import.
# Patch /etc/profile to unset those functions and their env vars at the end,
# so children inherit a clean env. Idempotent.
ensure_login_shells_clean() {
  local marker='# aiCodingBaseSetup: clear broken nvs/nvsudo exports'
  if [[ -w /etc/profile ]] || [[ -n "$SUDO" ]]; then
    if ! grep -qF "$marker" /etc/profile 2>/dev/null; then
      info "Patching /etc/profile to clear broken nvs/nvsudo exports"
      $SUDO tee -a /etc/profile >/dev/null <<EOF

$marker
unset -f nvs nvsudo 2>/dev/null
unset 'BASH_FUNC_nvs%%' 'BASH_FUNC_nvsudo%%' 2>/dev/null
EOF
    fi
  fi
}

ensure_node() {
  command -v npm &>/dev/null && return 0

  # Try common Node installer hooks (nvm, nvs) — non-interactive shells skip rc files
  [[ -f /usr/local/share/nvs/nvs.sh ]] && . /usr/local/share/nvs/nvs.sh >/dev/null 2>&1 && nvs use lts >/dev/null 2>&1 || true
  [[ -f "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]] && . "${NVM_DIR:-$HOME/.nvm}/nvm.sh" >/dev/null 2>&1 || true
  command -v npm &>/dev/null && return 0

  # Fall back to NodeSource (Node 20.x) — apt's npm is too old for modern packages
  if command -v curl &>/dev/null && command -v apt-get &>/dev/null; then
    info "Installing Node.js 20 via NodeSource"
    curl -fsSL https://deb.nodesource.com/setup_20.x | $SUDO -E bash - >/dev/null
    apt_install nodejs
  else
    err "No Node.js available and cannot bootstrap (need curl + apt-get)"
    return 1
  fi
}

npm_install_global() {
  ensure_node || return 1
  # Try unprivileged first (works with user-mode npm prefix); fall back to sudo
  npm install -g "$@" 2>/dev/null || $SUDO npm install -g "$@"
}

# Install Claude Code via the official native installer (binary at
# ~/.local/bin/claude). If a legacy npm install is detected, migrate it
# in-place via `claude install`.
ensure_claude_code() {
  if [[ -x "$HOME/.local/bin/claude" ]]; then
    ok "claude already installed at ~/.local/bin/claude"
    return 0
  fi

  if command -v claude &>/dev/null; then
    info "Migrating claude from npm to native installer"
    claude install 2>&1 | tail -3 || warn "claude install (migration) failed — try manually"
    return 0
  fi

  command -v curl &>/dev/null || { warn "curl not available — can't install Claude Code"; return 1; }
  info "Installing Claude Code via native installer"
  curl -fsSL https://claude.ai/install.sh | bash 2>&1 | tail -3 || warn "Claude Code install failed"
  [[ -d "$HOME/.local/bin" ]] && export PATH="$HOME/.local/bin:$PATH"
}

ensure_locales() {
  command -v locale-gen &>/dev/null || apt_install locales || return 0
  local need_gen=false
  for loc in "de_AT.UTF-8" "en_US.UTF-8"; do
    local short="${loc%.UTF-8}.utf8"
    if ! locale -a 2>/dev/null | grep -qi "^${short}$"; then
      $SUDO sed -i "s/^# *${loc}/${loc}/" /etc/locale.gen 2>/dev/null || warn "could not uncomment $loc in /etc/locale.gen (non-fatal)"
      need_gen=true
    fi
  done
  if [[ "$need_gen" == "true" ]]; then
    $SUDO locale-gen >/dev/null 2>&1 || warn "locale-gen failed — locale warnings may persist"
  fi
}

ensure_opencode() {
  command -v opencode &>/dev/null && return 0
  command -v curl &>/dev/null || { warn "curl not available — skipping opencode install"; return 0; }
  info "Installing opencode"
  curl -fsSL https://opencode.ai/install | bash 2>&1 | tail -5 || warn "opencode install failed"
  # The installer drops the binary in ~/.opencode/bin and only adds that to
  # PATH via .bashrc. Symlink into ~/.local/bin so non-interactive shells
  # (postStartCommand, etc.) see it without sourcing rc files.
  if [[ -x "$HOME/.opencode/bin/opencode" ]]; then
    mkdir -p "$HOME/.local/bin"
    ln -sf "$HOME/.opencode/bin/opencode" "$HOME/.local/bin/opencode"
    export PATH="$HOME/.local/bin:$PATH"
  fi
}

ensure_codex() {
  header "Ensuring OpenAI Codex CLI"
  command -v codex &>/dev/null && { ok "codex already installed"; return 0; }
  command -v curl  &>/dev/null || { warn "curl not available — skipping codex install"; return 0; }
  info "Installing OpenAI Codex CLI"
  # CODEX_NON_INTERACTIVE=1: upstream grew y/N prompts that read /dev/tty
  # directly, so piping into sh alone no longer keeps this unattended.
  curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh 2>&1 | tail -5 \
    || warn "codex install failed (non-fatal)"
  # Upstream installer's drop-path isn't formally documented. Probe two
  # likely locations and symlink into ~/.local/bin so non-interactive
  # shells (postStartCommand) see codex without sourcing rc files.
  if [[ ! -x "$HOME/.local/bin/codex" ]] && [[ -x "$HOME/.codex/bin/codex" ]]; then
    mkdir -p "$HOME/.local/bin"
    ln -sf "$HOME/.codex/bin/codex" "$HOME/.local/bin/codex"
  fi
  [[ -d "$HOME/.local/bin" ]] && export PATH="$HOME/.local/bin:$PATH"
}

ensure_cursor_agent() {
  header "Ensuring Cursor CLI"
  # Binary name is empirically uncertain (see spec Open Question #2):
  # current docs say `agent`, older releases shipped `cursor-agent`, npm
  # distro is `@cursor/cli`. Probe both names.
  local already_installed=0
  if command -v agent &>/dev/null || command -v cursor-agent &>/dev/null; then
    ok "cursor-agent already installed"
    already_installed=1
  fi

  if [[ $already_installed -eq 0 ]]; then
    command -v curl &>/dev/null || { warn "curl not available — skipping cursor-agent install"; return 0; }
    info "Installing Cursor CLI"
    curl -fsSL https://cursor.com/install | bash 2>&1 | tail -5 \
      || warn "cursor-agent install failed (non-fatal)"

    # Empirical probe: report which name the installer actually dropped.
    # This information is useful in postCreate logs when debugging.
    local found=""
    if   [[ -x "$HOME/.local/bin/agent" ]];        then found="agent"
    elif [[ -x "$HOME/.local/bin/cursor-agent" ]]; then found="cursor-agent"
    fi
    [[ -n "$found" ]] && info "cursor-agent installer dropped binary as: $found"
  fi

  # Establish a canonical name regardless of whether we just installed or
  # it was already present. update.sh and downstream tooling expect either
  # `agent` or `cursor-agent` to resolve; symlink whichever is present so
  # both names work. Idempotent across re-runs.
  if [[ -x "$HOME/.local/bin/cursor-agent" ]] && [[ ! -e "$HOME/.local/bin/agent" ]]; then
    ln -sf cursor-agent "$HOME/.local/bin/agent"
  elif [[ -x "$HOME/.local/bin/agent" ]] && [[ ! -e "$HOME/.local/bin/cursor-agent" ]]; then
    ln -sf agent "$HOME/.local/bin/cursor-agent"
  fi
  [[ -d "$HOME/.local/bin" ]] && export PATH="$HOME/.local/bin:$PATH"

  # cursor-agent keeps auth in ~/.config/cursor (NOT the mounted ~/.cursor).
  # Symlink it into the shared mount so `cursor-agent login` is once-ever.
  # If a real dir already exists (pre-existing login), adopt its contents.
  local cc_target="$HOME/.aicodingsetup/cursor-config"
  local cc_link="$HOME/.config/cursor"
  mkdir -p "$cc_target" "$HOME/.config"
  if [[ -d "$cc_link" && ! -L "$cc_link" ]]; then
    cp -an "$cc_link/." "$cc_target/" 2>/dev/null || true
    rm -rf "$cc_link"
  fi
  [[ -L "$cc_link" ]] || ln -s "$cc_target" "$cc_link"
}

ensure_go() {
  command -v go &>/dev/null && return 0
  command -v curl &>/dev/null || { warn "curl not available — skipping Go install"; return 0; }
  local goversion="1.22.5"
  local arch
  case "$(uname -m)" in
    x86_64)  arch="amd64" ;;
    aarch64) arch="arm64" ;;
    *)       warn "unsupported arch for Go install: $(uname -m)"; return 0 ;;
  esac
  info "Installing Go ${goversion}"
  curl -fsSL "https://go.dev/dl/go${goversion}.linux-${arch}.tar.gz" | $SUDO tar -C /usr/local -xz \
    || { warn "Go install failed"; return 0; }
  export PATH="/usr/local/go/bin:$PATH"
  # Persistence for future shells is handled by the managed ~/.bashrc block
  # (deployed by deploy_all_managed_files / adopt_existing_files); we no
  # longer append a standalone export here.
}

ensure_uv() {
  command -v uv &>/dev/null && return 0
  command -v curl &>/dev/null || { warn "curl not available — skipping uv install"; return 0; }
  info "Installing uv (Python package manager)"
  curl -LsSf https://astral.sh/uv/install.sh | sh 2>&1 | tail -3 || { warn "uv install failed"; return 0; }
  [[ -d "$HOME/.local/bin" ]] && export PATH="$HOME/.local/bin:$PATH"
}

ensure_tmux() {
  # Need tmux 3.8+ (2026-07-05): every release up to 3.7b leaves stale
  # fragments on the outer terminal when TUIs emit DEC 2026 synchronized
  # output (Claude Code does since 2.1.200) — tmux#5307/#5322,
  # claude-code#74122. The fixes are only on master until 3.8 ships, so we
  # build a pinned master commit; drop the pin for the release tarball once
  # tmux 3.8 is out.
  local minver="3.8"
  if command -v tmux &>/dev/null; then
    local current
    current="$(tmux -V 2>/dev/null | awk '{print $2}')"
    current="${current#next-}"                # master builds report "next-3.8"
    current="$(printf '%s' "$current" | sed 's/[a-z]//g')"
    if awk "BEGIN{exit !(${current:-0} >= ${minver})}" 2>/dev/null; then
      ok "tmux $current already installed"
      return 0
    fi
    info "tmux ${current:-?} is older than $minver — building newer from source"
  else
    info "tmux not installed — building from source"
  fi

  command -v curl &>/dev/null || { warn "curl not available — skipping tmux build"; return 0; }
  apt_install build-essential libevent-dev libncurses-dev pkg-config bison autoconf automake || {
    warn "Could not install tmux build deps — falling back to apt's tmux"
    apt_install tmux || warn "apt tmux install also failed — tmux may be missing (non-fatal)"
    return 0
  }

  # Pinned master commit (2026-07-04, verified to fix the artifacts; contains
  # the sync-end dirty-tracking + ED-2 dirty fixes).
  local tmux_commit="5356c62eadf8650ad1ffc95f52755d6f66029a20"
  local build_dir="/tmp/tmux-build-$$"
  rm -rf "$build_dir" && mkdir -p "$build_dir"
  (
    cd "$build_dir"
    curl -fsSL "https://github.com/tmux/tmux/archive/${tmux_commit}.tar.gz" \
      | tar xz --strip-components=1
    sh autogen.sh &>/dev/null            # git snapshot has no ./configure yet
    ./configure --prefix=/usr/local &>/dev/null
    make -j"$(nproc)" &>/dev/null
    $SUDO make install &>/dev/null
  ) || { warn "tmux build failed — falling back to apt's tmux"; apt_install tmux || warn "apt tmux install also failed — tmux may be missing (non-fatal)"; rm -rf "$build_dir"; return 0; }
  rm -rf "$build_dir"
  hash -r
  ok "tmux $(tmux -V 2>/dev/null | awk '{print $2}') (master ${tmux_commit:0:7}) built and installed to /usr/local/bin/tmux"
}

ensure_playwright_browsers() {
  command -v npx &>/dev/null || return 0
  local cache_dir="${PLAYWRIGHT_BROWSERS_PATH:-$HOME/.cache/ms-playwright}"
  if [[ -d "$cache_dir" ]] && [[ -n "$(ls -A "$cache_dir" 2>/dev/null)" ]]; then
    ok "Playwright browsers already installed"
    return 0
  fi
  info "Installing Playwright browsers (chromium)"
  npx -y playwright install chromium 2>&1 | tail -5 || warn "Playwright browser install failed"
}

# The universal devcontainer images bake in the git-lfs feature with autoPull
# hardcoded on: /usr/local/share/pull-git-lfs-artifacts.sh runs
# `git lfs install && git lfs pull` as a lifecycle hook AFTER install.sh and
# hard-fails the whole `devcontainer up` (set -e, exit 2) when the workspace's
# .git/hooks/pre-push is owned by another tool (e.g. pre-commit's push-stage
# hook). git-lfs only accepts hook files it wrote itself — even a hook that
# contains `git lfs pre-push "$@"` is rejected — so merging hooks can't fix it.
# Instead: dry-run `git lfs install` here; if it can't take ownership, flip the
# baked-in AUTO_PULL flag off and run the pull ourselves (a plain
# `git lfs pull` needs no hooks). Repos whose hooks are free stay on the
# feature's own auto-pull path, untouched.
ensure_lfs_autopull_safe() {
  local script="${AICODINGSETUP_LFS_PULL_SCRIPT:-/usr/local/share/pull-git-lfs-artifacts.sh}"
  [[ -f "$script" ]] || return 0
  git lfs version &>/dev/null || return 0
  # Same gate the feature script uses before it reaches `git lfs install`:
  # fails outside a git work tree, succeeds (even with no lfs files) inside one.
  git lfs ls-files &>/dev/null || return 0
  if git lfs install &>/dev/null; then
    ok "git lfs hooks install cleanly — baked-in lfs auto-pull can run"
    return 0
  fi
  info "pre-push hook owned by another tool — disabling baked-in git-lfs auto-pull"
  if [[ -w "$script" ]]; then
    sed -i 's/^AUTO_PULL=true$/AUTO_PULL=false/' "$script" || warn "could not patch $script"
  else
    $SUDO sed -i 's/^AUTO_PULL=true$/AUTO_PULL=false/' "$script" || warn "could not patch $script"
  fi
  if [[ "${AICODINGSETUP_SKIP_NETWORK:-}" == "1" ]]; then
    info "Skipping git lfs pull (AICODINGSETUP_SKIP_NETWORK)"
    return 0
  fi
  if git lfs ls-files --name-only 2>/dev/null | grep -q .; then
    info "Fetching git lfs artifacts directly"
    git lfs pull || warn "git lfs pull failed — run it manually in the workspace"
  fi
}

auto_install_prereqs() {
  header "Auto-installing prerequisites"
  ensure_login_shells_clean
  command -v git    &>/dev/null || { info "Installing git";    apt_install git; }
  command -v jq     &>/dev/null || { info "Installing jq";     apt_install jq; }
  command -v bwrap  &>/dev/null || { info "Installing bubblewrap"; apt_install bubblewrap; }
  # GNU parallel lets tests/bats/run.sh fan the suite across all cores. The
  # universal image only ships moreutils' incompatible parallel, which bats
  # can't use; the parallel package diverts it.
  parallel --version 2>/dev/null | head -1 | grep -q "GNU parallel" \
    || { info "Installing GNU parallel"; apt_install parallel; }
  ensure_tmux
  # Modern terminal terminfos so tmux works for kitty/alacritty/wezterm users.
  # Check for the xterm-kitty terminfo file directly — `infocmp` returns
  # inconsistent exit codes across distro versions.
  if ! ls /usr/share/terminfo/x/xterm-kitty /etc/terminfo/x/xterm-kitty 2>/dev/null | grep -q .; then
    info "Installing kitty-terminfo"
    apt_install kitty-terminfo
  fi
  # Make Node/npm available for install_mcp_packages and Playwright. With
  # claude on the native installer we no longer call npm_install_global, so
  # nothing else surfaces nvm-managed Node onto PATH.
  ensure_node || warn "Node not available — npm-based MCPs and Playwright will be skipped"
  ensure_claude_code
  ensure_opencode
  ensure_codex
  ensure_cursor_agent
  ensure_go
  ensure_uv
  ensure_locales
  ensure_playwright_browsers
}

# --- Prerequisite checks ---
check_prerequisites() {
  # Auto-install on container mode or explicit opt-in (AICODINGSETUP_AUTO_INSTALL=1),
  # UNLESS network provisioning is disabled. auto_install_prereqs pulls external
  # tooling over the network (Claude/opencode/codex installers, Go, uv, a Chromium
  # download via `npx playwright install`). That's right for a real provision but
  # wrong for the test suite: it makes `bash install.sh` slow and, when the
  # devcontainer is offline or its forwarded ssh-agent has rotated stale, hang on
  # those fetches. tests/bats/run.sh sets AICODINGSETUP_SKIP_NETWORK=1 so the suite
  # never reaches the network. Production installs leave it unset (behaviour as before).
  if [[ "${AICODINGSETUP_SKIP_NETWORK:-}" != "1" ]] \
     && { [[ "$ENV_TYPE" == "container" ]] || [[ "${AICODINGSETUP_AUTO_INSTALL:-}" == "1" ]]; }; then
    auto_install_prereqs
  fi

  local missing=()
  command -v git   &>/dev/null || missing+=("git")
  command -v jq    &>/dev/null || missing+=("jq")
  command -v claude &>/dev/null || missing+=("claude (Claude Code CLI)")

  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing required tools: ${missing[*]}"
    err "Please install them and re-run."
    exit 1
  fi

  # opencode is optional — warn if missing
  if ! command -v opencode &>/dev/null; then
    warn "opencode CLI not found — skipping opencode configuration"
  fi
}

# Top-level actions run only when executed, not when sourced — so tests can
# `source install.sh` to unit-test individual functions without triggering the
# prereq auto-install (and main) as a side effect. `if` (not `&&`) so a sourced
# run's final statement still exits 0 and doesn't trip the caller's set -e.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then check_prerequisites; fi

# --- Secrets Management ---
load_or_prompt_secrets() {
  header "Secrets Management"
  mkdir -p "$SECRETS_DIR"

  local example_file="$SCRIPT_DIR/.secrets.env.example"
  if [[ ! -f "$example_file" ]]; then
    err "Missing .secrets.env.example in repo"
    exit 1
  fi

  # Parse required keys from example file
  local required_keys=()
  while IFS= read -r line; do
    # Skip comments and blank lines
    [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
    local key="${line%%=*}"
    required_keys+=("$key")
  done < "$example_file"

  # Load existing secrets if present
  declare -A secrets
  if [[ -f "$SECRETS_FILE" ]]; then
    info "Found existing secrets file"
    while IFS='=' read -r key value; do
      [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
      secrets["$key"]="$value"
    done < "$SECRETS_FILE"
  else
    info "No secrets file found — will prompt for all keys"
  fi

  # Decide whether we can prompt (no tty, container mode, or env opt-out → no)
  local can_prompt=true
  [[ ! -t 0 ]] && can_prompt=false
  [[ "$ENV_TYPE" == "container" ]] && can_prompt=false
  [[ "${AICODINGSETUP_NONINTERACTIVE:-}" == "1" ]] && can_prompt=false

  # Prompt for missing keys (keys with empty values are treated as "skipped", not missing)
  local prompted=false
  for key in "${required_keys[@]}"; do
    if [[ ! -v "secrets[$key]" ]]; then
      if [[ "$can_prompt" == "true" ]]; then
        prompted=true
        read -rp "Enter $key [or press Enter to skip]: " value
        secrets["$key"]="${value:-}"
      else
        info "$key not set (non-interactive — leaving empty)"
        secrets["$key"]=""
      fi
    else
      if [[ -n "${secrets[$key]}" ]]; then
        ok "$key already set"
      else
        ok "$key skipped (empty)"
      fi
    fi
  done

  # Write secrets file — but NEVER regenerate an existing one in non-interactive
  # mode. ~/.aicodingsetup/.secrets.env is typically a host bind mount: the single
  # source of truth shared across containers. A container can't prompt, so a
  # rewrite would stamp every key it lacks (e.g. a freshly-added GH_TOKEN) to
  # EMPTY — destroying the user's real tokens on the host. So: only (re)write when
  # we can prompt (interactive host setup) or when bootstrapping a missing file.
  # When an existing file is left untouched, values already loaded above are still
  # exported below for secret substitution.
  if [[ -f "$SECRETS_FILE" && "$can_prompt" != "true" ]]; then
    info "Existing secrets file left untouched (non-interactive — host file is authoritative)"
  else
    {
      echo "# AI Coding Base Setup — Secrets"
      echo "# Auto-generated by install.sh — do not commit"
      echo ""
      for key in "${required_keys[@]}"; do
        echo "${key}=${secrets[$key]:-}"
      done
    } > "$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"
  fi

  if [[ "$prompted" == "true" ]]; then
    ok "Secrets saved to $SECRETS_FILE"
  fi

  # Export secrets for use by other functions
  for key in "${required_keys[@]}"; do
    export "$key"="${secrets[$key]:-}"
  done
}

# --- JSON merge helper ---
# Deep merges $2 into $1, writing result to $1
# Arrays in "allow" keys are unioned; objects are recursively merged
# Keys in $1 that don't exist in $2 are preserved
json_merge() {
  local target="$1"
  local source="$2"

  if [[ ! -f "$target" ]]; then
    cp "$source" "$target"
    return
  fi

  # Strategy: use jq recursive merge (.*) for objects, but handle arrays specially
  # For hooks arrays: concatenate and deduplicate by command string
  # For permissions.allow: union arrays
  # For enabledPlugins: merge objects (union keys)
  # For everything else: source wins for scalars, recursive merge for objects

  local merged
  merged="$(jq -s '
    # Deep merge: source values override target, objects merge recursively
    # "allow" arrays are unioned; all other arrays: source wins (preserves order)
    def deep_merge(key):
      if length == 2 then
        .[0] as $a | .[1] as $b |
        if ($a | type) == "object" and ($b | type) == "object" then
          ($a | keys_unsorted) + ($b | keys_unsorted) | unique |
          map(. as $k |
            if ($a | has($k)) and ($b | has($k)) then
              {($k): ([$a[$k], $b[$k]] | deep_merge($k))}
            elif ($b | has($k)) then
              {($k): $b[$k]}
            else
              {($k): $a[$k]}
            end
          ) | add // {}
        elif ($a | type) == "array" and ($b | type) == "array" then
          if key == "allow" then ($a + $b) | unique
          else $b
          end
        else
          if ($b == null or $b == "") then $a else $b end
        end
      else
        .[0]
      end;
    [.[0], .[1]] | deep_merge("")
  ' "$target" "$source")"

  echo "$merged" > "$target"
}

# --- Report unmanaged components ---
report_unmanaged() {
  header "Checking for unmanaged components"

  # Check MCPs in Claude Code
  if command -v claude &>/dev/null; then
    local mcp_list
    mcp_list="$(claude mcp list 2>/dev/null || true)"
    while IFS= read -r line; do
      # Lines with MCP names look like: "name: command..."
      if [[ "$line" =~ ^([a-zA-Z0-9_-]+):\ .* ]]; then
        local mcp_name="${BASH_REMATCH[1]}"
        # Skip plugin-provided MCPs (e.g. plugin:playwright:playwright)
        [[ "$mcp_name" == plugin* ]] && continue
        # Skip health check lines
        [[ "$mcp_name" == "Checking" ]] && continue
        local managed=false
        for m in "${MANAGED_MCPS[@]}"; do
          [[ "$mcp_name" == "$m" ]] && managed=true && break
        done
        if [[ "$managed" == "false" ]]; then
          info "Found MCP '$mcp_name' not managed by this installer — leaving untouched"
        fi
      fi
    done <<< "$mcp_list"
  fi

  # Check hooks
  if [[ -d "$CLAUDE_DIR/hooks" ]]; then
    for hook_file in "$CLAUDE_DIR/hooks"/*; do
      [[ ! -f "$hook_file" ]] && continue
      local hook_name
      hook_name="$(basename "$hook_file")"
      local managed=false
      for m in "${MANAGED_HOOKS[@]}"; do
        [[ "$hook_name" == "$m" ]] && managed=true && break
      done
      # Also skip infra hooks (managed by their own installer)
      [[ "$hook_name" == infra-* ]] && managed=true
      if [[ "$managed" == "false" ]]; then
        info "Found hook '$hook_name' not managed by this installer — leaving untouched"
      fi
    done
  fi

  # Check skills
  if [[ -d "$CLAUDE_DIR/skills" ]]; then
    for skill_dir in "$CLAUDE_DIR/skills"/*/; do
      [[ ! -d "$skill_dir" ]] && continue
      local skill_name
      skill_name="$(basename "$skill_dir")"
      local managed=false
      for m in "${MANAGED_SKILLS[@]}"; do
        [[ "$skill_name" == "$m" ]] && managed=true && break
      done
      # Also skip infra skills (managed by their own installer)
      [[ "$skill_name" == infra-* ]] && managed=true
      if [[ "$managed" == "false" ]]; then
        info "Found skill '$skill_name' not managed by this installer — leaving untouched"
      fi
    done
  fi
}

# install_mcp_packages / install_claude_mcps / install_claude_plugins live in
# lib/provision.sh (shared with aicoding-sync).

# --- Claude onboarding state ---
# Without these flags ~/.claude.json, the CLI treats every session as a fresh
# install and prompts for login even when ~/.claude/.credentials.json holds
# valid OAuth tokens (the case in containers that mount creds from the host).
ensure_claude_onboarding_state() {
  header "Claude onboarding state"
  local f="$HOME/.claude.json"
  [[ -f "$f" ]] || echo '{}' > "$f"
  local tmp
  tmp="$(mktemp)"
  jq '. + {hasCompletedOnboarding: true, installMethod: "native"}' "$f" > "$tmp" && mv "$tmp" "$f"
  ok "hasCompletedOnboarding=true, installMethod=native"
}

# --- GitHub SSH host key ---
# Containers start with an empty ~/.ssh/known_hosts, so the first git-over-SSH to
# GitHub (riding the forwarded agent) dies with "Host key verification failed"
# *before* auth — the key is never even offered. Seed GitHub's published ed25519
# host key, fingerprint-verified (not trust-on-first-use), so git pull/push/submodule
# work non-interactively. Idempotent.
seed_github_known_host() {
  header "GitHub SSH host key"
  local expected="SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"  # GitHub's published ed25519 fingerprint
  local kh="$HOME/.ssh/known_hosts"
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"; touch "$kh"
  if ssh-keygen -F github.com -f "$kh" >/dev/null 2>&1; then
    ok "github.com already in known_hosts"
    return
  fi
  local tmp scanned
  tmp="$(mktemp)"
  if ! ssh-keyscan -t ed25519 github.com >"$tmp" 2>/dev/null || [[ ! -s "$tmp" ]]; then
    warn "ssh-keyscan github.com failed (offline?) — skipping; git over SSH may prompt"
    rm -f "$tmp"; return
  fi
  scanned="$(ssh-keygen -lf "$tmp" | awk '{print $2}')"
  if [[ "$scanned" == "$expected" ]]; then
    cat "$tmp" >>"$kh"
    ok "Seeded github.com ed25519 host key (fingerprint verified)"
  else
    warn "github.com host-key fingerprint mismatch ($scanned) — NOT seeding"
  fi
  rm -f "$tmp"
}

# --- aicoding-sync CLI symlink ---
install_aicoding_sync_symlink() {
  header "aicoding-sync CLI"
  local src="$SCRIPT_DIR/bin/aicoding-sync"
  local dest="$HOME/.local/bin/aicoding-sync"
  if [[ ! -f "$src" ]]; then
    warn "bin/aicoding-sync not found in blueprint — skipping symlink"
    return
  fi
  mkdir -p "$HOME/.local/bin"
  ln -sf "$src" "$dest"
  chmod +x "$src"
  ok "aicoding-sync installed at $dest -> $src"
}

# --- aicoding-install CLI symlink ---
install_aicoding_install_symlink() {
  header "aicoding-install CLI"
  local src="$SCRIPT_DIR/bin/aicoding-install"
  local dest="$HOME/.local/bin/aicoding-install"
  if [[ ! -f "$src" ]]; then
    warn "bin/aicoding-install not found in blueprint — skipping symlink"
    return
  fi
  mkdir -p "$HOME/.local/bin"
  ln -sf "$src" "$dest"
  chmod +x "$src"
  ok "aicoding-install installed at $dest -> $src"
}

install_update_status_symlink() {
  header "aicoding-status CLI"
  local src="$SCRIPT_DIR/bin/aicoding-status" dest="$HOME/.local/bin/aicoding-status"
  [[ -f "$src" ]] || { warn "bin/aicoding-status not found — skipping"; return; }
  mkdir -p "$HOME/.local/bin"; chmod +x "$src"; ln -sf "$src" "$dest"
  ok "aicoding-status installed at $dest -> $src"
}

# --- SSH agent socket self-heal watcher (container only) ---
# Deploys the watcher onto PATH. We only DEPLOY here (a pure symlink); the
# daemon is *started* by update.sh on each container start — that keeps full
# install.sh runs (and the bats suite, which run install.sh end-to-end) free of
# a lingering background process. The watcher keeps ~/.ssh/agent.sock pointed at
# the live forwarded ssh-agent for non-interactive processes; the bashrc snippet
# (configs/bash/ssh-auth-sock.sh) covers interactive shells.
install_ssh_agent_watch_symlink() {
  header "SSH agent socket watcher"
  if [[ "$ENV_TYPE" != "container" ]]; then
    info "Skipping (host manages its own ssh-agent)"
    return
  fi
  local src="$SCRIPT_DIR/bin/aicoding-ssh-agent-watch"
  local dest="$HOME/.local/bin/aicoding-ssh-agent-watch"
  if [[ ! -f "$src" ]]; then
    warn "bin/aicoding-ssh-agent-watch not found in blueprint — skipping"
    return
  fi
  mkdir -p "$HOME/.local/bin"
  chmod +x "$src"
  ln -sf "$src" "$dest"
  ok "aicoding-ssh-agent-watch installed at $dest -> $src (started by update.sh)"
}

# --- tmux plugins (TPM) ---
# Container-only: bootstraps Tmux Plugin Manager and installs every plugin
# declared in configs/tmux/tmux.conf (resurrect, continuum, catppuccin, fzf,
# thumbs). Without this, the trailing `run '~/.tmux/plugins/tpm/tpm'` in
# tmux.conf exits 127 and the theme + session save/restore + fzf binding
# are all dead. Idempotent: re-running just updates clones in place.
install_tmux_plugins() {
  header "tmux plugins (TPM)"

  # Network provisioning disabled (test suite) — TPM + each plugin is a github
  # clone, slow and hang-prone offline. See AICODINGSETUP_SKIP_NETWORK in run.sh.
  if [[ "${AICODINGSETUP_SKIP_NETWORK:-}" == "1" ]]; then
    info "Skipping TPM install (AICODINGSETUP_SKIP_NETWORK)"
    return
  fi

  if [[ "$ENV_TYPE" != "container" ]]; then
    info "Skipping TPM install (host manages its own tmux plugins)"
    return
  fi

  if ! command -v git &>/dev/null; then
    warn "git not found — skipping TPM install"
    return
  fi

  local tpm_dir="$HOME/.tmux/plugins/tpm"
  if [[ ! -d "$tpm_dir" ]]; then
    git clone --quiet --depth=1 https://github.com/tmux-plugins/tpm "$tpm_dir"
    ok "TPM cloned to $tpm_dir"
  else
    ok "TPM already present at $tpm_dir"
  fi

  # Headless plugin install. Reads `set -g @plugin '...'` lines from
  # ~/.tmux.conf; skips already-cloned plugins. Output is left visible —
  # TPM is verbose on success ("Installing X / download success") and any
  # failure surfaces inline rather than disappearing into /dev/null.
  if [[ -x "$tpm_dir/bin/install_plugins" ]]; then
    if "$tpm_dir/bin/install_plugins"; then
      ok "tmux plugins installed/updated"
    else
      warn "TPM install_plugins exited non-zero (see output above)"
    fi
  else
    warn "$tpm_dir/bin/install_plugins missing or not executable"
  fi
}

# --- bubblewrap (bw-AICode) ---
install_bubblewrap() {
  header "bubblewrap (bw-AICode)"

  # Network provisioning disabled (test suite) — this clones/pulls bw-AICode from
  # github and runs its installer. See AICODINGSETUP_SKIP_NETWORK in run.sh.
  if [[ "${AICODINGSETUP_SKIP_NETWORK:-}" == "1" ]]; then
    info "Skipping bw-AICode (AICODINGSETUP_SKIP_NETWORK)"
    return
  fi

  local vendor_dir="$SCRIPT_DIR/vendor/bw-AICode"

  if [[ -d "$vendor_dir/.git" ]]; then
    info "Updating bw-AICode..."
    git -C "$vendor_dir" pull --ff-only 2>/dev/null && \
      ok "bw-AICode updated" || warn "bw-AICode update failed — check manually"
  else
    info "Cloning bw-AICode..."
    mkdir -p "$SCRIPT_DIR/vendor"
    git clone https://github.com/vossiman/bw-AICode.git "$vendor_dir" 2>/dev/null && \
      ok "bw-AICode cloned" || { err "Failed to clone bw-AICode"; return; }
  fi

  # Run bw-AICode's own installer
  if [[ -f "$vendor_dir/install.sh" ]]; then
    info "Running bw-AICode installer..."
    bash "$vendor_dir/install.sh" && \
      ok "bw-AICode installed" || warn "bw-AICode installer had issues — check output above"
  else
    err "bw-AICode install.sh not found"
  fi
}

# --- infra-audit ---
install_infra_audit() {
  header "infra-audit (python-infra-audit-cc)"

  # infra-audit has its own install mechanism via the repo
  if [[ -f "$CLAUDE_DIR/infra-audit-manifest.json" ]]; then
    info "infra-audit already installed — run /infra-update in Claude Code to update"
  else
    info "infra-audit not installed"
    info "To install, clone https://github.com/vossiman/python-infra-audit-cc and follow its README"
  fi
}

# --- Playwright check ---
check_playwright() {
  header "Playwright"

  if [[ -d "$HOME/.cache/ms-playwright" ]] || [[ -d "$HOME/Library/Caches/ms-playwright" ]]; then
    ok "Playwright browsers installed"
  else
    warn "Playwright browsers not found"
    info "Run: npx playwright install"
  fi
}

# Detect which deploy mode this install.sh run should use.
detect_install_mode() {
  if [[ -f "$AICODING_MANIFEST" ]]; then
    echo "reconcile"
    return
  fi
  # No manifest. Check whether any managed files already exist on disk.
  local dest
  while IFS='|' read -r dest _ _; do
    [[ -z "$dest" ]] && continue
    [[ -e "$dest" ]] && { echo "adopt"; return; }
  done < <(managed_inventory_overwrite; managed_inventory_merge)
  [[ -f "$HOME/.bashrc" ]] && grep -qxF "$BASHRC_BLOCK_START" "$HOME/.bashrc" \
    && { echo "adopt"; return; }
  # Legacy: today's install.sh appends a standalone Go-PATH export to
  # ~/.bashrc. Its presence signals a prior install, so treat as adopt
  # (adopt_existing_files strips the line before deploying the managed block).
  [[ -f "$HOME/.bashrc" ]] \
    && grep -qxF 'export PATH="/usr/local/go/bin:$PATH"' "$HOME/.bashrc" \
    && { echo "adopt"; return; }
  echo "first"
}

# adopt_existing_files — record current hashes for existing managed files
# without overwriting them. Files missing on disk are still deployed.
adopt_existing_files() {
  manifest_stage_begin
  local dest mode source
  local -a adopted=() deployed=()

  while IFS='|' read -r dest mode source; do
    [[ -z "$dest" ]] && continue
    if [[ -e "$dest" ]]; then
      local h
      h=$(compute_hash "$dest")
      manifest_set_file "$dest" \
        "$(jq -n --arg s "$source" --arg h "$h" \
            '{mode:"overwrite",source:$s,deployed_hash:$h}')"
      adopted+=("$dest")
    elif [[ -f "$SCRIPT_DIR/$source" ]]; then
      deploy_overwrite_file_substituted "$SCRIPT_DIR/$source" "$dest" "$source"
      deployed+=("$dest")
    fi
  done < <(managed_inventory_overwrite)

  while IFS='|' read -r dest mode source; do
    [[ -z "$dest" ]] && continue
    if [[ -e "$dest" ]]; then
      manifest_set_file "$dest" \
        "$(jq -n --arg s "$source" '{mode:"merge",source:$s}')"
      adopted+=("$dest")
    elif [[ -f "$SCRIPT_DIR/$source" ]]; then
      mkdir -p "$(dirname "$dest")"
      echo '{}' > "$dest"
      deploy_merge_file_substituted "$SCRIPT_DIR/$source" "$dest" "$source"
      deployed+=("$dest")
    fi
  done < <(managed_inventory_merge)

  # One-time fixup: today's install.sh appends a standalone Go-PATH export
  # to ~/.bashrc. The managed block now absorbs this export, so we strip
  # the standalone line during adopt to avoid duplication.
  if [[ -f "$HOME/.bashrc" ]]; then
    local tmp_bashrc
    tmp_bashrc=$(mktemp)
    grep -vxF 'export PATH="/usr/local/go/bin:$PATH"' "$HOME/.bashrc" > "$tmp_bashrc" || true
    mv "$tmp_bashrc" "$HOME/.bashrc"
  fi

  # ~/.bashrc managed block — adopt if marker block exists, else deploy.
  if [[ -f "$HOME/.bashrc" ]] && grep -qxF "$BASHRC_BLOCK_START" "$HOME/.bashrc"; then
    local h
    h=$(compute_block_hash "$HOME/.bashrc" "$BASHRC_BLOCK_START" "$BASHRC_BLOCK_END")
    manifest_set_file "$HOME/.bashrc" \
      "$(jq -n --arg s "$BASHRC_BLOCK_START" --arg e "$BASHRC_BLOCK_END" --arg h "$h" \
          '{mode:"marker_block",source:"(composed)",marker_start:$s,marker_end:$e,deployed_block_hash:$h}')"
    adopted+=("$HOME/.bashrc")
  else
    deploy_marker_block "$HOME/.bashrc" "$(managed_bashrc_block_body)" \
      "$BASHRC_BLOCK_START" "$BASHRC_BLOCK_END"
    deployed+=("$HOME/.bashrc")
  fi

  local commit origin
  commit=$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
  origin=$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || echo unknown)
  manifest_stage_set_top blueprint_commit "$commit"
  manifest_stage_set_top blueprint_origin "$origin"

  manifest_stage_commit

  info "Adopt mode: ${#adopted[@]} existing managed files captured into manifest:"
  local f
  for f in "${adopted[@]}"; do info "    $f"; done
  if [[ ${#deployed[@]} -gt 0 ]]; then
    info "Adopt mode: ${#deployed[@]} new managed files deployed from blueprint:"
    for f in "${deployed[@]}"; do info "    $f"; done
  fi
  info "Adopted files were not modified. To see what diverges from the blueprint,"
  info "run: aicoding-sync --dry-run"
}

# reconcile_existing_install — manifest exists; classify each managed file
# and auto-apply only the conservative bucket set (restore, will_update,
# drifted_but_aligned, merge). new_file and to_remove are skipped — they stay
# for the human-driven `aicoding-sync`.
#
# Strictly more conservative than `aicoding-sync --yes`: never auto-applies
# drifted_and_updating or to_remove, because automatic provisioning should
# never silently overwrite or delete files the user has touched.
reconcile_existing_install() {
  export AICODING_BLUEPRINT_CLONE="$SCRIPT_DIR"

  declare -gA BUCKETS FILE_MODE FILE_SOURCE
  classify_managed_files

  # Owned overwrite files self-heal even in the conservative reconcile path.
  local _d
  for _d in "${!BUCKETS[@]}"; do
    if [[ "${BUCKETS[$_d]}" == drifted_and_updating ]] && _is_owned_overwrite "$_d"; then
      BUCKETS[$_d]=will_update_owned
    fi
  done

  manifest_stage_begin
  apply_managed_buckets "restore new_file will_update will_update_owned drifted_but_aligned merge"
  # Stamp the blueprint commit/origin we reconciled to, so the manifest's
  # recorded version matches what's actually deployed. Without this, reconcile
  # leaves blueprint_commit stale (first-deploy/adopt set it, reconcile didn't),
  # which makes anything reading it — e.g. the update notifier — report wrongly.
  local rc_commit rc_origin
  rc_commit=$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
  rc_origin=$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || echo unknown)
  manifest_stage_set_top blueprint_commit "$rc_commit"
  manifest_stage_set_top blueprint_origin "$rc_origin"
  manifest_stage_commit

  # Counts for the end-of-run summary. drifted_but_aligned is auto-handled
  # (silent hash refresh) and not counted.
  local n_new=0 n_restored=0 n_updated=0 n_merged=0 n_drifted=0 n_to_review=0
  local dest bucket
  for dest in "${!BUCKETS[@]}"; do
    bucket=${BUCKETS[$dest]}
    case "$bucket" in
      new_file)             n_new=$((n_new+1)) ;;
      restore)              n_restored=$((n_restored+1)) ;;
      will_update)          n_updated=$((n_updated+1)) ;;
      will_update_owned)    n_updated=$((n_updated+1)) ;;
      merge)                n_merged=$((n_merged+1)) ;;
      drifted_and_updating) n_drifted=$((n_drifted+1)) ;;
      to_remove)            n_to_review=$((n_to_review+1)) ;;
    esac
  done

  _RECONCILE_NEW=$n_new
  _RECONCILE_RESTORED=$n_restored
  _RECONCILE_UPDATED=$n_updated
  _RECONCILE_MERGED=$n_merged
  _RECONCILE_DRIFTED=$n_drifted
  _RECONCILE_TO_REVIEW=$n_to_review
}

# _print_install_summary — emit the fixed-format summary line plus an
# optional NOTE follow-up. Counters default to 0 when not set by the mode.
_print_install_summary() {
  local commit_short
  commit_short=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)
  local n_new=${_RECONCILE_NEW:-0}
  local n_restored=${_RECONCILE_RESTORED:-0}
  local n_updated=${_RECONCILE_UPDATED:-0}
  local n_merged=${_RECONCILE_MERGED:-0}
  local n_drifted=${_RECONCILE_DRIFTED:-0}
  local n_to_review=${_RECONCILE_TO_REVIEW:-0}
  printf 'INSTALL OK  blueprint %s  new %d  restored %d  updated %d  merged %d  drifted %d  to_review %d\n' \
    "$commit_short" "$n_new" "$n_restored" "$n_updated" "$n_merged" "$n_drifted" "$n_to_review"
  if (( n_drifted > 0 || n_to_review > 0 )); then
    printf 'NOTE: %d drifted file(s), %d file(s) to review. Run aicoding-sync to address.\n' \
      "$n_drifted" "$n_to_review"
  fi
}

# install_templates — mirror the project-scaffold templates into
# ~/.aicodingsetup/templates/project. These are scaffolding source material
# consumed by /scaffold-project, not user-managed dotfiles, so they live
# outside the manifest: the repo is the source of truth and every run mirrors
# the latest tree over (rsync --delete, cp -r fallback for minimal containers).
install_templates() {
  header "Project Templates"

  local src_dir="$SCRIPT_DIR/templates/project"
  local dest_dir="$SECRETS_DIR/templates/project"

  if [[ ! -d "$src_dir" ]]; then
    warn "No templates/project directory in repo — skipping"
    return
  fi

  mkdir -p "$dest_dir"
  if command -v rsync &>/dev/null; then
    rsync -a --delete "$src_dir/" "$dest_dir/"
  else
    rm -rf "$dest_dir"
    mkdir -p "$dest_dir"
    cp -r "$src_dir/." "$dest_dir/"
  fi
  ok "templates/project mirrored to $dest_dir"
}

main() {
  local force_reinstall=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force-reinstall) force_reinstall=1; shift ;;
      *) shift ;;
    esac
  done

  header "AI Coding Base Setup"

  seed_github_known_host

  if [[ $force_reinstall -eq 1 ]]; then
    info "--force-reinstall: deleting existing manifest"
    rm -f "$AICODING_MANIFEST"
  fi

  load_or_prompt_secrets
  report_unmanaged
  install_mcp_packages
  install_claude_mcps
  ensure_claude_onboarding_state
  install_claude_plugins
  install_aicoding_sync_symlink
  install_aicoding_install_symlink
  install_update_status_symlink
  remove_deprecated_shims
  install_ssh_agent_watch_symlink

  local mode
  if [[ $force_reinstall -eq 1 ]]; then
    mode=first
  else
    mode=$(detect_install_mode)
  fi

  case "$mode" in
    first)
      info "Mode: first-deploy (no manifest, no managed files on disk)"
      deploy_all_managed_files
      ;;
    adopt)
      info "Mode: adopt-existing (no manifest, managed files present)"
      adopt_existing_files
      ;;
    reconcile)
      info "Mode: reconcile (manifest exists — restoring missing files, applying safe blueprint updates)"
      reconcile_existing_install
      ;;
  esac

  install_templates
  install_tmux_plugins
  install_bubblewrap
  install_infra_audit
  check_playwright
  ensure_lfs_autopull_safe

  header "Done!"
  info "Mode: $mode"
  info "Secrets: $SECRETS_FILE"
  info "Claude Code: $CLAUDE_DIR"

  _print_install_summary
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
