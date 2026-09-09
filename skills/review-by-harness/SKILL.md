---
name: review-by-harness
description: Use when asked to review an open PR with a second opinion from another agent - Claude Code, Codex, or Cursor, with an explicitly selected reviewer model - and especially when asked to have that harness also FIX what it finds. Runs the external harness in a throwaway worktree, then verifies its claims against the code before anything is committed.
---

# Review by another harness

Runs a different vendor's agent over an open PR, then checks its work.

The point is not to outsource the review. It is to get a second reader with
different training and different blind spots, and then **verify what it says**.
An external harness produces confident prose whether or not it is right, so
the last step of every run is you reading the diff, not the report.

## Running it

The driver requires `git`, `gh`, `jq`, and `python3`, plus the selected CLI.

```bash
~/.claude/skills/review-by-harness/run.sh <pr-number> [repo-dir] \
    --harness claude --model claude-opus-5 --effort high [--review-only]
```

Choose the reviewer model explicitly for every run, whichever coding agent
is orchestrating. Unless the user specifies otherwise, use **GPT-5.6 Sol**
(`gpt-5.6-sol`) for Codex and **Opus 5** (`claude-opus-5`) for Claude.
**Fable and Astra require an explicit user override**; do not upgrade based
on task complexity or inherit either from the caller or machine default.
Pass `--harness` and `--model` explicitly, plus `--effort` for Claude/Codex.
Respect any explicit user selection, including a different harness. Check
the selected CLI's available models when unsure about an identifier.

Examples:

```bash
run.sh 123 /path/to/repo --harness claude --model claude-opus-5 --effort high --review-only
run.sh 123 /path/to/repo --harness codex --model gpt-5.6-sol --effort high --review-only
run.sh 123 /path/to/repo --harness cursor --model cursor-grok-4.6-high-fast --review-only
```

CLI choices override `REVIEW_MODEL` / `REVIEW_EFFORT` in machine config.
Both passes receive the same requested model/effort, printed in the run header
and saved to `.review-round/run.json`. Cursor encodes effort in its model
selector (including bracket parameters on supported models); a separate
`--effort` is rejected rather than silently ignored. Adapter defaults remain
for older scripts, but skill-driven runs should always make the choice explicit.

- `--harness auto` (default) chooses Claude when called from Codex and Codex
  when called from Claude. Pass `--caller codex` or `--caller claude` when the
  runtime marker is unavailable. Explicit `--harness` always wins.
- `--harness claude` — Claude Code's Opus 5 (`claude-opus-5`) at high effort.
  Review has only Read/Glob/Grep tools and no MCP tools. Fix uses native
  sandboxing where available; the existing `REVIEW_SANDBOX='-s danger-full-access'` opt-in
  applies where user namespaces are unavailable. Cursor's `--force` is not
  a Claude opt-in. User and managed hooks remain active.
- `--harness codex` — GPT-5.6 Sol at high reasoning, via `codex exec
  review`. Has a real built-in review mode.
- `--harness cursor` — Grok 4.6 high, via `cursor-agent`. No built-in review
  mode, so the diff is handed to it with `prompts/review.md`.
- `--review-only` — findings only, nothing is edited. Start here on an
  unfamiliar repo.

Each run makes a fresh worktree at `.claude/worktrees/review-pr<N>-<harness>`,
reset to the PR head. It never commits and never pushes. The PR must not
contain `.review-round`: the driver refuses any pre-existing scratch path
before writing reports, including directories containing symlinks. Instruction
paths must be regular files or symlinks resolving to regular files inside the
worktree; directories, escaping links, dangling links and cycles are refused.
Instruction injection uses atomic replacement, preserves existing modes,
and restores the files after normal exit or handled HUP/INT/TERM signals.

## Your job when it finishes

The script prints three things, and they are not equally trustworthy:

1. **The findings** — claims. Unverified.
2. **The fix report** — the harness's account of what it changed. Also claims.
3. **The diff** — what actually happened. This is the only evidence.

