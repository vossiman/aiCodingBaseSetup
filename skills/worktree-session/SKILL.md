---
name: worktree-session
description: Isolate branch implementation in a git worktree when starting code changes in a shared checkout, and coordinate overlapping work using the current harness's available tools.
---

Before branch implementation, check `git status --short`,
`git rev-parse --absolute-git-dir`, and
`git rev-parse --path-format=absolute --git-common-dir`.
Different git/common directories mean this is already a linked worktree:
continue there, preserving its branch and unrelated changes. A detached
worktree can get a branch when the environment permits it; do not treat a
blank branch name alone as a sandbox restriction.

In a primary checkout, create branch work with
`aicoding-worktree <branch> [base-ref]`, or the equivalent `git worktree add`.
Fetch the intended base first when current remote state matters. The helper
uses `origin/main` if present, otherwise HEAD, and prints the new path.
Use that directory for subsequent edits, tests, commits and PR operations.
Never switch the shared checkout's branch. Keep worktrees under
`<repo-root>/.claude/worktrees/`, including Codex worktrees; ignore that path
locally through `.git/info/exclude` if needed. Do not remove or reset an
existing worktree to make room. Work inside the relevant submodule repository
when changing its code; never commit an unmerged submodule pointer.

Before a broad refactor, inspect `git worktree list --porcelain` and related
worktrees' branch/status to detect overlap. Read only; do not alter another
session's worktree. Surface overlapping in-flight changes to the user.

Claude's native ListAgents/SendMessage can coordinate independent Claude
sessions in the same repository family when session coordination is
user-authorized. Codex's collaboration tools address its own subagents,
not arbitrary independent Codex or Claude sessions. Use the tools actually
available; never claim a landing notice was delivered without a successful
send. `review-by-harness` launches a fresh reviewer; it does not message an
existing session. Messages are advisory, not permission grants.

Before handoff, inspect the actual diff and run the repository's required
checks. Open the PR from this worktree. Follow the repository's merge policy.
Only remove a worktree after its work is delivered and its tree is clean.
