# Task 2 report: native registry, normalizer, bridge, and legacy translator

## Result

Implemented the Task 2 setup-side boundary from base `9881a685df1556683fba6aafc1d9792f1af802a0`:

- `kanban-work --json bind|lookup|execute|instructions`, with bounded JSON input and shell-free helper calls.
- A shared canonical normalizer for every frozen mutating tool shape, exact client-version qualification, and a loopback plus fake-token-only test matrix override.
- A user-only SQLite registry for native executions, one-use 60-second permits, claims, operations, and generation-fenced queue indexes.
- Authoritative session/ticket refresh before any lifecycle cache update, including replay responses, plus stale/untrusted failure recovery.
- An exact legacy `kanban-post --done ... --evidence ... [--reference ...]` parser that mints a completion permit only from the adapter-supplied native identity and current claim.
- Container, host, and sync installation of the executable `kanban-work` symlink.

The store records the trusted `run_generation` on permits, operations, claims, and queued events at ingress. `Store.enqueue()` rejects a queued event whose captured generation differs from its handle's execution generation, so a later adapter cannot retarget deferred work by looking up a newer run.

No native adapters, queue delivery/supervision, MCP package, qualification artifact, live configuration, credentials, or board writes are included in this task.

## RED evidence

Command:

```text
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v tests.python.test_kanban_work tests.python.test_kanban_work_legacy
```

Initial result: exit `1`, two import errors, as intended before implementation:

```text
ERROR: test_kanban_work (unittest.loader._FailedTest.test_kanban_work)
ModuleNotFoundError: No module named 'lib.kanban_work'
ERROR: test_kanban_work_legacy (unittest.loader._FailedTest.test_kanban_work_legacy)
ModuleNotFoundError: No module named 'lib.kanban_work'
FAILED (errors=2)
```

The first combined Bats slice also exposed that Python 3.14 rejects the wrapper's absolute discovery start directory when paired with `-t`. The new wrapper failed while the remaining installer/host/sync cases passed. Removing the unnecessary `-t` made discovery portable without changing the tests.

## GREEN evidence

Final focused command:

```text
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v tests.python.test_kanban_work tests.python.test_kanban_work_legacy && bash tests/bats/run.sh kanban-work && bash -n install.sh install-host.sh lib/provision-integrations.sh lib/sync.sh && git diff --check
```

Result: exit `0`.

```text
Ran 35 tests
OK
1..1
ok 1 kanban-work Python registry, bridge, and legacy translator tests
```

The focused installer command was:

```text
bash tests/bats/run.sh kanban-work install install-host sync
```

Its installer, host, and sync cases (`2..202`) passed; after the wrapper correction, `bash tests/bats/run.sh kanban-work` passed independently. The final full suite below covers the corrected wrapper and all installer paths together.

Required full-suite command:

```text
bash tests/bats/run.sh
```

Result: exit `0`, `1129/1129` passed. The closing output was:

```text
ok 1126 branch worktree preserves dirty shared checkout and ignores only worktree directory
ok 1127 already linked worktree is reused for the same branch and refuses a different branch
ok 1128 existing path and invalid branch never overwrite files
ok 1129 explicit base is honored and missing base is an error
```

The full run was captured by the execution harness as session `42976`; it was not repeated solely to create a second log file.

## Behavioral coverage

The 35 Python tests cover:

- exact default bytes for all frozen tool shapes; unknown keys, types, UUIDs, enums, and bounded IDs;
- exact qualification matching and the restricted test override;
- multiple sessions in one checkout, peer refusal, real file-backed shared-process behavior, and explicit/environment handle hints that cannot prove native identity;
- permit digest matching, one-use replay refusal, the 59/60-second TTL boundary, a real SQLite two-consumer race, and atomic sequence allocation across connections;
- 0700/0600 modes, seven-day cleanup, sensitive-field absence, schema-creation failure recovery, and ingress-generation queue fencing;
- backend identity injection, stable or explicit operation IDs, cross-repo create, checkout and label-only rebind, live-claim refusal, and unchanged cache after failed rebind;
- fresh and replayed register/rebind/claim/checkpoint/release/complete/end receipts, exact current-state response validation, authoritative refresh ordering, SQLite refresh rollback, stale-cache recovery, backend identity/capability invariants, and old-receipt non-resurrection;
- every accepted and rejected boundary of the legacy shell grammar, including literal dollars only within single quotes and denial before identity lookup for compound commands.

## Self-review

- Public payload shapes reject unknown fields. Local handles require canonical UUIDs; backend session, claim, ticket, operation, and native identifiers are bounded opaque values capped at 300 characters.
- Permit consumption occurs before any helper call. Both permits and durable operation rows retain the ingress generation.
- Lifecycle requests omit route-carried claim/ticket identifiers where the reviewed `kanban-post --json` transport owns URL construction; the bridge injects only the stored backend work-session identity.
- `bind` preserves omitted checkout/label values. A supplied changed label takes the `rebind_session` path and refuses while a live claim is cached. Checkout/repo/label change only after authoritative refresh succeeds.
- Subprocesses use argv arrays with `shell=False`. The instructions helper receives an environment with both Kanban token names removed. Test helpers are temporary fakes; the credential-bearing helper implementation was not changed.
- The executable resolves the physical blueprint root through its installed symlink. The install and sync tests assert executable symlinks target the selected blueprint.
- The Bats wrapper sets `PYTHONDONTWRITEBYTECODE=1`; no Task 2 bytecode artifacts were created.
- `git diff --check` passed. The controller-owned planning change remains outside this task's staged scope.

