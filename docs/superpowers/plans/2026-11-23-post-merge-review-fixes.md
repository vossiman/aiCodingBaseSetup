# Fix plan: findings from the review of PRs #282 to #292

Date: 2026-11-23. Repo: aiCodingBaseSetup, `main` at `611735c`.
Status: implemented on 2026-11-23 in PRs #293, #294 and #295 (plus memory-lanes #86); the delivery later changed from six PRs to two.

Owner answers in revision 3:

- Delivery is two squash-merged PRs. PR 1 (safety) holds parts A, R and D.
  PR 2 holds parts B, E and C. The headings below still say "PR A" and so
  on; read them as parts.
- The owner is not consulted on review handback. The commissioning agent
  incorporates the fixes and cleans up. See A1 and A3.
- Memory-router read tokens no longer exist. Every environment has
  `MEMORY_WRITE_TOKEN`. See D4.

## Context

Eleven PRs merged on 2026-11-22. The rollout is healthy: CI is green on
`611735c`, the desktop activated it at 06:03 with no blockers, and devMachine
pins it. A read-only review found no blocker but several defects. This plan
fixes them in six small PRs.

Line numbers refer to `611735c`.

## What the Astra review changed

Each point was checked against the code before it was accepted.

- **A:** keeping only the branch for an unknown reviewed commit is not
  enough. The next run resets that branch (`run.sh:204,211`). The rerun guard
  in `run.sh` has the same blind spots as cleanup, so both now share one
  check. An existing test asserts the behaviour A1 removes.
- **C2:** adding columns is not enough. The sweep skips stores already
  inspected under the same rule fingerprint (`bin/redact-sessions:122-136`),
  so idle stores would keep the plaintext. C2 is now its own PR.
- **C1:** the early exit was wrong. A higher version on page 2 would lose to
  a lower backport on page 1. Downgraded and redesigned.
- **E2:** the existing compatibility gate does not cover the case. Codex
  config needs 0.148 (`lib/update-components.sh:149`), the new default needs
  0.171 (`configs/managed-config.json:40`). The fix is now required.
- **D4:** the `MEMORY_ROUTER_TOKEN` fallback is not dead. Sync supplies it
  and `tests/bats/provision.bats:467` covers it.
- **B3:** a local entry does not block a user registration
  (`tests/bats/install.bats:958`). Narrowed to confirmed duplicates.
- **Tests:** several proposed tests already pass today. Each item now says
  which test is the regression that fails first.

## Goals and non-goals

- Goal: close every finding that can lose work, leak a secret, or turn a
  one-off step into a permanent scheduled failure.
- Goal: each fix lands with a regression test that fails before the change.
- Non-goal: redesigning any of the merged features.
- Non-goal: new reason codes. None of the fixes below needs one.

## Priority order

| Order | PR | Content | Severity |
|-------|----|---------|----------|
| 1 | A | Review cleanup and rerun never drop unsaved fix work | High |
| 2 | R | Redact legacy OpenCode `session` columns, re-sweep old stores | High |
| 3 | D | Secrets store: indented key, preflight, mode | Medium |
| 4 | B | Superpowers removal runs once, MCP entries left alone | Medium |
| 5 | E | Reseed fallback for old tools, reseed log, leftovers | Low to medium |
| 6 | C | OpenCode probe and lookup follow-ups | Low |

## PR A: review-by-harness never drops unsaved fix work

Files: `skills/review-by-harness/cleanup.sh`, `skills/review-by-harness/run.sh`,
a new sourced `skills/review-by-harness/handback.sh`,
`skills/review-by-harness/SKILL.md`, `tests/bats/review-by-harness-cleanup.bats`,
`tests/bats/review-by-harness.bats`.

### A0. One handback check for cleanup, reruns and reporting

Problem: cleanup (`cleanup.sh:123-129`) and the rerun guard
(`run.sh:183-193`) each decide on their own whether a fix pass left work.
Both miss cases, and they miss different ones.

