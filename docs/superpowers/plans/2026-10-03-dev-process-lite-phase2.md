# dev-process-lite Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement your one task step by step. Steps use checkbox (`- [ ]`) syntax. This run is coordinated with the `dev-process-lite` skill.

**Goal:** Make every agent aware of the lite process (one global paragraph, byte-identical in the three managed instruction files), move reviewer defaults from frozen model ids to families, refresh the stale `review-by-harness` identifier table, and document the process in `docs/agent-parity.md`.

**Architecture:** Prose and config edits plus two guard tests. No new scripts. Families resolve through the phase 1 `routes.sh`; the prose names the family and today's id as an example.

**Tech Stack:** Markdown, bash adapters, bats via `tests/bats/run.sh`.

**Spec:** `docs/superpowers/specs/2026-10-03-dev-process-lite-design.md`, section "Phased implementation outline", phase 2; "Global rule text"; "Testing" items 4 (cross-file part) and 5; "Verification that balance-extract is unaffected".

## Global Constraints

- No em dash (the long dash character) in any line this plan adds or changes, or in commit messages. Existing em dashes in untouched lines stay.
- Run tests only through `bash tests/bats/run.sh [name]`; run the full suite before the final commit (`CLAUDE.md`, section Tests: guard tests pin cross-file text).
- Model ids verified against the installed CLIs on 2026-10-03: Claude aliases `opus`, `sonnet`, `fable` resolve to `claude-opus-5-5`, `claude-sonnet-5-5`, `claude-fable-5-1`; Codex lists `gpt-6.1-sol` (current Sol), `gpt-6-astra`, `gpt-6-luna`, older `gpt-5.6-*`; Cursor lists `grok-4.7-high`, `grok-4.7-high-fast`, `gpt-5.6-sol-high`, `claude-opus-5-5-high`, `claude-fable-5-1-high` and no `gpt-6` selector.
- Fable and Astra stay override-only everywhere except the documented `cursor.reviewer` row of `routes.default.json`.
- Commit trailer: `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Review Focus

1. The paragraph must be byte-identical in all three files, including the heading line; a trailing-space or wrapping difference must fail the test. Task 1.
2. A Codex reviewer route given as the alias-free family must still produce a valid `--model` for `codex`: prose must say to resolve it with `routes.sh`, not to pass `sol`. Task 2.
3. Changing the default family in `routes.default.json` without the prose (or the reverse) must fail a test. Task 2.

---

### Task 1: global "Dev process" paragraph

Route: `implementer`, `low`.

**Files:**
- Modify: `configs/claude/CLAUDE.md` (insert before `## Configuration scope`)
- Modify: `configs/codex/AGENTS.md` (insert before `## Worktree isolation and session coordination`)
- Modify: `configs/cursor/skills/aicoding-estate/SKILL.md` (insert before `## Secrets: never read them`)
- Test: `tests/bats/dev-process-lite-global.bats`

- [ ] **Step 1: Write the failing test**

Create `tests/bats/dev-process-lite-global.bats`:

```bash
#!/usr/bin/env bats
# The global "Dev process" paragraph is byte-identical in the three managed
# instruction files, from its heading to the next heading.

bats_require_minimum_version 1.5.0

setup() {
  : "${BLUEPRINT_ROOT:?unset, run via tests/bats/run.sh}"
}

section() {
  awk '/^## Dev process$/ {on=1; print; next} on && /^## / {exit} on {print}' "$1"
}

@test "global rule: identical Dev process section in claude, codex and cursor texts" {
  local c x u
  c=$(section "$BLUEPRINT_ROOT/configs/claude/CLAUDE.md")
  x=$(section "$BLUEPRINT_ROOT/configs/codex/AGENTS.md")
  u=$(section "$BLUEPRINT_ROOT/configs/cursor/skills/aicoding-estate/SKILL.md")
  [ -n "$c" ]
  [ "$c" = "$x" ]
  [ "$c" = "$u" ]
}

@test "global rule: names the project document first and both skills" {
  local c
  c=$(section "$BLUEPRINT_ROOT/configs/claude/CLAUDE.md")
  [[ "$c" == *'A repo with `docs/DEV_PROCESS.md` follows that document and its own skills.'* ]]
  [[ "$c" == *'`dev-process-lite`'* ]]
  [[ "$c" == *'`assess-run`'* ]]
  [ "$(grep -c . <<<"$c")" -le 8 ]
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/bats/run.sh dev-process-lite-global`
Expected: both FAIL (no `## Dev process` section yet).

