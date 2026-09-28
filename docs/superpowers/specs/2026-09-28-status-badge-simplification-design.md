# Status badge simplification

Date: 2026-09-28. Status: draft for review.

## Problem

After a clean rebuild on 2026-09-28, the devmachine container showed
`⬆sync ⬆provision!` in tmux, and neither badge was something the user could act on
from that container:

- `⬆sync` lit because `main` moved to `214fe3e` two minutes after the
  container installed `4a9f1d3`, while that commit's CI was still running.
  The updater refuses unqualified commits, so the badge promised an update
  that could not happen yet. It would have stayed lit until the next
  six-hour pass.
- `⬆provision!` lit because the aggregate `provision` receipt was
  `blocked — preparation deferred (deferred by claude,codex,cursor)`. The
  leaves behind it were:
  - three `managed_config_conflict` receipts. These are real, and the user
    can fix them here.
  - three `mcp-registration-claude-*: claude_consumers_incompatible`, plus
    `config-codex: mcp_exact_version_staging_unavailable` downstream of
    them. All four come from the fleet proof: 5 of 12 containers verified,
    7 idle containers probed nothing. The fix is on the host, not here.
  - `provision-claude` and `provision-codex: *_update_not_verified`,
    recorded at 10:44:44, before both tools updated successfully at
    10:45. They are stale but still listed by `--doctor`.

On top of that, a separate bug (fixed in #213) held the sync lock forever, so no
manual sync could clear anything.

This is not an isolated case. 69 of 181 commits on `main` since
2026-09-01 are `fix:` commits, and several of them chased the same badges
(#190 uv cache, #192 kanban registration, #194 doctor, #203 SIGCHLD).
Each gate is sound on its own. Together they turn every upstream wait into a
red badge the user cannot clear.

## Goal

A badge means "there is something you can do in this container, now".
Everything else is still recorded and explained by `aicoding-status` and
`--doctor`, but stays out of the status bar.

## Non-goals

- No change to CI qualification, immutable releases, or per-component
  receipts. Those work: today's boot updated Claude, Codex, Cursor and every
  MCP within two minutes.
- No change to `managed_config_conflict` semantics. It protects local edits.
- No new commands.

## Changes

### 1. `⬆sync` compares against the CI-qualified SHA

`bin/aicoding-status` `_refresh_all` caches the raw `git ls-remote` of
`main` (`bin/aicoding-status:208`), so the badge lights for every merge.

Change: `_refresh_all` caches the SHA that `aicoding_select_ci_sha`
(`lib/ci-selector.sh:123`) returns, the same selection the updater applies.
If selection fails (offline, API limit), keep the prior cached value, as
today. The badge then lights only when an update exists that the updater
would actually install.

### 2. Fleet proof stops blocking; it becomes a doctor warning

Today `_aicoding_shared_consumers_allow` (`lib/update-components.sh:282`)
refuses any write to a shared root (`~/.claude`, `~/.codex`, `~/.cursor`)
unless the dvw catalog's proof is fresh, complete, lists this container,
and every consumer is compatible. One idle container that probes nothing
freezes shared config and Claude MCP registrations on every container.
Any container start makes the proof stale.

What it guards against: a new shared config written by one container that
an older tool in another container cannot read. The wiki records no incident
of that breakage; the risk is preventive. It is also short-lived: running
containers update themselves within six hours, and a stopped container
catches up when it starts.

Change:
- The shared-root write requires only that **this** container's own tool
  passes its minimum-version check (already done by
  `_provision_tool_ready`).
- The fleet proof is still read. When it is incomplete, or a consumer
  reports an incompatible version, `aicoding-status` prints the existing
  "Fleet proof" section and `--doctor` lists the lagging containers. It
  records no blocker and lights no badge.
- `claude_consumers_incompatible` and `*_shared_consumers_incompatible`
  stop being recorded. Their `status-reasons.json` entries go away with
  them.

**Decision for the user:** this accepts that an old container may, for up
to one updater interval, read a config written for a newer tool. The
alternative is to keep the gate but ignore consumers whose last probe is
older than N minutes (treat idle containers as absent). That keeps the
protection but keeps the dependency on dvw's catalog and adds another
threshold. Recommendation: remove the gate.

### 3. Tool steps record success, so stale blockers clear

`_provision_tool_ready` (`lib/provision.sh:290`) only ever writes
`provision-<tool>` as blocked (`_provision_tool_blocked`, `:128`). A later
success writes nothing, so the blocked receipt remains until something
overwrites it.

Change: on success, `_provision_tool_ready` records
`provision-<tool>: current / verified` with the tool version. `--doctor`
then shows only blockers that are still true.

### 4. `⬆provision!` lights only for blockers you can fix in this container

`_behind_extra` (`bin/aicoding-status:165`) shows `provision-blocked` for any
`blocked|failed|conflict` aggregate. `preparation_deferred` just aggregates
other components.

`lib/status-reasons.json` already classifies every reason as
`ok | wait | action` (doctor spec, 2026-09-26). Change: the badge lights
when at least one unresolved leaf receipt for the active release has a
reason of kind `action`. `wait` reasons and the `preparation_deferred`
aggregate never light it. `action` is tightened to mean "you can act in
this container". Reclassifications:

| Reason | Today | New |
|---|---|---|
| `*_update_not_verified` | action | wait (resolves next pass) |
| `manual_rebuild_required_*` | action | wait (the ⬆rebuild badge covers it) |
| `claude_consumers_incompatible`, `*_shared_consumers_incompatible` | action | removed by change 2 |
| `mcp_exact_version_staging_unavailable` | action | follows its root cause, see 5 |

Everything else keeps its kind. `managed_config_conflict` stays `action`.
The static reason scan already requires every reason to be catalogued, so a
new reason cannot ship without deciding whether it badges.

### 5. `mcp_exact_version_staging_unavailable` names its cause

`lib/update-components.sh:137-178` returns this one reason whether the
package is missing, failed to build, or is merely not fleet-approved. On
2026-09-25 it hid the root-owned `~/.cache/uv` bug (#190).

Change: record the underlying component's reason in the receipt's `detail`
(for example `mcp-kanban: exact_package_not_staged`). `--doctor` prints it.
Actionability follows the underlying reason. With change 2, the fleet case
disappears.

## Testing

- `status-report.bats`: `⬆sync` stays dark when `ls-remote` is ahead
  but the CI selector returns the installed SHA; lights when the selector
  moves.
- `update-components.bats`: a shared-root write proceeds with an incomplete
  fleet proof when this container's tool is compatible; status shows the
  fleet warning; no `*_consumers_incompatible` receipt is written.
- `provision.bats`: a blocked `provision-claude` receipt becomes
  `current` after a later successful pass.
- Badge: a result file with only `*_update_not_verified` and
  `preparation_deferred` shows no `⬆provision!`; adding one
  `managed_config_conflict` shows it.
- `status-reasons.bats`: the reclassified kinds are asserted.
- Replay today's `update-results.json` (2026-09-28 devmachine) as a
  fixture: after changes 1 to 4 the tmux output is `⬆provision!` for the
  three config conflicts only, and nothing else.

## Rollout

One PR per change, in order 3, 1, 4, 5, 2. The first four only change what is
reported. Change 2 is the only one that changes behaviour, so it lands last
and alone. Each change is small enough to revert on its own.
