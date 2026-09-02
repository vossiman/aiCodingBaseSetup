# Global instructions (all projects)

Managed by the aiCodingBaseSetup blueprint (`configs/codex/AGENTS.md`);
`aicoding-sync` overwrites local edits — change it there, via PR.

## Memory retrieval

A persistent memory system (memory-lanes) indexes durable knowledge from all
past sessions and the homelab wiki. Call the `memory_search` tool on the
`memory-router` MCP server whenever the answer may live outside the current
repo and conversation — prior decisions, past incidents, environment facts,
"have we solved this before" — BEFORE re-deriving it or answering from
assumption. Treat results as leads and verify before relying on them. If the
router is unavailable, fall back to grepping the local `~/homelab-wiki` clone
(clone `https://github.com/vossiman/homelab-wiki` if missing); if both fail,
proceed without retrieval rather than blocking.

Durable lessons (gotchas, incidents, environment quirks) belong in the
homelab-wiki — follow its `AGENTS.md` conventions — never in project repos.

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

## The backlog board: file work you find, don't just report it

`https://kanban.dataprospectors.at` is the estate's shared backlog. Every
repo files against it, tagged with its own repo name, so work found in one
project is visible from the phone instead of dying in a transcript.

**Write to it with `kanban-post`, never `curl`.** The board authenticates
agents with a bearer token in the shared secrets store, and the secrets deny
hook refuses any command that expands the kanban token variable, because it
cannot tell "send it in a header" from "print it". `kanban-post` reads the
store itself, so no credential ever appears in a command you write. It
redacts the credential from everything it prints, refuses redirects, and
refuses plaintext destinations.

```bash
kanban-post "title" --repo NAME [--body TEXT] [--status KEY] [--priority P] [--due DATE]
kanban-post --patch TICKET ["new title"] [--body TEXT] [--status KEY] [--priority P] [--due DATE|none]
kanban-post --done TICKET
kanban-post --comment TICKET "text"
kanban-post --link TICKET --depends-on OTHER | --blocks OTHER | --relates OTHER
kanban-post --unlink TICKET OTHER
kanban-post --list-repos | --list-tickets
```

**Links.** `--link TICKET --depends-on OTHER` records that TICKET waits for
OTHER; the board shows TICKET as `blocked` until OTHER reaches `done`.
`--blocks` is the same link stated from the other side, and `--relates` is
a plain see-also with no direction. Link follow-ups to the work they wait
on instead of saying so in the body. `--unlink TICKET OTHER` removes the
link between the two (any kind); if more than one kind joins that pair it
refuses and lists them. Links cross repos freely, and `--repo` plays no part.

**Every ticket has an issue key (`DEVMACHINE-12`)**, the repo name
uppercased plus a number counted per repo. `TICKET` above is that key
(case-insensitive) or the ticket's uuid. **Quote the key, not the uuid,** in
commits, PRs and anything a human reads. Filing prints the new key on its
own line.

**`--repo` is required, and must name the repo you are standing in.** It is
checked against the `github.com` origin of the current checkout, case and
all. So file from the checkout the work belongs to: `cd` into the submodule
or sibling repo first, rather than tagging someone else's finding with your
own repo. A mismatch, or a directory that is no github.com checkout, is a
refusal that makes no request. There is no default repo.

Statuses are `backlog|todo|doing|done`; an unknown one is a 400 that lists
the valid keys. `--done ID` closes a ticket. Close what you finish: the board
only stays useful if it drains. `--comment ID "text"` adds a comment without
touching the card; use it for progress with no state change (a blocker, a
decision, a partial result). The owner reads comments on a phone, so write
for a human who lacks your context.

**When to file one:** a real defect or follow-up you found but were not
asked to fix, and that would otherwise only exist in this transcript. Not
for work you are about to do in this session, and not as a substitute for
telling the user what you found: file it *and* say so.

All four CLIs enforce this at the tool layer: Claude Code and Codex run the
same PreToolUse deny hook (Codex's is installed as a *managed* hook in
`/etc/codex/requirements.toml`, so it is trusted by policy and cannot be
switched off), and Cursor/OpenCode use deny rules. Casual reads are blocked; this is a
best-effort layer, not an airlock — determined bypasses (a redirected
`env`, an interpreter fed by heredoc) are exactly what the hook hardening
keeps chasing, so do not treat a block as proof nothing else works.