- [ ] **Step 3: Insert the section in all three files**

Insert exactly this block, followed by one blank line, directly before the named heading in each file:

```markdown
## Dev process

A repo with `docs/DEV_PROCESS.md` follows that document and its own skills.
Any other repo follows the shared `dev-process-lite` skill when a session
coordinates more than one task: an overseer log per run, the finish-in-the-run
ticket rules, the short list of reasons to interrupt the owner, and a routes
table for harness, model and effort per role. Assess a finished run from a
fresh session with `assess-run`. A single-ticket session needs none of this.
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bash tests/bats/run.sh dev-process-lite-global`
Expected: 2 tests `ok`.

- [ ] **Step 5: Run the full suite, then commit**

Run: `bash tests/bats/run.sh` (all `ok`), then:

```bash
git add configs/claude/CLAUDE.md configs/codex/AGENTS.md configs/cursor/skills/aicoding-estate/SKILL.md tests/bats/dev-process-lite-global.bats
git commit -m "feat(dev-process-lite): global Dev process rule for claude, codex, cursor

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 2: reviewer defaults as families, refreshed identifier table

Route: `implementer`, `low`.

**Files:**
- Modify: `configs/claude/CLAUDE.md` (the paragraph starting "For `review-by-harness`, pass the reviewer harness and model explicitly")
- Modify: `configs/codex/AGENTS.md` (the bullet starting "Local estate skills are shared through `~/.agents/skills`")
- Modify: `skills/review-by-harness/SKILL.md` (paragraph "Choose the reviewer model explicitly", the identifier table and its heading, the examples block below the table, and the section "Your job when it finishes")
- Modify: `skills/review-by-harness/harnesses/claude.sh:5`, `codex.sh:6`, `cursor.sh:6` (adapter defaults)
- Test: `tests/bats/dev-process-lite-global.bats` (append)

- [ ] **Step 1: Write the failing test**

Append to `tests/bats/dev-process-lite-global.bats`:

```bash
@test "reviewer defaults: routes table and prose name the same families" {
  local routes="$BLUEPRINT_ROOT/skills/dev-process-lite/routes.default.json" f
  [ "$(jq -r '.routes.claude.reviewer.harness + "/" + .routes.claude.reviewer.family' "$routes")" = "codex/sol" ]
  [ "$(jq -r '.routes.codex.reviewer.harness + "/" + .routes.codex.reviewer.family' "$routes")" = "claude/opus" ]
  for f in configs/claude/CLAUDE.md configs/codex/AGENTS.md skills/review-by-harness/SKILL.md; do
    grep -q 'the Sol family for Codex' "$BLUEPRINT_ROOT/$f"
    grep -q 'the Opus family for Claude' "$BLUEPRINT_ROOT/$f"
    grep -q 'routes.sh' "$BLUEPRINT_ROOT/$f"
    run grep -nE 'gpt-5\.6-sol`\)|\(`claude-opus-5`\)' "$BLUEPRINT_ROOT/$f"
    [ "$status" -eq 1 ]
  done
}

