# dev-process-lite Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. This plan is also run under the dev-process-lite process itself; see "Execution protocol".

**Goal:** Ship the two shared skills `dev-process-lite` and `assess-run` (policy text, project detection, routes table and resolver) with their bats tests, built by running the lite process on itself and measuring `low` against `medium` implementer effort.

**Architecture:** Everything lives under `skills/`, which `managed_config_apply` already deploys to `~/.claude/skills/` (`.md` files rendered with `{{HOME}}` only, everything else copied byte for byte with the exec bit kept, `lib/blueprint-deploy.sh:355-366,477,498`). Two small bash scripts carry the testable logic: `detect.sh` (project process or lite) and `routes.sh` (routes lookup and model resolution, reading CLI model lists, with env overrides for test fixtures). Prose goes into `policy.md` and two thin `SKILL.md` adapters.

**Tech Stack:** bash, jq 1.6+, GNU sort/sed/awk, bats via `tests/bats/run.sh`.

**Spec:** `docs/superpowers/specs/2026-10-03-dev-process-lite-design.md` (merged at `3161838`). Phase 1 of its "Phased implementation outline"; tests 1 to 4 (without the cross-file part of 4), 8 and 9 of its "Testing" section.

## Global Constraints

- No em dash (the long dash character) in any file this plan creates or in commit messages.
- No `{{` in any `.md` file under `skills/`: those files are rendered on deploy (`lib/blueprint-deploy.sh:184-190`).
- Run tests only through `bash tests/bats/run.sh [name]`, never bare `bats`; never write into `$BLUEPRINT_ROOT` from a test.
- Never assert with bare `! cmd`; use `run` plus a status check.
- No test may call a real `claude`, `codex` or `cursor-agent`: `routes.sh` reads `DEV_PROCESS_LITE_CODEX_MODELS` and `DEV_PROCESS_LITE_CURSOR_MODELS` (file paths) when set, and every test sets them.
- Every test that runs `routes.sh` unsets `CLAUDECODE` and `CODEX_THREAD_ID` first; the suite runs inside Claude Code sessions, which set `CLAUDECODE`.
- Shared skill names are exactly `dev-process-lite` and `assess-run`; no `skills/assess` or `skills/dev-process` directory.
- Entries: `claude`, `codex`, `cursor`. Roles: `overseer`, `implementer`, `complex-implementer`, `reviewer`, `assessor`. Efforts, low to high: `low medium high xhigh max`.
- `policy.md` under 150 lines; overseer log cap is 120 lines and the number `120` appears in `policy.md` and `skills/assess-run/SKILL.md`.
- No change to `configs/`, `templates/` or any managed instruction file in this phase.
- Commit trailer for implementer commits: `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Review Focus

1. A Codex session launched from Claude Code inherits `CLAUDECODE`; `routes.sh` must still detect `codex` (it checks `CODEX_THREAD_ID` first). Test in Task 3.
2. `routes.sh` and `detect.sh` run from a subdirectory of the repo must find the repo-root files. Tests in Tasks 1 and 3.
3. A missing or failing CLI (empty model list) must block with exit 2 and a message naming the list consulted, never print an empty model with exit 0. Test in Task 4.
4. A malformed project `.dev-process/routes.json` must block with exit 2 naming the file, not leak a jq error with another exit code. Test in Task 3.
5. A hidden or retiring Codex model must never win, even with a higher version number. Test in Task 4.

---

## Execution protocol (the process building itself)

The overseer is the session that runs this plan (Claude, Opus). It follows the spec's policy sections 1 to 4 by hand, because the skills do not exist yet.

**Branches.** Integration branch `feat/dev-process-lite-phase1` (this plan's branch). Each task arm gets its own worktree from the integration head:

```bash
cd /workspaces/devmachine/devpod/aicoding
git worktree add .claude/worktrees/p1-t<N>-<arm> -b p1/t<N>-<arm> feat/dev-process-lite-phase1
```

`<arm>` is `low`, `medium`, or `run` for a single-arm task. The accepted arm is merged into the integration branch with `git merge --no-ff`; the other arm's branch and worktree are deleted.

**Implementer launch.** Every implementer is a headless Claude Code run in its worktree, so effort is set explicitly and usage is recorded:

```bash
cd .claude/worktrees/p1-t<N>-<arm> && claude -p "$(cat <brief-file>)" \
  --model sonnet --effort <low|medium> --output-format json \
  --permission-mode acceptEdits \
  --allowedTools "Read" "Edit" "Write" "Glob" "Grep" \
    "Bash(bash tests/bats/run.sh:*)" "Bash(git add:*)" "Bash(git commit:*)" \
    "Bash(git status:*)" "Bash(git diff:*)" "Bash(chmod:*)" "Bash(jq:*)" \
    "Bash(bash skills/dev-process-lite/:*)" \
  > <run-dir>/t<N>-<arm>.json
```

The brief is: "Implement Task N of `docs/superpowers/plans/2026-10-03-dev-process-lite-phase1.md` exactly, step by step, in this worktree. Read the plan's Global Constraints first. Commit as the task says. Do not edit tests after their red step unless a step tells you to. Finish with one line: DONE, or BLOCKED and why."

**Effort arms.** Single-arm tasks start at `low`. Tasks 2, 4 and 6 are A/B pairs: launched twice from the same base, once at `low`, once at `medium`, in parallel.

**Per-arm check (same for every arm).**
1. `bash tests/bats/run.sh <task's bats file names>` in the arm worktree: pass or fail.
2. One fixed cross-vendor review of the arm diff, read-only:
   `codex exec -s read-only -m gpt-6.1-sol -c model_reasoning_effort=high "Review the diff of HEAD against <base> for correctness bugs against Task N of docs/superpowers/plans/2026-10-03-dev-process-lite-phase1.md. List findings as P1/P2/P3 with file:line. Do not edit anything."`
3. Record in `<run-dir>/effort.md`, one row per arm: task, arm, tests pass, P1/P2/P3 counts, verified findings, escalations, `total_cost_usd` and output tokens from the JSON, wall time.

The overseer verifies each finding against the code before counting it as verified.

**Accepting an arm.** Passing tests first, then fewer verified P1 plus P2 findings; a tie goes to `low`. Verified findings on the accepted arm are fixed on its branch before merge, by a follow-up `claude -p` run at the same effort with the findings as the brief.

**Escalation.** A failed single-arm task follows the spec's ladder: rerun at `medium`, then `high`, then `opus` at `high` (the complex-implementer route). Each step is a Decisions entry and an `effort.md` row. The failed branch is dropped, not patched.

**Run log.** `<run-dir>` is `.claude/dev-process-runs/<CLAUDE_CODE_SESSION_ID>/` in the aicoding checkout, listed in `.git/info/exclude`. `overseer.md` there has the five sections (Plan, Decisions, Deviations, Open questions, Board), at most 120 lines, appended at milestones.

**Closeout.** After Task 7: one integrated review of the whole branch with `review-by-harness` (Codex, `gpt-6.1-sol`, `high`, `--review-only`) on the PR; a fresh assessor session (Claude, Opus) assesses the run from `overseer.md`; `effort.md` is summarized in the PR body. The spec's "Evidence and caveats" is updated in a follow-up PR with the measured rows. This measures only one brief type: a plan that carries the code.

---

### Task 1: `detect.sh`

Arm: single, `low`.

**Files:**
- Create: `skills/dev-process-lite/detect.sh` (mode 0755)
- Test: `tests/bats/dev-process-lite-detect.bats`

**Interfaces:**
- Consumes: nothing.
- Produces: `skills/dev-process-lite/detect.sh` takes no arguments, always exits 0, and prints exactly one line: `project <absolute path to docs/DEV_PROCESS.md>` or `lite`. Tasks 6 and 7 call it.

- [ ] **Step 1: Write the failing test**

Create `tests/bats/dev-process-lite-detect.bats`:

