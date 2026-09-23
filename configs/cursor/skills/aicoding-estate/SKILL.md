---
name: aicoding-estate
description: Estate conventions for every task on this machine. Use at the start of any session, whenever a question may have been answered before, whenever unplanned follow-up belongs on the Kanban board through its installed MCP, or whenever a command could expose a secret, private key, or token.
---

# Estate conventions

Managed by the aiCodingBaseSetup blueprint
(`configs/cursor/skills/aicoding-estate/SKILL.md`); `aicoding-sync`
overwrites local edits, so change it there, via PR. Cursor has no
file-backed global rules (User Rules live in the account, not on disk), so
this global skill carries the same guidance that Claude Code reads from
`~/.claude/CLAUDE.md` and Codex from `~/.codex/AGENTS.md`.

## Configuration scope

Default configuration changes to the current repository. This includes model
and reasoning-effort changes: a request such as "use Astra" applies to the
current repo unless the user explicitly asks for a default across all repos
from now on. Use the tool's supported repo-local configuration, for example
`<repo>/.codex/config.toml` for Codex. Follow the user's preference on whether
to commit that file or keep it local with Git ignore rules.

Change home-level or other shared configuration only when the user explicitly
requests that scope. If the shared file is managed by `aicoding-sync`, make
that change in the aiCodingBaseSetup blueprint via PR so future syncs retain
it. If a tool has no repo-local override, explain that limitation instead of
silently broadening the change to all repos. This rule governs agent edits;
it does not redirect runtime state that a tool writes to its home directory.

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

## Kanban work

Use the installed `kanban` MCP for ticket reads, claims, checkpoints, release,
completion, comments, links, and follow-up filing. Its server instructions are
the canonical workflow. Native lifecycle adapters bind the supplied work-session
handle and release unfinished claims when a turn stops. `kanban-post` remains a
credential-safe recovery CLI; it is not a status-transition bypass.

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