Fix: one function in `handback.sh`, sourced by both scripts. It answers
"none", "present" or "unknown". Work is present when any of these holds
against the reviewed commit:

1. A tracked diff, including commits made by the harness.
2. Untracked files that are not ignored.
3. Ignored files under `out/` (see A2).

It answers "unknown" when the reviewed commit cannot be established.
"Unknown" is treated like "present" everywhere.

### A1. Merged or closed no longer implies "incorporated"

Problem: `cleanup.sh:167` keeps a worktree with fix changes only while the PR
is open. For a merged or closed PR it removes the worktree and deletes the
branch, with or without `--archive`. `--prune` (`cleanup.sh:218`) does this
for every merged or closed PR.

The test "a merged PR's fix diff counts as settled"
(`tests/bats/review-by-harness-cleanup.bats:100`) asserts the current
behaviour.

Fix: cleanup stays automatic and never asks. For a merged or closed PR whose
worktree still holds a handback:

1. With `--discard`: removed, as today.
2. With `--archive DIR`: archived there, then removed, as today.
3. With neither: archived to a default folder,
   `<git-common-dir>/review-by-harness/archive/`, then removed.

If the archive fails, the worktree is kept and the run exits 1. The open-PR
rule is unchanged: the commissioning agent incorporates the fixes and then
passes `--discard`.

Tests. Regression (fails today): cleanup and `--prune` on a merged PR with
a fix diff and no flag remove the worktree and leave the diff in the default
archive folder. This replaces the "counts as settled" test. Guards (pass
today, kept): `--archive` and `--discard` on a merged PR.

### A2. Files under an ignored `out/` are part of the handback

Problem: both checks use `git ls-files --others --exclude-standard`
(`cleanup.sh:127,146`, `run.sh:188`), so ignored files are neither detected
nor archived. The estate convention sends deliverables to `out/`, which most
repos ignore.

Fix: ignored files under `out/` count as handback and go into
`handback-untracked.tar`. Other ignored paths are not enumerated, because
build trees would make every cleanup noisy.

Tests. Regressions: an ignored-only fix (`out/report.md`) blocks cleanup
without a flag, lands in the archive, and makes a second `run.sh` refuse.

### A3. Unknown reviewed commit keeps the worktree

Problem: for a review made before #291 there is no `reviewed-head`. If the
harness committed, `archive_round` diffs against `HEAD` (`cleanup.sh:143-145`)
and writes a 0-byte `handback.diff`, then the branch is deleted. Keeping the
branch alone would not help: the next run force-removes the worktree and
resets the branch (`run.sh:204,211`).

Fix: when the answer is "unknown", every archive also gets a `git bundle` of
the branch without upstream history, so harness commits survive. For a
merged or closed PR the A1 rule then applies: archive (default folder when
none is given), then remove. For an open PR the worktree is kept until
`--discard`, as for any handback.

Test. Regression: a worktree without `reviewed-head` and with one harness
commit, on a merged PR and with no flag, is removed, and the bundle in the
default archive folder verifies and contains the commit. On an open PR it is
kept by cleanup and refused by a second `run.sh`.

### A4. The rerun guard uses the same check and never falls back to `HEAD`

Problem: `run.sh:185-186` reads `reviewed-head` in a pipeline under
`pipefail` and `errexit`, so a missing file exits 1 with no message. Its
fallback to `HEAD` is worse: after a clean harness commit the diff against
`HEAD` is empty, the guard passes, and the worktree is reset.

Fix: the guard calls the A0 check. "Present" or "unknown" refuses the run
with the existing message. The guard no longer depends on `fix-started`
alone, so a worktree from before #291 is covered too.

Tests. Regressions: a second run refuses after a committed-only fix, and
after a fix with `reviewed-head` deleted. Both print the message.

### A5. Hand-deleted worktree directory gets an accurate message

