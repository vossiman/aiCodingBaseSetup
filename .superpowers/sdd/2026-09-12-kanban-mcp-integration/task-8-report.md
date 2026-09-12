# Task 8 implementation report

## Status

DONE_WITH_CONCERNS. The user-approved scope is Codex-first and preflight-only.
No native model was launched, no client was qualified, and the production
matrix remains empty. The implementation is intended to make those facts
reviewable rather than synthesize native evidence.

Task commit subject: `test(kanban): qualify native client preflights`
Implementation base: `a831d535a44bcf3110d70a84672633c559dcb0c3`

## Implemented

- Added `tools/qualify-kanban-clients` with `--all`, focused `--client`, and
  output-directory modes.
- Added bounded, closed-stdin real `--version` observation for Claude Code,
  Codex, Cursor Agent, and OpenCode. Raw client output is never copied to a
  report.
- Added allowlisted JSON reports with an explicit `evidence: preflight_only`
  marker. The report validator cannot return `qualified` for this evidence
  type, even if every scenario boolean is supplied as true.
- Added concrete unsupported reasons. Codex names the decisive blocker: the
  nonexecuting app-server inventory does not load the same configuration as
  `codex exec --ignore-user-config`, so it cannot inventory the actual model
  launch.
- Added a loopback-only fake board with exact fake bearer authentication,
  Host-header rejection, bounded/redacted route logging, and accelerated
  17-minute lease expiry.
- Added an empty schema-1 production client matrix. No fixture or version-only
  observation can promote a version.
- Documented the Codex-first scope, current unverified state, command limits,
  report contents, and other-client preflight blockers. Corrected the parity
  table so Codex 0.154.0 does not claim a nonexistent PostToolUseFailure hook.
- Generated local reports in `out/kanban-mcp-qualification/` for all four exact
  installed versions. They are preserved for `dvw pull` and are not staged.

## TDD evidence

Initial RED:

```text
$ bash tests/bats/run.sh kanban-client-qualification
1..3
not ok 1 qualification harness self-tests pass
not ok 2 qualification command exposes focused and all-client modes
not ok 3 tracked client matrix starts with no fixture-qualified clients
```

The failures were expected because the qualification module, command, fake
board, and tracked matrix did not exist.

Report-label RED:

```text
$ bash tests/bats/run.sh kanban-client-qualification
1..4
not ok 4 focused preflight exits unsupported and labels unobserved native evidence
# evidence was absent
```

Preflight-proof RED:

```text
$ bash tests/bats/run.sh kanban-client-qualification
1..4
not ok 1 qualification harness self-tests pass
# preflight-only report could still be marked qualified when all flags were true
```

Final focused GREEN:

```text
$ bash tests/bats/run.sh kanban-client-qualification
1..4
ok 1 qualification harness self-tests pass
ok 2 qualification command exposes focused and all-client modes
ok 3 tracked client matrix starts with no fixture-qualified clients
ok 4 focused preflight exits unsupported and labels unobserved native evidence
```

The Python selftests reached through Bats cover loopback/token refusal, missing
scenario rejection, fixture/preflight nonqualification, token-output exclusion,
timeout termination, exact candidate-matrix shape, unsupported aggregate
status, fake-board auth/Host rejection, clock-driven expiry, and redacted logs.

Real version preflight evidence:

```text
$ tools/qualify-kanban-clients --all --output out/kanban-mcp-qualification
claude 2.1.268: unsupported
codex 0.154.0: unsupported
cursor 2026.09.10-fd3934a: unsupported
opencode 1.18.30: unsupported
```

Exit 1 is the required result because every native scenario remains
unobserved. A separate artifact scan found none of the fixed fake token or
test-native labels in the four reports.

## Files changed

- `tools/qualify-kanban-clients`
- `configs/kanban/qualified-clients.json`
- `tests/qualification/fake_kanban_board.py`
- `tests/qualification/qualify_kanban_clients.py`
- `tests/qualification/test_qualify_kanban_clients.py`
- `tests/bats/kanban-client-qualification.bats`
- `docs/kanban-mcp-qualification.md`
- `README.md`
- `docs/agent-parity.md`
- `docs/superpowers/plans/2026-09-12-kanban-mcp-integration.md`

## Self-review

I read the complete diff and found one qualification-integrity gap: the first
validator revision could mark a manually constructed all-true report qualified
despite the reporter being preflight-only. I added a failing test and made the
`preflight_only` evidence marker a hard unsupported condition. I also corrected
the stale Codex PostToolUseFailure claim in the parity table.

The reporter passes only a minimal PATH and locale to version commands, records
only command basenames indirectly through client names and exact parsed
versions, uses no shell, and never reads home/client configuration or auth.
Generated reports contain only allowlisted fields. The fake credential exists
only in test processes and is stripped if it reaches a report value.

## Concerns and rollout blockers

- This command is intentionally not a native qualification runner. It cannot
  collect promotable native evidence and therefore always reports unsupported.
- Codex cannot qualify until a nonexecuting inventory observes the same launch
  configuration as the eventual model turn, or another reviewed mechanism
  proves exactly which hooks can execute under `--ignore-user-config`.
- Claude managed-layer provenance, Cursor exclusive configuration, and OpenCode
  plugin/MCP isolation remain unresolved. They do not block the user-approved
  later Codex-only rollout.
- The fake board implements only the endpoints exercised by this narrowed
  preflight/selftest scope. A future native runner will need scenario-specific
  endpoints and tests before it can gather lifecycle evidence.

No push, PR, review, merge, deployment, live activation, secret access, or
production board write was performed as part of Task 8.
