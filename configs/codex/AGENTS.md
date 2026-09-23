# Global instructions (all projects)

Managed by the aiCodingBaseSetup blueprint (`configs/codex/AGENTS.md`);
`aicoding-sync` overwrites local edits — change it there, via PR.

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

## Bugsink API access

- The estate instance is `https://bugsink.dataprospectors.at`. Its API
  credential in the shared secret store is **`BUGSINK_AUTH_TOKEN`**. Check
  availability with `secrets-check BUGSINK_AUTH_TOKEN`; do not guess other
  token names and conclude that access is missing.
- `HUB_BUGSINK_TOKEN` is notify-hub's deployment setting, not the name of
  the shared agent credential. `HUB_BUGSINK_URL` is the server URL, not a
  project DSN.
- The canonical API uses bearer authentication. Retrieve a project's
  details, including its `dsn`, with
  `GET /api/canonical/0/projects/{id}/`; discover projects with
  `GET /api/canonical/0/projects/`. Use the returned DSN to submit a uniquely
  labeled smoke-test error through Sentry-compatible ingestion. The user
  does not need to copy a DSN when authenticated API access is available.
- Use **`bugsink-api`**, which reads the credential internally and redacts
  credentials and DSNs from its output. Never expand the token in shell
  commands or read the secret store yourself. Commands:

  ```bash
  bugsink-api projects
  bugsink-api project 1
  bugsink-api issues                    # every project, all pages
  bugsink-api issues --project 1
  bugsink-api issue ISSUE_UUID_OR_FRIENDLY_ID
  bugsink-api smoke --project 1         # creates one uniquely grouped error
  ```

  The helper refuses redirects and pins production requests to the estate
  instance. A smoke-test submission confirms ingestion acceptance, not
  Telegram delivery; let the user confirm receipt when that is their request.

## Kanban work

Use the installed `kanban` MCP for ticket reads, claims, checkpoints, release,
completion, comments, links, and follow-up filing. Its server instructions are
the canonical workflow. Native lifecycle adapters bind the supplied work-session
handle and release unfinished claims when a turn stops. `kanban-post` remains a
credential-safe recovery CLI; it is not a status-transition bypass.

All four CLIs enforce the secret-file restrictions above at the tool layer:
Claude Code and Codex run the
same PreToolUse deny hook (Codex's is installed as a *managed* hook in
`/etc/codex/requirements.toml`, so it is trusted by policy and cannot be
switched off), and Cursor/OpenCode use deny rules. Casual reads are blocked; this is a
best-effort layer, not an airlock — determined bypasses (a redirected
`env`, an interpreter fed by heredoc) are exactly what the hook hardening
keeps chasing, so do not treat a block as proof nothing else works.


## Shared development workflows

- Superpowers is installed through Codex's native plugin catalog. Use its
  relevant planning, debugging, implementation and verification skills when
  the task benefits from them; the user's scope and authorization take precedence.
- Local estate skills are shared through `~/.agents/skills`. For an independent
  PR review, use `review-by-harness` with an explicit `--harness`, `--model`,
  and supported `--effort`. Choose Claude for a different-vendor review unless
  the user chose otherwise. Default to Opus 5 (`claude-opus-5`) or GPT-5.6 Sol
  (`gpt-5.6-sol`) for the selected harness. Fable and Astra require an explicit
  user override. Verify findings against code.
- `housekeep` archives completed docs and prunes dated completed TODO entries.
- To start a project, copy `templates/project/` from the aiCodingBaseSetup
  checkout (`/tmp/aicoding` in containers), substitute `{{PROJECT_NAME}}` and
  `{{PURPOSE}}`, strip `.tpl` suffixes, and rename `dot-claude/` to `.claude/`.
  The retired scaffold command is not needed.
- Put deliverable files in `out/` at the repo root for `dvw pull`. Preserve
  existing contents and announce the path.
- Automatic memory hints are leads, not facts. Verify them and use
  `memory_feedback` with `confirmed` or `wrong` when the outcome is known.


## Worktree isolation and session coordination

For branch implementation, use the shared `worktree-session` skill. Create a
worktree at `<repo-root>/.claude/worktrees/<branch>` with `aicoding-worktree`
or `git worktree add`; if already in a linked worktree, continue there.
Never switch branches in a shared project or submodule checkout. Check for
other worktrees before broad changes, and surface overlapping work.
Codex collaboration tools coordinate this session's own subagents. They do
not message independent sessions or Claude Code. Use `review-by-harness` for
a fresh independent reviewer; do not mistake that for cross-session messaging.