Problem: `cleanup.sh:98` reports a registered worktree whose directory is
gone as "not made by run.sh".

Fix: say that the directory is missing and name `git worktree prune`.
Cleanup does not run it, because it would also drop unrelated registrations.

### Deliberately unchanged

A lingering harness child inherits the lock on fd 9 (`run.sh:174`) and blocks
later runs. Astra agrees: descendants may still write to the worktree, so
the lock must stay with them.

## PR R: redaction covers the legacy OpenCode session columns

Files: `lib/redact-sqlite.py`, `bin/redact-sessions`,
`tests/bats/redact-sqlite.bats`, `tests/bats/redact-sessions.bats`.

### R1. Add the three columns

Problem: in a store migrated from v1, `session.metadata`, `session.revert`
and `session.permission` exist but only `title` and `summary_diffs` are in
`OPENCODE_V1` (`lib/redact-sqlite.py:41-50`). Their `session_v2` twins are
scrubbed.

Fix: add the three columns to `OPENCODE_V1`. A store without them is already
handled: `scrub_opencode` reads the real schema and skips a missing column
(`lib/redact-sqlite.py:154-158`).

Tests. Regression: a migrated-store fixture with a distinct synthetic value
in each of the three columns reports one hit per column and keeps none of
the values. Guard: a plain v1 fixture without the columns still exits 0.

### R2. Old stores are swept again

Problem: `--sweep` only looks at stores newer than its stamp, unless the
rule fingerprint changed. The fingerprint covers the salt, the rules and the
roots (`bin/redact-sessions:122-136`), not the column list. An idle store
inspected before this fix would keep its plaintext for good.

Fix: add a sweep version constant to the fingerprint and bump it in this PR.
Every store becomes a candidate once, as it does after a key rotation.

Test. Regression: with an unchanged secrets file and an old stamp, a sweep
after the version bump inspects a store older than the stamp.

## PR D: secrets store

Files: `lib/provision-secrets.sh`,
`docs/superpowers/specs/2026-11-22-secrets-store-append-only-design.md`,
`tests/bats/provision-secrets.bats`. No change to `lib/provision.sh`, so D
and B do not overlap.

### D1. The reader accepts what the shell accepts

Problem: `_secrets_read_file` (`lib/provision-secrets.sh:23-26`) rejects a
key line with leading whitespace, and one with more than one space after
`export`. The shell that later sources the store accepts both. So
`  GH_TOKEN=abc` counts as missing, the user is prompted, Enter appends
`GH_TOKEN=`, and the later empty line wins when sourced.

Fix: strip spaces and tabs before the assignment and after `export`.

Test. Regression: stores with an indented key, a tab-indented key and
`export   KEY=` report "already set" and are not appended to.

### D2. Fail before asking, only when a write will happen

Problem: the lock and the write are checked only after all prompts
(`lib/provision-secrets.sh:117,139`).

Fix: work out the missing keys first. Only when a write will happen (store
missing, or keys missing and prompting is possible), check the lock and
writability before the first prompt. For a missing store, check the parent
directory. Non-interactive and container runs that only read are unchanged.
Give `flock` at line 69 a timeout.

Test. Regression: a read-only store with a missing key fails before any
prompt. Guard: a non-interactive run on a read-only store still succeeds.

### D3. Remove excess permissions, add none

Problem: the old rewrite ran `chmod 600` on every install. The append path
never tightens an existing store.

Fix: on a host, when the store is ours and group or other have any bit,
run `chmod go-rwx`. This keeps the inode and does not add owner write to a
`0400` store. Skipped in containers, where the mount is read-only.

Test. Regression: a `0644` store becomes `0600`, and a `0400` store stays
`0400`.

### D4. Design doc correction only

Item 8 of the design doc says the renderer is install's only consumer.
`install_claude_mcps` reads the environment too. Correct the doc.