```bash
#!/usr/bin/env bats
# skills/dev-process-lite/detect.sh: a repo with docs/DEV_PROCESS.md at its
# git top level has its own process; anything else uses the lite process.

bats_require_minimum_version 1.5.0

setup() {
  : "${BLUEPRINT_ROOT:?unset, run via tests/bats/run.sh}"
  TMPDIR=$(mktemp -d)
  DETECT="$BLUEPRINT_ROOT/skills/dev-process-lite/detect.sh"
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "detect: repo without docs/DEV_PROCESS.md prints lite" {
  git init -q "$TMPDIR/repo"
  cd "$TMPDIR/repo"
  run bash "$DETECT"
  [ "$status" -eq 0 ]
  [ "$output" = "lite" ]
}

@test "detect: repo with docs/DEV_PROCESS.md prints project and the path" {
  git init -q "$TMPDIR/repo"
  mkdir -p "$TMPDIR/repo/docs"
  echo "# process" > "$TMPDIR/repo/docs/DEV_PROCESS.md"
  cd "$TMPDIR/repo"
  run bash "$DETECT"
  [ "$status" -eq 0 ]
  [ "$output" = "project $(cd "$TMPDIR/repo" && pwd -P)/docs/DEV_PROCESS.md" ]
}

@test "detect: run from a subdirectory still finds the repo-root document" {
  git init -q "$TMPDIR/repo"
  mkdir -p "$TMPDIR/repo/docs" "$TMPDIR/repo/src/deep"
  echo "# process" > "$TMPDIR/repo/docs/DEV_PROCESS.md"
  cd "$TMPDIR/repo/src/deep"
  run bash "$DETECT"
  [ "$status" -eq 0 ]
  [[ "$output" == "project "*"/docs/DEV_PROCESS.md" ]]
}

@test "detect: a directory named DEV_PROCESS.md does not count" {
  git init -q "$TMPDIR/repo"
  mkdir -p "$TMPDIR/repo/docs/DEV_PROCESS.md"
  cd "$TMPDIR/repo"
  run bash "$DETECT"
  [ "$status" -eq 0 ]
  [ "$output" = "lite" ]
}

@test "detect: outside any git repo prints lite and exits 0" {
  mkdir -p "$TMPDIR/norepo"
  cd "$TMPDIR/norepo"
  run env GIT_CEILING_DIRECTORIES="$TMPDIR" bash "$DETECT"
  [ "$status" -eq 0 ]
  [ "$output" = "lite" ]
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/bats/run.sh dev-process-lite-detect`
Expected: all five tests FAIL (`detect.sh` does not exist, `bash` exits 127).

- [ ] **Step 3: Write the implementation**

Create `skills/dev-process-lite/detect.sh`:

```bash
#!/usr/bin/env bash
# Prints "project <path>" when this repo has its own docs/DEV_PROCESS.md,
# otherwise "lite". Fail-open: always exits 0.
root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo lite; exit 0; }
if [ -f "$root/docs/DEV_PROCESS.md" ]; then
  echo "project $root/docs/DEV_PROCESS.md"
else
  echo lite
fi
exit 0
```

Then: `chmod 0755 skills/dev-process-lite/detect.sh`.

- [ ] **Step 4: Run it to verify it passes**

Run: `bash tests/bats/run.sh dev-process-lite-detect`
Expected: 5 tests, all `ok`.

- [ ] **Step 5: Commit**

```bash
git add skills/dev-process-lite/detect.sh tests/bats/dev-process-lite-detect.bats
git commit -m "feat(dev-process-lite): detect a project-specific dev process

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `routes.default.json`

Arm: A/B pair, `low` and `medium`.

**Files:**
- Create: `skills/dev-process-lite/routes.default.json`
- Test: `tests/bats/dev-process-lite-routes.bats`

**Interfaces:**
- Consumes: nothing.
- Produces: `routes.default.json` with `version: 1` and `routes.<entry>.<role>` objects holding `harness`, `family` (or `model`), `effort`, optional `fast` (boolean, Cursor only) and optional `note` (string). Task 3 reads it.

- [ ] **Step 1: Write the failing test**

Create `tests/bats/dev-process-lite-routes.bats`:

```bash
#!/usr/bin/env bats
# skills/dev-process-lite/routes.default.json: the default routes table.

bats_require_minimum_version 1.5.0

setup() {
  : "${BLUEPRINT_ROOT:?unset, run via tests/bats/run.sh}"
  F="$BLUEPRINT_ROOT/skills/dev-process-lite/routes.default.json"
}

@test "routes: version 1, three entries, five roles, valid fields" {
  run jq -e '
    .version == 1
    and (.routes | keys) == ["claude", "codex", "cursor"]
    and all(.routes[]; keys == ["assessor", "complex-implementer", "implementer", "overseer", "reviewer"])
    and all(.routes[][];
          (.harness | IN("claude", "codex", "cursor"))
          and (has("model") != has("family"))
          and (.effort | IN("low", "medium", "high", "xhigh", "max")))
  ' "$F"
  [ "$status" -eq 0 ]
}

@test "routes: implementer and complex-implementer share a harness, implementer has lower effort" {
  run jq -e '
    def rank: {"low": 0, "medium": 1, "high": 2, "xhigh": 3, "max": 4}[.];
    all(.routes[];
      .implementer.harness == .["complex-implementer"].harness
      and ((.implementer.effort | rank) < (.["complex-implementer"].effort | rank)))
  ' "$F"
  [ "$status" -eq 0 ]
}

@test "routes: balanced family implements, workhorse family does complex work" {
  run jq -e '
    .routes.claude.implementer.family == "sonnet"
    and .routes.claude["complex-implementer"].family == "opus"
    and .routes.codex.implementer.family == "luna"
    and .routes.codex["complex-implementer"].family == "sol"
  ' "$F"
  [ "$status" -eq 0 ]
}

@test "routes: every reviewer is from another harness than its entry" {
  run jq -e 'all(.routes | to_entries[]; .value.reviewer.harness != .key)' "$F"
  [ "$status" -eq 0 ]
}

