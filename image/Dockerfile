# devbox-base — purpose-built replacement for devcontainers/universal:6.
# Built by .github/workflows/build-base-image.yml via `devcontainer build`
# (see image/devcontainer.json: docker-in-docker feature layers on top of this).
# Spec: docs/superpowers/specs/2026-08-06-custom-base-image-design.md
#
# Invariant: image = stable substrate; agent CLIs baked here are SEED copies
# in user-owned ~/.local/bin — aicoding-sync --boot self-updates them in place.

# --- Stage 1: build tmux from the pinned commit -----------------------------
# Pin MUST match tmux_commit in lib/provision-system.sh (ensure_tmux);
# tests/bats/image.bats enforces it.
FROM mcr.microsoft.com/devcontainers/base:ubuntu AS tmux-build
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG TMUX_COMMIT=b07424224b88fcc02bcb9b58d8655f00b97909c6
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential libevent-dev libncurses-dev pkg-config bison autoconf automake \
 && mkdir /tmp/tmux-src \
 && curl -fsSL "https://github.com/tmux/tmux/archive/${TMUX_COMMIT}.tar.gz" \
      | tar xz --strip-components=1 -C /tmp/tmux-src \
 && cd /tmp/tmux-src \
 && sh autogen.sh && ./configure --prefix=/usr/local \
 && make -j"$(nproc)" && make install DESTDIR=/tmp/tmux-out

# --- Stage 2: the image -----------------------------------------------------
FROM mcr.microsoft.com/devcontainers/base:ubuntu
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG TMUX_COMMIT=b07424224b88fcc02bcb9b58d8655f00b97909c6

# Release stamp for the ⬆rebuild staleness check (bin/aicoding-status):
# the repo commit this image was built from. An empty sha merely disables
# the badge (fail-open) — but image/smoke-test.sh hard-fails on it BY
# DESIGN, so CI can never publish an image with a dead ⬆rebuild check.
# Local hand-builds without --build-arg will see that one smoke FAIL.
ARG DEVBOX_BASE_SHA=""
RUN printf '{"sha":"%s","built":"%s"}\n' "$DEVBOX_BASE_SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      > /etc/devbox-base-release

# Keep uid 1000 named codespace: every blueprint mount targets /home/codespace.
RUN usermod -l codespace vscode \
 && groupmod -n codespace vscode \
 && usermod -d /home/codespace -m codespace \
 && printf 'codespace ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/codespace \
 && chmod 0440 /etc/sudoers.d/codespace \
 && rm -f /etc/sudoers.d/vscode

# CLI staples auto_install_prereqs otherwise apt-installs per-container, plus
# gh (universal shipped it via feature) and tmux runtime libs.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      git git-lfs jq ripgrep parallel bubblewrap kitty-terminfo locales \
      python3 python3-venv libevent-core-2.1-7t64 libncurses6 \
 && mkdir -p /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && printf 'deb [arch=amd64 signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# Node LTS via NodeSource apt — intentionally using apt instead of node version managers
# (alternative version managers' shell exports are problematic in non-interactive contexts).
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs \
 && node --version \
 && rm -rf /var/lib/apt/lists/*

# Locales ensure_locales otherwise generates per-container.
RUN sed -i 's/^# *de_AT.UTF-8/de_AT.UTF-8/; s/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen \
 && locale-gen

# Vienna time everywhere (tmux clock, logs, cron-ish tooling) — universal ran
# UTC. TZ env covers processes that read it; /etc/localtime covers the rest.
ENV TZ=Europe/Vienna
RUN ln -sf /usr/share/zoneinfo/Europe/Vienna /etc/localtime \
 && echo Europe/Vienna > /etc/timezone

# tmux from the pinned build; commit marker makes ensure_tmux a no-op.
COPY --from=tmux-build /tmp/tmux-out/usr/local/ /usr/local/
RUN mkdir -p /usr/local/share/aicoding \
 && printf '%s\n' "${TMUX_COMMIT}" > /usr/local/share/aicoding/tmux-commit

# dind log rotation baked (supersedes ensure_dind_log_rotation's runtime write
# on this image; PR #47). The docker-in-docker feature layers after this
# Dockerfile and does not touch daemon.json (verified against feature v4.0.0).
COPY daemon.json /etc/docker/daemon.json

# --- Agent CLI seeds --------------------------------------------------------
# Seeds live in user-owned ~/.local/bin so `aicoding-sync --boot` can
# self-update them in place, and ensure_* provisioning short-circuits.
# NEVER seed into ~/.claude ~/.codex ~/.cursor ~/.local/share/opencode —
# those are host bind mounts at runtime; baked content there is invisible.
USER codespace
ENV HOME=/home/codespace
WORKDIR /home/codespace

RUN curl -fsSL https://claude.ai/install.sh | bash \
 && [ -x ~/.local/bin/claude ]
RUN curl -fsSL https://opencode.ai/install | bash \
 && mkdir -p ~/.local/bin \
 && ln -sf "$HOME/.opencode/bin/opencode" ~/.local/bin/opencode \
 && [ -x "$(readlink -f ~/.local/bin/opencode)" ]
# Flattening the codex symlink costs the release layout, so the Code Mode
# sidecar `codex-code-mode-host` must be copied ALONGSIDE it: codex resolves
# the sidecar as a sibling of its own path, and upstream never links it on
# Linux. Seeding `codex` alone shipped a codex whose Code Mode failed closed
# ("host executable was not found", 2026-08-12). The final assertion is
# deliberately unconditional: if upstream moves the sidecar or drops the
# symlink layout, fail the build rather than ship a codex that fails closed.
RUN curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh \
 && mkdir -p ~/.local/bin \
 && if [ -L ~/.local/bin/codex ]; then \
      codex_real="$(readlink -f ~/.local/bin/codex)" \
      && codex_host="$(dirname "$codex_real")/codex-code-mode-host" \
      && rm -f ~/.local/bin/codex \
      && cp "$codex_real" ~/.local/bin/codex \
      && chmod +x ~/.local/bin/codex \
      && if [ -x "$codex_host" ]; then \
           cp "$codex_host" ~/.local/bin/codex-code-mode-host \
           && chmod +x ~/.local/bin/codex-code-mode-host; \
         fi; \
    fi \
 && rm -rf ~/.codex \
 && [ -x ~/.local/bin/codex ] \
 && [ -x ~/.local/bin/codex-code-mode-host ]
RUN curl -fsSL https://cursor.com/install | bash \
 && cd ~/.local/bin \
 && { [ -e agent ] || ln -s cursor-agent agent; } \
 && { [ -e cursor-agent ] || ln -s agent cursor-agent; } \
 && [ -x "$(readlink -f ~/.local/bin/cursor-agent)" ]

# uv (Python package manager) — installs to ~/.local/bin.
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
 && [ -x ~/.local/bin/uv ]

USER root
# Surface the seeds for non-interactive shells (postCreate/postStart run
# before the managed ~/.bashrc exists).
ENV PATH=/home/codespace/.local/bin:$PATH
# NodeSource npm's global prefix is root-owned /usr/lib — unlike universal's
# version-manager-based node, whose prefix was user-writable. Point npm -g at
# user space so install_mcp_packages (and agents) install without sudo;
# binaries land in ~/.local/bin, which is already first on PATH.
ENV NPM_CONFIG_PREFIX=/home/codespace/.local
USER codespace
