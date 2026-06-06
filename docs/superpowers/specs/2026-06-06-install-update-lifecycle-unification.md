# Install / update lifecycle — unification design note

**Date:** 2026-06-06
**Status:** DRAFT for discussion — no code yet. Captures the user's wish + a
proposed design to react to before implementation.
**Related:** `2026-06-05-update-notifier-cta-design.md` (the notifier this builds
on), `KNOWN_ISSUES.md`.

---

## The user's wish (in their words, paraphrased)

> "Unify this properly while we do the fix. I'm getting lost in how many update
> commands we have — `aicoding-update`, `update.sh`, `reconcile`… more??? It
> feels bloated & badly engineered. And in other repos either git (ssh) or gh
> keeps getting de-authed, which correlates timewise with the submodule/reconcile
> work."

Two intertwined goals:

1. **Stop the auth from going stale** (`gh` / git-over-ssh de-authing on
   long-lived containers and across devpod recreates) — permanently, not by hand.
2. **Unify / de-bloat** the install+update surface so there's one clear mental
   model of "what keeps my container in sync with the blueprint," with names that
   say what they do.

This note treats the auth fix as a *symptom* of the lifecycle design and folds it
into the larger unification, rather than patching it in isolation.

---

## Current state — what actually exists (the map)

There are **4** entry points with overlapping "update/install" names but **3
distinct jobs**. None of this is redundant work; it's *under-unified* and
*mis-named*.

| Component | Invoked by | When | Job | Touches config? |
|---|---|---|---|---|
| `install.sh` | `postCreateCommand` | container **create** / rebuild / recreate | Provision: deploy all managed config **and** install CLIs, tmux plugins, etc. 3 modes (below). | **Yes** |
| `update.sh` | `postStartCommand` | **every** start | Boot refresh: upgrade AI CLI **binaries** (`claude/opencode/agent`), seed GitHub host key, start ssh-agent watcher. | **No** |
| `bin/aicoding-update` | **human, manually** | on demand | Pull latest blueprint from git, re-apply managed config with the *full* bucket set behind a y/N prompt. | **Yes** |
| `bin/update-status` | bashrc + tmux | passive | **Read-only** CTA notifier. Never changes anything. | No |

Plus `dvw update` — a *separate tool in a separate repo*; not part of this set,
but shares the "update" verb and adds to the confusion.

`install.sh` + `aicoding-update` share one library: **`lib/blueprint-deploy.sh`**
(classify → bucket → apply). So config deployment has a single engine; the two
callers differ only in *which buckets they auto-apply* and *interactivity*.

**`reconcile` is not a command.** It's one of `install.sh`'s 3 modes, picked by
`detect_install_mode`:

- **first** — no manifest, no managed files → deploy everything.
- **adopt** — no manifest but files present → take ownership, then deploy.
- **reconcile** — manifest exists → re-apply a *conservative* bucket subset.

### Bucket policy by caller (the crux)

`classify_file` sorts every managed file into a bucket; the caller decides which
buckets to actually apply:

| Bucket | meaning | `aicoding-update` | `reconcile` (auto) |
|---|---|---|---|
| restore / new_file / will_update | redeploy | ✅ | ✅ |
| drifted_but_aligned | re-stamp hash, no write | ✅ | ✅ |
| merge | re-merge JSON | ✅ | ✅ |
| **drifted_and_updating** | back up file, redeploy | ✅ | ❌ **skipped** |
| to_remove | delete | ✅ | ❌ skipped |

`reconcile` skips `drifted_and_updating` **by design** (install.sh:1071-1073):
"automatic provisioning should never silently overwrite files the user has
touched."

---

## Root cause of the auth staleness

Two defects stack:

### Defect A — overwrite-owned config can't self-heal after a home reset

On a devpod **recreate**, the home dir is restored from an older image snapshot
(stale `~/.bashrc.d/aicoding-*.sh`) while the **manifest survives** (it's under
`~/.aicodingsetup`, which persists). Now for a managed snippet:

- on-disk = OLD, manifest.deployed_hash = NEW, blueprint source = NEW
- → `current != deployed && current != new` → **`drifted_and_updating`**
- → `reconcile` (the only automatic healer) **skips it** → stays stale forever.

The stale snippets are exactly the auth wiring:

- `aicoding-env.sh` (newer version) sources `~/.aicodingsetup/.secrets.env` →
  exports `GH_TOKEN` → **gh auth**. Stale 4-line version doesn't source it.
- `aicoding-ssh-auth-sock.sh` repoints the forwarded ssh-agent socket for
  non-interactive processes → **git-over-ssh auth**. Stale version lacks the
  current watcher logic.

**Evidence (this container):** `aicoding-env.sh` on disk = 4 lines / `401617a…`,
mtime Jun 1; manifest deployed_hash = `ce182d6…` (= current repo source);
`ssh-auth-sock.sh` 26 lines on disk vs 58 in repo. The manifest says "current,"
disk is stale, and nothing routine repairs it.

This is the **same bug class already fixed for the `~/.bashrc` marker block**
(blueprint-deploy.sh:416-426: ephemeral-home reset was being mis-read as user
drift). The fix was never extended to overwrite-mode `~/.bashrc.d/` files.

### Defect B — the every-boot path never reconciles config

`update.sh` (postStart, every start) refreshes *binaries* and does *boot*
self-heal, but **never re-applies managed config**. So config drift only heals on
(a) an `install.sh` recreate → reconcile, which is precisely the branch that
skips the drifted snippets, or (b) a manual `aicoding-update` you have to
remember. The drifted auth snippets fall into the one gap with no routine repair.

