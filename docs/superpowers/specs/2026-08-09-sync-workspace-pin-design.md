# Sync the workspace's devcontainer pin from the blueprint

**Date:** 2026-08-09
**Status:** accepted
**Scope:** `aicoding-sync` reconciles the current workspace's
`.devcontainer/devcontainer.json` image pin from the blueprint on every
sync. Closes the last manual step in the image-staleness loop.

## Problem

The pin chain now self-maintains up to the blueprint
(`2026-08-09-auto-pin-image-digest-design.md`): CI publishes and self-pins
`main`. But each workspace repo carries a *snapshot* of the blueprint
devcontainer.json committed by `dvw new` at creation, and nothing
reconciles it afterward. Consequence: the `⬆rebuild` badge fires, but
`dvw rebuild` recreates from the workspace's stale pin — the user must
hand-edit the digest in every container first ("a fucking complicated
command", user, 2026-08-09). The badge is a doorbell with no door.

## Design

New `_sync_devcontainer_pin` in `lib/sync.sh`, called from
`aicoding_sync` on every mode except `--dry-run` write paths (dry-run
reports, writes nothing). Local file ops only — no network, no throttle.

Behavior:

1. Workspace discovery: `git -C "$PWD" rev-parse --show-toplevel`
   (postStartCommand and on-start.sh run in the workspace folder; manual
   syncs from elsewhere resolve their own repo, which is the intended
   target — you sync where you stand). Not a git repo → silent skip.
2. Target: `<toplevel>/.devcontainer/devcontainer.json`. Absent → silent
   skip (not every repo is a dvw workspace).
3. Source of truth: `$AICODING_BLUEPRINT_CLONE/devcontainer.json` (the
   boot-refreshed clone; `--blueprint PATH` runs use that checkout's copy
   verbatim, which is exactly local-iteration semantics). Read
   `jq -r '.image // empty'`; empty → skip with a WARN (blueprint copy
   should always carry an image).
4. Guard: the target's current `image` must reference
   `ghcr.io/vossiman/devbox-base` — a workspace that switched to a custom
   image is never stomped (silent skip).
5. Equal pins → silent no-op. Different → sed only the image value
   (format-preserving, same pattern as devMachine's
   `update-submodules.sh`), then print one line:
   `devcontainer pin: <old-digest-12> -> <new-digest-12> (commit at your convenience)`.
6. **Never commits, never pushes.** The change sits in the working tree;
   `devpod up --recreate` reads on-disk config, so the next
   `dvw rebuild` already uses it — commit rides the project's normal
   flow. Fail-open throughout: any error warns and returns 0 (sync/boot
   must not break).
7. Dry-run mode: report the would-change line, write nothing.

## Resulting lifecycle (the whole point)

Image published → blueprint self-pins → every container's next boot sync
reconciles its workspace pin → badge fires (stamped images) →
`dvw rebuild <id>` from the laptop — and that's ALL the user does. The
pin edit is already on disk; the commit folds into normal work.

Bootstrap: containers still on stamp-less images show no badge, but their
pins reconcile at next boot anyway — one blind `dvw rebuild` per
workspace finishes the rollout.

Overlap: devMachine's `update-submodules.sh` also syncs devmachine's own
mirror — same value, idempotent, harmless. It remains useful there
because it *commits* the pin as part of the bump ritual.

## Tests (bats, standing rules)

New cases (sync.bats or a dedicated file): reconciles a stale
devbox-base pin from the blueprint copy and reports old→new; leaves a
non-devbox `image` untouched; silent no-op when equal; silent skip when
no `.devcontainer/devcontainer.json` or not a git repo; `--dry-run`
reports but does not write; formatting of untouched lines preserved.
All under `$TMP` fixtures; no network; no writes to `$BLUEPRINT_ROOT`.
