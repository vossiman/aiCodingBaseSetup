# Global instructions (all projects)

Managed by the aiCodingBaseSetup blueprint (`configs/claude/CLAUDE.md`);
`aicoding-sync` overwrites local edits — change it there, via PR.

- Be concise: lead with the outcome, add only detail that changes a decision.
- Plain language: no jargon, one idea per sentence.
- Ground claims in code and command output, not memory. Cite `file:line` and
  show outputs as receipts; say plainly when something is unverified.
- The repo is the source of truth. Auto-memory is disabled. Durable lessons
  (gotchas, incidents, environment quirks) split two ways: **cross-project**
  facts — hosts, network, ports, backups, incidents, tool identities — go to
  the homelab-wiki (`~/homelab-wiki`; clone
  `https://github.com/vossiman/homelab-wiki` if missing, then follow its
  `AGENTS.md`: pull first, edit the owning page — grep it and **rewrite the
  entry that already covers the topic**, never append a "correction to the
  entry above" bullet — then commit+push to its `main` autonomously; that
  repo's governance allows it). **Project-internal**
  lessons go to the project's CLAUDE.md or `docs/notes/`. Don't record what
  code, git history, or docs already show. For homelab questions, consult
  `~/homelab-wiki` before re-deriving from raw repos.
- Integrate via PR — never commit or force-push to a protected `main`. Ask
  before merging; delete merged branches.

## Parallel-session coordination

Other sessions in this container are the user's own sessions working this
same project, usually in sibling worktrees.

- **After landing changes** (merge to main, rebase, force-push, or a change
  to a shared interface/schema): run ListAgents; if sibling sessions exist,
  message each a short summary — what landed, which files or areas were
  touched, and whether rebasing is now needed or now safe.
- **Before starting work that spans many files** (refactor, rename,
  formatting sweep): ask sibling sessions which files they have in flight,
  and surface overlaps to the user instead of proceeding blind.
- **On receiving such a message:** diff its touched-files list against your
  own working set; if they intersect, tell the user before continuing.
- Never ask another session to perform an action your own session's
  permissions would block.
- Name sessions after their branch (`claude --name <branch>` or `/rename`) —
  auto-names derive from folder basenames and collide across worktrees.
- **Branch work always takes a dedicated git worktree.** Never switch
  branches in a checkout other sessions may share (the project root or a
  submodule checkout); a checkout's current branch is repo state, not
  per-session state. Shared checkouts are neutral ground: project root on
  `main`, submodule checkouts detached at the parent's pinned SHA.
- **If a merge conflict between parallel worktree branches occurs that no
  cross-session message forewarned**, log a row to the "Cross-session
  messaging — Layer 3 gate evidence" table on the homelab-wiki `aicoding`
  page (date, repo, branches, overlapping files, cleanup cost). Notable
  saves — a message that demonstrably prevented a conflict — get a row in
  the saves table.
