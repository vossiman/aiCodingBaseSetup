---
name: housekeep
description: Archive completed project docs and prune dated completed TODO entries when asked to housekeep or tidy project documentation.
allowed-tools: Read, Write, Edit, Bash(ls:*), Bash(mv:*), Bash(mkdir:*), Bash(find:*), Bash(date:*), Bash(test:*), Grep, Glob
---

Sweep `docs/specs/active`, `docs/plans/active`, and `docs/notes/active`.
Read each Markdown file's YAML frontmatter; move only files with an explicit
`status: done` to the sibling `archive/` directory. Create that directory if
needed. Skip malformed frontmatter and report the skip. Preserve contents.
If the destination exists, use an unused `(N)` suffix before `.md`; never
replace an existing archive.

If `TODO.md` exists, remove completed `- [x]` lines only when they end with a
valid `(YYYY-MM-DD)` date more than 14 days before today. Keep undated,
invalid-date, newer and incomplete items, and all other content.

Use the current agent's file/shell tools. If no supported docs directories
exist, report that there is nothing to housekeep. Otherwise summarize counts
archived, skipped and pruned, or say nothing needed doing. Do not commit or
publish the changes unless the user also requested that.
