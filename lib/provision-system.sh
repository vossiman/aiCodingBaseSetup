# lib/provision-system.sh - environment detection, tool bootstrapping, and
# prerequisite checks for install.sh. Sourced after install.sh defines its
# logging helpers (no shebang / set -e); matches lib/*.sh.

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
  # it was already present. on-start.sh and downstream tooling expect either
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
  # Agent CLIs (codex, opencode) expect a real ripgrep binary on PATH; Claude
  # Code only shims `rg` as a shell function inside its own sessions.
  command -v rg     &>/dev/null || { info "Installing ripgrep"; apt_install ripgrep; }
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
