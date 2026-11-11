# `/wrapup`: end-of-session check for every harness

Date: 2026-11-02
Status: approved by owner, reviewed by Codex gpt-6-astra. Amended 2026-11-02: see
"Close verdict amendment".

## Why

The owner ends sessions by asking the same thing in every harness: "all done
here? can I close this session? everything documented, cleaned up, committed,
pushed?" The answer is often a confident yes from memory.

A transcript audit on 2026-11-02 covered about 4,190 local sessions (Claude,
Codex, T3, OpenCode, Cursor) and found 36 real closing questions. 19 of them
turned up a gap. These are minimum counts, because keyword search misses some
questions.

| Gap | Times |
|---|---|
| Ticket stale, missing or in the wrong column | 7 |
| Uncommitted or unpushed work (all Codex) | 5 |
| Open decision hidden behind a "yes" | 3 |
| Docs or handoff only in chat | 2 |
| PR still open or not released | 2 |
| Requested work not done | 1 |
| Stale local branch reference | 1 |

The owner also reports unfinished work and skipped cleanup from experience.

## Close verdict amendment

The first version asked whether the work was finished. The owner's real question
is whether the session can be closed so work rolls into a new one. All three
`NOT DONE` runs on 2026-11-02 were in memory-lanes sessions (2de1e14a twice,
c29d467e once). Each had no claims and nothing unpushed, and the board held the
remaining work. In both sessions the owner had to ask again, and the agent then
said yes. In c29d467e one open item also asked the owner for proof they did not
want.

So the verdict now answers "does closing lose anything?". This replaces the
first version's rule that anything waiting on the owner blocks the close.
Unfinished work and owner decisions no longer block when they are on a ticket,
but they must still be listed. The rest of this spec uses "open item" for what
is now a blocker or a carry-over item.

## Goals

- One word from the owner replaces the closing question.
- The answer comes from checks run now, not from the agent's memory.
- The agent fixes what it safely can, then reports what is left.
- The result is a verdict the owner can act on without reading further.

## Non-goals

- No check of deployment or release. A merge is not always meant to ship
  straight away (owner decision), so the check neither asks nor reports how far
  merged work travelled.
- No Stop hook or automatic trigger in this version. The agent stops often, and
  most stops are not the end of a session. A warning hook may come later if the
  owner still forgets the command.
- No ending of the session. The kanban rules forbid agents from doing that.

## Anti-goals

The design has failed, even if it runs, if any of these happen:

- It says safe while a decision exists only in the conversation, or leaves a
  waiting decision off the list.
- It says safe because a check could not run.
- It touches another session's worktree, branch or claim.
- It merges, force-pushes or deletes unmerged work on its own.
- It reads a secret. The usual deny rules apply.

## Name and delivery

The name is `wrapup` (owner decision).

- `skills/wrapup/SKILL.md`: the full workflow, one copy for all harnesses.
- `skills/wrapup/check.sh`: the fact-gathering script, run with
  `bash ~/.claude/skills/wrapup/check.sh`, the same way `routes.sh` is run.
- `docs/agent-parity.md` and the README get a row next to Housekeeping.

Reach per harness:

- Claude: `/wrapup` straight from the skill, since Claude Code lists user
  skills as slash commands. A `commands/wrapup.md` wrapper shipped at first and
  was retired on 2026-11-11 because it showed `/wrapup` twice.
- Codex: `$wrapup` through the `~/.agents/skills` link (`lib/sync.sh:218`).
- OpenCode: loads the skill from `~/.claude/skills` or `~/.agents/skills`
  (confirmed with `opencode debug skill`). OpenCode also registers each skill
  as a slash command unless a configured command has the same name, so the
  former `command.wrapup` block was redundant and is retired.
- Cursor: `lib/sync.sh:211` says it scans `~/.claude/skills`. Its CLI has no
  skill listing, so this is not yet confirmed.
- Codex implicit use is disabled by `skills/wrapup/agents/openai.yaml`, and
  Claude's by `disable-model-invocation`. OpenCode has no such setting, so the
  skill itself stays read-only unless the owner invoked it.
- Pi: out of scope for this version.

## The workflow

Steps run in this order. The first pass finds and fixes. The last step re-runs
the script so the verdict rests on the final state.

### 1. Work against the request

Re-read the original request and any later requests in the conversation, plus
the acceptance criteria of each ticket the session touched. Mark each item done
or not done. Done needs evidence: a command result, commit, PR or file. Finish
small missing items now. Anything larger becomes a ticket or an open item. A
script cannot judge this, so this step stays with the agent.

### 2. Facts from the script

`check.sh` is read-only and reports, for the current repo and each repo the
session names as an argument:

- uncommitted changes, stashes, unpushed commits, branches with no upstream
- open PRs from the current branch, with check state
- local branches already merged into the default branch
- worktrees, each marked foreign or unknown
- submodules with local changes or commits not on a remote
- files in `out/`, and other artifacts the session names

Ownership has three classes, because the session registry at
`~/.claude/sessions/*.json` proves nothing about other harnesses:

- **Mine:** positive proof only. The session created or changed it in this
  conversation, or it is this session's own checkout and the diff matches this
  session's work. The agent decides this, not the script.
- **Foreign:** proven. A live registry entry or a live claim by another session
  points at it. The script marks these where it can.