No code change for the read token. Read tokens no longer exist and every
environment has `MEMORY_WRITE_TOKEN`, which is in the example and therefore
exported. The `MEMORY_ROUTER_TOKEN` fallbacks and the `{{MEMORY_ROUTER_TOKEN}}`
placeholder name are now dead weight. Removing them touches about 15 files
and is not part of this plan.

## PR B: provisioning stops repeating and stops overwriting

Files: `lib/provision.sh`, `tests/bats/codex-plugins.bats`,
`tests/bats/install.bats`, `tests/bats/plugins.bats`.

### B1. Superpowers removal runs once per Codex home

Problem: `install_codex_plugins` runs `codex plugin list --json` on every
sync (`lib/provision.sh:776`). An unreadable list is a failure in scheduled
mode, by design since d00c50a. A Codex release that changes the output shape
would fail every machine on every pass.

Fix: a stamp file inside the physical Codex home, so a home shared by
several containers has one stamp. It is written only when the list parsed,
every entry has a string `pluginId`, and the plugin is absent, or when the
removal succeeded. With the stamp present the list call is skipped. The link
check stays unconditional. A later manual reinstall is left alone.

Tests. Regression: a second run with a stamp makes no `plugin list` call.
The assertion names that call, because the readiness check before it also
runs `codex`. Guards: a malformed list still fails in scheduled mode, and
entries without a `pluginId` write no stamp.

### B2. A customized stdio MCP entry is left alone

Problem: `ensure_stdio_env_mcp` treats a user-scope entry as ours when the
command matches and no extra env names are found (`lib/provision.sh:444-452`).
`Args:` is never read, and the env-name pattern is uppercase only.

Fix: leave the entry unchanged when `Args:` is non-empty, since our
registration has no args. Widen the env-name pattern to
`[A-Za-z_][A-Za-z0-9_]*`. Values are still never parsed.

Tests. Regressions: on rotation, an entry with custom args and one with a
lowercase env var are left unchanged with the existing warning.

### B3. A confirmed duplicate is not a failure on every sync

Problem: when a local or project entry shadows an existing user entry,
`claude mcp add -s user` fails with "already exists" and the function
returns 1 on every sync (`lib/provision.sh:467`). A local entry alone does
not block the add, and that path must keep working.

Fix: always attempt the add. When it fails and its message confirms a
duplicate, warn that the user entry cannot be inspected behind the shadow
and return 0. Any other failure stays a failure.

Tests. Regression: shadowed user entry plus a duplicate error returns 0.
Guards: the existing local-scope test, and an add that fails for another
reason still returns 1.

### B4. Small

- Warn when the Claude uninstall of a retired plugin fails
  (`lib/provision.sh:706-713`).
- Correct the comment at `lib/provision.sh:743-745`.

## PR E: managed-config reseed and leftovers

Files: `lib/blueprint-deploy.sh`, `lib/managed_toml.py`, `lib/t3-migrate.sh`,
`root/tasks.d/20-host-packages.sh`, `configs/codex/config.toml`,
`docs/agent-release-audits.md`, matching bats files.

### E1. An old tool never receives a default it cannot run

Problem: only the reseed is version gated. A first seed
(`lib/blueprint-deploy.sh:493`) and a missing key in an existing file
(`lib/managed_toml.py:104-105`) take the current default whatever the tool
version. The compatibility gate does not help: Codex config is allowed from
0.148, the new model needs 0.171.

Fix: one step before any merge path. For each `reseeded_keys` entry whose
`requires` is unmet, replace the value at that path in the rendered source
with the newest entry of its `shipped` list. First seed, missing-key seed
and reseed then all behave, and the existing reseed moves the value once the
tool is new enough. The tool is probed only when the destination is missing
or lacks the key, or holds a shipped value.

Tests. Regressions, for Codex and for OpenCode: a first seed and a
missing-key seed with an old tool get the previous default. Guard: with a
current tool they get the new default.

### E2. A reseed says what it changed

