---
description: Sweep docs/*/active/ for docs with YAML frontmatter status:done and move them to archive/; prune TODO.md of [x] items older than 14 days.
allowed-tools: Read, Write, Edit, Bash(ls:*), Bash(mv:*), Bash(find:*), Bash(date:*), Bash(test:*), Grep, Glob
---

Perform project housekeeping. Be concise — this is a maintenance task, not a conversation.

## 1. Verify this is a scaffolded project

Check for `docs/specs`, `docs/plans`, or `docs/notes` (any one is enough). If none exist, stop and report:

> This directory doesn't look like a scaffolded project (no docs/specs|plans|notes). Nothing to housekeep.

## 2. Sweep `docs/*/active/` for `status: done`

For each of `docs/specs/active`, `docs/plans/active`, `docs/notes/active`:

- Use `Glob` to list `*.md` files.
- For each file, read the **first ~15 lines** and look for YAML frontmatter with `status: done` (literal match, case-sensitive, unquoted — `status: done`).
- If malformed YAML prevents reading the status, skip the file silently (do not fail the sweep). Note it in your summary as "skipped (malformed frontmatter)".
- For every `status: done` file, move it to the sibling `archive/` directory using `mv` via Bash:
  `mv docs/specs/active/foo.md docs/specs/archive/foo.md`
- If the destination file already exists, append a suffix `(N)` before the extension and move it there. Do not overwrite.

## 3. Prune stale `[x]` items from `TODO.md`

If `TODO.md` exists:

- Today's date is available via `!`date +%Y-%m-%d``.
- For each line matching `^- \[x\]` (completed TODO item), look for a trailing `(YYYY-MM-DD)` date token.
- If the date is more than **14 days** older than today, remove the line.
- If no date token, leave the line alone (user hasn't opted in to tracking).
- Use `Edit` to rewrite `TODO.md` with stale lines removed. Preserve all other content, including headings and comments, untouched.

## 4. Report

Print a short summary, one line per category:

```
specs:  2 archived, 0 skipped
plans:  0 archived, 0 skipped
notes:  1 archived, 1 skipped (malformed frontmatter)
TODO:   3 stale items pruned
```

If nothing was done in any category, report a single line:

> Nothing to housekeep.

Do not elaborate. The user can inspect the diffs if they want detail.
