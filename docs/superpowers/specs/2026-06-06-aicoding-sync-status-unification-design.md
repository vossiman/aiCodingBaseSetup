# aicoding `sync` / `status` — unifying the in-container install/update surface

**Date:** 2026-06-06
**Status:** design — approved direction, pending spec review.
**Scope:** spec #1 of the unification. Container-side, aicoding-only.
**Related:** `2026-06-05-update-notifier-cta-design.md` (the notifier `status`
subsumes), `2026-06-06-install-update-lifecycle-unification.md` (the broad
investigation this refines). devcontainer dedup + dvw cleanup are **spec #2**
(out of scope here).

---

## Problem

In a devcontainer there are four "install/update"-ish things, three of them named
"update", with no clear idea of what each touches:

- `install.sh` — provisions at container **create**: deploys config + installs CLIs.
- `update.sh` — runs **every boot** (`postStartCommand`): refreshes the third-party
  **binaries** (`claude`/`opencode`/`agent`) + boot auth plumbing (ssh-agent socket,
  `known_hosts`). Touches **no** config.
- `aicoding-update` — **manual**: deploys/heals the blueprint **config** files.
  Touches **no** binaries.
- `update-status` — read-only "is anything behind" notifier.

Two real defects fall out of this shape:
- **The binary/config split is accidental** — there is no principled reason one
  path does binaries and the other config. Trigger (boot vs. you) is conflated
  with behavior.
- **The boot path never reconciles config** ("Defect B") — so config drift (e.g.
  a stale `~/.bashrc.d/aicoding-env.sh` after a home reset) only heals on a manual
  `aicoding-update`, which is easy to forget. The user "kept losing" auth wiring
  for exactly this reason.

## Goals

- Collapse the surface to **two verbs the user reasons about**: "make me current"
  and "am I current".
- **Trigger becomes a flag, not a separate behavior.** create / boot / manual all
  run the *same* routine; they differ only in interactivity and throttling.
- Close Defect B: the boot path reconciles config (safely, throttled).
- Names that say the job. Kill the triple "update".
- Idempotent, fail-open, never block container start.

## Non-goals (this spec)

- dvw is **client-side, never in the container** — out of scope, and its (inert)
  entry comes **out** of the in-container registry.
- Canonical `devcontainer.json` dedup + dvw `cmd_blueprint` removal → **spec #2**.
- Client-side aicoding usage → later, separate.
- No daemon/systemd/cron. No new deploy engine (`lib/blueprint-deploy.sh` stays
  the single classify/apply engine).

---

## The model: two verbs, triggers are flags

```
aicoding sync     # make THIS container current  (changes things)
aicoding status   # am I current?                (changes nothing)
```

`aicoding sync` is one idempotent routine with three ordered steps:

1. **Auth plumbing** (fast, every run): repoint the forwarded ssh-agent socket,
   seed GitHub `known_hosts`. These genuinely must run every boot (the forwarded
   agent rotates per connection) — the *only* legitimately boot-coupled work.
2. **Config reconcile**: the manifest/classify/apply engine deploys + heals the
   blueprint config (see Self-heal below).
3. **Binaries** (throttled — network): `claude update`, `opencode upgrade`,
   `agent update`.

`aicoding status` is `sync`'s **dry-run**: run the same checks (config drift +
binary/blueprint behind-ness), report, change nothing. (This is today's
`update-status`, minus the dead dvw entry.)

**Triggers are thin wrappers around `sync`** (no independent behavior):

| Trigger | invokes | mode |
|---|---|---|
| container **create** | `install.sh` (bootstrap: ensure clone/deps) → `sync` | `--first` (provision; may prompt for secrets on a real host) |
| container **start** (`postStartCommand`) | `on-start.sh` (bootstrap: nvs-strip, PATH, fetch blueprint) → `sync` | `--boot` (non-interactive, throttled) |
| **you** | `aicoding sync` | interactive: show diffs, confirm |

`install.sh` and `on-start.sh` keep only the **bootstrap prologue** that must run
before the CLI exists (strip broken `nvs` env funcs, put `~/.local/bin` on PATH,
clone/refresh the blueprint, source the library). Everything else is `sync`.

## Naming

Recommended: a single **`aicoding <verb>`** dispatcher (consistent with the
existing `dvw <verb>` pattern) — you only ever type `aicoding`, and `aicoding`
with no args lists the verbs.

