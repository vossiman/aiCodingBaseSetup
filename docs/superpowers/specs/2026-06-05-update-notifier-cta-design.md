# Update notifier (CTA-only) for containerized tools — aicoding + dvw

**Date:** 2026-06-05
**Status:** design approved; spec hardened (decoupled dvw marker, stale-lock
recovery, network timeout/detach, behind-semantics, two-phase rollout)

## Problem

devbox containers are long-lived and **hardly ever restart**. Today the only
thing that refreshes the installed tooling is `postStartCommand` (aicoding's
`update.sh`), so in practice the tools (aiCodingBaseSetup, dvw) silently drift
behind their `main` branches and nobody notices.

We want each container to **know** whether its installed tools are behind `main`
and **keep reminding** the user to update — without ever updating on its own.

## Goals

- Detect, per tool, whether the installed version is behind the tool's `main`.
- Surface a **persistent call-to-action** (re-shown until acted on) telling the
  user which command to run.
- Cover **aicoding and dvw**, with a registry that makes adding a tool trivial.
- Be portable (no systemd/cron dependency) and **fail-open** (never block a
  shell or tmux).

## Non-goals (explicit)

- **No self-update.** Nothing in this system applies an update automatically.
  It only ever displays a CTA; the user runs the apply command themselves.
- No exact "N commits behind" count — **behind is a boolean** (up-to-date vs
  behind). Keeps the check clone-free and uniform across tools.
- No daemon, no systemd timer, no cron.

## Behavior model

Notify-only, persistent. A throttled background **check** records each tool's
status to a cache; cheap **notifiers** (shell banner + tmux badge) read that
cache and re-surface the CTA on every new shell and continuously in tmux, until
the installed version catches up.

## Components

### 1. Tool registry

A small declarative list the notifier iterates. Each entry:

```
name           e.g. "aicoding" | "dvw"
remote         https URL for `git ls-remote` (HTTPS so it works without SSH)
branch         "main"
installed_fn   how to read the installed SHA for this tool (see §2)
apply_cmd      the CTA command string, e.g. "aicoding-update" / "dvw update"
```

Lives in the notifier (hosted in aicoding). Adding a third tool = one entry.

### 2. Version sources

- **Latest SHA:** `git ls-remote <remote> <branch>` → tip SHA. One cheap call,
  HTTPS, no clone/fetch, **wrapped in `timeout`** (see §3). Works even when the
  forwarded SSH agent is stale.
- **Installed SHA, per tool — each tool owns its own marker; the registry's
  `installed_fn` only *reads* it. No tool writes into another tool's directory:**
  - *aicoding:* manifest `blueprint_commit` (already recorded by install.sh /
    aicoding-update).
  - *dvw:* a new **dvw-owned** marker (e.g. `~/.config/dvw/version` — final path
    is dvw's choice, in dvw's own state dir), containing the dvw repo HEAD SHA,
    **written by `dvw-install.sh` at install and by `dvw update`**. dvw has no
    version awareness today; this adds it. The aicoding registry points
    `installed_fn` at that path — **dvw never touches `~/.aicodingsetup`**.

`status = behind` if `installed != latest`. Note we compare SHAs, so this
strictly means "installed **differs from the main tip**"; for containers that
only ever track main that is equivalent to "behind". `up_to_date` if equal.
If either SHA is unavailable (offline, missing marker) → `unknown` (rendered as
nothing).

### 3. Checker + cache

A script (`update-status`, in aicoding `bin/`) that, for each registered tool,
resolves installed + latest and writes:

```
~/.aicodingsetup/state/updates/<tool>.json
{ "tool":"aicoding", "installed":"a1b2c3d", "latest":"d4e5f6a",
  "status":"behind", "checked_at":"2026-06-05T12:00:00Z",
  "apply_cmd":"aicoding-update" }
```

- **Throttled:** network refresh only if the cache is older than `TTL`
  (default 6h; override `AICODING_UPDATE_TTL`). Otherwise serve cache.
- **Atomic + locked, with stale-lock recovery:** write via tmp+`mv`; a
  best-effort `mkdir` lock stops concurrent shells/panes from stampeding the
  network. **A lock older than `TTL` is treated as stale and stolen** — a
  crashed refresh must never wedge checks forever. Fresh-lock contention → skip
  refresh, serve cache.
- **Network never stalls the caller:** `git ls-remote` is wrapped in `timeout`
  (default 8s; `AICODING_UPDATE_NET_TIMEOUT`) and the refresh runs **detached**
  (backgrounded, stdout/stderr discarded). Shell startup and the tmux status bar
  only ever *read the cache* — they never block on the network.
- **Fail-open:** any error (no network, ls-remote timeout/failure, missing
  marker) leaves the prior cache intact and exits 0. Never blocks the caller.

