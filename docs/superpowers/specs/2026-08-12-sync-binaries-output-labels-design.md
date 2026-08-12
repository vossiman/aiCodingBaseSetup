# `_sync_binaries` output labels

*2026-08-12. Trigger: `aicoding-sync` printed `Error: Update failed:
[unauthenticated] Error` with no indication of which updater said it; the
user (reasonably) suspected codex. It was Cursor's `agent update` — expired
session tokens in the shared auth mount. Diagnosis cost a debugging session
that a one-line label would have avoided.*

## Problem

`_sync_binaries` (`lib/sync.sh`) runs four updaters back-to-back — `claude
update`, `opencode upgrade`, `agent update` (or `cursor-agent update`), and
`_update_codex` — with each tool's stdout/stderr passing through unlabeled.
Any error text is unattributable, and Cursor's is doubly so because its
binary is named `agent`.

## Design

Print a one-line header before each pass-through updater:

```
--- claude update ---
--- opencode upgrade ---
--- cursor (agent update) ---        # or: cursor (cursor-agent update)
```

- The Cursor header leads with **cursor**, the product name, because the
  binary name `agent` is exactly what made the error unattributable; the
  literal command stays in parentheses.
- A header is printed only when the corresponding binary exists (inside the
  existing `command -v` guards), so absent tools stay silent.
- **codex gets no header.** `_update_codex` is silent on success (installer
  output is already discarded) and every error line it emits is
  self-labeled (`ERROR: codex …`). A header before guaranteed silence is
  noise, and tests assert the silent no-op.
- Error handling is unchanged: every step remains `|| true`; sync never
  breaks on a failed updater.

## Testing

Extend `tests/bats/codex-update.bats`'s `_sync_binaries` test (which already
stubs claude/opencode/agent) to assert the three headers appear and that the
cursor one names cursor.
