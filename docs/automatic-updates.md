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
cache and verifies its runtime libraries. Cursor Agent remains installed but
is not automatically updated because the inspected upstream interface cannot
safely stage a requested exact version without touching the active install.

Local result receipts are stored at:

```text
~/.local/state/aicoding/update-results.json
```

Each component records its latest attempt, target, state, reason, and last
verified successful version. `failed`, `blocked`, and `conflict` attempts do
not replace that last success. These receipts describe only this consumer.
They never certify another container that happens to mount the same config.

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