### Adjacent (host-side, out of repo scope)

`~/.aicodingsetup/.secrets.env` currently has `GH_TOKEN=` **empty** (other keys
populated). Even a perfect deploy exports an empty token, so gh stays
unauthenticated until the **host** puts a real PAT there. The repo fix can't
solve this; it should at minimum *detect & warn*.

---

## Design principles for the unification

1. **One engine, already true.** `lib/blueprint-deploy.sh` stays the single
   classify/apply engine. Don't add a third deployer.
2. **Idempotent + safe to run often.** Any "sync" must be a no-op when nothing
   changed and must never lose user data (back up before overwrite).
3. **Owned vs user-data is explicit.** `overwrite` mode = blueprint owns the
   file; users put their own content in `~/.bashrc.d/local-*.sh` / `merge`-mode
   files. Treat overwrite drift as recoverable, not precious.
4. **The boot path should converge config, not just binaries.** Drift must not be
   able to accumulate silently between manual runs.
5. **Names say the job.** Distinct verbs for distinct jobs; no three "update"s.
6. **Fail-open, never block container start.** Same posture as today's update.sh.

---

## Proposed design

### 1. Fix Defect A — heal overwrite-owned drift in reconcile

In `reconcile_existing_install`, auto-apply `drifted_and_updating` **for
`overwrite`-mode files only** (leave `merge` and `marker_block` on their current
paths). The apply handler already backs up the file before overwriting
(blueprint-deploy.sh:559), so a genuine in-place edit is preserved as a `.bak`
while the blueprint version is restored. This mirrors the marker-block precedent
and makes reconcile able to self-heal owned dotfiles.

*Rejected alternative:* a per-entry `owned` flag. More plumbing for no gain —
`overwrite` already encodes ownership.

### 2. Fix Defect B — converge config on the boot path

Have the every-start path run a **fast, throttled, non-interactive config
reconcile** (the same `reconcile`, now healed by fix #1), in addition to the
binary refresh. Options for *how*:

- **2a (recommended):** `update.sh` calls the reconcile path directly (against the
  already-present blueprint clone or a cheap refresh), throttled like the notifier
  (e.g. once / N hours, env-overridable), fail-open. One boot script, one sync.
- **2b:** keep `update.sh` binaries-only; add a separate boot unit for config
  reconcile. More moving parts — rejected unless 2a proves too slow.

This closes the "drift accumulates until you remember to run aicoding-update" gap.

### 3. Rename for clarity (the de-bloat)

Same code, clearer verbs. Proposed (bikeshed welcome):

| Today | Proposed | Why |
|---|---|---|
| `install.sh` | `install.sh` (keep) | genuinely the provisioner; well-known entry. |
| `update.sh` | `boot-sync.sh` (or `on-start.sh`) | it's the per-boot refresh, not "the updater." |
| `bin/aicoding-update` | `bin/aicoding-sync` | it *syncs* config to the blueprint; "update" overloaded. |
| `bin/update-status` | `bin/aicoding-status` | it reports status; not an updater at all. |

Keep thin back-compat shims (old name → new) for one cycle so existing
`postStartCommand` / muscle memory / docs don't break. `dvw update` stays as-is
(different repo); optionally note the distinction in docs.

### 4. Make the model legible

- One **lifecycle doc** (diagram) that states: *create* → `install.sh`;
  *every start* → boot-sync (binaries + throttled config reconcile); *on demand*
  → `aicoding-sync` (full, interactive); *passive* → `aicoding-status` (notify).
- Have `aicoding-status` / the boot path **warn on empty `GH_TOKEN`** (Defect B
  adjacent) so the host-side gap is visible instead of silent.

---

## What this explicitly does NOT do (scope guard)

- No new deploy engine; no daemon/systemd/cron (consistent with the notifier
  spec's non-goals).
- No change to `merge`-mode (JSON user-data) safety.
- Does not fix the host `.secrets.env` token — only detects/warns.
- Does not change devMachine submodule pinning semantics.

---

## Rollout (proposed phasing)

1. **Phase A — heal (small, high value):** fix #1 (reconcile heals overwrite
   drift) + a bats test. Ships the auth self-heal. Low risk.
2. **Phase B — converge:** fix #2a (boot path runs throttled reconcile) + tests +
   `GH_TOKEN` warning. Closes the routine-drift gap.
3. **Phase C — rename + docs:** fix #3/#4 with back-compat shims + the lifecycle
   doc. Pure clarity; no behavior change.

Each phase is its own PR. Phase A alone fixes the reported pain; B and C are the
"unify properly" the user asked for.

---

## Open questions (for the user to react to)

1. **Boot-path reconcile (fix #2):** comfortable with the every-start path
   *changing config* (throttled, backup-safe), or do you want config sync to stay
   manual and only fix the recreate path (fix #1)?
2. **Throttle for boot reconcile:** reuse the notifier's TTL knob, or a separate
   interval? Default cadence?
3. **Renames (#3):** worth the churn now, or keep names and just document the
   model? If renaming, OK with one-cycle back-compat shims?
4. **`drifted_and_updating` for overwrite:** auto-heal silently (with `.bak`), or
   heal-but-log each one so you can see what got reverted?
5. **Scope of "owned":** apply the heal to *all* overwrite files, or only the
   `~/.bashrc.d/aicoding-*.sh` auth-critical subset to start?
6. **`GH_TOKEN` empty:** want the tooling to hard-warn, or also attempt a
   fallback (e.g. detect a working `gh auth` keyring and not shadow it with an
   empty env var)?