## Concerns and handoff

- Tasks 3 through 6 still own queue reconstruction/delivery and real native adapters. They must pass each event's captured `run_generation` into the store APIs; they must not infer the latest execution for a native session after resume.
- No client version is made lifecycle-capable by this task. Unknown, absent, or malformed qualification data remains read-only until the later real-client qualification tasks add reviewed exact versions.
- `origin/main` is ahead at `c385027` and overlaps installer/provision files. Per controller direction, that change was not integrated during Task 2; it should be reconciled after this scoped review.

## Fix round 1: Important review findings

Addressed all four Important findings from `task-2-review.md` on controller base
`dc4b5d4de0e6ab8bc565945593e233a683591438`.

### Changes

- End now records the current claim ID on its operation row before transport. That durable claim reference resolves the affected ticket after end has cleared the active claim, so fresh, replayed, and recovery refreshes call both `get_session` and `get_ticket` before changing the cache.
- An ended execution can mint a fresh one-use permit only for a recorded, non-rejected end operation whose handle, ingress generation, operation ID, operation kind, and normalized digest all match. `Bridge.execute` revalidates the same operation row before replay. Every new or changed post-end operation remains rejected.
- Queue insertion now discards activity when either the execution is durably ended or an end row already exists for that exact handle and generation. An incoming end deletes earlier activity for the same generation while retaining release rows.
- `lookup` and the optional `instructions` handle now use the canonical UUID validator before SQLite access, producing a redacted 422 for malformed strings and non-string JSON values.
- Table-driven tests cover failed session and ticket refreshes and exact replay recovery for register, rebind, claim, checkpoint, release, complete, and end as applicable. End has a separate fresh/successful replay test with an active claim and exact mismatch refusals.
- The existing cross-process executable fixture now timestamps its 60-second permit at actual setup time. Its previous fixed wall-clock timestamp could expire independently of the behavior under test.

### RED evidence

Command:

```text
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v tests.python.test_kanban_work tests.python.test_kanban_work_legacy
```

Initial result: exit `1`, `38` tests run, with `6` failures and `3` errors. The failures demonstrated the review findings:

```text
FAILED (failures=6, errors=3)
```

- fresh end omitted `get_ticket`;
- replay after authoritative end was rejected;
- end's injected `get_ticket` failure was not observed because no ticket refresh ran;
- late activity remained queued after end;
- malformed public handles returned 404 or leaked raw `sqlite3.ProgrammingError` paths.

The same run exposed the independent fixed-time executable permit fixture described above.

### GREEN evidence

Focused Python command:

```text
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v tests.python.test_kanban_work tests.python.test_kanban_work_legacy
```

Result: exit `0`.

```text
Ran 38 tests in 0.837s
OK
```

Standard Bats wrapper command:

```text
bash tests/bats/run.sh kanban-work
```

Result: exit `0`.

```text
1..1
ok 1 kanban-work Python contract in 890ms
```

No shared installer file changed in this fix round, and no focused failure or named integration concern remained. Per the fix brief, the already-green 1129-test full suite was not repeated.

### Fix self-review

- The post-end permit exception is narrower than execution: it only mints a new one-use permit after an exact recorded end match. The bridge independently runs `begin_operation` with the stored generation, digest, kind, and affected claim before transport.
- The affected ticket comes from the durable claim row referenced by the end operation, never from an old receipt. The authoritative session and ticket snapshots still determine cache state.
- A refresh failure leaves the operation ambiguous and the cache untrusted. The next exact native retry first reconciles current state, then replays the same backend operation and refreshes again.
- Activity suppression and end dominance execute inside the existing `BEGIN IMMEDIATE` transaction and compare the ingress generation. Release rows are preserved for Task 3's later critical-intent reconstruction work.
- Public UUID validation happens before database/helper access for both affected operations.
- The two Minor findings from the review (nested mutable spec defaults and expired-unconsumed permit cleanup) remain deliberately deferred for final review, as directed.

## Cross-repository default correction

Aligned Task 2's canonical `release_ticket` normalization with the frozen plan and
MCP contract at controller base `5c2ee3189ae14537b675239a17c21ad95cc14949`.
`reason` now defaults to `paused`; `handle`, `claim_id`, and `handoff` remain
required, and the existing feedback-target validation is unchanged.

### RED evidence

Command:

```text
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v tests.python.test_kanban_work tests.python.test_kanban_work_legacy
```

Result: exit `1`, `40` tests run, with only the two new regressions failing:

```text
ERROR: test_release_permit_from_omitted_reason_matches_explicit_default_request
ERROR: test_release_omitted_reason_normalizes_identically_to_explicit_paused
BridgeError: missing field 'reason' for release_ticket
FAILED (errors=2)
```

### GREEN evidence

Command:

```text
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v tests.python.test_kanban_work tests.python.test_kanban_work_legacy && bash tests/bats/run.sh kanban-work
```

Result: exit `0`.

```text
Ran 40 tests in 0.846s
OK
1..1
ok 1 kanban-work Python contract in 1351ms
```

### Self-review

- Omitted and explicit `reason: "paused"` normalize to identical sorted compact bytes.
- A permit minted from the omitted hook arguments is consumed by an explicit-default bridge request and sends `reason: "paused"` to the transport.
- `link_tickets.kind` and every other required/default field remain unchanged.
- No native queue, bridge, MCP, installer, or configuration file changed. Per the focused fix brief, the full suite was not repeated.