- `aicoding sync`   (was `aicoding-update`)
- `aicoding status` (was `update-status`)
- `install.sh`      (kept — the create-time bootstrap; optionally also `aicoding install`)
- `on-start.sh`     (was `update.sh` — boot bootstrap; stays a standalone fetchable
                     script because it runs before the CLI is present)

**Back-compat (one release):** keep `aicoding-update`, `update-status`, and
`update.sh` as thin shims that exec the new path, so existing `postStartCommand`s
and muscle memory don't break. `devcontainer.json` `postStart`/`postCreate` get
updated to the new names (the shim covers already-created containers).

> Open decision A (confirm in review): unified `aicoding <verb>` dispatcher
> (recommended) vs. separate `aicoding-sync` / `aicoding-status` scripts.

## Config self-heal (the Defect-A piece)

`sync` must heal blueprint-owned config that goes stale after a home reset
(manifest persists on the host mount; `~/.bashrc.d/*` is ephemeral → reverts to
base-image versions → classified `drifted_and_updating`, which reconcile currently
skips). But a stale snapshot and a genuine in-place edit are **indistinguishable
by hash**, and `install.bats:161/506` deliberately protect in-place edits to
`~/.tmux.conf` and `~/.codex/config.toml`.

Recommended resolution:
- **Blueprint-owned plumbing** (`~/.bashrc.d/aicoding-*.sh`, hooks): **always
  restore** to blueprint in every mode (incl. `--boot`), backing up to `.bak`.
  These are never meant to be hand-edited (the documented escape hatch is
  `~/.bashrc.d/local-*.sh`). This is the only class that *must* self-heal for auth.
- **User-editable overwrite files** (`~/.tmux.conf`, `~/.codex/config.toml`):
  keep today's preserve-on-drift behavior; add documented **include hatches**
  (`tmux`: `source-file ~/.tmux.local.conf`; codex: confirm include support) so
  users customize without touching the managed file. In interactive `sync`, show
  the diff and let the user choose; in `--boot`, leave them.

> Open decision B (confirm in review): the user leaned toward "restore *all*
> overwrite files". The above is the safer split (auth plumbing always heals;
> the two genuinely-editable files are preserved/confirmed). Confirm which.

## Throttling

Network steps (binary upgrades, blueprint `ls-remote`/fetch) are throttled by a
TTL (reuse the notifier's `AICODING_UPDATE_TTL`, default 6h) so `--boot` on every
start is cheap. Auth plumbing (step 1) is never throttled (must be correct now).
`status` reads cache; `sync --boot` refreshes only past TTL. Fail-open throughout.

## Registry

The tool registry (today in `update-status`) stays, but **in the container it is
aicoding-only** — drop the inert dvw entry (dvw is client-side; its marker never
exists here, so it always reports "unknown"). Adding a future *in-container* tool
is still one entry.

## Testing (bats)

- `sync` runs all three steps; `--boot` is non-interactive + honours throttle
  (stub network, assert no fetch when cache fresh).
- Self-heal: a stale blueprint-owned `aicoding-*.sh` is restored by `sync`
  (with `.bak`); an edited `~/.tmux.conf` is preserved in `--boot`.
- `status` changes nothing (dry-run parity with `sync`'s classification).
- Back-compat shims: `aicoding-update`/`update-status`/`update.sh` still work.
- Fail-open: any step failing leaves the container bootable, exit 0.
- Existing suite stays green (94 today), adjusting only tests that encode the old
  split.

## Rollout

1. **Extract `sync`**: factor the config-reconcile (from `aicoding-update`) and
   binary-refresh + plumbing (from `update.sh`) into one routine with
   `--first/--boot/interactive` modes. Wire `install.sh`/`on-start.sh` to call it.
2. **Self-heal**: force-restore blueprint-owned files in reconcile (per decision B).
3. **`status`**: rename `update-status` → `aicoding status`, drop dvw entry.
4. **Names + shims**: introduce `aicoding <verb>`, add back-compat shims, update
   `devcontainer.json`.

Each step is its own PR; the suite stays green throughout.

## Open decisions (confirm in spec review)

- **A. Naming:** unified `aicoding <verb>` dispatcher (recommended) vs. separate
  `aicoding-sync`/`aicoding-status`.
- **B. Self-heal scope:** auth-plumbing-only force-restore + include hatches
  (recommended/safe) vs. restore *all* overwrite files (your earlier lean).
