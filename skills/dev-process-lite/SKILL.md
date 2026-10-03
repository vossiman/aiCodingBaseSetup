---
name: dev-process-lite
description: Use when coordinating more than one task in a repo that has no docs/DEV_PROCESS.md, covering delegation, routes, review findings, board state and the overseer log. Not for a single-ticket session, and not for repos with their own docs/DEV_PROCESS.md.
---

# dev-process-lite

The scripts and the policy sit beside this file, in
`~/.claude/skills/dev-process-lite/` when deployed.

1. Run `bash detect.sh` from the repo. If it prints `project <path>`, say in
   one line that this repo has its own process at that path, and stop:
   that document and the repo's own skills apply.
2. Read `policy.md`. It is the policy; this file only orders the steps.
3. Run `bash routes.sh [entry]` to see the routes table, and
   `bash routes.sh [entry] <role>` before each launch. Exit 2 means
   blocked: report the message, never pick another model. Write each
   resolved model id into the log's Plan section.
4. Keep the overseer log from policy section 1 at
   `.claude/dev-process-runs/<session>/overseer.md`, and add
   `.claude/dev-process-runs/` to `.git/info/exclude` if the repo does not
   ignore it.
5. Give every worker its own branch and worktree (the `worktree-session`
   skill), its role and route, the files it owns, the acceptance criteria
   and what to hand back. Choose `implementer` or `complex-implementer` by
   policy section 4 and record the choice under Decisions.
6. Run one integrated review with `review-by-harness`, passing the
   `reviewer` route as `--harness`, `--model` and `--effort`. Fix verified
   findings on the open branch (policy section 2).
7. Before closeout, check the Board section against policy section 2, and
   stop for the owner only for the reasons in policy section 3.
8. Tell the owner the run can be assessed with `assess-run` from a fresh
   session, and name the session id.

## Opt-in files for a repo

Nothing is required. A repo may add, by copying from the blueprint's
`templates/project/`:

- `.dev-process/routes.json`, to pin models for the repo;
- `.github/pull_request_template.md`, for the "Independent review" section;
- `.claude/settings.json` hooks plus `.claude/hooks/`, once the repo has a
  `docs/REQUIREMENTS.md` worth injecting. Merge into an existing settings
  file by hand; never overwrite project permissions.
