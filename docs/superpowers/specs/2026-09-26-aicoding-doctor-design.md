# aicoding-status --doctor

Date: 2026-09-26. Status: implemented in `feat/aicoding-doctor`.

## Problem

`aicoding-status` prints recorded blockers as raw reason codes. On
2026-09-25 it showed `mcp-registration-claude-kanban: blocked — registration
not selected` and `Fleet proof ... 5 of 13 containers verified`. Neither said
what was wrong or what to run. Finding the cause took an hour of reading
`lib/update-components.sh` and dvw's fleet code. The count was also
misleading: only 2 containers passed; 5 had reported at least one tool.

## Goal

One command that explains every recorded blocker in plain words and names
the command that fixes it, and that stays current as features add new
reason codes.

Decisions (user, 2026-09-26):

- Built into `aicoding-status` as `--doctor`, not a separate command, so it
  reads the same data and cannot drift from it.
- Suggest only. Doctor never changes state.
- Every existing reason is covered in the first release.

## Design

### Reason catalog: `lib/status-reasons.json`

```json
{"schema": 1,
 "reasons":  {"<code>": {"kind": "ok|wait|action", "meaning": "...", "fix": "..."}},
 "patterns": {"<glob>": {"kind": "...", "meaning": "...", "fix": "...", "source_marker": "..."}}}
```

- `kind`: `ok` for success codes (no fix), `wait` for conditions that clear
  on their own, `action` for ones that need the user.
- `patterns` cover codes built at runtime, such as `*_runtime_unavailable`,
  `manual_rebuild_required_*`, `*_timeout`, `verification_failed:*`. An exact
  entry wins over a pattern; among patterns the most specific one wins.
- `source_marker` is a fixed fragment of the code that builds the pattern's
  codes, so the stale check can tell whether the pattern is still used.

### Doctor output (`lib/status-report.py`, `doctor()`)

1. Fleet check, when the shared-config fleet proof is not valid: the
   containers that fail it, grouped by the tools they are missing, with this
   container marked. Roots with identical results are merged into one line.
2. Every `blocked`, `conflict` or `failed` record: component, state, reason,
   time, then `Why:` and `Fix:` from the catalog. An uncatalogued reason gets
   a generic line instead of an error.
3. Exit 0 when nothing is blocked, 1 otherwise.

The plain `aicoding-status` fleet count now counts only containers that
report all six tools, matching dvw's `_verified`.

### Coverage enforcement

Three checks keep the catalog complete:

- **Static** (`tests/status_reasons.py static`, run by
  `tests/bats/status-reasons.bats`): scans `lib/` and `bin/` for literal
  reason codes and fails on any without an entry. It finds codes passed to
  `aicoding_result_record` and to every wrapper that forwards a reason. It
  discovers those wrappers itself: a function that passes its own `"$N"`, an
  alias of it (`local reason=$2`), or `"$@"` into a known recorder becomes a
  recorder too. It also finds `reason=<code>` assignments, `${reason:-<code>}`
  defaults, and `echo <code>; return 1` in compatibility checks.
- **Stale**: fails on catalog entries that no code produces any more.
- **Runtime audit**: `tests/bats/run.sh` exports `AICODING_REASON_AUDIT`.
  `aicoding_result_record` appends each reason whose origin is `lib/` or
  `bin/` code (walking past the forwarding wrappers) to that file. After
  bats finishes, run.sh fails the run if any logged reason is uncovered.
  This catches codes the static scan cannot see. Reasons that test fixtures
  record directly are skipped.

The wrapper list the audit uses (`_AICODING_REASON_WRAPPERS` in
`lib/update-results.sh`) must equal the wrappers the scanner discovers; a
test enforces that.

Rejected: making the recorder reject unknown codes at runtime. One missed
entry would then break a production sync.

## Out of scope

`--json` output and a `--fix` mode (YAGNI). Host-side fleet fixes stay
suggestions because doctor runs inside one container.
