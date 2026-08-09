# Auto-pin the blueprint to the freshly published devbox-base digest

**Date:** 2026-08-09
**Status:** accepted
**Scope:** close the manual gap between "CI published a new devbox-base
image" and "the blueprint `devcontainer.json` pins it". Companion change in
devMachine syncs its local devcontainer copy during the routine submodule
bump (separate PR, that repo).

## Problem

`build-base-image.yml` publishes a digest and then *prints* it with "Pin
the blueprint" (`.github/workflows/build-base-image.yml:74`) — a manual
step that has never been done since digest pinning landed: the blueprint
still pins the 2026-08-07 image while three newer ones exist. The stale
pin makes the `⬆rebuild` badge's CTA false: the badge fires from
published-tag/`image/` signals independent of the pin, but `dvw rebuild`
recreates from the *pinned* digest, reinstalling the old image.

Decision context: PR-per-digest was rejected — the "review" would be a
hash nobody can eyeball, CI-token PRs don't trigger checks, and the user's
governance already sends mechanical bumps (submodule pointers, docs-only)
straight to `main`. A machine-generated digest for an image that just
passed its smoke test is the same class.

## Design

New final step in `build-base-image.yml`'s build job, **non-PR events
only**, after the Push step (so it never runs unless build + smoke test +
publish all succeeded):

1. `git pull --rebase origin main` — `main` may have advanced during the
   ~2 min build. (Checkout needs `fetch-depth: 0` for this.)
2. Rewrite only the digest inside the existing pin, preserving file
   formatting:
   `sed -i -E "s|(ghcr\.io/vossiman/devbox-base@)sha256:[0-9a-f]{64}|\1$DIGEST|" devcontainer.json`
3. If `git diff --quiet devcontainer.json` reports no change (identical
   digest republished), log and skip the commit — idempotent.
4. Commit as `github-actions[bot]` with message
   `chore(image): pin devbox-base $DATE_TAG ($DIGEST)` and push to `main`.
5. Any failure in this step **fails the workflow loudly** — the step
   summary still carries the digest for a manual pin, and a red run is the
   signal that the automation needs attention. No silent fallback.

Workflow-level `permissions: contents` goes from `read` to `write`
(needed for the push; `packages: write` already present).

**No retrigger loop:** the workflow's `push.paths` filter is
`image/**` + the workflow file itself; the bump commit touches only root
`devcontainer.json`, so it cannot re-trigger the build. `tests.yml` does
run on the bump commit — intended, it's the suite guarding the repo.

**Lifecycle after this change:** merge an `image/` change or
`gh workflow run build-base-image.yml` → CI builds, smokes, publishes,
self-pins → `⬆rebuild` badges fire in stamped containers → `dvw rebuild`
now actually installs the new image → devMachine's pointer picks up the
pin commit at the next routine submodule bump.

## devMachine companion (separate PR in that repo)

`.devcontainer/devcontainer.json` in devMachine mirrors the blueprint pin
and would silently drift once the blueprint self-bumps. Extend
`scripts/update-submodules.sh`: after bumping pointers, copy the `image`
value from `devpod/aicoding/devcontainer.json` into
`.devcontainer/devcontainer.json` (same sed pattern) and include it in
the bump commit. The digest then propagates through the existing
bump-direct-to-main ritual with zero new ceremony.

Out of scope: how existing dvw *workspaces* refresh their own
devcontainer.json copies — that's dvw's staleness-indicator territory
(`⬆rebuild` badge + `dvw rebuild` behavior), unchanged here.

## Tests (bats, standing rules apply)

- `image.bats` workflow guards: `contents: write` present; the pin step
  exists (grep for the sed pattern target and the
  `chore(image): pin devbox-base` message); pin step is gated on
  `github.event_name != 'pull_request'`.
- The existing "PR builds never push" guard stays green (the pin step
  reuses the same gate).
- No live-git or network execution in tests — these are static contract
  checks like the rest of `image.bats`.

## Bootstrap

First dispatch after merge publishes a fresh image *and* self-pins,
closing the currently-stale pin (2026-08-07) without a manual bump; one
`dvw rebuild` per container then activates the badge fleet-wide.
