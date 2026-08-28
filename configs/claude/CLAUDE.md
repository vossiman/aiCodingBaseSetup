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
  **Search before you write:** call `memory_search` with a one-sentence
  statement of the lesson — phrased as the *lesson*, not the session —
  before editing any page. The read path knows which page and section
  already own it, and that is usually not the page you would guess. A query
  written from raw session text finds the right page 54% of the time; one
  phrased from the distilled lesson, 92% (61 replayed runs, 2026-08-21). A
  hit that is already correct means write nothing; a hit that is wrong or
  partial is the entry you rewrite; an empty result is a real answer. There
  is no `log.md` — the wiki's central changelog was deleted 2026-08-21
  because it restated every page and out-ranked the real owner in
  retrieval; provenance goes in the commit message as a `Source: <repo/
  session, date>` trailer. That is the **write path**.
- **Read path — retrieval.** A persistent memory system indexes durable
  knowledge from all past sessions and the homelab wiki. Matching memories
  are auto-injected into context as `<memory-hints>` blocks — treat them as
  leads, verify before relying on them, and send `memory_feedback` whenever
  you learn the answer they were guessing at: `confirmed` when a hint
  located the entry you relied on or rewrote, `wrong` (with a one-line note
  saying where it actually was) when they were irrelevant or contradicted
  what you verified. Verdicts are the only signal that says whether
  retrieval works — an unreported hint teaches the router nothing. Independently of hints, call the `memory_search`
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

## The backlog board — file work you find, don't just report it

`https://kanban.dataprospectors.at` is the estate's shared backlog. Every
repo files against it, tagged with its own repo name, so work found in one
project is visible from the phone instead of dying in a transcript.

**Write to it with `kanban-post`, never `curl`.** The board authenticates
agents with a bearer token in the shared secrets store, and the secrets deny
hook refuses any command that expands `$KANBAN_TOKEN` — it cannot tell
"send it in a header" from "print it". `kanban-post` is the same answer
`git` got: a helper that reads the store itself, so no credential ever
appears in a command you write. It redacts the credential from everything it
prints, refuses redirects, and refuses plaintext destinations.

```bash
kanban-post "title" --repo NAME [--body TEXT] [--status KEY] [--priority P]
kanban-post --patch TICKET ["new title"] [--body TEXT] [--status KEY] [--priority P]
kanban-post --done TICKET
kanban-post --list-repos | --list-tickets
```

**Every ticket has an issue key — `DEVMACHINE-12`** — the repo name
uppercased plus a number counted per repo. `TICKET` above is that key
(case-insensitive) or the ticket's uuid; both work. **Quote the key, not the
uuid,** in commits, PRs and anything a human reads — that is what it is for.
Filing prints the new key on its own line. Numbers are never reused, so a key
keeps meaning the same work; the one thing that changes it is moving a ticket
to another repo, which re-keys it.

**`--repo` is required, and must name the repo you are standing in** — it is
checked against the `github.com` origin of the current checkout, case and
all. So file from the checkout the work belongs to: `cd` into the submodule
or sibling repo first, rather than tagging someone else's finding with your
own repo. A mismatch, and a directory that is no github.com checkout at all,
are both refusals that make no request. There is no default: everything used
to land in `devMachine`, which made the per-repo filter on the phone useless.

A repo the board has not seen yet registers itself on first use — the name
comes from the remote, so it cannot be a typo. Statuses are
`backlog|todo|doing|done`; an unknown one is a 400 that lists the valid keys.

`--done ID` closes a ticket (shorthand for `--patch ID --status done`). Close
what you finish: the board only stays useful if it drains.

**When to file one:** a real defect or follow-up you found but were not
asked to fix, and that would otherwise only exist in this transcript. Not
for work you are about to do in this session, and not as a substitute for
telling the user what you found — file it *and* say so.

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
- **The file is not the only route, and the others are blocked too**: the
  process environment (`printenv GH_TOKEN` — the token is no longer exported),
  the git credential helper (`git credential fill`, `git-credential-*`), and
  `gh auth token`. Don't reach for them.
- **You do not need the token to use GitHub.** `git` and `gh` are already
  authenticated from the secrets file — just run them.

All four CLIs enforce this at the tool layer: Claude Code and Codex run the
same PreToolUse deny hook (Codex's is installed as a *managed* hook in
`/etc/codex/requirements.toml`, so it is trusted by policy and cannot be
switched off), and Cursor/OpenCode use deny rules. Casual reads are blocked; this is a
best-effort layer, not an airlock — determined bypasses (a redirected
`env`, an interpreter fed by heredoc) are exactly what the hook hardening
keeps chasing, so do not treat a block as proof nothing else works.