@test "routes: a frontier family appears only in cursor.reviewer, which must have one" {
  run jq -e '
    def frontier: ((.family // "") | test("fable|astra")) or ((.model // "") | test("fable|astra"));
    [.routes | to_entries[] | .key as $e | .value | to_entries[]
      | select(.value | frontier) | "\($e).\(.key)"] == ["cursor.reviewer"]
  ' "$F"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/bats/run.sh dev-process-lite-routes`
Expected: all five FAIL (jq cannot open the file, status 2).

- [ ] **Step 3: Write the file**

Create `skills/dev-process-lite/routes.default.json`:

```json
{
  "version": 1,
  "_comment": "Defaults for dev-process-lite. A repo pins its own in .dev-process/routes.json. A route names a family (resolved to the newest installed model by routes.sh) or an exact model, which wins.",
  "routes": {
    "claude": {
      "overseer": { "harness": "claude", "family": "opus", "effort": "high" },
      "implementer": { "harness": "claude", "family": "sonnet", "effort": "medium" },
      "complex-implementer": { "harness": "claude", "family": "opus", "effort": "high" },
      "reviewer": { "harness": "codex", "family": "sol", "effort": "high" },
      "assessor": { "harness": "claude", "family": "opus", "effort": "high" }
    },
    "codex": {
      "overseer": { "harness": "codex", "family": "sol", "effort": "high" },
      "implementer": { "harness": "codex", "family": "luna", "effort": "medium", "note": "Owner choice as the Sonnet-level counterpart; unproven, revisit with own evals." },
      "complex-implementer": { "harness": "codex", "family": "sol", "effort": "high" },
      "reviewer": { "harness": "claude", "family": "opus", "effort": "high" },
      "assessor": { "harness": "codex", "family": "sol", "effort": "high" }
    },
    "cursor": {
      "overseer": { "harness": "cursor", "family": "grok", "effort": "xhigh" },
      "implementer": { "harness": "cursor", "family": "grok", "effort": "medium" },
      "complex-implementer": { "harness": "cursor", "family": "grok", "effort": "xhigh" },
      "reviewer": { "harness": "codex", "family": "astra", "effort": "high", "note": "Owner override 2026-10-03: the only frontier row. Alternative: harness claude, family fable." },
      "assessor": { "harness": "cursor", "family": "grok", "effort": "xhigh" }
    }
  }
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bash tests/bats/run.sh dev-process-lite-routes`
Expected: 5 tests, all `ok`.

- [ ] **Step 5: Commit**

```bash
git add skills/dev-process-lite/routes.default.json tests/bats/dev-process-lite-routes.bats
git commit -m "feat(dev-process-lite): default routes table

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `routes.sh` lookup, entry detection and Claude resolution

Arm: single, `low`.

**Files:**
- Create: `skills/dev-process-lite/routes.sh` (mode 0755)
- Test: `tests/bats/dev-process-lite-resolver.bats`

**Interfaces:**
- Consumes: `routes.default.json` from Task 2 (same directory as `routes.sh`).
- Produces: `routes.sh [entry] [role]`.
  - No role: exit 0, stdout one JSON object `{"entry", "source", "routes", "note"?}`.
  - With role: exit 0, stdout one JSON object `{"entry", "role", "harness", "family", "effort", "model", "resolved", "source", "note"?}` where `resolved` is `pinned`, `family` or `alias`; `family` is `null` when pinned.
  - Blocked: exit 2, nothing on stdout, stderr one line starting `blocked: `.
  - Functions Task 4 adds to: `block MESSAGE`, and the `case "$harness"` dispatch in the "Resolve" part, which calls `resolve_claude`; Task 4 adds `resolve_codex` and `resolve_cursor` with the same contract (read globals `model family effort fast`, set global `resolved_model` and `how`).

- [ ] **Step 1: Write the failing test**

Create `tests/bats/dev-process-lite-resolver.bats`:

```bash
#!/usr/bin/env bats
# skills/dev-process-lite/routes.sh: routes lookup, entry detection and model
# resolution. No real agent CLI is ever called: model lists come from fixtures.

bats_require_minimum_version 1.5.0

setup() {
  : "${BLUEPRINT_ROOT:?unset, run via tests/bats/run.sh}"
  TMPDIR=$(mktemp -d)
  unset CLAUDECODE CODEX_THREAD_ID
  FIX="$BLUEPRINT_ROOT/tests/bats/fixtures/dev-process-lite"
  export DEV_PROCESS_LITE_CODEX_MODELS="$FIX/codex-models.json"
  export DEV_PROCESS_LITE_CURSOR_MODELS="$FIX/cursor-models.txt"
  export GIT_CEILING_DIRECTORIES="$TMPDIR"
  R="$BLUEPRINT_ROOT/skills/dev-process-lite/routes.sh"
  DEFAULT="$BLUEPRINT_ROOT/skills/dev-process-lite/routes.default.json"
  mkdir -p "$TMPDIR/norepo"
  cd "$TMPDIR/norepo"
}

teardown() {
  rm -rf "$TMPDIR"
}

# Creates a repo at $1 whose .dev-process/routes.json holds $2.
project_repo() {
  git init -q "$1"
  mkdir -p "$1/.dev-process"
  printf '%s\n' "$2" > "$1/.dev-process/routes.json"
}

@test "resolver: explicit entry without role prints the default table" {
  run --separate-stderr bash "$R" claude
  [ "$status" -eq 0 ]
  [ "$(jq -r .entry <<<"$output")" = "claude" ]
  [ "$(jq -r .routes.implementer.family <<<"$output")" = "sonnet" ]
  [ "$(jq -r .source <<<"$output")" = "$DEFAULT" ]
  [ "$(jq -r 'has("note")' <<<"$output")" = "false" ]
}

@test "resolver: CLAUDECODE selects claude when no entry is given" {
  run --separate-stderr env CLAUDECODE=1 bash "$R"
  [ "$status" -eq 0 ]
  [ "$(jq -r .entry <<<"$output")" = "claude" ]
}

@test "resolver: CODEX_THREAD_ID wins over an inherited CLAUDECODE" {
  run --separate-stderr env CLAUDECODE=1 CODEX_THREAD_ID=t-1 bash "$R"
  [ "$status" -eq 0 ]
  [ "$(jq -r .entry <<<"$output")" = "codex" ]
}

@test "resolver: no entry and no marker blocks" {
  run --separate-stderr bash "$R"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == "blocked: "*"claude, codex or cursor"* ]]
}

@test "resolver: opencode and unknown entries block with the start-runs message" {
  run --separate-stderr bash "$R" opencode implementer
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"start runs from Claude, Codex or Cursor"* ]]
  run --separate-stderr bash "$R" vim
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"start runs from Claude, Codex or Cursor"* ]]
}

@test "resolver: claude family passes the alias through" {
  run --separate-stderr bash "$R" claude overseer
  [ "$status" -eq 0 ]
  [ "$(jq -r .model <<<"$output")" = "opus" ]
  [ "$(jq -r .resolved <<<"$output")" = "alias" ]
  [ "$(jq -r .effort <<<"$output")" = "high" ]
  [ "$(jq -r .harness <<<"$output")" = "claude" ]
}

@test "resolver: unknown role blocks" {
  run --separate-stderr bash "$R" claude janitor
  [ "$status" -eq 2 ]
  [[ "$stderr" == "blocked: "*"janitor"* ]]
}

@test "resolver: project routes file is used, found from a subdirectory" {
  project_repo "$TMPDIR/repo" '{"version":1,"routes":{"claude":{"implementer":{"harness":"claude","model":"claude-sonnet-5-5","effort":"low"}}}}'
  mkdir -p "$TMPDIR/repo/src/deep"
  cd "$TMPDIR/repo/src/deep"
  run --separate-stderr bash "$R" claude implementer
  [ "$status" -eq 0 ]
  [ "$(jq -r .model <<<"$output")" = "claude-sonnet-5-5" ]
  [ "$(jq -r .resolved <<<"$output")" = "pinned" ]
  [ "$(jq -r .effort <<<"$output")" = "low" ]
  [[ "$(jq -r .source <<<"$output")" == *"/repo/.dev-process/routes.json" ]]
}

@test "resolver: exact model wins over family and family is reported null" {
  project_repo "$TMPDIR/repo" '{"version":1,"routes":{"claude":{"overseer":{"harness":"claude","model":"claude-opus-5-5[1m]","family":"sonnet","effort":"high"}}}}'
  cd "$TMPDIR/repo"
  run --separate-stderr bash "$R" claude overseer
  [ "$status" -eq 0 ]
  [ "$(jq -r .model <<<"$output")" = "claude-opus-5-5[1m]" ]
  [ "$(jq -r .family <<<"$output")" = "null" ]
}

@test "resolver: a claude pin with the wrong shape blocks" {
  project_repo "$TMPDIR/repo" '{"version":1,"routes":{"claude":{"overseer":{"harness":"claude","model":"opus-latest","effort":"high"}}}}'
  cd "$TMPDIR/repo"
  run --separate-stderr bash "$R" claude overseer
  [ "$status" -eq 2 ]
  [[ "$stderr" == "blocked: "*"opus-latest"* ]]
}

@test "resolver: project file without the entry table falls back with a note" {
  project_repo "$TMPDIR/repo" '{"version":1,"routes":{"claude":{}}}'
  cd "$TMPDIR/repo"
  run --separate-stderr bash "$R" cursor
  [ "$status" -eq 0 ]
  [ "$(jq -r .source <<<"$output")" = "$DEFAULT" ]
  [[ "$(jq -r .note <<<"$output")" == *"has no 'cursor' table"* ]]
}

@test "resolver: malformed project file blocks and names the file" {
  project_repo "$TMPDIR/repo" '{"version":1,"routes":'
  cd "$TMPDIR/repo"
  run --separate-stderr bash "$R" claude implementer
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == "blocked: "*".dev-process/routes.json"* ]]
}

