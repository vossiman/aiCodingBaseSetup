# dev-process-lite Phase 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement your one task step by step. Steps use checkbox (`- [ ]`) syntax. This run is coordinated with the `dev-process-lite` skill.

**Goal:** Give new projects the opt-in pieces of the lite process: two project hooks (North Star and ship-check), a routes file, a PR template with an "Independent review" section, ignore rules, and the AGENTS.md section that explains them.

**Architecture:** Files under `templates/project/`, which nothing deploys; agents copy them into a new repo, substitute placeholders, strip `.tpl` and turn each `dot-` prefix into `.`. The hooks are fail-open bash scripts so file content is escaped into JSON safely.

**Tech Stack:** bash, python3 (JSON escaping), jq, bats via `tests/bats/run.sh`.

**Spec:** `docs/superpowers/specs/2026-10-03-dev-process-lite-design.md`, sections "Templates for new projects" and "Testing" items 6 and 7; phase 3 of "Phased implementation outline".

## Global Constraints

- No em dash (the long dash character) in any line this plan adds or changes, or in commit messages.
- Run tests only through `bash tests/bats/run.sh [name]`; run the full suite before the final commit. Tests never write into `$BLUEPRINT_ROOT`.
- Hook scripts are fail-open: no `set -e`, every path exits 0, the pattern of `configs/claude/hooks/check-archived-docs.sh:6-11`.
- Template hook scripts are committed executable (mode 100755).
- Commit trailer: `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Review Focus

1. `ship-check.sh` with a `SHIP_CHECK.md` holding quotes, a backslash, a tab and non-ASCII text must emit valid JSON that round-trips exactly. Task 1.
2. `north-star.sh` run from a subdirectory session must still find the file through `CLAUDE_PROJECT_DIR`, and must print nothing (not an error) when the variable points nowhere. Task 1.
3. The template routes file must not drift from `skills/dev-process-lite/routes.default.json`. Task 2.

---

### Task 1: project hooks

Route: `implementer`, `low`.

> **Delivered differently:** the `"if": "Bash(git commit*)"` filter below missed `git -c ... commit` and `git -C <dir> commit` (live check and review). The shipped `settings.json.tpl` has no `if`; `ship-check.sh` reads `tool_input.command` from stdin and matches git with any global options before `commit` (commit a67d0de). The shipped files and tests are the authority.

**Files:**
- Create: `templates/project/dot-claude/hooks/north-star.sh` (mode 0755)
- Create: `templates/project/dot-claude/hooks/ship-check.sh` (mode 0755)
- Modify: `templates/project/dot-claude/settings.json.tpl`
- Create: `templates/project/docs/SHIP_CHECK.md.tpl`
- Modify: `templates/project/CLAUDE.md.tpl` (two bullets)
- Test: `tests/bats/dev-process-lite-template-hooks.bats`

- [ ] **Step 1: Write the failing test**

Create `tests/bats/dev-process-lite-template-hooks.bats`:

```bash
#!/usr/bin/env bats
# Project template hooks: North Star injection at session start and the
# ship-check read-back after git commit. Both are fail-open.

bats_require_minimum_version 1.5.0

