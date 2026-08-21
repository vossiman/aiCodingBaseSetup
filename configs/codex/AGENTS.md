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

All four CLIs enforce this at the tool layer: Claude Code and Codex run the
same PreToolUse deny hook (Codex's is installed as a *managed* hook in
`/etc/codex/requirements.toml`, so it is trusted by policy and cannot be
switched off), and Cursor/OpenCode use deny rules. Attempts are refused, not
silently ignored.
