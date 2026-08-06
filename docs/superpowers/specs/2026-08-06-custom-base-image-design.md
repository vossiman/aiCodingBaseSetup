# Custom devcontainer base image (replace universal:6)

**Date:** 2026-08-06
**Status:** design — draft, for review.
**Scope:** a purpose-built, digest-pinned base image for all devbox workspaces,
replacing `mcr.microsoft.com/devcontainers/universal:6`. Covers image contents,
build/release pipeline, blueprint integration, and what it removes from
`install.sh`/`provision-system.sh`. Rollout is per-workspace on recreate.

## Problem

Every workspace runs on `universal:6` — a ~15GB kitchen-sink (dotnet, conda,
PHP, Ruby, Java, …) of which we use a small fraction. Concrete costs, all hit
in the 2026-08-05/06 disk incident:

- **Size amplification.** Each digest bump strands the old copy until every
  workspace pinning it is recreated. The devbox carried 3 × ~15GB copies of
  effectively the same image (~45GB of a 232GB disk) while the host sat at
  0 bytes free.
- **No control.** universal's quirks are patched downstream, at provision
  time, forever: the nvs/nvsudo `BASH_FUNC` breakage (`on-start.sh` re-exec +
  `/etc/profile` patch), the stale yarn apt key, moreutils' `parallel`
  shadowing GNU parallel, an old tmux needing a pinned rebuild, and unbounded
  docker-in-docker logs (fixed at runtime in PR #47). Every fix runs in every
  container forever instead of once at image build.
- **Slow first start.** `postCreateCommand` downloads Node, Go, uv, tmux,
  Claude Code, opencode, codex, cursor-agent, Playwright's Chromium, … on
  every workspace create.

## Hard requirements (non-negotiable, from review discussion)

The tool-update lifecycle that works today MUST keep working. Three lifecycles,
three answers — this is the design's core invariant:

| Lifecycle | Invariant | Mechanism (unchanged from today) |
|---|---|---|
| Container **restart** | nothing is wiped | container fs persists across stop/start |
| Container **recreate** | logins/config/state survive | host bind mounts: `~/devpod/{aicodingsetup,claude,codex,cursor,opencode}` → container homes |
| **Daily CLI updates** (claude, codex, cursor-agent, opencode) | image staleness is irrelevant | CLIs live/self-update in user-writable `~/.local/bin`; `aicoding-sync --boot` does the throttled refresh on every start; `~/.local/bin` precedes any image path in PATH |

**Image = stable substrate. Agent CLIs = self-updating user space. State =
host mounts.** Baked-in CLI copies are a fast starting point only — never the
source of truth, never something a user must "reinstall" after recreate.

## Decisions

**Base: `mcr.microsoft.com/devcontainers/base:ubuntu` (~500MB), not raw
Ubuntu.** Keeps the devcontainer plumbing (common-utils, non-root user with
sudo, locale hooks) without the toolchain zoo. Target final size: **2–3GB**.

**User: keep `codespace` (uid 1000).** All blueprint mounts target
`/home/codespace/...`; changing the username would orphan every existing
`~/devpod/*` mount pairing for zero benefit.

**Contents (build-time layers):**
- docker-in-docker: docker-ce + the moby dind init script (same
  `/usr/local/share/docker-init.sh` contract the blueprint's entrypoint
  expects), **with `/etc/docker/daemon.json` log rotation (20m × 3) baked in**
  — supersedes the runtime fix from PR #47 on this image.
- Runtimes: Node LTS, Python 3 + uv, Go (decide: keep or drop — see open
  questions).
- CLI staples currently apt-installed by `auto_install_prereqs`: git, gh, jq,
  ripgrep, GNU parallel, bubblewrap, kitty-terminfo, locales (de_AT + en_US),
  **tmux from the pinned commit** (`ensure_tmux`'s build, baked so no
  per-container compile).
- Agent CLIs (claude, codex, opencode, cursor-agent) preinstalled to a
  system path as seed copies; first `aicoding-sync --boot` refresh shadows
  them in `~/.local/bin` per the invariant above.
- NOT baked: Playwright's Chromium (~1GB; keep `ensure_playwright_browsers`
  at provision time — it caches into the container fs once per recreate).

**Build & release pipeline:**
- Dockerfile lives in this repo (`image/`), built by a GitHub Actions workflow:
  weekly cron + manual dispatch + on-change to `image/`.
- Push to `ghcr.io/vossiman/devbox-base` with a date tag (`2026-08-06`) and
  `latest`; amd64 only (the devbox and all workspaces are amd64).
- The blueprint `devcontainer.json` pins **by digest**
  (`ghcr.io/vossiman/devbox-base@sha256:…`). Digest bumps are ordinary PRs to
  this repo — reviewable, revertible, and each workspace picks the new image
  up on its next recreate. The N-copies problem stays bounded by recreate
  cadence, and `docker image prune -a` on the host clears strays (no
  container pins an image invisibly once recreated).

**Provisioning simplification (follow-up PRs, gated on image adoption):**
`ensure_login_shells_clean`, `drop_broken_apt_sources`, the nvs re-exec block
in `on-start.sh`, `ensure_tmux`'s compile path, `ensure_dind_log_rotation`'s
write path, and most of `auto_install_prereqs`' apt calls become no-ops on the
new image. Keep them (they're idempotent and cheap) until the last
universal-based workspace is gone, then delete in one sweep.

## Rollout

1. Build + push image; smoke-test with a throwaway `dvw new` workspace.
2. Switch the blueprint `devcontainer.json` image ref (PR).
3. First real ride: the parked dataenv recreate (which also clears its ~20GB
   orphaned nested-containerd store and drops a stale universal digest), then
   financepdfs. Verify: dind works, `make up` builds, agent CLIs update via
   `aicoding-sync --boot`, logins survive recreate.
4. As remaining workspaces recreate naturally, universal digests age out;
   final `docker image prune -a` on the host.

## Open questions

- **Go**: only needed if some workspace actually builds Go — audit before
  baking (~300MB).
- **Seed-CLI staleness**: weekly builds mean seeds are ≤7 days old; is that
  worth the workflow noise, or build monthly and lean fully on boot refresh?
- **Image repo**: this repo (`image/` + workflow) vs. a dedicated repo.
  Leaning this repo — the image and the provisioning it simplifies should
  version together.

## Acceptance criteria

- Fresh `dvw new` workspace on the image: postCreate < 2 min (vs ~10 today),
  nested docker functional, log rotation active without runtime patching.
- Recreate an existing workspace: no re-login for claude/codex/cursor/opencode,
  `aicoding-sync --boot` refreshes CLIs on first start.
- Host: after dataenv + financepdfs recreates and prune, zero universal
  digests remain; total base-image footprint ≤ 3GB.