Check each finding against the real source before you accept it. Open the
files it cites and confirm the line numbers and the mechanism. On the first
real run of this skill (memory-lanes #44), both findings held up under that
check — but the value of the check is that it would have caught them if they
had not, and a harness reporting "354 tests passed" is not the same as tests
having passed.

Then report to the user: which findings are real, which are noise, and what
the diff does. Do not commit on the harness's say-so.

## This skill runs on more than one kind of machine

It decides per machine, at the start of every run, and tells you which mode it
picked:

```
### sandbox: harness-native        <- the harness confines itself; nothing given up
### sandbox: UNAVAILABLE ...       <- it cannot, so the fix pass needs your opt-in
```

The test is whether unprivileged user namespaces work (`unshare -Ur`), which is
what bubblewrap needs. A laptop or desktop normally passes; the devpod
container does not.

Two rules follow, and both matter more than they look:

- **Where the sandbox works, it is used — and `config.env` is ignored.** That
  file is an opt-in for a machine that *cannot* confine a harness. It must
  never quietly follow you onto one that can, via a synced dotfile, a copied
  checkout, or a rebuilt container. So the run drops those overrides and says
  it did.
- **Where the sandbox does not work, the fix pass refuses to start** unless
  `config.env` says you accept that, and prints a warning when it does.
  `--review-only` always works and never needs an override.

The upshot: installing this on a laptop does not get you an unconfined agent.
You would have to write `config.env` on that laptop, by hand, after the run
told you why.

## Which passes actually run here

Not the same answer per harness, and the difference decides which one you
reach for:

| | review | fix |
|---|---|---|
| **claude** | file-reading tools only | native sandbox, or existing full-access opt-in |
| **codex** | works out of the box | needs a sandbox override (below) |
| **cursor** | works out of the box | works with `REVIEW_APPROVAL=--force` |

Both harnesses lose their own sandbox in this container for the same reason.
The difference is what they do about it: codex hard-fails every tool call,
while cursor-agent falls back to allowlist mode and keeps working. So a full
unattended round is available today on `--harness cursor` with no
sandbox-bypass flag anywhere. Verified end to end on this skill's own PR.

Be clear-eyed about what that buys: cursor's sandbox is unavailable too, so
`--force` means unrestricted shell inside the worktree. That is comparable
exposure to running codex with full access — not safer, just reachable
without a flag. The worktree boundary and the "do not commit" instruction are
the only limits in both cases.

## Why the codex fix pass needs a sandbox override

The reason is not fixable from inside the script:

```
bwrap: setting up uid map: Permission denied
unshare -Ur true  ->  write failed /proc/self/uid_map: Operation not permitted
```

The host kernel sets `apparmor_restrict_unprivileged_userns=1` (the Ubuntu
24.04 default), which blocks unprivileged user namespaces. Codex sandboxes
itself with bubblewrap, which needs them, so **every** codex tool call fails
here — regardless of `-s workspace-write`, `network_access=true`, or any other
config. Verified 2026-08-27.

There are exactly two ways forward, and both are a human's call:

- **Make user namespaces work on the machine.** Then the harness sandboxes
  itself and none of this applies. Note that **`--security-opt
  apparmor=unconfined` in the devcontainer does NOT do it** — measured
  2026-08-28: the container is *already* `unconfined` in
  `/proc/self/attr/current` and userns is still denied, because the block is
  the kernel restriction applied to unprivileged processes and we run with
  `CapEff: 0`. (`sudo unshare -Ur true` succeeds, which is what pins it to
  capabilities rather than AppArmor confinement.) The real levers are the host
  sysctl `kernel.apparmor_restrict_unprivileged_userns=0`, or a setuid
  `bwrap` — both are host-level security decisions, not repo changes.
- **Let the harness run without its own sandbox** — put your chosen flags in a
  config file (never tracked). Write it to the FIRST path that fits, because
  the obvious one is the worst one:

  | path | lives as long as |
  |---|---|
  | `$REVIEW_CONFIG` | the command you set it on |
  | `~/.claude/review-by-harness.env` | **a host bind mount under devpod — survives rebuilds, covers every container on that host** |
  | `$XDG_CONFIG_HOME/review-by-harness/config.env` | the machine (laptop/desktop) |
  | `config.env` beside this skill | the installed copy, unmanaged by aicoding-sync |

  Every run prints which one it used (`### config: <path>`). Prefer the second
  on devpod; the last will have you rewriting the same file forever. Contents
  either way:

  ```bash
  # ~/.claude/skills/review-by-harness/config.env
  REVIEW_SANDBOX='-s danger-full-access'
  REVIEW_APPROVAL='--force'  # or --yolo; --auto-review still prompts
  ```

  Written once, picked up by every run. The container is then the only
  sandbox, plus the worktree the harness is confined to and told not to
  commit. Decide that deliberately; the adapters deliberately do not decide
  it for you.

## The harness gets session rules, not just a prompt

The driver installs repo-root `AGENTS.md` rules and, for Claude, `CLAUDE.md`
rules plus an appended system prompt. The global instructions (`~/.codex/AGENTS.md`, `~/.claude/CLAUDE.md`, the cursor
estate skill) say to file work you find on the kanban board. A reviewer that
obeys that files tickets for findings the author is about to fix: on
aiCodingBaseSetup#139 one review-only pass filed four. So `run.sh` prepends
`prompts/agents-review.md` (no writes, no tickets, no commits) to the
worktree's `AGENTS.md` before the review, swaps in `prompts/agents-fix.md`
(edits allowed, still no tickets, no commits) before the fix pass, keeps the
project's own content underneath, and strips exactly its own marker-delimited
block before the handback diff, so an edit the fix pass made to that file
survives. `AGENTS.override.md` gets the same treatment when the repo has one
(codex prefers it over `AGENTS.md`). An `AGENTS.md` that is a symlink is
replaced by a regular file for the run and put back from git afterwards, so
nothing is written through the link. Restore also runs from an EXIT trap, so
a failing adapter leaves no rules behind. First live run of this, on its own
PR (#140): the board's ticket count was the same before and after. A harness can still ignore instructions; the handback is
what catches that, and `kanban-post --list-tickets` after a run is the check
for the board.

## Layout

```
run.sh              deterministic driver: worktree, base ref, output, handback
harnesses/claude.sh adapter: claude -p, read tools for review, edit/shell for fix
harnesses/codex.sh  adapter: codex exec review / codex exec
harnesses/cursor.sh adapter: cursor-agent --mode ask / cursor-agent
prompts/review.md   review instructions (harnesses with no built-in review)
prompts/fix.md      fix instructions (all harnesses)
prompts/agents-*.md session rules installed as the worktree's AGENTS.md per phase
config.env          your sandbox/model choices, untracked
```

Adapters take `review <worktree> <base-ref> <outdir>` or
`fix <worktree> <outdir>`. Adding a harness means adding one file that honours
that contract — no changes to `run.sh`.
