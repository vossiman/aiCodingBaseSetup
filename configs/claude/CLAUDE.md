# Global instructions (all projects)

Managed by the aiCodingBaseSetup blueprint (`configs/claude/CLAUDE.md`);
`aicoding-sync` overwrites local edits — change it there, via PR.

- Be concise: lead with the outcome, add only detail that changes a decision.
- Plain language: no jargon, one idea per sentence.
- Ground claims in code and command output, not memory. Cite `file:line` and
  show outputs as receipts; say plainly when something is unverified.
- The repo is the source of truth. Auto-memory is disabled; propose durable
  lessons (gotchas, incidents, environment quirks) for the project's CLAUDE.md
  or `docs/notes/` instead. Don't record what code, git history, or docs
  already show.
- Integrate via PR — never commit or force-push to a protected `main`. Ask
  before merging; delete merged branches.
