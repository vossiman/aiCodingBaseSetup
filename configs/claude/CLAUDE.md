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
  `AGENTS.md`: pull first, edit the owning page, commit+push to its `main`
  autonomously — that repo's governance allows it). **Project-internal**
  lessons go to the project's CLAUDE.md or `docs/notes/`. Don't record what
  code, git history, or docs already show. For homelab questions, consult
  `~/homelab-wiki` before re-deriving from raw repos.
- Integrate via PR — never commit or force-push to a protected `main`. Ask
  before merging; delete merged branches.
