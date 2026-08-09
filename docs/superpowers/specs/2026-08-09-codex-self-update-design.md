# Codex self-update in `_sync_binaries`

**Date:** 2026-08-09
**Status:** accepted
**Scope:** close the codex gap in the CLI self-update path
(`_sync_binaries`, `lib/sync.sh`). Follow-up flagged in
`2026-08-06-custom-base-image-design.md` (seed-CLI caveat + Rollout).

## Problem

`_sync_binaries` self-updates claude, opencode, and cursor-agent on every
`aicoding-sync` (throttled to 6h on `--boot`). Codex has no `update`
subcommand, so the baked seed (~258MB, `~/.local/bin/codex`) stays at the
image digest's build date until the digest is bumped. With the weekly image
build dropped (PR #57), codex would otherwise go stale indefinitely.

## Design

New `_update_codex` in `lib/sync.sh`, appended to `_sync_binaries` — it
inherits the existing 6h boot throttle and runs on every manual sync,
exactly where the other CLIs update. `ensure_codex` (install path) is
unchanged: install short-circuits on presence for all CLIs; sync owns
freshness.

**Version gate** (avoids re-downloading 258MB when current):

- installed: last word of `codex --version` (today: `codex-cli 0.147.0`).
- latest: `curl -fsSL --max-time 10
  https://registry.npmjs.org/@openai/codex/latest | jq -r .version`
  (verified same release channel as the chatgpt.com installer).
- Equal → done, silent.

**Update path** (versions differ):

1. Re-run the official installer — `curl -fsSL
   https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh` —
   the same invocation `ensure_codex` and the image bake use.
2. If `~/.codex/bin/codex` is now executable, **force** `ln -sf` into
   `~/.local/bin/codex`. Unlike `ensure_codex`'s probe (which only links
   when `~/.local/bin/codex` is absent), the force is required so the new
   binary replaces the stale baked seed instead of being shadowed by it.
   Side benefit: `~/.codex` is the shared host bind mount, so the updated
   binary reaches all containers and survives recreates.
3. **Post-verify:** re-probe `codex --version`; mismatch → error (below).

**Failure behavior — never silent, never fatal.** Every abnormal outcome
prints an error line to stderr but returns 0 (sync/boot must not break,
matching the rest of the pipeline):

| Case | Behavior |
| --- | --- |
| codex not installed | silent skip (nothing to update) |
| `AICODINGSETUP_SKIP_NETWORK` set | silent skip (test env; standing rule for new network calls) |
| versions equal | silent no-op |
| curl/jq missing, registry probe fails, or `codex --version` unparseable | error: `codex update check failed (<cause>) — codex may be stale` |
| installer exits nonzero | error: `codex update failed — still at <installed>` |
| post-verify mismatch | error: `codex updated but version is still <X> (expected <Y>)` |

Known coupling, accepted: the two version formats (`codex-cli X.Y.Z`,
npm `version` field). If either changes shape, the parse guard fires and
the error line makes it visible on the next sync — no silent rot.

## Tests (bats, per CLAUDE.md standing rules)

Stub `codex` and `curl` in the same commit that adds the reference.
Cases: versions equal → installer not invoked; mismatch → installer runs
and symlink is forced over an existing real file; registry probe failure →
error line, exit 0; `SKIP_NETWORK` → no network attempted. Assertions via
`run`/`if-then-false`, never bare `!`.

## Docs

Update `2026-08-06-custom-base-image-design.md` (lifecycle table row +
seed-CLI caveat) to point at `_update_codex` instead of "no codex
self-updater". The related note in PR #57's workflow header lands on its
own branch; reconcile whichever merges second.
