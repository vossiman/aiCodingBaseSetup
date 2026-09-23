# Automatic updates and shared compatibility

## Immutable installed releases

Normal install and scheduled paths select exact versions before changing an
active command. Own repositories require a full `main` SHA with the configured
required workflow completed successfully at that same SHA. Supported vendor
packages use an exact requested version and their package-specific validation.

Installed artifacts live under:

```text
~/.local/share/aicoding/
├── versions/<component>/<version>/
├── current/<component>  -> ../versions/<component>/<version>
└── previous/<component> -> ../versions/<component>/<prior-version>
```

Staging happens outside the active directory. Activation prepares recovery
material and stable wrappers, then atomically publishes the `current` pointer.
Wrappers resolve that pointer once before executing a physical path. A running
process therefore keeps the release it started with while the next invocation
uses the new one. Validation failures before activation leave the active
command unchanged. If an activation mutation fails, the runtime attempts to
restore the prior state; an incomplete rollback retains its recovery directory
and reports the path.

Old release, source, and browser trees intentionally remain available because
a running process may still hold a physical path after a pointer advances.
Monitor disk use under `~/.local/share/aicoding`; do not delete retained trees
solely by age or the `previous` pointer. Liveness-aware retention is tracked in
`AICODINGBASESETUP-52`.

Source releases carry `.aicoding-version` and a retained-tree digest. Exact npm
components retain the dependency tree and validate package metadata,
entrypoints and integrity data. Codex also requires the matching
`codex-code-mode-host`; Playwright retains a package-version-specific browser
cache and verifies its runtime libraries. Cursor Agent reads the official
installer as data to select an exact Linux x64/arm64 archive. It validates
archive paths and types, probes the version under a temporary HOME, and only
then activates the managed launchers. HTTPS authenticates the vendor download;
the locally recorded digest detects later changes, not publisher authenticity.
Unavailable platforms or failed verification preserve the existing installation.

Slow selection, download and integrity operations report their phase and elapsed
time on stderr. Downloads and package hashing are timeout-bounded. Cancelling a
supervised operation stops its process group, including nested timeout commands.
Package hashing streams file contents and keeps existing integrity receipts valid.

Firecrawl staging keeps npm lifecycle scripts disabled. The audited tldjs2.3.2
exception requires exact registry provenance and matching hook/data hashes:
its optional postinstall only refreshes rules that are already bundled. Changed
hooks or versions require another audit.

Enrollment reports preserved configuration conflicts immediately. Tool-config
conflicts mark dependent provisioning deferred; ordinary local edits such as
tmux preferences remain preserved without blocking tool provisioning.

Local result receipts are stored at:

```text
~/.local/state/aicoding/update-results.json
```

Each component records its latest attempt, target, state, reason, and last
verified successful version. `failed`, `blocked`, and `conflict` attempts do
not replace that last success. These receipts describe only this consumer.
They never certify another container that happens to mount the same config.
Playwright Chromium has a separate `playwright-chromium` result so a later
browser repair or dependency failure cannot be mistaken for the earlier MCP
package outcome.

Use `aicoding-status` to read those results alongside scheduler health and
installed versions. Times are shown in the machine's local timezone. Result
timestamps describe when the updater observed something; reading status does
not refresh component availability checks. An old failure is unresolved until
there is evidence of recovery, even when a newer blueprint is active.

Config results such as `config-cursor` cover multiple managed destinations.
Reconciliation records recovery only when all relevant destinations have
compatible prerequisites and verified reconciliation outcomes. A remaining
conflict, blocked destination, failed apply, or failed manifest write prevents
that group from being marked recovered. Components not examined in a pass
retain their previous result. Aggregate `config` or `provision` success does
not by itself supersede individual blockers.

Updater attempts and completed outcomes live separately in
`~/.local/state/aicoding/auto-update/`. Manual `--once`, systemd and fallback
runs record outcomes there. `last-attempt` records when an updater controller
starts; a concurrent request refused by its run lock preserves that timestamp.
A controller that discovers a separately running sync still counts as an
attempt. Busy requests never overwrite the last completed outcome. The legacy
`last-success` file remains specific to a completed fallback pass without deferrals. An interrupted attempt has no
successful completion receipt. Status combines process identity and lock
evidence when reporting activity, and treats an overdue fallback `next-due`
as pending/retrying rather than proof of a running scheduler.

