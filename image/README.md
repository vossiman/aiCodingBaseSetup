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

**dind check:** `smoke-test.sh`'s "nested dockerd" check boots a privileged
nested `dockerd` and runs a container inside it, backed by anonymous volumes
at `/var/lib/docker` and `/var/lib/containerd` (see the comment in
`smoke-test.sh`). Those volumes matter: without them, the nested dockerd's
`/var/lib/docker` is the container's own overlayfs upper layer, and while
`docker info` still succeeds, actually running a container fails to mount an
overlay filesystem on top of overlayfs (`failed to mount ...: fstype:
overlay ... invalid argument`). In real workspaces this never comes up — the
docker-in-docker feature's `devcontainer.metadata` mounts named volumes at
both paths. An earlier theory blamed nested-devbox depth instead (a 4th
level of overlayfs nesting hitting a docker-ce/containerd limitation), based
on a confounded control: `docker:dind` "worked" without an explicit volume
only because its Dockerfile declares `VOLUME /var/lib/docker`, so plain
`docker run` auto-created an anonymous volume for it, while vanilla
ubuntu+docker-ce (which "failed") got none. Confirmed 2026-08-07: with the
volumes, the check passes locally too, including from inside this
already-nested devbox session — a local `FAIL: nested dockerd` is a real
regression, not an artifact of local nesting depth.

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
