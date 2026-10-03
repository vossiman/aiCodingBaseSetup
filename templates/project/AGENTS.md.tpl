# {{PROJECT_NAME}}

{{PURPOSE}}

## Working conventions (read before taking action)

This project uses the `aiCodingBaseSetup` project scaffold. A few conventions keep
the working set small and the history clean. They are **agent-agnostic** — they
apply whether you drive this repo with Claude Code, Codex, OpenCode, or Cursor
(every one of those reads this `AGENTS.md`).

### Document lifecycle — active/archive

All living project documents belong under `docs/`, split by category and by
lifecycle state:

- `docs/specs/active/` — designs currently guiding work
- `docs/plans/active/` — implementation plans currently being executed
- `docs/notes/active/` — WIP investigation notes

When a document's work is finished, flip its YAML frontmatter `status: active`
to `status: done`, then move it into the sibling `archive/` folder.

> Claude Code users: run `/housekeep` to sweep `status: done` docs automatically.
> With other agents, move done docs into `archive/` by hand (or via an
> equivalent command/script).

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
might ever do. Keep it to ~10 lines per section. Completed items (`[x]`) with a
trailing `(YYYY-MM-DD)` date token older than 14 days can be pruned (Claude Code:
`/housekeep` does this for you).

### Development process

This repo has no `docs/DEV_PROCESS.md`, so the shared `dev-process-lite`
skill applies whenever a session coordinates more than one task. Model routes
for this repo are pinned in `.dev-process/routes.json`; edit that file to
change them, and add `docs/DEV_PROCESS.md` only when the repo needs its own
full process, which then replaces the lite one. `docs/REQUIREMENTS.md`, when
present, is the North Star and is injected at session start, so keep it under
about 150 lines. `docs/SHIP_CHECK.md`, when present, is read back to the agent
after every `git commit`.
