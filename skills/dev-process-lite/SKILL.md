---
name: dev-process-lite
description: Use when coordinating more than one task in a repo that has no docs/DEV_PROCESS.md, covering delegation, routes, review findings, board state and the overseer log. Not for a single-ticket session, and not for repos with their own docs/DEV_PROCESS.md.
---

# dev-process-lite

The scripts and the policy sit beside this file, in
`~/.claude/skills/dev-process-lite/` when deployed.

1. Run `bash ~/.claude/skills/dev-process-lite/detect.sh` from the repo. If it prints `project <path>`, say in
   one line that this repo has its own process at that path, and stop:
   that document and the repo's own skills apply.
2. Read `policy.md`. It is the policy; this file only orders the steps.
3. Run `bash ~/.claude/skills/dev-process-lite/routes.sh [entry]` to see the routes table, and
   `bash ~/.claude/skills/dev-process-lite/routes.sh [entry] <role>` before each launch. Exit 2 means
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
6. Run one review per PR (one PR per run unless the plan ships independent
   PRs, policy section 4) with `review-by-harness`, passing the
   `reviewer` route as `--harness` and `--model`, plus `--effort` only when the reviewer harness is claude or codex. Fix verified
   findings on the open branch (policy section 2). Once the fixes are
   committed there, run
   `bash ~/.claude/skills/review-by-harness/cleanup.sh <N> --harness <reviewer harness> --archive .claude/dev-process-runs/<session>/reviews --discard`.
   It archives the review for the assessment and removes only that review's
   worktree and branch; the fetched PR ref is shared by every reviewer and
   goes with the last one. Do this before a second round too, which would
   otherwise overwrite the first round's report. Log each PR's number, base,
   head and review under Plan.
7. Before closeout, check the Board section against policy section 2, and
   stop for the owner only for the reasons in policy section 3. Remove the
   run's worker worktrees whose branches merged, and run the step 6 cleanup
   for any of the run's reviews still left. Never run `cleanup.sh --prune`
   at closeout: it is repo-wide maintenance and would also take reviews
   other runs have not archived yet.
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