@test "resolver: project file with the wrong shape blocks and names the file" {
  project_repo "$TMPDIR/repo" '{"version":1,"routes":[]}'
  cd "$TMPDIR/repo"
  run --separate-stderr bash "$R" claude implementer
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == "blocked: "*".dev-process/routes.json"* ]]
  project_repo "$TMPDIR/repo2" '{"version":1,"routes":{"claude":"x"}}'
  cd "$TMPDIR/repo2"
  run --separate-stderr bash "$R" claude implementer
  [ "$status" -eq 2 ]
  [[ "$stderr" == "blocked: "*".dev-process/routes.json"* ]]
}

@test "resolver: an effort outside the known levels blocks" {
  project_repo "$TMPDIR/repo" '{"version":1,"routes":{"claude":{"overseer":{"harness":"claude","family":"opus","effort":"turbo"}}}}'
  cd "$TMPDIR/repo"
  run --separate-stderr bash "$R" claude overseer
  [ "$status" -eq 2 ]
  [[ "$stderr" == "blocked: "*"turbo"* ]]
}
```

Also create the two fixture files now (Task 4 adds tests that use them; they must exist so `setup` paths are real):

`tests/bats/fixtures/dev-process-lite/codex-models.json`:

```json
{
  "models": [
    { "slug": "gpt-7-sol", "visibility": "hide", "upgrade": null },
    { "slug": "gpt-6.1-sol", "visibility": "list", "upgrade": null },
    { "slug": "gpt-6-astra", "visibility": "list", "upgrade": null },
    { "slug": "gpt-6-luna", "visibility": "list", "upgrade": null },
    { "slug": "gpt-5.6-sol", "visibility": "list", "upgrade": null },
    { "slug": "gpt-9-sol", "visibility": "list", "upgrade": { "model": "gpt-6.1-sol" } },
    { "slug": "gpt-5.5", "visibility": "list", "upgrade": { "model": "gpt-6.1-sol" } }
  ]
}
```

`tests/bats/fixtures/dev-process-lite/cursor-models.txt`:

```
Available models

auto - Auto (default)
grok-4.7-xhigh - Grok 4.7  Extra High
grok-4.7-medium - Grok 4.7  Medium
cursor-grok-4.6-xhigh - Grok 4.6 Extra High
cursor-grok-4.6-high-fast - Grok 4.6 Fast
claude-fable-5-thinking-high - Claude Fable 5 1M Thinking (NO ZDR)
claude-opus-5-5-high - Claude Opus 5.5 1M High
gpt-5.6-sol-high - GPT-5.6 Sol 1M High
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/bats/run.sh dev-process-lite-resolver`
Expected: all 14 tests FAIL (`routes.sh` does not exist).

- [ ] **Step 3: Write the implementation**

Create `skills/dev-process-lite/routes.sh`:

```bash
#!/usr/bin/env bash
# Resolve a dev-process-lite route.
#   routes.sh [entry] [role]
# Without a role, print the entry's routes table. With a role, resolve it to a
# model. Success: exit 0, one JSON object on stdout. Blocked: exit 2, one
# "blocked: ..." line on stderr. Never substitutes another family or harness.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
default_file="$here/routes.default.json"

block() { printf 'blocked: %s\n' "$*" >&2; exit 2; }

# --- Entry -------------------------------------------------------------------
entry=${1:-}
role=${2:-}
if [ -z "$entry" ]; then
  # Codex first: a Codex session started from Claude Code inherits CLAUDECODE.
  if [ -n "${CODEX_THREAD_ID:-}" ]; then entry=codex
  elif [ -n "${CLAUDECODE:-}" ]; then entry=claude
  else block "no entry harness detected; pass claude, codex or cursor"
  fi
fi
case "$entry" in
  claude|codex|cursor) ;;
  *) block "entry '$entry' is not supported; start runs from Claude, Codex or Cursor" ;;
esac

# --- Routes file -------------------------------------------------------------
source_file=$default_file
note=""
root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -n "$root" ] && [ -f "$root/.dev-process/routes.json" ]; then
  source_file="$root/.dev-process/routes.json"
  jq -e '(.routes | type == "object") and all(.routes[]; type == "object") and all(.routes[][]; type == "object")' \
    "$source_file" >/dev/null 2>&1 || block "$source_file is not valid JSON with routes.<entry>.<role> objects"
fi
table=$(jq -c --arg e "$entry" '.routes[$e] // empty' "$source_file")
if [ -z "$table" ]; then
  [ "$source_file" != "$default_file" ] || block "no '$entry' table in $default_file"
  note="$source_file has no '$entry' table; used the default table from $default_file"
  source_file=$default_file
  table=$(jq -c --arg e "$entry" '.routes[$e]' "$default_file")
fi

if [ -z "$role" ]; then
  jq -n --arg e "$entry" --arg s "$source_file" --arg n "$note" --argjson t "$table" \
    '{entry: $e, source: $s, routes: $t} + (if $n == "" then {} else {note: $n} end)'
  exit 0
fi

# --- Route -------------------------------------------------------------------
route=$(jq -c --arg r "$role" '.[$r] // empty' <<<"$table")
[ -n "$route" ] || block "no '$role' route in the '$entry' table of $source_file"
harness=$(jq -r '.harness // ""' <<<"$route")
model=$(jq -r '.model // ""' <<<"$route")
family=$(jq -r '.family // ""' <<<"$route")
effort=$(jq -r '.effort // ""' <<<"$route")
fast=$(jq -r '.fast // false' <<<"$route")
[ -n "$model" ] && family=""

case "$effort" in
  low|medium|high|xhigh|max) ;;
  *) block "effort '$effort' in $entry.$role is not one of low, medium, high, xhigh, max" ;;
esac
if [ -z "$model" ]; then
  [[ "$family" =~ ^[a-z][a-z0-9-]*$ ]] || block "$entry.$role names neither a model nor a valid family"
fi

# --- Resolve -----------------------------------------------------------------
resolved_model=""
how=""

resolve_claude() {
  if [ -n "$model" ]; then
    [[ "$model" =~ ^claude-(fable|opus|sonnet|haiku)-[0-9]+(-[0-9]+)*(\[1m\])?$ ]] \
      || block "claude model '$model' is not a claude-<family>-<version> id"
    resolved_model=$model; how=pinned
  else
    case "$family" in
      fable|opus|sonnet|haiku) resolved_model=$family; how=alias ;;
      *) block "claude family '$family' is not one of fable, opus, sonnet, haiku" ;;
    esac
  fi
}

case "$harness" in
  claude) resolve_claude ;;
  codex|cursor) block "harness '$harness' resolution is not implemented yet" ;;
  *) block "harness '$harness' in $entry.$role is not one of claude, codex, cursor" ;;
esac

jq -n --arg entry "$entry" --arg role "$role" --arg harness "$harness" \
  --arg family "$family" --arg effort "$effort" --arg model "$resolved_model" \
  --arg how "$how" --arg source "$source_file" --arg note "$note" \
  '{entry: $entry, role: $role, harness: $harness,
    family: (if $family == "" then null else $family end),
    effort: $effort, model: $model, resolved: $how, source: $source}
   + (if $note == "" then {} else {note: $note} end)'
```

Then: `chmod 0755 skills/dev-process-lite/routes.sh`.

- [ ] **Step 4: Run it to verify it passes**

Run: `bash tests/bats/run.sh dev-process-lite-resolver`
Expected: 14 tests, all `ok`.

- [ ] **Step 5: Commit**

```bash
git add skills/dev-process-lite/routes.sh tests/bats/dev-process-lite-resolver.bats tests/bats/fixtures/dev-process-lite
git commit -m "feat(dev-process-lite): routes lookup, entry detection, claude resolution

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 4: `routes.sh` Codex and Cursor resolution

Arm: A/B pair, `low` and `medium`.

**Files:**
- Modify: `skills/dev-process-lite/routes.sh` (the "Resolve" part: add two functions, change the `codex|cursor)` case arm)
- Test: `tests/bats/dev-process-lite-resolver.bats` (append)

