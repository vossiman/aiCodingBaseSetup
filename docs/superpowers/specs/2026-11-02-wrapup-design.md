# `/wrapup`: end-of-session check for every harness

Date: 2026-11-02
Status: approved by owner, reviewed by Codex gpt-6-astra

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

- It says safe while a decision still waits on the owner.
- It says safe because a check could not run.
- It touches another session's worktree, branch or claim.
- It merges, force-pushes or deletes unmerged work on its own.
- It reads a secret. The usual deny rules apply.

## Name and delivery

The name is `wrapup` (owner decision).

- `skills/wrapup/SKILL.md`: the full workflow, one copy for all harnesses.
- `skills/wrapup/check.sh`: the fact-gathering script, run with
  `bash ~/.claude/skills/wrapup/check.sh`, the same way `routes.sh` is run.
- `commands/wrapup.md`: thin wrapper, same pattern as `commands/housekeep.md`.
- `docs/agent-parity.md` and the README get a row next to Housekeeping.

Reach per harness:

- Claude: `/wrapup` through `~/.claude/commands` (`lib/blueprint-deploy.sh:368`).
- Codex: `$wrapup` through the `~/.agents/skills` link (`lib/sync.sh:218`).
- OpenCode: loads the skill from `~/.claude/skills` or `~/.agents/skills`
  (confirmed with `opencode debug skill`). `/wrapup` comes from the `command`
  block in `configs/opencode/opencode.json`.
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
compaction, that is an open item and the verdict is `NOT DONE`.

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
steps as normal, and end in `NOT DONE`.

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

Re-run `check.sh`, then finish with exactly one of these as the first line:

```
SAFE TO CLOSE
NOT DONE: <N> open items
```

`SAFE TO CLOSE` needs all of the following:

- every requested item is done with evidence, or handed to someone other than
  the owner with its ticket in Waiting (listed under "waiting on others")
- nothing waits on the owner, including a decision or a merge
- every check ran
- every session ticket is in the right state
- no blocking unknown work remains

Anything else is `NOT DONE`, including a check that could not run. Open items
are listed one per line, each with what it needs and who acts. Foreign and
non-blocking unknown items are mentioned once under "left alone" and do not
affect the verdict. A short list of what `/wrapup` fixed follows.

The agent does not soften this into "yes, after your answers". Open decisions
mean `NOT DONE`.

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
  - a gap it cannot repair (an open owner decision, a stale ticket whose
    criteria are unmet, a dirty file of unknown owner in the checkout) ends in
    `NOT DONE` with nothing changed

## Calls made by the author, not the owner

- An open PR waiting on the owner is `NOT DONE`. One handed to someone else,
  with its ticket in Waiting, can be `SAFE TO CLOSE`.
- An incomplete ticket list means `NOT DONE` rather than a guess.
- Unknown-owner work blocks only in the current checkout or on a branch the
  session used.
- There is no durable per-session ticket record in this version.

## Left to the builder

- The exact output format of `check.sh`.
- How `gh` absence or failure is reported, within the rule that a check that
  could not run is a failed check.
- How to size the Cursor and OpenCode adapters, if they need one.
