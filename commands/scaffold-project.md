---
description: Drop the canonical aiCodingBaseSetup project layout into the current directory (CLAUDE.md, TODO.md, docs/specs|plans|notes with active/archive, project .claude/).
argument-hint: "[optional: project name]"
allowed-tools: Read, Write, Bash(ls:*), Bash(git init:*), Bash(git status:*), Bash(mkdir:*), AskUserQuestion
---

You are scaffolding a new project from templates. Follow this procedure exactly.

## 1. Safety check — are we about to clobber something?

Inspect the current working directory (do not run a tool yet — just reason about what files would be created). The scaffold will create, at minimum:

- `CLAUDE.md`
- `README.md`
- `TODO.md`
- `.claude/settings.json`
- `docs/specs/{active,archive}/.gitkeep`
- `docs/plans/{active,archive}/.gitkeep`
- `docs/notes/{active,archive}/.gitkeep`

Use `ls -la` (Bash) to list the current directory. If **any** of those target paths already exist, use `AskUserQuestion` to ask the user whether to (a) abort, (b) skip existing files and create missing ones, or (c) overwrite. Do not proceed without an explicit choice.

## 2. Collect project metadata

Use `AskUserQuestion` with two questions in a single call:

1. **Project name** — the short name, used as `{{PROJECT_NAME}}` in templates. If `$ARGUMENTS` is non-empty, preselect it; otherwise ask freeform.
2. **One-sentence purpose** — used as `{{PURPOSE}}` in templates.

For both questions, offer 2-4 sensible options plus an "Other" escape. If you truly cannot generate plausible options, present a single open-ended option; the harness will let the user answer freely via "Other".

## 3. Locate the templates

Templates live at `~/.aicodingsetup/templates/project/`. Use Bash to check existence:

```
ls ~/.aicodingsetup/templates/project/
```

If the directory does not exist, stop and tell the user:

> Templates not installed. Re-run `install.sh` from the aiCodingBaseSetup repo.

Do **not** try to invent a layout. The templates are the source of truth.

## 4. Materialize the layout

For each template file under `~/.aicodingsetup/templates/project/`:

- If the source name ends in `.tpl`, strip the `.tpl` suffix for the destination.
- If the source path starts with `dot-claude/`, rewrite to `.claude/` in the destination (templates can't ship dotfiles cleanly through some archives, so we use the `dot-` prefix in the repo).
- Read the source with the `Read` tool, substitute `{{PROJECT_NAME}}` and `{{PURPOSE}}` with the collected values, and write the result with `Write`.
- For `.gitkeep` files, just copy them (no substitution).

Walk the tree in a predictable order (breadth-first or sorted). Skip files per the user's conflict-resolution choice from step 1.

## 5. Initialize git (if not already a repo)

```
git status --short  # fails with non-zero exit if not a repo
```

If not a git repo, run `git init`. Do not make a commit — leave that to the user.

## 6. Report

Print a concise summary: how many files created, how many skipped, path to the new `CLAUDE.md`, and a one-line pointer:

> Next: fill in `TODO.md` and run `/housekeep` when you start marking docs `status: done`.

Do not elaborate further. The user can read `CLAUDE.md` for the conventions.