Fix: after the write succeeded, log one line per applied reseed with
destination, key path, old and new value. Model ids are not secrets.

### E3. Shared homes: investigate

`~/.codex` is a shared root (`lib/blueprint-deploy.sh:608-613`), and the gate
probes only the local binary. An offline container with an older Codex would
inherit the new default. `_provision_tool_ready` (`lib/provision.sh:293`)
already verifies shared consumers for provisioning. Find out whether the
reseed gate can reuse it. If not, document the limit.

### E4. Small

- Reuse `_aicoding_version_at_least` for the comparison in
  `_managed_reseed_ready`. The version probe stays.
- `lib/t3-migrate.sh:101`: also require a sentinel printed after `find` ends
  normally, so a `find` killed mid-scan cannot pass as "nothing open".
- `root/tasks.d/20-host-packages.sh:30`: add `-o DPkg::Lock::Timeout=60`.
- Stale text: `configs/codex/config.toml:6-8` and
  `docs/agent-release-audits.md:245` still call the model seed-only.

## PR C: OpenCode v2 follow-ups

Files: `lib/update-opencode.sh`, `lib/update-components.sh`,
`lib/status-reasons.json`, `tests/bats/update-opencode.bats`.

### C1. Release lookup: measure first

Problem: `_aicoding_opencode_target` (`lib/update-opencode.sh:20-28`) follows
the `Link` header for up to 5 pages, unauthenticated. GitHub allows 60 calls
per hour per IP. The limit has not been hit in practice.

An early exit on page 1 is wrong: the maximum must be taken over all pages,
or a lower backport can win. So paging stays as it is.

Step 1: find out what `target_version_unavailable` does to a machine whose
OpenCode is already verified. If it only delays the update by one pass,
close this item with a comment in the code.

Step 2, only if it fails the pass or blocks the managed config: reuse the
last successful lookup for up to 24 hours when a lookup fails.

### C2. Unknown version does not fall back to the non-standalone probe

Problem: `_aicoding_opencode_config_probe` (`lib/update-components.sh:126-130`)
treats an empty version like v1 and runs `opencode debug config` without
`--standalone`.

Fix: an empty version fails the probe.

Test. Regression: a stub whose `--version` prints nothing makes the probe
fail and never receives `debug config`.

### C3. Small

`lib/status-reasons.json:46`: `archive_invalid` should also name the journal
for extraction failures.

The `opencode.pre-aicoding` backup (`lib/runtime.sh:473-478`) stays. The
activation cannot prove that a binary came from the image.

## Delivery

- One branch and worktree per PR under `.claude/worktrees/`. The six PRs
  touch disjoint source files and can run in parallel. Merge in the priority
  order above.
- Every PR: the regression test first, `bash tests/bats/run.sh` before each
  push, external binaries stubbed in the same commit, temporary repositories
  and `blueprint_copy` instead of the real checkout, explicit status
  assertions, no bare `! cmd`.
- Review: `review-by-harness` with the estate default reviewer before merge.
- After the last merge: bump the devMachine pointer with
  `scripts/update-submodules.sh`.

## Verification still owed from yesterday's rollout

1. A devbox container moving from OpenCode v1 to v2 on its next pass. Check
   `aicoding-status` in one container.
2. A real key rotation: rotate one MCP key in the host secrets file, run
   `aicoding-sync`, confirm "re-registering" and a working search. Needs the
   owner, because agents do not touch the secrets file.
3. The fleet proof line in `aicoding-status` shows "missing" on the desktop.
   Confirm whether that is expected there.

## Decisions

None are open. Taken by the overseer:

1. **A1:** cleanup of a merged or closed PR archives unapplied fixes to a
   default folder and removes the worktree. Nobody is asked.
2. **R2:** every machine re-inspects all session stores once after the
   sweep version bump, as after a key rotation.
3. `out/` only for A2, a stamp per Codex home for B1, no read-token change
   for D4, and the `pre-aicoding` backup stays.