- **Unknown:** everything else. Never changed by `/wrapup`.

Unknown work in the current checkout, or on a branch the session used, blocks
the verdict. Unknown work elsewhere is listed as "unclear, left alone" and does
not block, otherwise stale worktrees would block every session.

The script exits non-zero if a section could not run, and names the section.

The script does not cover background processes, because they are known to the
harness rather than to git. The agent lists what it started and stops it or
waits for it.

### 3. Tickets

Using the `kanban` MCP. Its server instructions stay the canonical workflow, and
this step follows them where they differ.

First build the list of tickets the session touched. `my_work` shows only live
claims, and a Stop hook may already have released earlier ones
(`lib/kanban_work/queue.py:115`), so it is not enough. Use the conversation,
ticket ids in this session's branches and commits, and the repo's open tickets
on the board. If the list may be incomplete, for example after context
compaction, that is a blocker.

For each ticket:

- Check who holds it now. Never take over another live session's claim.
- Claim it again first if the claim was released, since `complete_ticket` needs
  one. A ticket in Waiting closes through `resolve_feedback` instead.
- Complete it only with evidence, once its acceptance criteria are met on the
  target branch.
- A ticket with an open PR is released with reason `feedback`, naming the
  `feedback_target`.
- Read the body as a stranger would. If it still describes an old plan, update
  it.
- Release any claim still held before finishing, on every harness, because not
  all of them have a Stop event.

Each unfinished finding, follow-up or leftover that lives only in chat or in a
doc gets a ticket. Work that was found and finished in this session needs no
retrospective ticket, in line with the MCP's filing rules.

With no kanban MCP or no valid handle, skip the ticket writes, run the other
steps as normal, and report a blocker.

### 4. Knowledge

- Durable lessons go to the homelab-wiki through its normal write path.
- A handoff or decision that exists only in chat goes where the next session
  will find it: the ticket, or the repo docs through their normal flow.
- Files the owner needs are in `out/` and announced by path. Anything else that
  exists on only one machine is reported, with its size.

### 5. Repo end-of-session rules

Follow what the repo's `CLAUDE.md` or `AGENTS.md` asks for at session end. In
devMachine that is the submodule pointer bump. No repo's rule is hardcoded in
the skill.

### 6. Fix what is safe

An explicit `/wrapup` from the owner authorizes the following, for work proven
mine only. A skill that loaded itself by matching a description authorizes
nothing, so its frontmatter disables automatic use where the harness allows it,
and the skill stays read-only unless the owner invoked it.

- commit and push to this session's feature branch
- delete this session's worktrees and local branches once merged
- stop processes this session started
- all kanban and wiki writes above

It never does the following, and lists them as open items instead:

- merge a PR
- push to a protected `main`, except where the repo's rules exempt it
- force-push, or delete unmerged work
- touch anything of another session's

Before any commit or push, inspect the index, the exact diff to be committed,
and the whole outgoing commit range. Stage named files, never everything. If
the staged content, a file with mixed edits, or any outgoing commit cannot be
proven mine, or may hold a secret, do not commit or push it. It becomes an open
item.

### 7. Verdict

Re-run `check.sh`, then start with one of these:

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

The verdict is about closing the session, not finishing the work. A blocker is
something lost or stuck if the session closes now, which this run could not fix:
work or a decision held only in the conversation or in an unpushed change, a
process in the session that is still needed, a held claim or wrong ticket state,
a check that did not run, an incomplete ticket list, or blocking unknown work.

Unfinished work with a ticket and a usable handoff carries over, and so does a
decision or merge waiting on the owner once it is written on its ticket, and
work running outside the session. Each carry-over item is listed with its ticket
and who acts next, owner items first, followed by a line the owner can paste to
start the next session. Foreign and non-blocking unknown items are mentioned once
under "left alone". A short list of what `/wrapup` fixed follows.

## Testing

- Bats tests for `check.sh` using temporary git repos: dirty tree, stash,
  unpushed commit, no upstream, merged branch, foreign worktree, submodule with
  local change, failing section gives non-zero exit.
- The deployment tests in `tests/bats/install.bats` cover the new skill and
  command where they cover `housekeep`, and also run the deployed `check.sh`,
  since those tests today check Markdown only.
- A fresh session in each of Claude, Codex, Cursor and OpenCode must find the
  skill. A harness that cannot is reported in the PR, not assumed.
- Manual runs in one Claude and one Codex session:
  - a gap `/wrapup` can repair (an unpushed commit on its own branch) gets
    fixed, and the run ends in `SAFE TO CLOSE`
  - unfinished work with a ticket and an owner decision on its ticket end in
    `SAFE TO CLOSE` with both listed as carrying over
  - a gap it cannot repair (a dirty file of unknown owner in the checkout) ends
    in `DO NOT CLOSE` with nothing changed

## Calls made by the author, not the owner

- An open PR with its ticket in Waiting carries over, whoever it waits on.
- An incomplete ticket list means `DO NOT CLOSE` rather than a guess.
- Unknown-owner work blocks only in the current checkout or on a branch the
  session used.
- There is no durable per-session ticket record in this version.

## Left to the builder

- The exact output format of `check.sh`.
- How `gh` absence or failure is reported, within the rule that a check that
  could not run is a failed check.
- How to size the Cursor and OpenCode adapters, if they need one.
