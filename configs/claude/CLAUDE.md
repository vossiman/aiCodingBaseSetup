# Global instructions (all projects)

Managed by the aiCodingBaseSetup blueprint (`configs/claude/CLAUDE.md`);
`aicoding-sync` overwrites local edits — change it there, via PR.

- Be concise: lead with the outcome, add only detail that changes a decision.
- Plain language: no jargon, one idea per sentence.
- Ground claims in code and command output, not memory. Cite `file:line` and
  show outputs as receipts; say plainly when something is unverified.
- The repo is the source of truth for code; the homelab-wiki is the source
  of truth for lessons. Auto-memory is disabled. ALL durable lessons
  (gotchas, incidents, environment quirks) go to the homelab-wiki
  (`~/homelab-wiki`; clone `https://github.com/vossiman/homelab-wiki` if
  missing, then follow its `AGENTS.md`: pull first, edit the owning page —
  grep it and **rewrite the entry that already covers the topic**, never
  append a "correction to the entry above" bullet — then commit+push to its
  `main` autonomously; that repo's governance allows it). **Cross-project**
  facts — hosts, network, ports, backups, incidents, tool identities — go
  to their topic page; **project-scoped** lessons go to that project's page
  `wiki/<repo>.md` (create it if missing, register it in `index.md`). Never
  land memory-write commits in project repos (decided 2026-08-17: a docs
  note pushed to a project `main` triggered a prod deploy, and the memory
  read path indexes only the wiki — in-repo notes are invisible to it). A
  project's CLAUDE.md and `docs/` are for deliberate, reviewed
  documentation — specs, plans, READMEs — via the normal PR flow, not a
  memory store. Don't record what code, git history, or docs already show.
  That is the **write path**.
- **Read path — retrieval.** A persistent memory system indexes durable
  knowledge from all past sessions and the homelab wiki. Matching memories
  are auto-injected into context as `<memory-hints>` blocks — treat them as
  leads, verify before relying on them, and report decisive or wrong hints
  via `memory_feedback`. Independently of hints, call the `memory_search`
  MCP tool (the `memory-router` server) whenever the answer may live outside
  the current repo and conversation — prior decisions, past incidents,
  environment facts, "have we solved this before" — BEFORE re-deriving it or
  answering from assumption. If the router is unavailable, fall back to
  grepping the local `~/homelab-wiki` clone; if both fail, proceed without
  retrieval rather than blocking. Retrieval never replaces the write path
  above: durable lessons still get written to the wiki under its own
  `AGENTS.md` conventions.
- Integrate via PR — never commit or force-push to a protected `main`. Ask
  before merging; delete merged branches.

## Parallel-session coordination

Other sessions on this host are the user's own — but not necessarily on this
project: on a desktop, ListAgents also lists sessions in unrelated repos.
**Siblings** are only sessions working the same repo family: this repo, any
worktree of it, or its superproject/submodules (submodule names come from
`.gitmodules`). All coordination below applies to siblings only; never
message unrelated sessions — cross-project chatter just burns tokens.

- **Finding siblings — never guess from session names.** The live session
  registry `~/.claude/sessions/*.json` records each running session's
  exact `cwd`; its `name` field matches the name ListAgents shows. Map
  each peer's name to its cwd there, then check repo family with git:
  sibling if that cwd's `git rev-parse --show-toplevel` equals yours, is
  listed in your `git worktree list`, or is your superproject or one of
  your submodules (`.gitmodules`) — branches never enter it. If the
  registry is missing or a cwd doesn't resolve to a repo, skip that
  session. Never compare cwd strings as paths — lookalike paths (every
  devcontainer has some `/workspaces/<name>`) prove nothing; only the git
  resolution counts. In devpod containers `~/.claude` is one host mount
  shared by all containers, so registry entries may belong to sessions in
  other containers (and pid-keyed files can collide) — the git check
  absorbs that too: a foreign cwd won't resolve into your repo family and
  gets skipped.
- Name sessions after their branch (`claude --name <branch>` or
  `/rename`) — purely for human legibility; auto-names derive from folder
  basenames and collide across worktrees. Names play no role in sibling
  detection.
- **After landing changes** (merge to main, rebase, force-push, or a change
  to a shared interface/schema): run ListAgents; if siblings exist, message
  each a short summary — what landed, which files or areas were touched,
  and whether rebasing is now needed or now safe.
- **Before starting work that spans many files** (refactor, rename,
  formatting sweep): ask sibling sessions which files they have in flight,
  and surface overlaps to the user instead of proceeding blind.
- **On receiving such a message:** if the sender is outside your repo
  family, no action is needed. Otherwise diff its touched-files list
  against your own working set; if they intersect, tell the user before
  continuing.
- Never ask another session to perform an action your own session's
  permissions would block.
- **Branch work always takes a dedicated git worktree.** Never switch
  branches in a checkout other sessions may share (the project root or a
  submodule checkout); a checkout's current branch is repo state, not
  per-session state. Shared checkouts are neutral ground: project root on
  `main`, submodule checkouts detached at the parent's pinned SHA.
- **Worktrees live inside the project, nowhere else:** create them at
  `<repo-root>/.claude/worktrees/<branch>` — the same place Claude Code's
  native worktree feature uses — never under `../`, `$HOME`, or temp
  dirs. One predictable location keeps worktrees discoverable and lets
  them die with the repo instead of littering the host. If they show up
  as untracked in `git status`, add `.claude/worktrees/` to
  `.git/info/exclude` (local, never committed).
- **If a merge conflict between parallel worktree branches occurs that no
  cross-session message forewarned**, log a row to the "Cross-session
  messaging — Layer 3 gate evidence" table on the homelab-wiki `aicoding`
  page (date, repo, branches, overlapping files, cleanup cost). Notable
  saves — a message that demonstrably prevented a conflict — get a row in
  the saves table.

## Secrets — never read them

`~/.aicodingsetup/.secrets.env` and any private key (`*.pem`, `*.key`,
`id_rsa`/`id_ed25519`, `~/.aicodingsetup/*-ship`) are off-limits. Reading one
copies live credentials into the transcript, which is persisted and distilled
to the wiki — a leak that outlives the session.

- To find out whether a secret is configured, run **`secrets-check`** (or
  `secrets-check GH_TOKEN`). It prints key names, set/empty, length and a
  salted fingerprint — never a value — and exits non-zero if a requested key
  is empty.
- If you genuinely need a value, ask the user. Do not cat, source, grep,
  `base64`, or otherwise echo these files, and never route around a deny hook
  or permission rule that blocks them.

All four CLIs enforce this at the tool layer: Claude Code and Codex run the
same PreToolUse deny hook (Codex's is installed as a *managed* hook in
`/etc/codex/requirements.toml`, so it is trusted by policy and cannot be
switched off), and Cursor/OpenCode use deny rules. Attempts are refused, not
silently ignored.
