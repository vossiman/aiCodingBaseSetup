# Canonical devcontainer.json + dvw blueprint cleanup

**Date:** 2026-06-06
**Status:** design — approved.
**Scope:** spec #2 (Phases 2–3 of the unification). Pairs with spec #1
(`2026-06-06-aicoding-sync-status-unification-design.md`).

## Problem

Three diverging `devcontainer.json` copies:
- `devpod/aicoding/devcontainer.json` — no mounts, clone-based provisioning.
- `devpod/dvw/blueprint/devcontainer.json` — hardcoded host mounts; pushed by `dvw blueprint`.
- `.devcontainer/devcontainer.json` (devMachine) — hardcoded host mounts; submodule-based.

They diverge on (a) the `mounts:` block (hardcoded `/home/vossi/devpod/...`) and
(b) provisioning strategy. dvw's copy is redundant with aicoding's.

## Decisions

**Generic mounts.** Use `${localEnv:HOME}/devpod/<name>` for every bind source.
DevPod resolves `${localEnv:HOME}` on the host at provision time (not in the
container). Convention: host keeps persistent state under `~/devpod/<name>`. This
resolves to the existing `/home/vossi/devpod/...` → zero migration, portable, one
mounts block everywhere. (Bind mounts kept over named volumes because `.secrets.env`
must stay host-editable.)

```jsonc
"mounts": [
  "source=${localEnv:HOME}/devpod/aicodingsetup,target=/home/codespace/.aicodingsetup,type=bind",
  "source=${localEnv:HOME}/devpod/claude,target=/home/codespace/.claude,type=bind",
  "source=${localEnv:HOME}/devpod/opencode,target=/home/codespace/.local/share/opencode,type=bind",
  "source=${localEnv:HOME}/devpod/codex,target=/home/codespace/.codex,type=bind",
  "source=${localEnv:HOME}/devpod/cursor,target=/home/codespace/.cursor,type=bind"
]
```

**One canonical, no redundant copies:**
- **aicoding** owns the canonical `devcontainer.json` — clone-based provisioning +
  the generic mounts. Used for any project workspace.
- **devMachine `.devcontainer`** stays (legitimately different: provisions via the
  pinned submodule, not a clone) but adopts the identical generic mounts.
- **dvw**: delete `blueprint/devcontainer.json` and `cmd_blueprint`. README gets a
  one-liner that pulls aicoding's canonical file (raw URL) into a workspace's
  `.devcontainer/`, plus a note to create the `~/devpod/<name>` host dirs first.

## Out of scope

Spec #1 (sync/status). Client-side aicoding. Named-volume migration.

## Testing

- dvw: remove `cmd_blueprint` + its bats; assert dispatcher no longer routes `blueprint`.
- aicoding: the canonical devcontainer.json parses and carries the generic mounts.
- README install one-liner documented and correct.

## Rollout

- **Phase 2** — canonical aicoding `devcontainer.json` with generic mounts;
  devMachine `.devcontainer` switched to the same generic mounts.
- **Phase 3** — remove dvw `cmd_blueprint` + `blueprint/`; add README command.
  (Depends on Phase 2.)
