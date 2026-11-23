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

A running process may still hold a physical path after a pointer advances, so
old releases are never deleted by age or by the `previous` pointer alone. On a
host (profile `host` or `minimal-pi`, outside a container), a scheduled pass
that succeeded without deferrals ends with a retention step. A directory
`versions/<component>/<version>` is a removal candidate on a run only when all
of these hold, and is kept whenever any check is unclear. Retention never
renames, stamps or deletes anything outside `versions/<component>/` and its own
stamp directories (see the end of this section):

- it is a real directory, not a symlink, and its name has no leading dot and
  no `.staging.` or `.replaced.` part, so staging and transaction trees and a
  release set aside by an in-place rebuild are never touched;
- `current/<component>` is a symlink whose own target (read once, not fully
  resolved) is exactly `../versions/<component>/<name>` or the absolute form
  of that path, and that release is a real directory, not a symlink. A
  staging directory, a deeper path, a chain through another link or another
  component's release keeps the whole component. Any `previous/<component>`
  must pass the same check;
- no symlink anywhere under `~/.local/share/aicoding` (including every
  `current/` and `previous/` pointer, relative or absolute) resolves into it
  or through it: every release that a link's resolution steps through is
  kept, not only the final target. A chain that cannot be followed to its end,
  including one that reaches a missing path, keeps every component it
  touched. One exception keeps pruning possible: a link inside a release whose
  missing step lies inside that same release directory keeps nothing, whether
  its text is relative or absolute (dangling links inside `node_modules` are
  common). Passing through its own release is not enough: a link
  `versions/pi/1.0/x -> <data>/versions/pi/1.0/../../../missing` fails
  outside the release and keeps the component. A dangling link that never touches `versions/` keeps nothing
  either, even when the text after its missing step names a release: only
  steps that really exist count. A link inside a release that resolves back
  into the same release does not protect that release;
- no file in `~/.local/bin` names it, no symlink there resolves into it or
  through it (resolved step by step like the links above, so a chain through
  an alias outside the data directory keeps every release it passes, and one
  that cannot be followed keeps the components it touched), no regular file
  that such a symlink points to names it, wherever that file lives (a target
  that cannot be read stops the run; symlinked directories are not followed),
  and `~/.local/bin` itself neither resolves into it nor reaches its final
  directory through it (its path is walked step by step too, so a parent
  directory or a link whose text passes through a release keeps it);
- no process of the user has its executable, working directory, an open file
  or directory, or a memory-mapped file inside it, and no command line of the
  user's processes names `versions/<component>/<name>` under the data
  directory, whatever that process holds open. Every occurrence in an
  argument counts on its own, so `--paths=<data>/versions/pi/1.0/bin:<data>/current/pi/bin`
  names release `pi/1.0` and component `pi`. Repeated slashes in an argument
  are read as one, so `<data>//versions/pi//1.0/cli.js` names `pi/1.0` too.
  An argument that names a component's `versions/` or `current/` path and
  also contains a `.` or `..` segment, such as
  `<data>/versions/pi/1.1/../1.0/cli.js`, keeps every version of that
  component for the run. Each entry of a `:` or `,` separated list counts as
  a path of its own, so `--paths=<data>/versions/pi/1.0/..:/opt/other` keeps
  every `pi` version too;
- no process holds a launcher lease on it (below);
- no process of the user belongs to the component without holding any of its
  releases (the unknown-release rule, below);
- no mount point lies at or below it (read from `/proc/self/mountinfo`, which
  also lists bind mounts on the same filesystem); such a version is kept with
  a warning, and so is a leftover tombstone that contains a mount point. The
  table is read again right before each rename of a release, right after it
  (before its tombstone is deleted) and before each leftover tombstone is
  deleted, so a mount that appears during the run is never deleted through;
  a table that cannot be read at that moment keeps the tree;
- the update lock (`sync.lock`) and the component's activation lock are free.

