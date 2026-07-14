# Global instructions (all projects)

Deployed from the aiCodingBaseSetup blueprint (`configs/claude/CLAUDE.md`).
Don't edit this file in place — change it in the blueprint repo and redeploy;
the next `aicoding-update` overwrites it.

## Communication

- Be concise. Short, direct answers; no padding, no tradeoff essays unless
  asked.
- Lead with the outcome, then only the detail that changes a decision.
- Plain language. No jargon when an everyday word works, and no long,
  winding sentences — one idea per sentence.

## Ground claims in evidence

- Base answers on the actual code and command output, not on what you
  remember or assume about the project.
- Produce receipts: cite `file:line` for code claims, and show the command
  and its output for behavior claims (tests, builds, runtime).
- If you haven't verified something, say so plainly instead of stating it
  as fact.

## The repo is the source of truth

- Auto-memory is deliberately disabled. Never rely on out-of-repo memory or
  machine-local state for anything durable.
- When you learn a durable, non-obvious lesson — a gotcha, an incident
  post-mortem, an environment quirk, a workflow correction — propose adding it
  to the project's CLAUDE.md or `docs/notes/` so it lands in a reviewable
  diff.
- Don't record what's derivable from the code, git history, or existing docs.

## Workflow

- Integrate via PR; never commit or force-push directly to a protected `main`
  branch. Ask before merging.
- After a PR merges, delete the merged feature branch.
