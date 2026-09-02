---
name: aicoding-estate
description: Estate conventions for every task on this machine. Use at the start of any session and whenever a question may have been answered before (memory retrieval via the memory-router MCP), whenever you find a defect or follow-up you were not asked to fix (file it on the kanban backlog board with kanban-post), and whenever a command would touch a secrets file, a private key, or a token (run secrets-check instead of reading them).
---

# Estate conventions

Managed by the aiCodingBaseSetup blueprint
(`configs/cursor/skills/aicoding-estate/SKILL.md`); `aicoding-sync`
overwrites local edits, so change it there, via PR. Cursor has no
file-backed global rules (User Rules live in the account, not on disk), so
this global skill carries the same guidance that Claude Code reads from
`~/.claude/CLAUDE.md` and Codex from `~/.codex/AGENTS.md`.

## Memory retrieval

A persistent memory system (memory-lanes) indexes durable knowledge from all
past sessions and the homelab wiki. Call the `memory_search` tool on the
`memory-router` MCP server whenever the answer may live outside the current
repo and conversation (prior decisions, past incidents, environment facts,
"have we solved this before") BEFORE re-deriving it or answering from
assumption. Treat results as leads and verify before relying on them. If the
router is unavailable, fall back to grepping the local `~/homelab-wiki`
clone (clone `https://github.com/vossiman/homelab-wiki` if missing); if both
fail, proceed without retrieval rather than blocking.

Durable lessons (gotchas, incidents, environment quirks) belong in the
homelab-wiki, following its `AGENTS.md` conventions, never in project repos.

## The backlog board: file work you find, don't just report it

`https://kanban.dataprospectors.at` is the estate's shared backlog. Every
repo files against it, tagged with its own repo name, so work found in one
project is visible from the phone instead of dying in a transcript.

**Write to it with `kanban-post`, never `curl`.** The board authenticates
agents with a bearer token in the shared secrets store. `kanban-post` reads
the store itself, so no credential ever appears in a command you write. It
redacts the credential from everything it prints, refuses redirects, and
refuses plaintext destinations.

```bash
kanban-post "title" --repo NAME [--body TEXT] [--status KEY] [--priority P] [--due DATE]
kanban-post --patch TICKET ["new title"] [--body TEXT] [--status KEY] [--priority P] [--due DATE|none]
kanban-post --done TICKET
kanban-post --comment TICKET "text"
kanban-post --list-repos | --list-tickets
```

**Every ticket has an issue key (`DEVMACHINE-12`)**, the repo name
uppercased plus a number counted per repo. `TICKET` above is that key
(case-insensitive) or the ticket's uuid. **Quote the key, not the uuid,** in
commits, PRs and anything a human reads. Filing prints the new key on its
own line.

**`--repo` is required, and must name the repo you are standing in.** It is
checked against the `github.com` origin of the current checkout, case and
all. So file from the checkout the work belongs to: `cd` into the submodule
or sibling repo first. A mismatch, or a directory that is no github.com
checkout, is a refusal that makes no request. There is no default repo.

Statuses are `backlog|todo|doing|done`. `--done ID` closes a ticket. Close
what you finish: the board only stays useful if it drains. `--comment ID
"text"` adds a comment without touching the card; use it for progress with
no state change. The owner reads comments on a phone, so write for a human
who lacks your context.

**When to file one:** a real defect or follow-up you found but were not
asked to fix, and that would otherwise only exist in this transcript. Not
for work you are about to do in this session, and not as a substitute for
telling the user what you found: file it *and* say so.

## Secrets: never read them

`~/.aicodingsetup/.secrets.env` and any private key (`*.pem`, `*.key`,
`id_rsa`/`id_ed25519`, `~/.aicodingsetup/*-ship`) are off-limits. Reading
one copies live credentials into the transcript, which is persisted and
distilled to the wiki, a leak that outlives the session.

- To find out whether a secret is configured, run `secrets-check` (or
  `secrets-check GH_TOKEN`). It prints key names, set/empty, length and a
  salted fingerprint, never a value, and exits non-zero if a requested key
  is empty.
- If you genuinely need a value, ask the user. Do not cat, source, grep,
  `base64`, or otherwise echo these files, and never route around a deny
  rule that blocks them.
- The process environment (`printenv`, a bare `env`), the git credential
  helper (`git credential fill`), and `gh auth token` are blocked too.
- You do not need the token to use GitHub. `git` and `gh` are already
  authenticated from the secrets file, so just run them.