setup() {
  : "${BLUEPRINT_ROOT:?unset, run via tests/bats/run.sh}"
  TMPDIR=$(mktemp -d)
  H="$BLUEPRINT_ROOT/templates/project/dot-claude/hooks"
  mkdir -p "$TMPDIR/proj/docs"
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "template hooks: settings.json.tpl is valid JSON and wires both hooks" {
  local s="$BLUEPRINT_ROOT/templates/project/dot-claude/settings.json.tpl"
  jq -e . "$s" >/dev/null
  [ "$(jq -r '.hooks.SessionStart[0].matcher' "$s")" = "startup|resume" ]
  [[ "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$s")" == *'/.claude/hooks/north-star.sh' ]]
  [ "$(jq -r '.hooks.PostToolUse[0].matcher' "$s")" = "Bash" ]
  [ "$(jq -r '.hooks.PostToolUse[0].hooks[0].if' "$s")" = "Bash(git commit*)" ]
  [[ "$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$s")" == *'/.claude/hooks/ship-check.sh' ]]
  [ "$(jq -r '.permissions.allow | length' "$s")" = "0" ]
}

@test "template hooks: scripts are committed executable" {
  [ -x "$H/north-star.sh" ]
  [ -x "$H/ship-check.sh" ]
  run git -C "$BLUEPRINT_ROOT" ls-files -s templates/project/dot-claude/hooks
  [[ "$output" == *"100755"*"north-star.sh"* ]]
  [[ "$output" == *"100755"*"ship-check.sh"* ]]
}

@test "north-star: no REQUIREMENTS.md prints nothing and exits 0" {
  run env CLAUDE_PROJECT_DIR="$TMPDIR/proj" bash "$H/north-star.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run env CLAUDE_PROJECT_DIR="$TMPDIR/does-not-exist" bash "$H/north-star.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "north-star: a short file is injected after a header" {
  seq 1 10 | sed 's/^/line /' > "$TMPDIR/proj/docs/REQUIREMENTS.md"
  run env CLAUDE_PROJECT_DIR="$TMPDIR/proj" bash "$H/north-star.sh"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"North Star"* ]]
  [[ "$output" == *"line 1"* ]]
  [[ "$output" == *"line 10"* ]]
}

@test "north-star: a file over 200 lines is replaced by a warning" {
  seq 1 300 | sed 's/^/line /' > "$TMPDIR/proj/docs/REQUIREMENTS.md"
  run env CLAUDE_PROJECT_DIR="$TMPDIR/proj" bash "$H/north-star.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"300 lines"* ]]
  [[ "$output" != *"line 150"* ]]
}

@test "ship-check: no SHIP_CHECK.md prints nothing and exits 0" {
  run env CLAUDE_PROJECT_DIR="$TMPDIR/proj" bash "$H/ship-check.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ship-check: awkward content round-trips through valid JSON" {
  printf 'Say "done" only if:\n\tC:\\path holds\nUmlaut \xc3\xa4 ok\n' > "$TMPDIR/proj/docs/SHIP_CHECK.md"
  run env CLAUDE_PROJECT_DIR="$TMPDIR/proj" bash "$H/ship-check.sh"
  [ "$status" -eq 0 ]
  jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' <<<"$output" >/dev/null
  jq -j '.hookSpecificOutput.additionalContext' <<<"$output" > "$TMPDIR/back"
  cmp -s "$TMPDIR/proj/docs/SHIP_CHECK.md" "$TMPDIR/back"
}

@test "template: SHIP_CHECK.md example ships with three questions" {
  local f="$BLUEPRINT_ROOT/templates/project/docs/SHIP_CHECK.md.tpl"
  [ "$(grep -cE '^[0-9]+\. ' "$f")" -eq 3 ]
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/bats/run.sh dev-process-lite-template-hooks`
Expected: all 8 FAIL.

- [ ] **Step 3: Write the hooks**

`templates/project/dot-claude/hooks/north-star.sh`:

```bash
#!/usr/bin/env bash
# SessionStart: inject docs/REQUIREMENTS.md, the project's North Star.
# Fail-open: every path exits 0 and a missing file prints nothing.

main() {
  local dir="${CLAUDE_PROJECT_DIR:-$PWD}" f n
  f="$dir/docs/REQUIREMENTS.md"
  [[ -f "$f" ]] || return 0
  n=$(wc -l < "$f")
  printf '# North Star: docs/REQUIREMENTS.md (injected by the project SessionStart hook)\n'
  if (( n > 200 )); then
    printf 'docs/REQUIREMENTS.md has %s lines, over the 200-line injection limit. Read it directly and shorten it.\n' "$n"
  else
    cat "$f"
  fi
}

main 2>/dev/null
exit 0
```

`templates/project/dot-claude/hooks/ship-check.sh`:

```bash
#!/usr/bin/env bash
# PostToolUse on git commit: read docs/SHIP_CHECK.md back to the agent as
# additional context. Fail-open: every path exits 0.

main() {
  local dir="${CLAUDE_PROJECT_DIR:-$PWD}" f
  f="$dir/docs/SHIP_CHECK.md"
  [[ -f "$f" ]] || return 0
  python3 -c 'import json, sys
text = open(sys.argv[1], encoding="utf-8").read()
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": text}}))' "$f"
}

main 2>/dev/null
exit 0
```

Then `chmod 0755` both.

- [ ] **Step 4: Wire them and add the example**

Replace `templates/project/dot-claude/settings.json.tpl` with:

```json
{
  "permissions": {
    "allow": []
  },
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume",
        "hooks": [
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/north-star.sh" }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "if": "Bash(git commit*)", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/ship-check.sh" }
        ]
      }
    ]
  }
}
```

Create `templates/project/docs/SHIP_CHECK.md.tpl`:

```markdown
# Ship check