Modes:
- `update-status --refresh`   force a (throttled) refresh, write cache.
- `update-status --banner`    print the shell banner from cache (kicks a
                              throttled background refresh first).
- `update-status --tmux`      print the compact tmux segment from cache (kicks a
                              throttled background refresh first).

### 4. Triggers (piggyback — no daemon)

- **Shell startup:** a managed bashrc snippet `configs/bash/update-notify.sh`
  (sibling of `ssh-auth-sock.sh`, deployed to `~/.bashrc.d/`), interactive
  shells only, runs `update-status --banner`.
- **tmux:** a status-line segment runs `update-status --tmux`; tmux's
  `status-interval` is the periodic heartbeat that keeps the badge fresh and
  drives the throttled refresh even in a long-lived session with no new shells.

### 5. Notifier surfaces

- **Banner** (shell start), one line per behind tool:
  `⬆ aicoding behind main — run: aicoding-update`
  Silent when everything is up to date.
- **tmux badge:** compact `⬆aicoding ⬆dvw`; empty string when all current.

### 6. Apply commands (manual; the CTA targets)

- *aicoding:* `aicoding-update` (exists).
- *dvw:* **new `dvw update`** subcommand — a thin, **user-invoked** wrapper that
  updates dvw in place (pull latest main + re-run its installer), then rewrites
  dvw's own version marker (§2). It is run manually by the user; the notifier
  never calls it. This is the "dvw should have an update mechanism" piece —
  manual, not self-updating.

After any apply, the installed SHA advances → next check flips status to
`up_to_date` → both surfaces clear themselves.

## Relationship to devMachine pinning

This concerns the **running container** only. devMachine's pinned submodule
commit remains the **floor** used to provision *new* containers; applying an
update in-container moves the container ahead of the pin (the pin is not a
ceiling). The session-end pin bump (devMachine `CLAUDE.md`) is unchanged and
independent. No conflict.

## Rollout (two phases)

The tmux badge is the fiddliest piece (slotting cleanly into the existing
**catppuccin** status line without fighting its modules), so split delivery:

- **Phase 1 — checker + shell banner.** Registry, `bin/update-status`, cache
  with throttle / stale-lock / timeout, `configs/bash/update-notify.sh` (+
  manifest entry), dvw version marker + `dvw update`. This alone delivers the
  persistent CTA (banner on every new shell). Lower risk, immediate value.
- **Phase 2 — tmux badge.** Add the `update-status --tmux` segment into the
  catppuccin status line. Purely additive; ships once Phase 1 is in use.

Each phase is its own plan/PR cycle.

## Failure & concurrency summary

- Offline / ls-remote timeout or failure → `unknown`, stale cache served, exit 0.
- Missing dvw marker → dvw shows `unknown` (not behind), never errors.
- Concurrent shells/panes → mkdir-lock; losers serve cache. A lock older than
  TTL is stolen, so a crashed refresh never permanently wedges checks.
- Background refresh is detached + `timeout`-bounded → never stalls shell/tmux.
- Every entry point exits 0 regardless of internal failure (fail-open).

## Testing (bats)

- Checker: stub `git ls-remote` + fake installed sources → assert cache JSON and
  `status` for up_to_date / behind / unknown.
- Throttle: cache newer than TTL → no network call (assert stub not invoked);
  older → refresh.
- Banner + tmux formatters: seed cache → assert exact output (behind vs empty).
- Fail-open: ls-remote returns non-zero / offline → exit 0, cache untouched.
- Stale-lock: a lock dir older than TTL is stolen and refresh proceeds; a fresh
  lock is respected (serve cache, no network call).
- Timeout: an ls-remote that hangs is killed by `timeout` → `unknown`, cache
  intact, exit 0; shell/tmux path returns immediately.
- dvw marker: `dvw-install.sh` writes dvw's own version marker; `dvw update`
  rewrites it (assert the write path; network steps stubbed).

## Scope / YAGNI

In: boolean behind-detection, throttled clone-free check, shell+tmux CTA,
registry (aicoding+dvw), dvw version marker + manual `dvw update`.
Out: counts, auto-apply, daemon, systemd, push/desktop notifications.

## Cross-repo work breakdown

- **aiCodingBaseSetup** (this repo): registry + `bin/update-status`,
  `configs/bash/update-notify.sh` (+ manifest entry), tmux status segment,
  bats tests, README/PHASES note.
- **dvw**: `dvw-install.sh` writes **dvw's own** version marker; new `dvw update`
  subcommand (rewrites it); its own tests. dvw never writes into
  `~/.aicodingsetup`. Separate PR.

Each repo ships on a feature branch → PR → merge to its `main` (per the devbox
conventions). Phase 1 = aicoding banner/checker + dvw changes; Phase 2 =
aicoding tmux badge.