@test "reviewer defaults: adapters default to current models" {
  grep -q 'MODEL="${REVIEW_MODEL:-opus}"' "$BLUEPRINT_ROOT/skills/review-by-harness/harnesses/claude.sh"
  grep -q 'MODEL="${REVIEW_MODEL:-gpt-6.1-sol}"' "$BLUEPRINT_ROOT/skills/review-by-harness/harnesses/codex.sh"
  grep -q 'MODEL="${REVIEW_MODEL:-grok-4.7-high-fast}"' "$BLUEPRINT_ROOT/skills/review-by-harness/harnesses/cursor.sh"
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/bats/run.sh dev-process-lite-global`
Expected: the two new tests FAIL.

- [ ] **Step 3: Edit the prose**

In `configs/claude/CLAUDE.md`, replace the whole paragraph that starts "For `review-by-harness`, pass the reviewer harness and model explicitly" and ends "task complexity or machine defaults do not authorize an upgrade." with:

```markdown
For `review-by-harness`, pass the reviewer harness and model explicitly from
any coding agent. Choose Codex for a different-vendor review unless the user
chose otherwise. Default to the Sol family for Codex and the Opus family for
Claude at `high` effort; resolve the exact id with
`bash ~/.claude/skills/dev-process-lite/routes.sh <entry> reviewer` (today
`gpt-6.1-sol` and the `opus` alias). Fable and Astra require an explicit user
override; task complexity or machine defaults do not authorize an upgrade.
```

In `configs/codex/AGENTS.md`, replace the bullet that starts "- Local estate skills are shared through `~/.agents/skills`." and ends "Verify findings against code." with:

```markdown
- Local estate skills are shared through `~/.agents/skills`. For an independent
  PR review, use `review-by-harness` with an explicit `--harness`, `--model`,
  and supported `--effort`. Choose Claude for a different-vendor review unless
  the user chose otherwise. Default to the Opus family for Claude and the Sol
  family for Codex at `high` effort; resolve the exact id with
  `bash ~/.claude/skills/dev-process-lite/routes.sh <entry> reviewer` (today
  the `opus` alias and `gpt-6.1-sol`). Fable and Astra require an explicit
  user override. Verify findings against code.
```

In `skills/review-by-harness/SKILL.md`:

(a) Replace the paragraph from "Choose the reviewer model explicitly for every run" through "the identifier from the table below; do not query the CLI for it." with:

```markdown
Choose the reviewer model explicitly for every run, whichever coding agent
is orchestrating. Unless the user specifies otherwise, use the Sol family for
Codex and the Opus family for Claude at `high` effort. Resolve the exact id
with `bash ~/.claude/skills/dev-process-lite/routes.sh <entry> reviewer`, or
take it from the table below. **Fable and Astra require an explicit user
override**; do not upgrade based on task complexity or inherit either from
the caller or machine default. Pass `--harness` and `--model` explicitly,
plus `--effort` for Claude/Codex. Respect any explicit user selection,
including a different harness.
```

(b) Replace the heading "### Model identifiers (verified 2026-09-09 against the installed CLIs)" and the table under it with:

```markdown
### Model identifiers (verified 2026-10-03 against the installed CLIs)

| harness | `--model` | `--effort` | note |
|---|---|---|---|
| claude | `opus` (alias, today `claude-opus-5-5`) | `high` | **default** |
| claude | `sonnet` (alias, today `claude-sonnet-5-5`) | `high` | cheaper second reader |
| claude | `fable` (alias, today `claude-fable-5-1`) | `high` | user override only |
| codex | `gpt-6.1-sol` | `high` | **default** (Sol family) |
| codex | `gpt-6-luna`, `gpt-6-sol`, `gpt-5.6-sol` | `high` | alternatives |
| codex | `gpt-6-astra` | `high` | user override only |
| cursor | `grok-4.7-high-fast` | (none) | **default**; effort is in the name |
| cursor | `grok-4.7-high`, `gpt-5.6-sol-high`, `claude-opus-5-5-high` | (none) | alternatives |
```

(c) In the usage block at the top of "## Running it" (`--harness claude --model claude-opus-5`) change the model to `opus`. In the effort paragraph below the table, change the bracket example `'claude-opus-5[effort=high,fast=false]'` to `'claude-opus-5-5[effort=high,fast=false]'`. In the examples block right below the table, change `--model claude-opus-5` to `--model opus`, `--model gpt-5.6-sol` to `--model gpt-6.1-sol`, and `--model cursor-grok-4.6-high-fast` to `--model grok-4.7-high-fast`.

(d) In the bullet list below the examples, change "`--harness claude` — Claude Code's Opus 5 (`claude-opus-5`) at high effort." to "`--harness claude`: the Opus family (`opus` alias) at high effort." and "`--harness codex` — GPT-5.6 Sol at high reasoning" to "`--harness codex`: the Sol family (`gpt-6.1-sol` today) at high reasoning", and "`--harness cursor` — Grok 4.6 high" to "`--harness cursor`: Grok 4.7 high".

(e) In "## Your job when it finishes", after the paragraph ending "Do not commit on the harness's say-so.", add:

```markdown
When the PR body has an "Independent review" section, fill it: harness,
model, effort, the reviewed commit, and each finding with its disposition.
```

- [ ] **Step 4: Edit the adapter defaults**

`skills/review-by-harness/harnesses/claude.sh:5`: `MODEL="${REVIEW_MODEL:-opus}"`
`skills/review-by-harness/harnesses/codex.sh:6`: `MODEL="${REVIEW_MODEL:-gpt-6.1-sol}"`
`skills/review-by-harness/harnesses/cursor.sh:6`: `MODEL="${REVIEW_MODEL:-grok-4.7-high-fast}"`

- [ ] **Step 5: Run the tests**

Run: `bash tests/bats/run.sh dev-process-lite-global review-by-harness claude-review-adapter`
Expected: all `ok`. Then the full suite: `bash tests/bats/run.sh`, all `ok`.

- [ ] **Step 6: Commit**

```bash
git add configs/claude/CLAUDE.md configs/codex/AGENTS.md skills/review-by-harness tests/bats/dev-process-lite-global.bats
git commit -m "feat(review-by-harness): reviewer defaults as families, ids refreshed 2026-10-03

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `docs/agent-parity.md`

Route: `implementer`, `low`.

**Files:**
- Modify: `docs/agent-parity.md`

- [ ] **Step 1: Add the capability row**

In the table under "## Managed capabilities", after the row starting "| Branch isolation |", add:

```markdown
| Dev process | `dev-process-lite` and `assess-run` skills; repo `docs/DEV_PROCESS.md` wins | Same skills via `~/.agents/skills`; same precedence |
```

- [ ] **Step 2: Update "## Review from either CLI"**

In the code block, change `--model claude-opus-5` to `--model opus` and `--model gpt-5.6-sol` to `--model gpt-6.1-sol`. In the paragraph below it, replace "use Opus 5 (`claude-opus-5`) or GPT-5.6 Sol (`gpt-5.6-sol`)." with "use the Opus family (`opus` alias) or the Sol family (`gpt-6.1-sol` today); resolve with `bash ~/.claude/skills/dev-process-lite/routes.sh <entry> reviewer`." and replace "Claude defaults to `claude-opus-5`, Codex to `gpt-5.6-sol`." with "Claude defaults to `opus`, Codex to `gpt-6.1-sol`, Cursor to `grok-4.7-high-fast`."

- [ ] **Step 3: Add a section before "## Differences that remain"**

```markdown
## Dev process and model tiers

A session that coordinates more than one task follows the shared
`dev-process-lite` skill unless the repo has `docs/DEV_PROCESS.md`, which
wins. Routes name a model family per role; `routes.sh` resolves the newest
installed model and blocks rather than substitute. Runs start from Claude,
Codex or Cursor; OpenCode is not an entry harness. Tiers as resolved on
2026-10-03:

| tier | Claude | Codex | Cursor |
|---|---|---|---|
| frontier (override only) | `fable` (`claude-fable-5-1`) | `astra` (`gpt-6-astra`) | `claude-fable-5-1-*`; no Grok or GPT frontier |
| workhorse | `opus` (`claude-opus-5-5`) | `sol` (`gpt-6.1-sol`) | `grok` (`grok-4.7-xhigh`) |
| balanced (implementer) | `sonnet` (`claude-sonnet-5-5`) | `luna` (`gpt-6-luna`, unproven) | `grok` at `medium` (`grok-4.7-medium`) |
| reviewer of this entry | Codex `sol` | Claude `opus` | Codex `astra` (alt: Claude `fable`) |
```

- [ ] **Step 4: Check and commit**

Run: `grep -nP '\x{2014}' docs/agent-parity.md` shows no line you added or changed; `bash tests/bats/run.sh` all `ok`.

```bash
git add docs/agent-parity.md
git commit -m "docs(agent-parity): dev process row, review defaults as families, tier table

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Overseer: live checks (spec "Verification that balance-extract is unaffected")

Run in a balance-extract clone against the deployed phase 1 skills, while the tasks run:

1. `comm -12 <(ls ~/.claude/skills | sort) <(ls <be>/.claude/skills <be>/.agents/skills | grep -v ':$' | grep -v '^$' | sort -u)` prints nothing.
2. `bash ~/.claude/skills/dev-process-lite/detect.sh` in the clone prints `project .../docs/DEV_PROCESS.md`.
3. `git -C <be> status --short` is empty before and after `aicoding-sync --dry-run`.
4. `claude -p '/dev-process-lite'` in the clone answers that the repo has its own process at `docs/DEV_PROCESS.md`; `claude -p '/assess-run'` the same.
5. `claude -p '/assess'` in the clone answers from the project skill (asks for a run id or lists `.claude/dev-process-runs/`).
6. `codex exec` in the clone lists exactly one `dev-process` skill, from `.agents/skills`.

Results go into the PR body under Validation.
