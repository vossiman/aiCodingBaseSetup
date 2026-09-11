# Task 3 report: support, prerequisites, documentation, and regression readiness

## Result

Status: `DONE_WITH_CONCERNS`.

Task 3 is implemented. The new Codex state directory is protected by the
agent file guard, Python 3.8 or newer is enforced across planning and install
prerequisites, container bootstrap installs the package when required, hosts
retain manual installation, and user documentation describes the final smart
merge behavior and rollout limits.

Task 3 focused and affected tests pass. Full merge readiness remains gated on
an independent green full-suite run because the repository's known
AICODINGBASESETUP-48 parallel harness race reproduced in both final full runs.
No harness code was changed in this task.

No live config, receipt, settings, secret store, or private key was read or
changed. No runtime dependency download, deployment, parent pointer update,
branch switch, push, PR, merge, or ticket creation was performed.

## Implementation

- `configs/claude/hooks/bw-deny-files.sh` treats
  `~/.codex/.aicoding-sync` and every child as both a sensitive directory and
  an unconditional denied path. `DENY_PATHS` is evaluated before `DIR_ALLOW`,
  so names such as `manifest.json` and `config` cannot bypass the state guard.
- `lib/provision-system.sh` uses a real-output Python version probe. A no-op
  executable named `python3` cannot satisfy it. Container bootstrap requests
  the `python3` apt package when the runtime is absent or older than 3.8, then
  the prerequisite gate verifies it. The host gate prints the existing manual
  apt instruction and never auto-installs.
- `lib/codex-merge.sh` performs the same Python 3.8 capability probe before
  rendering or planning. Missing or old runtimes return the value-safe
  `runtime_unavailable` result and cannot fall through to overwrite behavior.
- `bin/aicoding-sync --help` explains the explicit clean-checkout operation
  that returns a local-provenance receipt to `origin/main` tracking.
- `README.md`, `configs/codex/config.toml`, and the design spec document:
  user-owned existing model/effort/projects; unchanged `gpt-5.6-sol` seed
  default; silent local-only settings; true three-way conflicts; unattended
  local preservation without acknowledgment; conservative adoption;
  fingerprints-only receipt state; schema 2 behavior; no planning-time
  runtime install; return to tracking; old-writer rollout limits; and the
  inability of fingerprints to recover preferences from a physically deleted
  config.
- Legacy end-to-end test clones now provide real origin metadata and commit
  simulated blueprint changes. This exercises the real provenance path rather
  than weakening it or relying on no-op Git commands.

## TDD evidence

Focused RED before production changes:

```text
$ bash tests/bats/run.sh secrets-deny-hook install-host install \
    --print-output-on-failure \
    --filter 'Codex sync state|Python older than 3.8|auto_install_prereqs installs python3'
1..6
0 passed, 6 failed
```

The failures showed that allow-name state files, native Glob, shell globs and
relative reads were allowed; host and container gates accepted old Python;
and container bootstrap did not request Python.

The sync-before-provisioning RED was separate:

```text
$ bash tests/bats/run.sh blueprint-deploy --print-output-on-failure \
    --filter 'reports runtime_unavailable for Python older'
1..1
not ok 1 Codex smart planning reports runtime_unavailable for Python older than 3.8
```

Focused GREEN after the narrow changes:

```text
$ bash tests/bats/run.sh secrets-deny-hook install-host install blueprint-deploy \
    --print-output-on-failure \
    --filter 'Codex sync state|Python older than 3.8|auto_install_prereqs installs python3|reports runtime_unavailable for Python older'
1..7
7 passed, 0 failed

$ bash tests/bats/run.sh install-host --print-output-on-failure
1..23
23 passed, 0 failed
```

The help behavior also followed RED/GREEN:

```text
$ bash tests/bats/run.sh aicoding-sync --print-output-on-failure \
    --filter 'help documents the local blueprint option'
1..1
not ok 1 aicoding-sync help documents the local blueprint option

$ bash tests/bats/run.sh aicoding-sync --print-output-on-failure \
    --filter 'help documents the local blueprint option'
1..1
ok 1 aicoding-sync help documents the local blueprint option
```

Minimum-runtime and syntax checks:

```text
$ bash -n configs/claude/hooks/bw-deny-files.sh lib/provision-system.sh \
    lib/codex-merge.sh bin/aicoding-sync
exit 0

$ CODEX_MERGE_TEST_PYTHON=/tmp/codex-smart-sync-python.htekBY/install/cpython-3.8.20-linux-x86_64-gnu/bin/python3.8 \
    bash tests/bats/run.sh codex-merge --print-output-on-failure
1..1
ok 1 codex merge Python behavior suite in 7463ms
```

The Bats wrapper invokes 38 Python unittest cases in that minimum-runtime
test.

## Full-suite evidence

The first required default-parallel run exposed only feature-related legacy
fixture gaps:

```text
$ bash tests/bats/run.sh --print-output-on-failure
925 passed, 12 failed, 7 skipped, 944 total
```

The 12 failures were:

