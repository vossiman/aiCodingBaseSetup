# {{PROJECT_NAME}}

{{PURPOSE}}

## Working conventions (read before taking action)

This project uses the `aiCodingBaseSetup` project scaffold. A few conventions keep
the working set small and the history clean.

### Document lifecycle — active/archive

All living project documents belong under `docs/`, split by category and by
lifecycle state:

- `docs/specs/active/` — designs currently guiding work
- `docs/plans/active/` — implementation plans currently being executed
- `docs/notes/active/` — WIP investigation notes

When a document's work is finished, flip its YAML frontmatter `status: active`
to `status: done`. Do **not** move the file manually — the `/housekeep`
slash command sweeps `status: done` docs into the sibling `archive/` folder.

Every document in `docs/*/active/` should carry frontmatter:

```yaml
---
title: <short title>
status: active   # active | done
created: YYYY-MM-DD
---
```

### TODO.md stays short

`TODO.md` is for what's top-of-mind right now, not a backlog of everything you
might ever do. Keep it to ~10 lines per section. Finished items (`[x]`) with a
trailing `(YYYY-MM-DD)` date token older than 14 days are pruned by `/housekeep`.

### Slash commands

- `/scaffold-project` — already used (you're looking at the output).
- `/housekeep` — sweep `docs/*/active/` → `archive/` for any `status: done` doc,
  and prune stale TODO items.

A `SessionStart` hook reminds you when archive-eligible docs exist.