Read back to the agent after every `git commit`. Answer each question before
calling the work done, and tell the user when an answer is no.

1. Did the relevant tests run at this commit, and did they pass?
2. Are the docs that describe this behavior updated in the same change?
3. Was anything filed as a ticket that this run could have fixed instead?
```

In `templates/project/CLAUDE.md.tpl`, append two bullets to the list under "## Claude Code specifics":

```markdown
- A `SessionStart` hook injects `docs/REQUIREMENTS.md`, when present, as the
  project's North Star (warning instead when it passes 200 lines).
- A `PostToolUse` hook reads `docs/SHIP_CHECK.md`, when present, back after
  every `git commit`.
```

- [ ] **Step 5: Run the tests, then the suite**

Stage first (the mode test reads the index): `git add templates/project tests/bats/dev-process-lite-template-hooks.bats`. Then run `bash tests/bats/run.sh dev-process-lite-template-hooks install` and `bash tests/bats/run.sh`. Expected: all `ok`.

- [ ] **Step 6: Commit**

```bash
git add templates/project tests/bats/dev-process-lite-template-hooks.bats
git commit -m "feat(templates): North Star and ship-check project hooks

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 2: routes, PR template, ignore rules, AGENTS.md section

Route: `implementer`, `low`.

**Files:**
- Create: `templates/project/dot-dev-process/routes.json.tpl` (byte copy of `skills/dev-process-lite/routes.default.json`)
- Create: `templates/project/dot-github/pull_request_template.md.tpl`
- Create: `templates/project/dot-gitignore.tpl`
- Create: `.github/pull_request_template.md` (the blueprint adopts it; same content)
- Modify: `templates/project/AGENTS.md.tpl` (append a section)
- Modify: `configs/claude/CLAUDE.md`, `configs/codex/AGENTS.md` (the new-project instruction: every `dot-` prefix)
- Modify: `README.md` (section "### Project templates")
- Test: `tests/bats/dev-process-lite-templates.bats`

- [ ] **Step 1: Write the failing test**

Create `tests/bats/dev-process-lite-templates.bats`:

```bash
#!/usr/bin/env bats
# Project templates for the lite process: routes, PR template, ignore rules,
# AGENTS.md section, and the new-project instruction that renames dot- files.

bats_require_minimum_version 1.5.0

setup() {
  : "${BLUEPRINT_ROOT:?unset, run via tests/bats/run.sh}"
  T="$BLUEPRINT_ROOT/templates/project"
}

@test "templates: routes.json is a byte copy of the default routes" {
  cmp -s "$BLUEPRINT_ROOT/skills/dev-process-lite/routes.default.json" "$T/dot-dev-process/routes.json.tpl"
}

@test "templates: PR template has the three sections in order, blueprint adopts it" {
  run grep -E '^## ' "$T/dot-github/pull_request_template.md.tpl"
  [ "${lines[0]}" = "## Change" ]
  [ "${lines[1]}" = "## Validation" ]
  [ "${lines[2]}" = "## Independent review" ]
  [ "${#lines[@]}" -eq 3 ]
  cmp -s "$T/dot-github/pull_request_template.md.tpl" "$BLUEPRINT_ROOT/.github/pull_request_template.md"
}

@test "templates: gitignore keeps worktrees and run journals out" {
  grep -qx '.claude/worktrees/' "$T/dot-gitignore.tpl"
  grep -qx '.claude/dev-process-runs/' "$T/dot-gitignore.tpl"
}

@test "templates: AGENTS.md explains the process files" {
  local f="$T/AGENTS.md.tpl"
  grep -q '^### Development process$' "$f"
  grep -q 'dev-process-lite' "$f"
  grep -q '.dev-process/routes.json' "$f"
  grep -q 'docs/DEV_PROCESS.md' "$f"
  grep -q 'docs/REQUIREMENTS.md' "$f"
  grep -q 'docs/SHIP_CHECK.md' "$f"
}

@test "templates: new-project instructions rename every dot- prefix" {
  local f
  for f in configs/claude/CLAUDE.md configs/codex/AGENTS.md; do
    grep -q 'every `dot-` prefix' "$BLUEPRINT_ROOT/$f"
  done
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/bats/run.sh dev-process-lite-templates`
Expected: all 5 FAIL.