- `aicoding-sync: reads existing manifest and prints blueprint commit`
- `aicoding-sync --blueprint uses a dirty local checkout without fetch or reset`
- `aicoding-sync: 'n' answer preserves the existing managed config`
- `aicoding-sync --yes: busts stale aicoding-status cache when commit advances`
- `aicoding-sync --dry-run: leaves aicoding-status cache untouched`
- `aicoding-sync --yes: records the FULL blueprint SHA (badge comparison needs >=12 chars)`
- `aicoding-sync does not re-exec when the clone is already current`
- `e2e: first install -> modify -> blueprint changes -> aicoding-sync applies`
- `regression: aicoding-sync does not delete ~/.bashrc`
- `regression: aicoding-sync preserves placeholder substitutions`
- `regression: to_remove removes orphan but not ~/.bashrc`
- `regression: aicoding-sync restores missing managed file cleanly`

All used partial clones without an `origin`, or left simulated tracking-clone
changes dirty. The engine correctly returned `invalid_blueprint_clone` or
`dirty_tracking_clone`. After the first fixture correction pass:

```text
$ bash tests/bats/run.sh aicoding-sync e2e regressions --print-output-on-failure
16 passed, 7 failed, 0 skipped, 23 total
```

All 9 e2e/regression cases passed in that combined run. The 7 remaining thin
CLI fixture failures were resolved by committing simulated blueprint edits and
using `remote set-url` when refresh tests replace the setup origin. The final
focused result was fully green:

```text
$ bash tests/bats/run.sh aicoding-sync --print-output-on-failure
1..14
14 passed, 0 failed
```

A later default-parallel full run exercised all 944 cases. One unchanged
`memory-hint.bats` one-shot HTTP server waited indefinitely after its client
timed out. After validating its PID, parent, state, and task-worktree cwd, only
that fixture server was terminated so Bats could aggregate the completed run:

```text
$ bash tests/bats/run.sh --print-output-on-failure
936 passed, 1 failed, 7 skipped, 944 total
not ok 548 non-conforming router JSON (array instead of object): no output, exit 0 in 230778ms
```

The unchanged failing case passed immediately in isolation:

```text
$ bash tests/bats/run.sh memory-hint --print-output-on-failure \
    --filter 'non-conforming router JSON'
1..1
ok 1 non-conforming router JSON (array instead of object): no output, exit 0 in 251ms
```

Per controller direction, one bounded-parallel full verification reduced the
default 12 workers to 4 to avoid blind repetition under the known harness
contention. The same memory server race recurred. Only the revalidated fixture
server was terminated; the remaining workers completed. The existing SQLite
timing race tracked by the same ticket also fired:

```text
$ bash tests/bats/run.sh --jobs 4 --print-output-on-failure
935 passed, 2 failed, 7 skipped, 944 total
not ok 548 non-conforming router JSON (array instead of object): no output, exit 0 in 294201ms
not ok 641 sqlite: busy db is deferred, not corrupted, and scrubbed by the next sweep in 3888ms
```

AICODINGBASESETUP-48 already tracks both parallel harness races. The controller
added this reproduction there, so this task did not create a duplicate ticket
or broaden into harness repair. Final merge readiness remains blocked on an
independent green full run, such as CI.

## Process and diff inspection

After the default-parallel aggregate and isolated reproduction:

```text
no bats, parallel, or python3 process remains with the task worktree as cwd
```

No broad cleanup was performed. Only the two individually validated,
test-owned one-shot server processes were terminated. Pre-existing long-lived
MCP processes and every unrelated worktree process were untouched.

`git diff --check` was clean before full verification. A final post-report
diff/status receipt is recorded immediately before the task commit.

## Files

- `configs/claude/hooks/bw-deny-files.sh`
- `lib/provision-system.sh`
- `lib/codex-merge.sh`
- `bin/aicoding-sync`
- `configs/codex/config.toml`
- `README.md`
- `docs/superpowers/specs/2026-09-11-sync-smart-diff-design.md`
- `tests/bats/secrets-deny-hook.bats`
- `tests/bats/install-host.bats`
- `tests/bats/install.bats`
- `tests/bats/blueprint-deploy.bats`
- `tests/bats/aicoding-sync.bats`
- `tests/bats/e2e.bats`
- `tests/bats/regressions.bats`
- `.superpowers/sdd/2026-09-11-sync-smart-diff/task-3-report.md`

`.github/workflows/tests.yml` was inspected but did not need a change. Its
Ubuntu runner already supplies a supported Python runtime and the full Bats
job invokes real engine paths.

## Self-review and remaining limits

- No Task 3 implementation blocker was found. Guard precedence, host policy,
  no-op-runtime rejection, value-safe error mapping, and fixture provenance
  were checked directly.
- The current model seed remains `gpt-5.6-sol`. This task does not change a
  fleet default to Astra. Existing model and effort values remain user-owned.
- Every old sibling writer sharing `~/.codex` must be upgraded before the
  receipt and advisory lock provide end-to-end protection.
- Fingerprints provide equality history only. They cannot reconstruct personal
  preferences or trust from a physically deleted config.
- Full regression readiness is not yet proven green due solely to the known
  AICODINGBASESETUP-48 test-harness races described above. Task review and CI
  must retain this gate; this report does not claim merge readiness.
- Main advanced in another worktree during verification. This task did not
  fetch, rebase, merge, switch branches, or incorporate that unrelated change.
