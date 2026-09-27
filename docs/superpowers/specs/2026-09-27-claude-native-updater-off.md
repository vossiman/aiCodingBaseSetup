# Turn off Claude's built-in updater under aicoding (AICODINGBASESETUP-68)

## Problem

Since the immutable runtime (2026-09-13), `~/.local/bin/claude` is an
aicoding wrapper that execs `~/.local/share/aicoding/current/claude`. Claude's
own background updater still runs inside every session. It downloads each new
release into `~/.local/share/claude/versions/`, which nothing executes. On the
devmachine container that directory held 1.8G across nine versions on
2026-09-27. The running CLI only changes when aicoding activates a release.

A spike (same date) established:

- aicoding never reads or writes that directory. `aicoding_update_claude`
  stages the native installer under a throwaway `HOME` and XDG tree and copies
  only the binary into `versions/claude/<v>` (lib/update-components.sh:1016-1061).
- `DISABLE_AUTOUPDATER=1` switches the background updater off (`claude doctor`
  reports `disabled (set by env: DISABLE_AUTOUPDATER)`). Claude's docs say it
  leaves `claude update` and `claude install` working. It also stops
  background plugin auto-update unless `FORCE_AUTOUPDATE_PLUGINS=1` is set.
- No live process executed from that directory.

## Owner requirements

1. Stop the wasted downloads.
2. Updating Claude on demand must stay a single obvious command, in containers
   and on host-profile machines (desktop, Surface/WSL), without waiting for the
   scheduler.

## Design

### 1. Scope the switch to managed launches, in the wrapper

Set the variables in the aicoding `claude` launcher, not in the managed
`configs/claude/settings.json`.

Reason: `~/.claude` is shared. In devpod containers it is a host bind mount,
and vossisrv deliberately has no aicoding install. A `settings.json` env entry
would reach any Claude started against that tree, including a natively
installed one that still depends on its own updater, and freeze it. The
wrapper only runs where aicoding manages the binary, so the scope is exact.

The generated launcher for component `claude` gains, before `exec`:

```bash
export DISABLE_AUTOUPDATER="${DISABLE_AUTOUPDATER:-1}"
export FORCE_AUTOUPDATE_PLUGINS="${FORCE_AUTOUPDATE_PLUGINS:-1}"
```

An explicit value set by the user wins. `DISABLE_UPDATES` is not used: it
would also block `claude install`, which aicoding's staging relies on.

Other components' launchers are unchanged.

### 2. `claude update` and `claude upgrade` run aicoding's updater

Both are real subcommands (`claude --help`: `update|upgrade`). When the first
argument is `update` or `upgrade`, the launcher prints one line to stderr and
execs `aicoding-auto-update --once`, which runs the same pass the scheduler
runs, including the Claude component:

```
claude: updates are managed by aicoding; running aicoding-auto-update --once
```

It resolves the updater as `$HOME/.local/bin/aicoding-auto-update`, falling
back to `command -v`. If neither exists, it says so and exits 1 instead of
calling the native updater. All other arguments pass through unchanged.

`aicoding-auto-update --once` already refuses to overlap a running pass
("update already running; request deferred"), so the command is safe to run
at any time.

### 3. "Current" means the managed release, not whatever is on PATH

Today `aicoding_update_claude` returns early when `claude --version` equals
the target. On a fresh machine the native installer usually installs exactly
that version, and `current/claude` does not exist yet, so the early return
leaves the native launcher and its updater in charge until the next Claude
release. Launchers are also only rewritten on activation, so existing
machines would keep the old wrapper until then.

The early return therefore applies only when `current/claude` already
resolves to `versions/claude/<target>`. In that case it still calls the
existing activation for the same version: `aicoding_activate_version` has a
reconcile branch for an already-active release that rewrites changed
launchers without moving `current` or `previous` (lib/runtime.sh, "Reconcile
launchers for an already-active release"); unchanged launchers are a no-op.
In every other case (native install of the same version, no managed release,
stale pointer) the normal staging and activation path runs.

### 4. Staging ignores the switch

The staged installer runs under an isolated `HOME`, but inherits the process
environment. A sync started from inside a Claude session would pass
`DISABLE_AUTOUPDATER=1` to it. Docs say that is harmless; to avoid depending
on that, the staging and version-probe invocations run with
`env -u DISABLE_AUTOUPDATER -u FORCE_AUTOUPDATE_PLUGINS`.

### 5. Remove the unused download tree

After the Claude component finishes (either outcome), remove
`~/.local/share/claude/versions` only when all hold:

- `~/.local/bin/claude` is a regular file carrying the
  `# Managed by aicoding immutable runtime.` marker;
- `~/.local/share/aicoding/current/claude` resolves to a valid release;
- no process's `/proc/<pid>/exe` resolves inside that directory.

Anything else leaves it alone, including a machine where the native binary is
still the live `claude` (first install before aicoding takes over, or a legacy
launcher). Failure to remove is a warning, never a component failure.
`~/.local/share/claude` itself and any other contents are untouched.

The first activation preserved the native launcher as
`~/.local/bin/claude.pre-aicoding`, a symlink into this tree
(lib/runtime.sh:426,456). The runtime only reads it to roll back that same
first activation (lib/runtime.sh:314); managed rollback uses
`previous/claude`. When the guards pass, cleanup first removes that backup if,
and only if, it is a symlink whose target lies inside
`~/.local/share/claude/versions`. A backup that is a regular file or points
elsewhere is kept, and the tree is then kept too, so nothing it references is
ever left dangling.

### Profiles

- `container` and `host` both run `aicoding_update_installed_components`
  during sync (lib/sync.sh:1893-1896), so both get the wrapper and cleanup.
- `minimal-pi` installs no Claude and is unaffected.
- A machine without aicoding (vossisrv) is unaffected: no wrapper, and no
  managed settings change.

## Test plan

bats (TDD, red first):

1. The generated `claude` launcher exports both variables with default 1 and
   keeps an explicit caller value.
2. `claude update` and `claude upgrade` exec a stub `aicoding-auto-update`
   with `--once` and print the notice; `claude --version`, `claude doctor`
   and `claude update-foo` pass through to the release binary.
3. A missing updater makes `claude update` exit 1 with a clear message and
   never runs the release binary.
4. Launchers of other components carry neither the variables nor the
   interception.
5. `aicoding_update_claude` on the already-current path rewrites an outdated
   `claude` launcher without changing `current`/`previous`; a native install
   of the target version with no managed release is staged and activated.
6. The staged installer does not see `DISABLE_AUTOUPDATER`.
7. Cleanup removes the directory and a `claude.pre-aicoding` symlink into it
   when all guards hold, and keeps both when the launcher is unmanaged,
   `current/claude` is missing, a process executes from inside it, or the
   backup is a regular file or points elsewhere.

Manual, after merge and one sync on a container and on the desktop host:

- `claude doctor` shows `Auto-updates: disabled (set by env: DISABLE_AUTOUPDATER)`.
- `claude update` prints the notice and completes an aicoding pass.
- `~/.local/share/claude/versions` is gone and does not reappear a day later.

## Out of scope

- IDE extensions that bundle their own Claude binary.
- Pruning old aicoding releases (retention remains conservative).
