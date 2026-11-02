---
name: wrapup
description: End-of-session check. Run only when the owner explicitly invokes /wrapup or $wrapup, to answer whether this session can be closed and rolled into a new one without losing anything.
disable-model-invocation: true
---

# Wrapup

The owner wants to close this session and roll into a new one. Answer one
question: does closing it now lose anything? Unfinished work does not stop the
close if a new session can pick it up without this conversation.

Answer from checks run now, never from memory. Fix what is safe, then give the
verdict.

If you loaded this skill without the owner asking for it, stay read-only: run
the checks, change nothing, and report.

## Ownership

Sort everything you might touch into three classes:

- **Mine:** positive proof only. You created or changed it in this conversation,
  or it is this session's checkout and the diff matches this session's work.
- **Foreign:** a live session or another session's live claim points at it.
- **Unknown:** everything else.

Change only what is mine. Unknown work in the current checkout, or on a branch
this session used, is a blocker. Foreign work and unknown work elsewhere go
under "left alone".

## 1. Work against the request

Re-read the original request, every later request in the conversation, and the
acceptance criteria of each ticket the session touched. Mark each item done or
not done. Done needs evidence: a command result, commit, PR or file. Finish small
missing items now. Larger ones become a ticket with a handoff.

## 2. Facts

Run this for the current repo, adding every other repo the session changed:

```bash
bash ~/.claude/skills/wrapup/check.sh [repo-path ...]
```

A non-zero exit or a `[FAILED]` section means a check did not run, which is a
blocker. List the background processes you started, then stop them or wait for
them.

## 3. Tickets

Use the `kanban` MCP. Its server instructions are canonical and win over this
section.

Build the list of tickets this session touched. `my_work` shows only live
claims, so also use the conversation, ticket ids in this session's branches and
commits, and the repo's open tickets. If the list may be incomplete, for example
after context compaction, that is a blocker.

For each ticket:

- Check who holds it. Never take over another live session's claim.
- Claim it again if the claim was released, since `complete_ticket` needs one. A
  ticket in Waiting closes through `resolve_feedback` instead.
- Complete it only with evidence, once its acceptance criteria are met on the
  target branch. Merged is enough. Do not check deployment.
- For an open PR, release with reason `feedback` and name the `feedback_target`.
- Read the body as a stranger would. If it describes an old plan, update it.
- Release any claim you still hold before finishing.

File a ticket for each unfinished finding, follow-up or leftover that lives only
in chat or in a doc. Work found and finished in this session needs no
retrospective ticket.

With no kanban MCP or no valid handle, skip the ticket writes, run the other
steps, and report a blocker.

## 4. Knowledge

- Durable lessons go to the homelab-wiki through its normal write path.
- A handoff or decision that exists only in chat goes where the next session will
  find it: the ticket, or the repo docs through their normal flow. Write it so a
  stranger can act on it without this conversation.
- Files the owner needs are in `out/` and announced by path. Report anything else
  that exists on only one machine, with its size.

## 5. Repo rules

Follow whatever the repo's `CLAUDE.md` or `AGENTS.md` asks for at session end.

## 6. Fix what is safe

The owner's explicit invocation authorizes these, for work that is mine:

- commit and push to this session's feature branch
- delete this session's merged worktrees and local branches
- stop processes this session started
- the kanban and wiki writes above

Before any commit or push, inspect the index, the exact diff, and the whole
outgoing commit range. Stage named files, never everything. If any of it cannot
be proven mine, or may hold a secret, do not commit or push it. It becomes a
blocker.

Never do these. Report them in the verdict instead:

- merge a PR
- push to a protected `main`, unless the repo's rules exempt that change
- force-push, or delete unmerged work
- touch foreign or unknown work
- read a secret

## 7. Verdict

Run `check.sh` again, then make the first two lines of your reply exactly one of
these:

```
SAFE TO CLOSE
Work finished.
```

```
SAFE TO CLOSE
Work carries over: <N> items.
```

```
DO NOT CLOSE: <N> blockers
```

The verdict is about closing this session, not about finishing the work. A
blocker is something that is lost or stuck if the session closes now, and that
this run could not fix:

- work or a decision that exists only in this conversation or in an uncommitted
  or unpushed change
- a process inside this session that something still needs, since it dies with
  the session
- a claim this session still holds, or a session ticket in the wrong state
- a check that did not run, or a ticket list that may be incomplete
- unknown work in the current checkout or on a branch this session used

These are not blockers. They carry over:

- unfinished work with a ticket whose handoff lets a stranger continue
- a decision or merge that waits on the owner, written on its ticket with what
  the owner needs to know
- work running outside this session, such as a remote job, with its watch points
  on a ticket

Never use a blocker to ask for proof or a chore nobody requested. Never leave
a carry-over item off the list.

Then list, leaving out empty groups:

- **Blockers:** numbered, with what each needs and who acts.
- **Carries over:** one per line, with the ticket and who acts next. Put what
  waits on the owner first.
- **Next session:** when work carries over, one line per piece of work that the
  owner can paste to start it, naming the ticket and the first step.
- **Fixed:** what this run changed.
- **Left alone:** foreign and unknown work, once each.
