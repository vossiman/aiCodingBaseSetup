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

### Defect C — ssh-agent *absence* is not surfaced or self-recovered

Distinct from the stale-snippet bug. On a **remote** devbox, when **all clients
detach** (no terminal/IDE attached anywhere), there is **no forwarded ssh-agent
at all** — every `/tmp/auth-agent*/listener.sock` is a dead file (`Connection
refused`). Observed live this session: the watcher (`aicoding-ssh-agent-watch`)
*was running*, `~/.ssh/agent.sock` pointed at the newest socket, but nothing was
listening, so git-over-ssh failed with `Permission denied (publickey)`.

This is a *legitimate steady state*, not a fault — but today it manifests as an
opaque auth failure. Requirements this implies:

- The watcher / snippet must distinguish "agent present but socket rotated" (→
  repoint, today's job) from "**no live agent anywhere**" (→ leave a clear signal,
  don't present a dead symlink as valid).
- On **client reattach**, recovery must be automatic (the watcher repoints to the
  newly-forwarded socket) — verify the running watcher actually does this with the
  *current* snippet version (note: this container's deployed watcher snippet is
  the stale one per Defect A, so its reattach behavior may be the old logic).
- `aicoding-status` should report ssh-agent reachability (live / rotated / absent)
  so "why is git asking for a password" has a one-glance answer.

### Adjacent — `GH_TOKEN` (mostly a non-issue; verified)

`~/.aicodingsetup/.secrets.env` has `GH_TOKEN=` **empty**. Re-checked, this is
**not** a real problem and is **decoupled from git auth**:

- **Git is unaffected.** Remotes are `git@github.com` (ssh); no git operation
  reads `GH_TOKEN`. The recurring git deauth is Defect A/C (ssh), not the token.
- **Empty doesn't shadow.** Verified: `GH_TOKEN=` empty → gh treats it as *unset*
  ("not logged into any host"); only a non-empty value is consulted. So an empty
  token never overrides a keyring/hosts.yml login — it's simply absent.
- **Only the `gh` CLI cares** (`gh pr create`, `gh api`). With no keyring either,
  gh is just unauthenticated. If PRs are made via the web, gh is not needed and
  the empty token costs nothing.

**Conclusion:** out of scope for the auth-staleness fix. *Optional:* if headless
`gh` is wanted, the host populates a real PAT in `GH_TOKEN`. Tooling could note
"gh unauthenticated" in `aicoding-status` as info, but no hard warning is
warranted. **Priority stays on the ssh path (Defect A + C).**

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

> ⚠️ **Tension discovered during review — this is the real decision.** The current
> "skip `drifted_and_updating`" behavior is **deliberate and tested**:
> `install.bats:161` ("does not auto-resolve drifted_and_updating") edits
> `~/.tmux.conf` in place and asserts reconcile preserves it **byte-for-byte with
> no `.bak`**; `install.bats:506` asserts the same for an edited
> `~/.codex/config.toml`. So reconcile intentionally **preserves in-place user
> edits to overwrite files.**
>
> **The crux:** a home-reset *stale snapshot* and a *genuine user edit* are
> **indistinguishable by content hash** — both yield `current != deployed &&
> current != new` → `drifted_and_updating`. Any fix must choose how to tell them
> apart (or decide it doesn't care). This is a product-behavior call.

Options, least → most surgical:

- **(a) Heal all overwrite drift (revert with `.bak`).** Auto-apply
  `drifted_and_updating` for overwrite files in reconcile. Simplest, but
  **reverses the tested philosophy** — genuine in-place edits get reverted (kept
  as `.bak`). Breaks install.bats:161/506 (they'd be rewritten to assert the new
  behavior). Pick this only if "overwrite = blueprint always wins" is the desired
  contract.

- **(b) Provenance discriminator (most precise).** Heal only when the on-disk
  content matches a **known prior blueprint version** of that file (provably stale
  blueprint output), and otherwise preserve (genuine user edit). The 4-line
  `aicoding-env.sh` *is* an older blueprint version → healed; arbitrary user
  content is not → preserved. Requires either a `deployed_hash_history[]` per file
  in the manifest, or hashing the source file's git history in the blueprint
  clone to recognize "this is an old me." Keeps the preserve-edits guarantee
  intact while fixing the auth case. More code.

- **(c) Owned-set carve-out (recommended for the immediate fix).** Declare the
  auth-critical snippets (`~/.bashrc.d/aicoding-*.sh`) as **force-managed**:
  reconcile always restores them to blueprint (with `.bak`), users put their own
  shell config in `~/.bashrc.d/local-*.sh` (already the documented convention).
  Everything else keeps today's preserve-edits behavior, so install.bats:161/506
  stay green. Smallest blast radius; fixes the reported pain; honest about the
  one class of files that genuinely isn't user-editable.

**Recommendation:** ship **(c)** as Phase A (narrow, no philosophy reversal,
existing tests stay valid), and consider **(b)** later if you want *every*
overwrite file to self-heal after a recreate without losing edits. Avoid **(a)**
— it throws away a deliberate guarantee.

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
4. **Defect A discriminator (the key call):** which option — (a) heal all
   overwrite drift and accept reverting in-place edits (reverses tested
   behavior), (b) provenance discriminator that heals only provably-stale
   blueprint output (preserves edits, more code), or (c) force-manage just the
   `~/.bashrc.d/aicoding-*.sh` auth set (recommended, narrow, keeps existing
   tests green)?
5. **Logging:** when reconcile heals/reverts a file, just back up to `.bak`, or
   also print each reverted file in the summary so nothing changes silently?
6. **`GH_TOKEN`:** confirmed mostly a non-issue (git unaffected; empty doesn't
   shadow; only the `gh` CLI cares). OK to drop it from scope and just surface
   "gh unauthenticated" as info in `aicoding-status` — or do you want headless
   `gh` to work (→ you add a PAT to the host secrets)?
