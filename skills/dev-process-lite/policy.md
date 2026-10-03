# dev-process-lite policy

This policy applies when a session coordinates more than one task in a repo
that has no `docs/DEV_PROCESS.md`. It assumes the global instructions are
loaded and refines them; worktree, sibling, kanban and review rules stay
where they are. A repo with `docs/DEV_PROCESS.md` follows that document.

## 1. Overseer log

An overseer is a session that coordinates more than one task: it prepares
work for subagents or worker sessions, reads their diffs and decides what
merges. A session doing one ticket end to end is not an overseer and keeps
no log.

The overseer keeps `.claude/dev-process-runs/<session>/overseer.md`, written
for a reader who did not watch the run. `<session>` is
`CLAUDE_CODE_SESSION_ID` in Claude and `CODEX_THREAD_ID` in Codex. A Codex
overseer never uses `CLAUDE_CODE_SESSION_ID`: Codex can inherit a stale one
from whatever launched it. Add `.claude/dev-process-runs/` to
`.git/info/exclude` when the repo does not ignore it.

Append an entry at each milestone (task prepared, handed off, accepted,
blocked or abandoned; review done; PR opened), never per tool call. Hard
cap: 120 lines. Five sections, in this order:

- **Plan**: plan or spec path and revision, tickets, base revision, the
  overseer's session id and its current name (the `name` of the
  `~/.claude/sessions/*.json` entry whose `sessionId` matches), and the
  exact model id each route resolved to.
- **Decisions**: each decision the plan did not settle, with a one-sentence
  reason and the commit, record or file that shows it. The implementer role
  chosen per task and every reassignment go here.
- **Deviations**: where delivery differs from the plan: unmet acceptance
  criteria, skipped validation, diff-only reviews, overridden blocking
  findings, each with the reason.
- **Open questions**: what the owner or an assessment must decide. Empty
  means the overseer claims none.
- **Board**: tickets closed, filed and left open. Each filed ticket names
  its accepted reason from section 2; each open one names its blocker.

Entries point at evidence instead of restating it. No secrets, no customer
data.

## 2. Finish in the run, close what is old

- **Do the work in the run.** A defect, gap or review finding found during
  a run goes to a worker in that run when the fix touches what the run
  already works on or a worker could finish it in about an hour. "Out of
  scope" and "pre-existing" are not reasons to file. Widen scope for small
  work without asking and record it under Decisions.
- **A ticket is a mechanism, not a slot.** A work ticket names one
  mechanism and holds about three to four agent tasks. It never names one
  data row, one document or one test case; those are evidence rows in it.
- **Fix review findings at once.** A verified finding that is easy to fix
  goes onto the open PR's branch before merge. A change to Markdown, a
  comment, a name or a link never gets its own ticket, branch or PR.
- **File a ticket only when the run cannot do the work.** The accepted
  reasons are closed:
  1. it needs an answer from the owner or a third party (a feedback ticket
     in `waiting_for_feedback`, or a link to one);
  2. it needs a paid action or another authorization the run does not hold;
  3. another live session owns the files;
  4. it is a separate piece of work larger than one worker task, which the
     run's tickets do not need in order to close.
- **Search the board first.** A finding an open ticket covers becomes a
  comment there; findings sharing a cause go into one ticket with a
  checklist. Before filing a third ticket, or more than the run closes,
  re-read the list.
- **Close the run's tickets.** When the agreed scope was delivered but the
  title promised more, close it, comment what was delivered and file the
  remainder as bounded tickets linked `relates`.
- **Split old tickets.** A work ticket still open three days after a run
  worked on it, or carried through two runs, is closed with a comment and
  replaced by bounded remainders. Feedback tickets and untouched backlog
  are exempt.

The kanban instructions define the transitions; this section only decides
whether a ticket is filed.

## 3. When the overseer comes back to the owner

The overseer decides, records under Decisions and carries on. It stops for
the owner only when:

- an action needs an authorization the run does not hold: a paid action
  above the project's stated cap, a message sent outside the repo, a
  production or storage change, a release;
- the next step would be destructive or could not be undone;
- every remaining task is blocked on a person's answer.

Merging a reviewed, green PR and cleaning up the run's own worktrees need
no owner go, unless the repo's own instructions say "ask before merging";
that rule wins. In a run the owner declared overnight or unattended, the
overseer never stops: it parks the blocked step under Open questions,
finishes the rest and leaves one closeout.

## 4. Routes

Model and effort per role come from the routes table, never from prose.
Run `routes.sh [entry] [role]` beside this file. It reads
`.dev-process/routes.json` at the repo root when present, else
`routes.default.json` beside it, resolves a family to the newest installed
model, and blocks (exit 2) rather than substitute. Write the resolved id
into the Plan section.

Roles: `overseer`, `implementer`, `complex-implementer`, `reviewer`,
`assessor`. Entries: `claude`, `codex`, `cursor`; OpenCode is not an entry.

**Choosing the implementer role.** A task is `implementer` work when all
of these hold, else `complex-implementer`:

1. the plan names the files and the acceptance criteria, so the worker
   makes no design choice;
2. it stays inside one module or mechanism, with no change to an
   interface, a data format, a lock or ownership model, or a public CLI;
3. a unit test or a scripted check proves it done;
4. a worker can finish it in about an hour.

A mechanical edit (rename, formatting, docs) may drop to `low` effort.

**Escalation ladder.** After a failed attempt, raise effort first, then
move up a model tier (the `complex-implementer` route). Record each step
under Decisions as a reassignment. Drop the failed branch; do not patch it.
A task never moves down.

**Tests are the contract.** When the acceptance tests were written in an
earlier step, the implementer does not edit them. A test change needs the
overseer's approval, recorded under Decisions with the reason.

**Review.** One integrated review per run with `review-by-harness`, passing
the reviewer route as `--harness`, `--model` and `--effort`. Every
reviewer is from another vendor than the entry harness.