**Interfaces:**
- Consumes: Task 3's globals `model family effort fast`, `block`, the fixtures in `tests/bats/fixtures/dev-process-lite/`.
- Produces: `resolve_codex` and `resolve_cursor`, each setting `resolved_model` and `how` (`pinned` or `family`). Model lists come from `$DEV_PROCESS_LITE_CODEX_MODELS` / `$DEV_PROCESS_LITE_CURSOR_MODELS` when set, else `codex debug models` / `cursor-agent --list-models`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/bats/dev-process-lite-resolver.bats`:

```bash
@test "resolver: codex sol resolves to the newest listed, non-retiring slug" {
  run --separate-stderr bash "$R" codex overseer
  [ "$status" -eq 0 ]
  [ "$(jq -r .model <<<"$output")" = "gpt-6.1-sol" ]
  [ "$(jq -r .resolved <<<"$output")" = "family" ]
}

@test "resolver: codex luna and astra resolve" {
  run --separate-stderr bash "$R" codex implementer
  [ "$status" -eq 0 ]
  [ "$(jq -r .model <<<"$output")" = "gpt-6-luna" ]
  run --separate-stderr bash "$R" cursor reviewer
  [ "$status" -eq 0 ]
  [ "$(jq -r .harness <<<"$output")" = "codex" ]
  [ "$(jq -r .model <<<"$output")" = "gpt-6-astra" ]
}

@test "resolver: codex family with no listed model blocks and names the list" {
  project_repo "$TMPDIR/repo" '{"version":1,"routes":{"codex":{"implementer":{"harness":"codex","family":"terra","effort":"high"}}}}'
  cd "$TMPDIR/repo"
  run --separate-stderr bash "$R" codex implementer
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == "blocked: "*"terra"*"codex debug models"* ]]
}

@test "resolver: codex pin present in the list is returned, absent pin blocks" {
  project_repo "$TMPDIR/repo" '{"version":1,"routes":{"codex":{"overseer":{"harness":"codex","model":"gpt-5.6-sol","family":"sol","effort":"high"},"implementer":{"harness":"codex","model":"gpt-4-sol","effort":"high"}}}}'
  cd "$TMPDIR/repo"
  run --separate-stderr bash "$R" codex overseer
  [ "$status" -eq 0 ]
  [ "$(jq -r .model <<<"$output")" = "gpt-5.6-sol" ]
  [ "$(jq -r .resolved <<<"$output")" = "pinned" ]
  run --separate-stderr bash "$R" codex implementer
  [ "$status" -eq 2 ]
  [[ "$stderr" == "blocked: "*"gpt-4-sol"* ]]
}

@test "resolver: empty codex model list blocks instead of printing an empty model" {
  : > "$TMPDIR/empty.json"
  run --separate-stderr env DEV_PROCESS_LITE_CODEX_MODELS="$TMPDIR/empty.json" bash "$R" codex overseer
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == "blocked: "*"codex debug models"* ]]
}

@test "resolver: cursor grok xhigh picks unprefixed 4.7 over prefixed 4.6" {
  run --separate-stderr bash "$R" cursor overseer
  [ "$status" -eq 0 ]
  [ "$(jq -r .model <<<"$output")" = "grok-4.7-xhigh" ]
  run --separate-stderr bash "$R" cursor implementer
  [ "$status" -eq 0 ]
  [ "$(jq -r .model <<<"$output")" = "grok-4.7-medium" ]
}

@test "resolver: cursor fast flag selects the -fast selector, plain does not" {
  project_repo "$TMPDIR/repo" '{"version":1,"routes":{"cursor":{"implementer":{"harness":"cursor","family":"grok","effort":"high","fast":true},"overseer":{"harness":"cursor","family":"grok","effort":"high"}}}}'
  cd "$TMPDIR/repo"
  run --separate-stderr bash "$R" cursor implementer
  [ "$status" -eq 0 ]
  [ "$(jq -r .model <<<"$output")" = "cursor-grok-4.6-high-fast" ]
  run --separate-stderr bash "$R" cursor overseer
  [ "$status" -eq 2 ]
  [[ "$stderr" == "blocked: "*"grok"*"cursor-agent --list-models"* ]]
}

@test "resolver: cursor variant tokens and dashed versions resolve, missing effort blocks" {
  project_repo "$TMPDIR/repo" '{"version":1,"routes":{"cursor":{"reviewer":{"harness":"cursor","family":"claude-fable","effort":"high"},"overseer":{"harness":"cursor","family":"claude-opus","effort":"high"},"implementer":{"harness":"cursor","family":"gpt","effort":"xhigh"}}}}'
  cd "$TMPDIR/repo"
  run --separate-stderr bash "$R" cursor reviewer
  [ "$status" -eq 0 ]
  [ "$(jq -r .model <<<"$output")" = "claude-fable-5-thinking-high" ]
  run --separate-stderr bash "$R" cursor overseer
  [ "$status" -eq 0 ]
  [ "$(jq -r .model <<<"$output")" = "claude-opus-5-5-high" ]
  run --separate-stderr bash "$R" cursor implementer
  [ "$status" -eq 2 ]
}

@test "resolver: cursor pin present is returned, absent pin blocks" {
  project_repo "$TMPDIR/repo" '{"version":1,"routes":{"cursor":{"overseer":{"harness":"cursor","model":"cursor-grok-4.6-xhigh","effort":"xhigh"},"implementer":{"harness":"cursor","model":"grok-9-low","effort":"low"}}}}'
  cd "$TMPDIR/repo"
  run --separate-stderr bash "$R" cursor overseer
  [ "$status" -eq 0 ]
  [ "$(jq -r .model <<<"$output")" = "cursor-grok-4.6-xhigh" ]
  run --separate-stderr bash "$R" cursor implementer
  [ "$status" -eq 2 ]
  [[ "$stderr" == "blocked: "*"grok-9-low"* ]]
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bash tests/bats/run.sh dev-process-lite-resolver`
Expected: the 14 Task 3 tests pass; the 9 new tests FAIL with `harness 'codex' resolution is not implemented yet` or `harness 'cursor' ...`.

- [ ] **Step 3: Write the implementation**

In `skills/dev-process-lite/routes.sh`, insert after the `resolve_claude` function:

```bash
codex_models() {
  if [ -n "${DEV_PROCESS_LITE_CODEX_MODELS:-}" ]; then
    cat "$DEV_PROCESS_LITE_CODEX_MODELS" 2>/dev/null || true
  else
    codex debug models 2>/dev/null || true
  fi
}

cursor_models() {
  if [ -n "${DEV_PROCESS_LITE_CURSOR_MODELS:-}" ]; then
    cat "$DEV_PROCESS_LITE_CURSOR_MODELS" 2>/dev/null || true
  else
    cursor-agent --list-models 2>/dev/null || true
  fi
}

# Newest listed, non-retiring gpt-<version>-<family> slug.
resolve_codex() {
  local list
  list=$(codex_models)
  jq -e '.models | type == "array"' >/dev/null 2>&1 <<<"$list" \
    || block "no codex model list (consulted: codex debug models)"
  if [ -n "$model" ]; then
    jq -e --arg m "$model" 'any(.models[]; .slug == $m)' >/dev/null <<<"$list" \
      || block "codex model '$model' is not installed (consulted: codex debug models)"
    resolved_model=$model; how=pinned
    return
  fi
  resolved_model=$(jq -r --arg f "$family" '
      .models[] | select(.visibility == "list" and .upgrade == null) | .slug
      | select(test("^gpt-[0-9]+(\\.[0-9]+)*-" + $f + "$"))' <<<"$list" \
    | sed -E 's/^gpt-([0-9.]+)-.*$/\1\t&/' | sort -t$'\t' -k1,1V | tail -n 1 | cut -f2)
  [ -n "$resolved_model" ] \
    || block "no codex model of family '$family' (consulted: codex debug models)"
  how=family
}

# Newest [cursor-]<family>-<version>[-<variant>...]-<effort>[-fast] selector.
resolve_cursor() {
  local list fam_re suffix
  list=$(cursor_models | awk 'NF >= 1 && $2 == "-" { print $1 }')
  [ -n "$list" ] || block "no cursor model list (consulted: cursor-agent --list-models)"
  if [ -n "$model" ]; then
    grep -qxF -- "$model" <<<"$list" \
      || block "cursor model '$model' is not installed (consulted: cursor-agent --list-models)"
    resolved_model=$model; how=pinned
    return
  fi
  fam_re=${family//./\\.}
  if [ "$fast" = true ]; then suffix="-fast"; else suffix=""; fi
  resolved_model=$(grep -E "^(cursor-)?${fam_re}-[0-9]+([.-][0-9]+)*(-[a-z]+)*-${effort}${suffix}\$" <<<"$list" \
    | awk -v fam="$family" '{
        s = $0; sub(/^cursor-/, "", s)
        v = substr(s, length(fam) + 2)
        match(v, /^[0-9]+([.-][0-9]+)*/)
        ver = substr(v, 1, RLENGTH); gsub(/-/, ".", ver)
        print ver "\t" $0
      }' \
    | sort -s -t$'\t' -k1,1V | tail -n 1 | cut -f2 || true)
  [ -n "$resolved_model" ] \
    || block "no cursor model of family '$family' at effort '$effort'$([ "$fast" = true ] && echo ' (fast)') (consulted: cursor-agent --list-models)"
  how=family
}
```

Replace the case arm

```bash
  codex|cursor) block "harness '$harness' resolution is not implemented yet" ;;
```

with

```bash
  codex) resolve_codex ;;
  cursor) resolve_cursor ;;
