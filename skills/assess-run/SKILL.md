---
name: assess-run
description: Use in a fresh short session to assess a finished dev-process-lite run from its overseer log and integrated diff, without re-reading the overseer conversation. Takes the run session id, or lists runs when omitted. Not for repos with their own docs/DEV_PROCESS.md.
---

# Assess a dev-process-lite run

1. Run `bash ~/.claude/skills/dev-process-lite/detect.sh`. If it prints
   `project <path>`, say that this repo has its own process and stop.
2. Without a session id, list `.claude/dev-process-runs/` newest first and
   ask which run.

Read, in this order, and nothing else unless a spot-check needs it:

1. `.claude/dev-process-runs/<session>/overseer.md`.
2. The `review-by-harness` report under
   `.claude/worktrees/review-pr<N>-<harness>/.review-round/`, if present.
3. `git diff --stat <base>...<head>` for the integrated branch, and the PR
   body if a PR is open.

Then check, against `~/.claude/skills/dev-process-lite/policy.md`:

- The log has the five sections in order and at most 120 lines, and Plan
  names the plan, the base and the resolved model ids.
- Spot-check at least one Decisions entry and one Deviations entry against
  the diff or the review report. A contradiction is a finding; do not
  soften it.
- The Board section against policy section 2: a ticket filed that the run
  could have done, an easy review finding filed instead of fixed, a
  finding filed singly that belongs in an existing ticket, or an old ticket
  carried instead of split is a `fix first` finding. So is a question to
  the owner outside policy section 3.
- Answer each Open question, or say which ones need the owner.

Report in under 300 words: the verdict, findings ranked by severity, and
the answers, each pointing at a file, commit or record. Verdicts:

- `sound`: the work may merge; name who merges under the repo's rules.
- `fix first`: name the fix; it goes back to the overseer as a task.
- `stop`: name the contradiction; the owner decides.

Hand-back depends on the harness. `ListAgents` and `SendMessage` exist only
in Claude Code, and `~/.claude/sessions/*.json` lists only Claude sessions.

- Claude assessor, and Plan names a Claude session id: find the
  `~/.claude/sessions/*.json` entry with that `sessionId`, take its `name`,
  run `ListAgents`, and send the report with `SendMessage` only when that
  name is listed. Say whether the send succeeded; never claim a send that
  did not happen.
- Any other combination: report only. End with one line saying the owner
  relays the verdict to the overseer, naming the overseer's session id.

Never spawn workers, edit code or move the board from this session.
