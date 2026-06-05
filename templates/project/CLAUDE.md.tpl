# {{PROJECT_NAME}}

The shared, agent-agnostic working conventions live in `AGENTS.md` (so Codex,
OpenCode, and Cursor honor the same rules). Claude Code imports them here:

@AGENTS.md

## Claude Code specifics

On top of the shared conventions above, Claude Code adds:

- `/scaffold-project` — already used (you're looking at the output).
- `/housekeep` — sweep `docs/*/active/` → `archive/` for any `status: done` doc,
  and prune stale `TODO.md` items.
- A `SessionStart` hook prints a one-line reminder when archive-eligible docs
  exist, so you know when to run `/housekeep`.