```

Note for the implementer: with `set -o pipefail`, a `grep` that matches nothing makes the pipeline fail; the trailing `|| true` inside the command substitution keeps the empty result and lets the explicit `block` report it.

- [ ] **Step 4: Run them to verify they pass**

Run: `bash tests/bats/run.sh dev-process-lite-resolver`
Expected: 23 tests, all `ok`.

- [ ] **Step 5: Commit**

```bash
git add skills/dev-process-lite/routes.sh tests/bats/dev-process-lite-resolver.bats
git commit -m "feat(dev-process-lite): resolve codex and cursor families from the CLI lists

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 5: `policy.md`

Arm: single, `low`.

**Files:**
- Create: `skills/dev-process-lite/policy.md`
- Test: `tests/bats/dev-process-lite-policy.bats`

**Interfaces:**
- Consumes: nothing.
- Produces: `policy.md` with four `##` sections named exactly `## 1. Overseer log`, `## 2. Finish in the run, close what is old`, `## 3. When the overseer comes back to the owner`, `## 4. Routes`. Task 6's skills link to these headings.

- [ ] **Step 1: Write the failing test**

Create `tests/bats/dev-process-lite-policy.bats`:

```bash
#!/usr/bin/env bats
# Prose guards for the dev-process-lite policy and its two skills.

bats_require_minimum_version 1.5.0

setup() {
  : "${BLUEPRINT_ROOT:?unset, run via tests/bats/run.sh}"
  S="$BLUEPRINT_ROOT/skills"
}

@test "policy: under 150 lines, four numbered sections in order" {
  [ "$(wc -l < "$S/dev-process-lite/policy.md")" -lt 150 ]
  run grep -E '^## ' "$S/dev-process-lite/policy.md"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "## 1. Overseer log" ]
  [ "${lines[1]}" = "## 2. Finish in the run, close what is old" ]
  [ "${lines[2]}" = "## 3. When the overseer comes back to the owner" ]
  [ "${lines[3]}" = "## 4. Routes" ]
  [ "${#lines[@]}" -eq 4 ]
}

@test "policy: names the 120-line log cap and the five log sections" {
  grep -q '120' "$S/dev-process-lite/policy.md"
  local section
  for section in Plan Decisions Deviations "Open questions" Board; do
    grep -q "\*\*$section\*\*" "$S/dev-process-lite/policy.md"
  done
}

@test "policy: no em dash and no template braces in the skill prose" {
  run grep -rlP '\x{2014}' "$S/dev-process-lite" "$S/assess-run" --include='*.md'
  [ "$status" -eq 1 ]
  run grep -rlF '{{' "$S/dev-process-lite" "$S/assess-run" --include='*.md'
  [ "$status" -eq 1 ]
}
```

Note: the third test also covers Task 6's `assess-run` files; `grep -r` on a missing directory exits 2, so in this task it fails until Task 6 creates `skills/assess-run/`. Step 2 below expects that.

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/bats/run.sh dev-process-lite-policy`
Expected: all 3 FAIL (`policy.md` does not exist; the third exits 2 on the missing `assess-run` directory).

- [ ] **Step 3: Write `policy.md`**

Create `skills/dev-process-lite/policy.md` with exactly this content:

```markdown
# dev-process-lite policy

This policy applies when a session coordinates more than one task in a repo
that has no `docs/DEV_PROCESS.md`. It assumes the global instructions are
loaded and refines them; worktree, sibling, kanban and review rules stay
where they are. A repo with `docs/DEV_PROCESS.md` follows that document.

## 1. Overseer log

An overseer is a session that coordinates more than one task: it prepares
work for subagents or worker sessions, reads their diffs and decides what
merges. A session doing one ticket end to end is not an overseer and keeps
no log.

The overseer keeps `.claude/dev-process-runs/<session>/overseer.md`, written
for a reader who did not watch the run. `<session>` is
`CLAUDE_CODE_SESSION_ID` in Claude and `CODEX_THREAD_ID` in Codex. A Codex
overseer never uses `CLAUDE_CODE_SESSION_ID`: Codex can inherit a stale one
from whatever launched it. Add `.claude/dev-process-runs/` to
`.git/info/exclude` when the repo does not ignore it.

Append an entry at each milestone (task prepared, handed off, accepted,
blocked or abandoned; review done; PR opened), never per tool call. Hard
cap: 120 lines. Five sections, in this order:

- **Plan**: plan or spec path and revision, tickets, base revision, the
  overseer's session id and its current name (the `name` of the
  `~/.claude/sessions/*.json` entry whose `sessionId` matches), and the
  exact model id each route resolved to.
- **Decisions**: each decision the plan did not settle, with a one-sentence
  reason and the commit, record or file that shows it. The implementer role
  chosen per task and every reassignment go here.
- **Deviations**: where delivery differs from the plan: unmet acceptance
  criteria, skipped validation, diff-only reviews, overridden blocking
  findings, each with the reason.
- **Open questions**: what the owner or an assessment must decide. Empty
  means the overseer claims none.
- **Board**: tickets closed, filed and left open. Each filed ticket names
  its accepted reason from section 2; each open one names its blocker.

Entries point at evidence instead of restating it. No secrets, no customer
data.

## 2. Finish in the run, close what is old

- **Do the work in the run.** A defect, gap or review finding found during
  a run goes to a worker in that run when the fix touches what the run
  already works on or a worker could finish it in about an hour. "Out of
  scope" and "pre-existing" are not reasons to file. Widen scope for small
  work without asking and record it under Decisions.
- **A ticket is a mechanism, not a slot.** A work ticket names one
  mechanism and holds about three to four agent tasks. It never names one
  data row, one document or one test case; those are evidence rows in it.
- **Fix review findings at once.** A verified finding that is easy to fix
  goes onto the open PR's branch before merge. A change to Markdown, a
  comment, a name or a link never gets its own ticket, branch or PR.
- **File a ticket only when the run cannot do the work.** The accepted
  reasons are closed:
  1. it needs an answer from the owner or a third party (a feedback ticket
     in `waiting_for_feedback`, or a link to one);
  2. it needs a paid action or another authorization the run does not hold;
  3. another live session owns the files;
  4. it is a separate piece of work larger than one worker task, which the
     run's tickets do not need in order to close.