The reporting files are `last-attempt`, `run.json` with `run.lock`, and
`last-completed.json`. A fallback worker's `worker.protocol` binds its reporting
capability to its PID and process start time. Existing workers migrate after
their next scheduled sync or normal enrollment; replacement waits for active
sync work to finish and preserves the saved next-due time.

Automatic passes require no recurring install command. To request the next
check immediately, run `aicoding-auto-update --once`. Status itself never
enrolls or restarts a scheduler and never installs an update.

## Shared consumer evidence

Some config roots are bind-mounted into several containers. A writer lock
prevents simultaneous writes, but it cannot prove that an older or stopped
consumer can use a managed change. Every gated mutation to a confirmed shared
root therefore requires a separate authoritative inventory, including checks
whose component-specific minimum version is empty.

This gate covers Claude settings, Codex config, OpenCode config, all managed
Cursor config, and exact Context7/Playwright MCP configuration and Claude
registration. When the Claude settings gate is closed, the same pass also
defers Claude MCP and plugin provisioning. When the Codex config gate is
closed, it defers Codex plugin and skill provisioning. Publishing complete,
fresh inventory is therefore a rollout prerequisite for all of these shared
steps, not only for changes that introduce a new syntax version.

The default inventory is:

```text
~/.aicodingsetup/consumer-versions.json
```

`AICODING_SHARED_CONSUMERS_FILE` may select another metadata file.
`AICODING_SHARED_CONFIG_ROOTS` may list colon-separated canonical roots when
the environment cannot prove the exact mount target with `findmnt`. These
overrides do not relax validation.

The current format is schema 1:

```json
{
  "schema": 1,
  "roots": [
    {
      "shared_root": "/canonical/physical/root",
      "inventory_complete": true,
      "expires_at": 1789084800,
      "consumers": [
        {
          "id": "stable-consumer-id",
          "components": {
            "codex": {
              "version": "0.148.0",
              "config_compatible": true
            }
          }
        }
      ]
    }
  ]
}
```

For the exact canonical root being changed, there must be exactly one matching
root entry. `inventory_complete` must be `true`, `expires_at` must be a future
Unix epoch value, and the consumer list must be nonempty. Every listed consumer
must have a nonempty stable ID and, for the component being gated, a semantic
version and `config_compatible: true`. Component-specific minimum versions are
then checked. Missing, malformed, duplicate, incomplete, expired, or
root-mismatched evidence defers the shared mutation.

### Establishing the authoritative inventory

The rollout operator establishes this file from machine inventory, not from a
single enrolling container:

1. Resolve each shared config destination to its canonical physical root.
2. Enumerate every consumer of that root, including stopped containers and
   machines that are temporarily unreachable. Assign each a stable ID.
3. Verify the installed component version and the relevant config capability
   for every consumer. Keep `inventory_complete: false` while any consumer is
   unknown or unverified.
4. Write the complete root entry atomically under that shared root's writer
   lock, then set a bounded future `expires_at`. Do not include auth or config
   contents; this file contains capability metadata only.
5. Before expiry, repeat the inventory and capability checks. Advance
   `expires_at` only after dormant as well as running consumers are accounted
   for again. Expiry deliberately closes the gate.

Enrollment does not create this proof and does not mark an inventory complete.
That conservative behavior prevents one new container from declaring older or
stopped siblings compatible. It also means the shared steps listed above remain
deferred until rollout supplies the authoritative file. Ungated safe files and
updates to roots proven local continue separately.

The two evidence sources answer different questions and both may be required:

- `update-results.json` proves what this local consumer successfully installed
  or attempted during a pass.
- `consumer-versions.json` proves that every known consumer of one exact shared
  root can use a proposed gated mutation.

A local success receipt cannot replace shared inventory, and shared inventory
cannot turn a failed local update into success.
