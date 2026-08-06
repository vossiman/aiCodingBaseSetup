# devbox-base image

Purpose-built base image replacing `devcontainers/universal:6`
(spec: `../docs/superpowers/specs/2026-08-06-custom-base-image-design.md`).

- `Dockerfile` — staples, tmux pin, Node, locales, agent-CLI seeds.
- `devcontainer.json` — build config only; adds the docker-in-docker feature
  (with `moby: false`, docker-ce engine — see below) so the image carries
  universal-compatible `devcontainer.metadata`.
- `daemon.json` — baked dind log rotation (20m × 3).
- `smoke-test.sh <ref>` — contract assertions incl. a privileged dind boot.

## Build & release

CI (`.github/workflows/build-base-image.yml`) builds weekly (Mon 05:17 UTC),
on any `image/**` change (PRs: build+smoke only), and on manual dispatch;
pushes `ghcr.io/vossiman/devbox-base:{YYYY-MM-DD,latest}` and prints the
digest in the job summary.

Current baseline image size: **~985MB** (well under the 2–3GB target).

Local build (needs ~15GB free docker disk):

    npx -y @devcontainers/cli@0.88.0 build --workspace-folder image --config image/devcontainer.json --image-name devbox-base:local
    bash image/smoke-test.sh devbox-base:local

`--config` is required: the CLI looks for `.devcontainer/devcontainer.json`
under the workspace folder by default, but `image/devcontainer.json` lives
directly in `image/`.

`image/devcontainer-lock.json` is committed: it pins the docker-in-docker
feature's resolved version so weekly builds don't silently float; feature
bumps become reviewable diffs when you run a local build and commit the
updated lock file.

**dind check caveat:** `smoke-test.sh`'s "nested dockerd" check boots a
privileged nested `dockerd` and runs a container inside it. From inside an
already-nested devbox session (this container's own root fs is already
`overlay`), that check adds a 4th level of overlayfs nesting and fails on a
docker-ce/containerd overlay-snapshotter limitation unrelated to this image
(reproduces identically on vanilla Ubuntu + docker-ce at the same depth). The
check is authoritative only on a non-nested host, e.g. a CI runner — the
workflow's `pull_request` build runs it at the correct (3-level) depth and is
the real gate. Treat a local `FAIL: nested dockerd` from inside a devbox as
inconclusive, not a regression, and confirm via CI instead.

## Rollout (per spec)

1. First publish happens when this lands on `main` (or via dispatch).
   One-time: make the GHCR package public / link it to this repo in the UI.
2. Follow-up PR: point the blueprint `devcontainer.json` at
   `ghcr.io/vossiman/devbox-base@sha256:…` (digest from the job summary)
   and update `tests/bats/devcontainer.bats` accordingly.
3. Recreate rides: dataenv first, then financepdfs. Verify dind, CLI boot
   refresh, and surviving logins per the spec's acceptance criteria.
4. Digest bumps = ordinary PRs editing the ref.
5. Follow-up: add throttled codex refresh to `_sync_binaries` (`lib/sync.sh`)
   — until then codex staleness = digest age.

## Cross-file pins (enforced by tests/bats/image.bats)

- `TMUX_COMMIT` here == `tmux_commit` in `lib/provision-system.sh`.
- `daemon.json` == what `ensure_dind_log_rotation` would write.