- **Search the board first.** A finding an open ticket covers becomes a
  comment there; findings sharing a cause go into one ticket with a
  checklist. Before filing a third ticket, or more than the run closes,
  re-read the list.
- **Close the run's tickets.** When the agreed scope was delivered but the
  title promised more, close it, comment what was delivered and file the
  remainder as bounded tickets linked `relates`.
- **Split old tickets.** A work ticket still open three days after a run
  worked on it, or carried through two runs, is closed with a comment and
  replaced by bounded remainders. Feedback tickets and untouched backlog
  are exempt.

The kanban instructions define the transitions; this section only decides
whether a ticket is filed.

## 3. When the overseer comes back to the owner

The overseer decides, records under Decisions and carries on. It stops for
the owner only when:

- an action needs an authorization the run does not hold: a paid action
  above the project's stated cap, a message sent outside the repo, a
  production or storage change, a release;
- the next step would be destructive or could not be undone;
- every remaining task is blocked on a person's answer.

Merging a reviewed, green PR and cleaning up the run's own worktrees need
no owner go, unless the repo's own instructions say "ask before merging";
that rule wins. In a run the owner declared overnight or unattended, the
overseer never stops: it parks the blocked step under Open questions,
finishes the rest and leaves one closeout.

## 4. Routes

Model and effort per role come from the routes table, never from prose.
Run `bash ~/.claude/skills/dev-process-lite/routes.sh [entry] [role]` from the repo. It reads
`.dev-process/routes.json` at the repo root when present, else
`routes.default.json` beside it, resolves a family to the newest installed
model, and blocks (exit 2) rather than substitute. Write the resolved id
into the Plan section.

Roles: `overseer`, `implementer`, `complex-implementer`, `reviewer`,
`assessor`. Entries: `claude`, `codex`, `cursor`; OpenCode is not an entry.

**Choosing the implementer role.** A task is `implementer` work when all
of these hold, else `complex-implementer`:

1. the plan names the files and the acceptance criteria, so the worker
   makes no design choice;
2. it stays inside one module or mechanism, with no change to an
   interface, a data format, a lock or ownership model, or a public CLI;
3. a unit test or a scripted check proves it done;
4. a worker can finish it in about an hour.

A mechanical edit (rename, formatting, docs) may drop to `low` effort.

**Escalation ladder.** After a failed attempt, raise effort first, then
move up a model tier (the `complex-implementer` route). Record each step
under Decisions as a reassignment. Drop the failed branch; do not patch it.
A task never moves down.

**Tests are the contract.** When the acceptance tests were written in an
earlier step, the implementer does not edit them. A test change needs the
overseer's approval, recorded under Decisions with the reason.

**Review.** One integrated review per run with `review-by-harness`, passing
the reviewer route as `--harness` and `--model`, plus `--effort` only when the reviewer harness is claude or codex. Every
reviewer is from another vendor than the entry harness.
```

- [ ] **Step 4: Run it**

Run: `bash tests/bats/run.sh dev-process-lite-policy`
Expected: tests 1 and 2 `ok`; test 3 still FAILS until Task 6 creates `skills/assess-run/`. Record that in the commit message.

- [ ] **Step 5: Commit**

```bash
git add skills/dev-process-lite/policy.md tests/bats/dev-process-lite-policy.bats
git commit -m "feat(dev-process-lite): policy text

The prose guard over skills/assess-run stays red until the assess-run
skill lands in the next task.

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 6: the two `SKILL.md` adapters

Arm: A/B pair, `low` and `medium`.

**Files:**
- Create: `skills/dev-process-lite/SKILL.md`
- Create: `skills/assess-run/SKILL.md`
- Test: `tests/bats/dev-process-lite-policy.bats` (append)

**Interfaces:**
- Consumes: `detect.sh` (Task 1), `routes.sh` (Tasks 3 and 4), `policy.md` section headings (Task 5).
- Produces: two skills whose frontmatter `name` equals the directory name.

- [ ] **Step 1: Write the failing tests**

Append to `tests/bats/dev-process-lite-policy.bats`:

```bash
@test "skills: frontmatter names match directories and descriptions defer to a project process" {
  local s
  for s in dev-process-lite assess-run; do
    run sed -n '2p' "$S/$s/SKILL.md"
    [ "$output" = "name: $s" ]
    grep -q '^description: .*docs/DEV_PROCESS.md' "$S/$s/SKILL.md"
  done
}

@test "skills: both run detect.sh first" {
  grep -q 'detect.sh' "$S/dev-process-lite/SKILL.md"
  grep -q 'detect.sh' "$S/assess-run/SKILL.md"
}

@test "skills: no shared skill shadows a project skill name" {
  [ ! -e "$S/assess" ]
  [ ! -e "$S/dev-process" ]
}

@test "skills: assess-run states the 120-line cap and the conditional hand-back" {
  grep -q '120' "$S/assess-run/SKILL.md"
  grep -q 'ListAgents' "$S/assess-run/SKILL.md"
  grep -qi 'report only' "$S/assess-run/SKILL.md"
}

@test "skills: helpers are invoked by deployed path, never by bare name" {
  run grep -nE 'bash (detect|routes)\.sh' "$S/dev-process-lite/SKILL.md" "$S/dev-process-lite/policy.md" "$S/assess-run/SKILL.md"
  [ "$status" -eq 1 ]
  grep -q 'bash ~/.claude/skills/dev-process-lite/detect.sh' "$S/dev-process-lite/SKILL.md"
  grep -q 'bash ~/.claude/skills/dev-process-lite/routes.sh' "$S/dev-process-lite/SKILL.md"
}

@test "skills: --effort is only passed for claude and codex reviewers" {
  grep -q 'only when the reviewer harness is claude or codex' "$S/dev-process-lite/SKILL.md"
  grep -q 'only when the reviewer harness is claude or codex' "$S/dev-process-lite/policy.md"
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bash tests/bats/run.sh dev-process-lite-policy`
Expected: the em dash test and the "frontmatter", "detect.sh first" and "assess-run" tests FAIL; the "no shared skill shadows" test passes already (a guard, not new behavior).

- [ ] **Step 3: Write the two skills**

Create `skills/dev-process-lite/SKILL.md`:

```markdown
---
name: dev-process-lite
description: Use when coordinating more than one task in a repo that has no docs/DEV_PROCESS.md, covering delegation, routes, review findings, board state and the overseer log. Not for a single-ticket session, and not for repos with their own docs/DEV_PROCESS.md.
---

# dev-process-lite

The scripts and the policy sit beside this file, in
`~/.claude/skills/dev-process-lite/` when deployed.

1. Run `bash ~/.claude/skills/dev-process-lite/detect.sh` from the repo. If it prints `project <path>`, say in
   one line that this repo has its own process at that path, and stop:
   that document and the repo's own skills apply.
2. Read `policy.md`. It is the policy; this file only orders the steps.
3. Run `bash ~/.claude/skills/dev-process-lite/routes.sh [entry]` to see the routes table, and
   `bash ~/.claude/skills/dev-process-lite/routes.sh [entry] <role>` before each launch. Exit 2 means
   blocked: report the message, never pick another model. Write each
   resolved model id into the log's Plan section.
4. Keep the overseer log from policy section 1 at
   `.claude/dev-process-runs/<session>/overseer.md`, and add
   `.claude/dev-process-runs/` to `.git/info/exclude` if the repo does not
   ignore it.
5. Give every worker its own branch and worktree (the `worktree-session`
   skill), its role and route, the files it owns, the acceptance criteria
   and what to hand back. Choose `implementer` or `complex-implementer` by
   policy section 4 and record the choice under Decisions.
6. Run one integrated review with `review-by-harness`, passing the
   `reviewer` route as `--harness` and `--model`, plus `--effort` only when the reviewer harness is claude or codex. Fix verified
   findings on the open branch (policy section 2).
7. Before closeout, check the Board section against policy section 2, and
   stop for the owner only for the reasons in policy section 3.
8. Tell the owner the run can be assessed with `assess-run` from a fresh
   session, and name the session id.

## Opt-in files for a repo

Nothing is required. A repo may add, by copying from the blueprint's
`templates/project/`:

- `.dev-process/routes.json`, to pin models for the repo;
- `.github/pull_request_template.md`, for the "Independent review" section;
- `.claude/settings.json` hooks plus `.claude/hooks/`, once the repo has a
  `docs/REQUIREMENTS.md` worth injecting. Merge into an existing settings
  file by hand; never overwrite project permissions.
```