- [ ] **Step 3: Create the template files**

`cp skills/dev-process-lite/routes.default.json templates/project/dot-dev-process/routes.json.tpl` (after `mkdir -p templates/project/dot-dev-process`).

`templates/project/dot-github/pull_request_template.md.tpl` and `.github/pull_request_template.md`, identical:

```markdown
## Change

Describe the problem and the resulting behavior.

## Validation

State the checks run and their results, with commands and exit codes.

## Independent review

Reviewer harness/model/effort, reviewed commit, findings and disposition.
"none" needs a reason.
```

`templates/project/dot-gitignore.tpl`:

```
.claude/worktrees/
.claude/dev-process-runs/
```

- [ ] **Step 4: Append to `templates/project/AGENTS.md.tpl`**

```markdown

### Development process

This repo has no `docs/DEV_PROCESS.md`, so the shared `dev-process-lite`
skill applies whenever a session coordinates more than one task. Model routes
for this repo are pinned in `.dev-process/routes.json`; edit that file to
change them, and add `docs/DEV_PROCESS.md` only when the repo needs its own
full process, which then replaces the lite one. `docs/REQUIREMENTS.md`, when
present, is the North Star and is injected at session start, so keep it under
about 150 lines. `docs/SHIP_CHECK.md`, when present, is read back to the agent
after every `git commit`.
```

- [ ] **Step 5: Update the new-project instruction**

In `configs/claude/CLAUDE.md`, in the bullet "**Starting a brand-new project?**", replace "strip the `.tpl` suffixes, and rename `dot-claude/` to\n  `.claude/`." with "strip the `.tpl` suffixes, and turn every `dot-` prefix\n  into `.` (`dot-claude/`, `dot-github/`, `dot-dev-process/`,\n  `dot-gitignore`), keeping the hook scripts executable." Keep the surrounding sentences.

In `configs/codex/AGENTS.md`, in the bullet "To start a project, copy `templates/project/`", replace "strip `.tpl` suffixes, and rename `dot-claude/` to `.claude/`." with "strip `.tpl` suffixes, and turn every `dot-` prefix into `.`\n  (`dot-claude/`, `dot-github/`, `dot-dev-process/`, `dot-gitignore`), keeping\n  the hook scripts executable."

In `README.md`, section "### Project templates", change the parenthesized file list "(`CLAUDE.md`, `AGENTS.md`, `TODO.md`, `docs/{specs,plans,notes}/{active,archive}/`, project `.claude/settings.json`)" to "(`CLAUDE.md`, `AGENTS.md`, `TODO.md`, `docs/{specs,plans,notes}/{active,archive}/`, `docs/SHIP_CHECK.md`, project `.claude/settings.json` with the North Star and ship-check hooks, `.dev-process/routes.json`, `.github/pull_request_template.md`, `.gitignore`)".

- [ ] **Step 6: Run the tests, then the suite**

Run: `bash tests/bats/run.sh dev-process-lite-templates install dev-process-lite-global` then `bash tests/bats/run.sh`. Expected: all `ok`.

- [ ] **Step 7: Commit**

```bash
git add templates/project .github/pull_request_template.md configs/claude/CLAUDE.md configs/codex/AGENTS.md README.md tests/bats/dev-process-lite-templates.bats
git commit -m "feat(templates): routes, PR template, ignore rules and process section

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Overseer: devMachine adopts the PR template

After this PR merges, a separate devMachine PR adds the same `.github/pull_request_template.md` (devMachine's docs-only exemption does not cover `.github/`).
