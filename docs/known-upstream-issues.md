# Known upstream issues

These are accepted limitations in tools managed by aiCodingBaseSetup. They are
documented here when there is no proportionate local workaround. This is not an
active monitoring list; normal tool upgrades may resolve an entry.

## Codex repeats rejected Bash and patch input

- Upstream: [openai/codex#32573](https://github.com/openai/codex/issues/32573)
- Status checked: 2026-09-09 — open, unassigned, and still present on Codex
  `main`.
- Local tracking: AICODINGBASESETUP-34, closed as an accepted upstream
  limitation.

When a Codex `PreToolUse` hook rejects Bash or `apply_patch`, Codex appends the
complete command or patch to the rejection message even if the hook returned a
sanitized reason. The rejected operation does not execute, but its submitted
input is duplicated into the visible transcript and may also reach persisted
logs.

Treat this as a transcript-hygiene limitation, not an enforcement boundary:

- Never put secret values in commands or patches.
- Use `secrets-check` to inspect whether credentials are configured.
- A protected path may appear in a rejection, but the secrets guard still
  prevents the rejected access or write.

We do not maintain a Codex fork for this issue. If upstream fixes it, the normal
Codex update path will inherit the change.