**The launcher lease.** An interpreter-run tool (for example a node tool such
as `pi`) can have an executable and a working directory outside its release,
and may rewrite its own command line. To keep them visible, every managed launcher
in `~/.local/bin` opens a read-only descriptor on the physical release
directory just before its `exec`, and the tool inherits it; the descriptor scan
then finds the release. The launcher also takes a shared `flock` on that
descriptor. The lock belongs to the open file, so it lasts while any process
still holds an inherited copy, including a detached child whose parent has
exited. Retention does not need `/proc` to see it: immediately before it
renames a release into its tombstone, it opens the release directory and
tries an exclusive, non-blocking lock, which it holds until the rename is
done. If the lock cannot be taken, the release is kept, its stamp is deleted
so the window starts again, and one line says it is held by a running
process. Every run, preview included, makes the same test for each candidate
and drops the test lock at once. A launcher that finds its shared lock refused
because retention holds the exclusive one (flock's exit status 1) closes the
descriptor, resolves `current/<component>` once more, opens and locks that
release, and runs it; it never retries a second time. A failed open or a
missing or otherwise failing `flock` never stops or delays the launcher.
The lock protects only processes that keep the inherited descriptor. Some
programs close extra descriptors in the children they start (Python's
`subprocess` does by default); for such descendants the `/proc` checks are
the fallback. Retention itself needs `flock`:
without it, the run removes nothing and says so once. Launchers
written by an older release are rewritten by the next sync, even for a
component that is already current. That refresh accepts a relative or an
absolute `current/<component>` pointer and never moves or rewrites `current`
or `previous`.

**The unknown-release rule.** A process belongs to a component when its command
line mentions `current/<component>/` or `versions/<component>/` under the data
directory, or when its `argv[0]` matches a managed launcher of that
component: `argv[0]` is compared by its full basename, while the kernel short
name (`comm`) is compared against the first 15 bytes of the launcher name (from the `current=` line of the
launchers in `~/.local/bin`). A name match does not count when the process's
own executable (`/proc/<pid>/exe`) lies outside the data directory and
outside `~/.local/bin` (given and resolved) and has that same name: its
basename equals the `argv[0]` basename, or its first 15 bytes equal the short
name. Such a process is another program that only shares the launcher's name,
for example `/usr/libexec/geoclue-2.0/demos/agent` next to the Cursor
launcher `agent`. The name match still counts when the executable has another
name (an interpreter such as `node` that renamed itself), lies inside the data
directory or `~/.local/bin`, or cannot be read.

A process that belongs to a component but holds no path under that
component's `versions/` keeps every version of the component on that run,
with one log line naming its pid, short name and component. One exception:
when the program itself is a path inside a release, the release it runs is
known. That holds only in two shapes. Either the whole `argv[0]` is a path
inside `versions/<component>/<name>/` under the data directory, or the
basename of `argv[0]` is an interpreter (`python`, `python3`, `python3.<N>`,
`node`, `nodejs`, `bash`, `sh`, `dash`, `perl`, `ruby` or `bun`) and its
very first argument, with no option before it, is such a path as a whole.
The path must have no `.` or `..` segments, and the command line must name
no `current/<component>` path. That release is kept (as every release named
on a command line is), and the process does not keep the rest of the
component. A `python3 <data>/versions/aicoding/<sha>/bin/kanban-work` helper
therefore keeps only release `<sha>`. Any other shape keeps the whole
component as before: `python3 -u <release path>`, `node --require
<data>/versions/tool/1.0/preload.js /opt/wrapper.js`, a release named only in
an option such as `--log=<data>/versions/cursor/1.1/log`, a process that also
names `current/<component>`, and one that matched the component only by name.
`deno` is left out of the list because its first operand is a subcommand
(`deno run`), so a `deno` process keeps the component.

**Processes that cannot be inspected.** A process of the user counts as
inspected only when its executable link, working directory link, descriptor
directory and memory map could all be read; one that exits during the scan
uses nothing. If the scan itself cannot be proven complete, the run removes
nothing. A live process that cannot be inspected (for example a non-dumpable
or setuid helper) stops the whole run when it is relevant: its command line
cannot be read, mentions the data directory or `~/.local/bin`, its `argv[0]`
basename or short name matches a managed launcher, or a process in its parent
chain belongs to a component or holds a path under `versions/`. The parent
chain check walks at most 64 ancestors and stops at PID 1; a chain that loops
back on itself also stops the run. The warning names only its pid and short
name. An uninspectable process that is not
relevant is ignored, so a release used only by an unrelated, uninspectable
process outside any managed process tree could still be removed.

The process scan is a snapshot. After it, retention lists the user's
processes once more. If a process that held a managed release or belonged to
a component has exited meanwhile, has become a zombie (its children may have
been reparented), or now has another start time than in the first pass (its
PID was reused), or a new process appeared whose parent is such a process,
the scan counts as incomplete: the run removes nothing and
leaves every stamp untouched. Retention's own helper processes are ignored.
This catches only what the snapshot could attribute; the launcher lock above
covers everything started through a launcher, and the `/proc` rules remain
for processes started before launchers took the lock or without a launcher.

**The observation window.** A candidate is removed only after it stayed a
candidate on every run for `AICODING_RETENTION_GRACE` seconds (default seven
days). The value is read as a decimal number of seconds, so a leading zero
never makes it octal; anything other than plain digits, an empty value
included, or more than ten years (315360000 seconds), warns and removes
nothing. The default applies only when the variable is unset. A version is due once
the time since its stamp reaches the window. The first run that sees it as a
candidate records a stamp,
`~/.local/state/aicoding/retention/<component>/<version>`, whose mtime is that
moment. `retention/` and each component directory in it are created private
(mode 0700) and must be plain directories inside the resolved state
directory. A symlinked or otherwise odd component directory keeps every
version of that component with a warning; such a `retention/` itself keeps
everything. Stamp cleanup never follows a symlink and deletes only regular
files named like a version. Before a stamp is deleted or created, an existing
entry must be a regular file; a symlink, FIFO, directory or other entry is
left in place, its version is kept, and one warning names it. A new stamp is
created exclusively, never through a link. A stamp store that cannot be
written is not trusted: a component directory the user cannot write or
search keeps every version of that component with a warning, and when
deleting or creating a stamp fails during a run, that component is kept for
the rest of the run, so a stale stamp is never honoured after its reset
failed. The candidate whose stamp could not be created is kept on that run
too, even with `AICODING_RETENTION_GRACE=0`. A run that sees the version referenced, in use, or kept by any rule
deletes its stamp, so the window starts again. Stamps of versions that no
longer exist are deleted. A run that removes nothing because a scan was
incomplete, the mount table could not be read, an uninspectable process was
relevant, or an update was running leaves every stamp untouched.
`AICODING_RETENTION_GRACE=0` removes on the first clean run, for a deliberate
manual run.

The step runs inside the pass's `run.lock` after every component finished and
only when the pass succeeded and recorded no deferrals. Removal renames the
version to a dot-prefixed tombstone in the same directory, then deletes it, so
an interrupted removal never leaves a half-deleted tree under a valid version
name; the next run finishes such a tombstone. Each removed version is logged
with its size, followed by one total. A failed removal is a warning and never
changes the pass result. A fallback worker keeps the library it loaded for
its whole life, so each of its passes loads the retention library of the
release `current/aicoding` points at, and only when every check holds:
`current/` is a plain directory, the pointer's own target is exactly
`../versions/aicoding/<name>` or that path under the resolved data
directory, `<name>` is a valid release name, the release is a real
directory, and `<release>/lib/version-retention.sh` resolves to exactly that
path under the resolved data directory and is a regular file. A symlinked
`lib/` or a symlinked directory above the release fails the last check.
Otherwise the worker uses its own copy. Workers that cannot do this are
replaced by the idle upgrade path, because their receipt lacks the
`retention2` capability: that covers workers loaded before retention existed
and workers that advertise only `retention` and always ran their own copy.
The receipt keeps its first line in the original three fields (protocol,
pid, start time), which older releases parse to verify ownership, and records
`capabilities retention2` on a second line. A one-line receipt, or one with
an older capability, still proves ownership but counts as an outdated
worker.

`AICODING_RETENTION=preview` logs, per candidate, whether it would be removed
now or the date it becomes eligible, and lists leftover tombstones a real run
would delete; it removes nothing and writes no stamp. `AICODING_RETENTION=off`
disables the step. `aicoding-auto-update --retention-preview` prints the same
preview without an update pass. Containers never prune: a rebuild replaces
their whole tree. Source snapshots under `sources/` and the Playwright browser
cache under `browser-cache/` are never pruned on any machine: retention never
renames, stamps or deletes anything there. A directory under `sources/` may be
a hand-made checkout with uncommitted work, and a running Playwright process
can select its cache through the `PLAYWRIGHT_BROWSERS_PATH` environment
variable, which retention could see only by reading other processes'
environments.

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
`ai-usage` (private `vossiman/ai-usage`) follows the newest `main` commit whose
`ci` push run passed, like bw-AICode. Its unit tests run on the fetched source
before the release is staged. The container profile selects it even before it
is installed; a host updates it only once `ai-usage` is on `PATH`. Status
never executes it, because any invocation polls the quota APIs.

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

`aicoding-status --doctor` explains each unresolved blocker in plain words
and names the command that fixes it, and lists which containers fail the
shared-config fleet check. It exits 1 while blockers remain. Its text comes
from `lib/status-reasons.json`. Every reason code the code records needs an
entry there: `tests/bats/status-reasons.bats` scans `lib/` and `bin/` for
literal codes, and `tests/bats/run.sh` fails the run when a test records a
reason the catalog does not cover.

Config results such as `config-cursor` cover multiple managed destinations.
Reconciliation records a group as current only when every destination in it
was written or already matched the blueprint. A blocked destination, an
unreadable file or a failed write keeps the group from being marked
recovered. Components not examined in a pass
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

### Releases corrupted by Python bytecode

Before this was fixed, `kanban-work` ran from the active release and let Python
write `lib/kanban_work/__pycache__/` into it. That breaks the release digest.
Activation then refused to move away from the invalid `current` release, so
every later update failed with `activation_failed` and Codex config merges
reported `invalid_blueprint_release`.

Releases no longer receive bytecode. Activation now also replaces an invalid
`current` release instead of stopping. It prints one warning and leaves
`previous` untouched, so the corrupt tree never becomes a fallback.

A container stuck before the fix still runs the old activation code, and that
code performs the switch. It heals on its own at its next pass that stages a
release it does not have yet. While staging, even old code sources the new
release's `lib/blueprint-deploy.sh` from the fresh staging clone. Only in that
context does `lib/release-heal.sh` remove bytecode written into a release after
staging. Ordinary sourcing, including `aicoding-sync --dry-run`, never touches
releases. It removes a `__pycache__` directory only when the directory is newer
than the release digest and the digest matches without it. The repository
tracks `tools/render-debug/__pycache__/`, and the digest covers that, so a
blanket delete of every `__pycache__` would corrupt every release.

An old `kanban-work` hook can write the bytecode again in the seconds before
activation. So the heal also starts one detached background healer. It repeats
the same check every half second until the staged release is active, or the
staging process has ended and the current release validates, or 180 seconds
have passed. A lock under `~/.local/state/aicoding` keeps it to one instance.

A container that already staged the newest release has nothing left to stage,
so heal it by hand. Remove only the bytecode `kanban-work` wrote, then run the
newest staged release's sync directly:

```bash
find ~/.local/share/aicoding/versions/aicoding -path '*/lib/kanban_work/__pycache__' -type d -prune -exec rm -rf {} +
~/.local/share/aicoding/versions/aicoding/<newest-sha>/bin/aicoding-sync --boot
```

Every sync activation also installs the five stable launchers
(`aicoding-sync`, `aicoding-install`, `aicoding-status`, `aicoding-select`,
`aicoding-auto-update`), just as `aicoding-install` does. Provisioning then
requests scheduler enrollment. Older installs that symlinked these launchers
into the `/tmp/aicoding` tracking clone converge without a reinstall. The
symlinks are replaced atomically and the clone's files are never written.

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
~/.aicodingsetup/fleet/consumer-versions.json
```

`AICODING_SHARED_CONSUMERS_FILE` may select another metadata file.
`AICODING_SHARED_CONFIG_ROOTS` may list colon-separated canonical roots when
the environment cannot prove the exact mount target with `findmnt`. These
overrides do not relax validation.

The current format is schema 1:

```json
{
  "schema": 1,
  "generated_at": 1789084700,
  "newest_container_started_at": 1789084640,
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

The proof must also carry a numeric `generated_at` later than a numeric
`newest_container_started_at`, and the updater's own container id (see below)
must appear among the matching root's consumers. For the exact canonical root
being changed, there must be exactly one matching root entry.
`inventory_complete` must be `true`, `expires_at` must be a future Unix epoch
value, and the consumer list must be nonempty. Every listed consumer must have
a nonempty stable ID and, for the component being gated, a semantic version and
`config_compatible: true`. Component-specific minimum versions are then
checked. Missing, malformed, duplicate, incomplete, expired, stale, or
root-mismatched evidence, or a proof that does not list this container,
defers the shared mutation.

### Who publishes the inventory

On vossisrv the dvw catalog publishes it (dvw `catalog-service/app/fleet.py`).
Only running containers count. Every 30 seconds the catalog probes every
running devpod container and writes one root entry per shared mount. A
2-second container-list watcher, which keeps running while a pass probes,
deletes the file as soon as a new container id appears, so the gate closes
until that container has been probed. A pass that finds a running container
it did not enumerate writes nothing and retries. A container that mounts a
root's host folder (or a parent of it) at another path marks that root
incomplete. The catalog removes the file when it starts and when it stops.

The updater additionally requires `generated_at` to be later than
`newest_container_started_at`, and requires its own container id (from the
`/etc/hostname` bind mount in `/proc/self/mountinfo`) among the root's
consumers. A container the catalog has not probed yet can therefore never
authorize a shared write.

Hosts without a catalog (local Linux and WSL setups) have no shared roots, and
the gate already passes local roots, so they need no inventory.

The two evidence sources answer different questions and both may be required:

- `update-results.json` proves what this local consumer successfully installed
  or attempted during a pass.
- `consumer-versions.json` proves that every known consumer of one exact shared
  root can use a proposed gated mutation.

A local success receipt cannot replace shared inventory, and shared inventory
cannot turn a failed local update into success.

## Scheduled system packages

On the container profile, every sync pass except `--dry-run` also runs
`aicoding_run_system_provision` (`lib/provision-scheduled.sh`). It is additive:
it installs what is missing and swaps binaries atomically. It never stops a
process, restarts a container, or deletes anything outside its own temp and
state files. Hosts (Mint, WSL) skip it; they never ran install-time system
provisioning. Because a machine with no recorded profile defaults to the
container profile, the step also requires a second signal: an explicit container
profile, or a container runtime (`/.dockerenv`, `/run/.containerenv`, or the devcontainer
and Codespaces variables).

What it covers is a fixed descriptor: the apt packages
`git git-lfs jq bubblewrap ripgrep parallel kitty-terminfo gh`, the tmux pin
`AICODING_TMUX_COMMIT_PIN`, frogmouth as a uv tool in `/opt/uv` with its
launcher in `/usr/local/bin`, go and uv when missing, and a setuid-root
`bwrap` (a persistent `dpkg-statoverride` 4755). The host denies unprivileged
user namespaces, so the Codex and Claude Code bubblewrap sandboxes start only
when bwrap is setuid. The sha256 of that
descriptor is the recorded `provision-system` successful version. A pass does
nothing when the recorded digest matches; otherwise it installs the pending
items and records the new digest only after every item verifies.

Limits: `sudo -n` only; apt waits at most 120 s for the dpkg lock and 900 s per
call; the tmux build runs under `nice -n 19 ionice -c3`, `make -j2` and a 1800 s
limit. The shared config writer locks are released before this step starts.

Outcomes use the normal result states: `current` or `updated` with the digest;
`blocked` with `sudo_unavailable`, `apt_lock_busy`, `apt_unavailable` or the
fallback `system_provision_blocked`; `failed` with `apt_timeout`,
`apt_install_failed`, `tmux_build_failed`, `tmux_build_timeout`,
`uv_install_failed`, `uv_install_timeout`, `frogmouth_install_failed`,
`frogmouth_install_timeout`, `go_install_failed`, `go_install_timeout`,
`bwrap_setuid_failed`, `bwrap_setuid_timeout`,
`verification_failed:<items>` or the fallback `system_provision_failed`. A
timeout on the `apt-get update` call itself is also recorded as
`apt_timeout`. Failures retry on the next pass and never block tool or
config updates. The existing `provision` record is unrelated.

A rebuilt tmux takes effect when the tmux server next starts. Until then
`aicoding-status` prints `tmux: updated, active after restart`. Nothing
restarts it. Items that exist only in the image are not handled here; status
suggests a rebuild when the image is older than its pin.
