---
name: wrapup
description: End-of-session check. Run only when the owner explicitly invokes /wrapup or $wrapup, to verify that requested work, tickets, git state and cleanup are finished and give a close verdict.
disable-model-invocation: true
---

# Wrapup

The owner wants to know whether this session can be closed. Answer from checks
run now, never from memory. Fix what is safe, then give the verdict.

If you loaded this skill without the owner asking for it, stay read-only: run
the checks, change nothing, and report.

## Ownership

Sort everything you might touch into three classes:

- **Mine:** positive proof only. You created or changed it in this conversation,
  or it is this session's checkout and the diff matches this session's work.
- **Foreign:** a live session or another session's live claim points at it.
- **Unknown:** everything else.

Change only what is mine. Unknown work in the current checkout, or on a branch
this session used, is an open item. Foreign work and unknown work elsewhere go
under "left alone".

## 1. Work against the request

Re-read the original request, every later request in the conversation, and the
acceptance criteria of each ticket the session touched. Mark each item done or
not done. Done needs evidence: a command result, commit, PR or file. Finish small
missing items now. Larger ones become a ticket or an open item.

## 2. Facts

Run this for the current repo, adding every other repo the session changed:

```bash
bash ~/.claude/skills/wrapup/check.sh [repo-path ...]
```

A non-zero exit or a `[FAILED]` section means a check did not run, which is an
open item. List the background processes you started, then stop them or wait for
them.

## 3. Tickets

Use the `kanban` MCP. Its server instructions are canonical and win over this
section.

Build the list of tickets this session touched. `my_work` shows only live
claims, so also use the conversation, ticket ids in this session's branches and
commits, and the repo's open tickets. If the list may be incomplete, for example
after context compaction, that is an open item.

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
steps, and report an open item.

## 4. Knowledge

- Durable lessons go to the homelab-wiki through its normal write path.
- A handoff or decision that exists only in chat goes where the next session will
  find it: the ticket, or the repo docs through their normal flow.
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
be proven mine, or may hold a secret, do not commit or push it. It becomes an open
item.

Never do these. List them as open items instead:

- merge a PR
- push to a protected `main`, unless the repo's rules exempt that change
- force-push, or delete unmerged work
- touch foreign or unknown work
- read a secret

## 7. Verdict

Run `check.sh` again, then make the first line of your reply exactly one of:

```
SAFE TO CLOSE
NOT DONE: <N> open items
```

`SAFE TO CLOSE` needs all of these:

- every requested item is done with evidence, or handed to someone other than the
  owner with its ticket in Waiting
- nothing waits on the owner, including a decision or a merge
- every check ran
- every session ticket is in the right state
- no blocking unknown work remains

Anything else is `NOT DONE`. Never soften it into "yes, after your answers".

Then list, leaving out empty groups:

- **Open items:** one per line, numbered, with what it needs and who acts.
- **Waiting on others:** one per line, with who.
- **Fixed:** what this run changed.
- **Left alone:** foreign and unknown work, once each.