Create `skills/assess-run/SKILL.md`:

```markdown
---
name: assess-run
description: Use in a fresh short session to assess a finished dev-process-lite run from its overseer log and integrated diff, without re-reading the overseer conversation. Takes the run session id, or lists runs when omitted. Not for repos with their own docs/DEV_PROCESS.md.
---

# Assess a dev-process-lite run

1. Run `bash ~/.claude/skills/dev-process-lite/detect.sh`. If it prints
   `project <path>`, say that this repo has its own process and stop.
2. Without a session id, list `.claude/dev-process-runs/` newest first and
   ask which run.

Read, in this order, and nothing else unless a spot-check needs it:

1. `.claude/dev-process-runs/<session>/overseer.md`.
2. The `review-by-harness` report under
   `.claude/worktrees/review-pr<N>-<harness>/.review-round/`, if present.
3. `git diff --stat <base>...<head>` for the integrated branch, and the PR
   body if a PR is open.

Then check, against `~/.claude/skills/dev-process-lite/policy.md`:

- The log has the five sections in order and at most 120 lines, and Plan
  names the plan, the base and the resolved model ids.
- Spot-check at least one Decisions entry and one Deviations entry against
  the diff or the review report. A contradiction is a finding; do not
  soften it.
- The Board section against policy section 2: a ticket filed that the run
  could have done, an easy review finding filed instead of fixed, a
  finding filed singly that belongs in an existing ticket, or an old ticket
  carried instead of split is a `fix first` finding. So is a question to
  the owner outside policy section 3.
- Answer each Open question, or say which ones need the owner.

Report in under 300 words: the verdict, findings ranked by severity, and
the answers, each pointing at a file, commit or record. Verdicts:

- `sound`: the work may merge; name who merges under the repo's rules.
- `fix first`: name the fix; it goes back to the overseer as a task.
- `stop`: name the contradiction; the owner decides.

Hand-back depends on the harness. `ListAgents` and `SendMessage` exist only
in Claude Code, and `~/.claude/sessions/*.json` lists only Claude sessions.

- Claude assessor, and Plan names a Claude session id: find the
  `~/.claude/sessions/*.json` entry with that `sessionId`, take its `name`,
  run `ListAgents`, and send the report with `SendMessage` only when that
  name is listed. Say whether the send succeeded; never claim a send that
  did not happen.
- Any other combination: report only. End with one line saying the owner
  relays the verdict to the overseer, naming the overseer's session id.

Never spawn workers, edit code or move the board from this session.
```

- [ ] **Step 4: Run them to verify they pass**

Run: `bash tests/bats/run.sh dev-process-lite-policy`
Expected: 9 tests, all `ok`.

- [ ] **Step 5: Commit**

```bash
git add skills/dev-process-lite/SKILL.md skills/assess-run/SKILL.md tests/bats/dev-process-lite-policy.bats
git commit -m "feat(dev-process-lite): overseer and assess-run skill adapters

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 7: deployment and precedence

Arm: single, `low`.

**Files:**
- Test: `tests/bats/dev-process-lite-deploy.bats`

**Interfaces:**
- Consumes: every file from Tasks 1 to 6; `managed_config_apply` and `enumerate_skill_files` from `lib/blueprint-deploy.sh`.
- Produces: nothing new; proves deployment and precedence.

- [ ] **Step 1: Write the test**

Create `tests/bats/dev-process-lite-deploy.bats`:

```bash
#!/usr/bin/env bats
# The dev-process-lite skills deploy byte for byte, the scripts stay
# executable, and a repo with its own process is detected and not shadowed.

bats_require_minimum_version 1.5.0

setup() {
  : "${BLUEPRINT_ROOT:?unset, run via tests/bats/run.sh}"
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR/home" AICODING_BLUEPRINT_CLONE="$BLUEPRINT_ROOT"
  export AICODING_STATE_DIR="$TMPDIR/state"
  export GIT_CEILING_DIRECTORIES="$TMPDIR"
  export DEV_PROCESS_LITE_CODEX_MODELS="$BLUEPRINT_ROOT/tests/bats/fixtures/dev-process-lite/codex-models.json"
  export DEV_PROCESS_LITE_CURSOR_MODELS="$BLUEPRINT_ROOT/tests/bats/fixtures/dev-process-lite/cursor-models.txt"
  mkdir -p "$HOME"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  managed_config_apply >/dev/null
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "deploy: both skills land byte for byte, scripts stay executable" {
  local rel
  for rel in dev-process-lite/SKILL.md dev-process-lite/policy.md \
             dev-process-lite/detect.sh dev-process-lite/routes.sh \
             dev-process-lite/routes.default.json assess-run/SKILL.md; do
    cmp -s "$BLUEPRINT_ROOT/skills/$rel" "$HOME/.claude/skills/$rel"
  done
  [ -x "$HOME/.claude/skills/dev-process-lite/detect.sh" ]
  [ -x "$HOME/.claude/skills/dev-process-lite/routes.sh" ]
}

@test "deploy: the deployed routes.sh finds its deployed default table" {
  mkdir -p "$TMPDIR/norepo"
  cd "$TMPDIR/norepo"
  run --separate-stderr env -u CLAUDECODE -u CODEX_THREAD_ID \
    bash "$HOME/.claude/skills/dev-process-lite/routes.sh" claude implementer
  [ "$status" -eq 0 ]
  [ "$(jq -r .source <<<"$output")" = "$HOME/.claude/skills/dev-process-lite/routes.default.json" ]
}

@test "precedence: a repo with its own process is detected and its skills are not shadowed" {
  local be="$TMPDIR/be"
  git init -q "$be"
  mkdir -p "$be/docs" "$be/.claude/skills/assess" "$be/.claude/skills/dev-process" "$be/.agents/skills/dev-process"
  echo "# process" > "$be/docs/DEV_PROCESS.md"
  printf -- '---\nname: assess\n---\n' > "$be/.claude/skills/assess/SKILL.md"
  printf -- '---\nname: dev-process\n---\n' > "$be/.claude/skills/dev-process/SKILL.md"
  printf -- '---\nname: dev-process\n---\n' > "$be/.agents/skills/dev-process/SKILL.md"
  cd "$be"
  run bash "$HOME/.claude/skills/dev-process-lite/detect.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == "project "*"/docs/DEV_PROCESS.md" ]]
  run comm -12 <(ls "$HOME/.claude/skills" | sort) \
               <(ls "$be/.claude/skills" "$be/.agents/skills" | grep -v ':$' | grep -v '^$' | sort -u)
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
```

- [ ] **Step 2: Run it**

Run: `bash tests/bats/run.sh dev-process-lite-deploy`
Expected: 3 tests, all `ok` (the code exists; this task proves deployment and precedence). If any fails, the defect is in an earlier task's file: fix it there in this branch and note it in the commit message.

- [ ] **Step 3: Run the full suite**

Run: `bash tests/bats/run.sh`
Expected: every test `ok`, including the existing deployment and inventory tests in `blueprint-deploy.bats` that enumerate all skill files.

- [ ] **Step 4: Commit**

```bash
git add tests/bats/dev-process-lite-deploy.bats
git commit -m "test(dev-process-lite): deployment and project-process precedence

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

## Not in this phase

The global "## Dev process" paragraph, the `review-by-harness` table refresh and the cross-file reviewer guard (phase 2); templates and hooks (phase 3); the first real run on devMachine (phase 4). The spec's live checks 4 to 6 for balance-extract run in phase 2, the first phase a balance-extract session can observe.
