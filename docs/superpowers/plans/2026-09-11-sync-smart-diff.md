# Codex smart sync implementation plan

> For agentic workers: execute with superpowers:subagent-driven-development.

**Goal:** Preserve Codex preferences and trust while applying safe blueprint updates and reporting only genuine setting conflicts.

**Architecture:** A pure TOML planner compares per-setting fingerprints; a filesystem/CLI adapter owns shared receipt, provenance, and atomic writes. Shell integration uses the same plan for preview, install, and sync.

**Tech stack:** Bash, Python >=3.8, vendored tomlkit 0.13.3, unittest and bats.

**Spec:** docs/superpowers/specs/2026-09-11-sync-smart-diff-design.md

**Current integration:** PR172 is being completed on main `0e7fc1a` after
Surface rollout verification. The remaining blocker is Gitless release
provenance (AICODINGBASESETUP-57). Extend the offline engine with an explicit
Git evidence-cache input, prepare that cache through the shell adapter for
both enrollment and sync, and test real Gitless host reconciliation. Retain
all existing preference, conflict, receipt and local-development contracts.
Require the full guarded suite and fresh Opus 5 high review on the final head.

## Global constraints

- Work only in this linked worktree. Never switch the shared checkout branch.
- No live configuration changes; tests use temporary fixtures. Never read real secrets or credential files.
- Existing model, effort, and projects are user-owned; local-only keys stay silent.
- Actual conflicts retain local values unattended. Explicit resolution acknowledges the incoming value; unanswered EOF does not.
- No plaintext values in persistent receipt, diagnostic output, or review artifacts.
- Run bats through bash tests/bats/run.sh. New tests must not write into the real blueprint; use existing fixture helpers.
- No runtime package/network downloads for the merge engine. Python 3.8 compatibility.
- Implementers do not spawn subagents, push, or create PRs. Commit only their task files after focused checks. The controller runs the full suite before push.

## Task 1: Merge engine, shared state, and offline dependency

**Files:** create lib/codex_merge.py (pure planner), lib/codex_merge_state.py (state/provenance/IO), lib/codex-merge.py (CLI), lib/vendor/tomlkit/ and license/provenance metadata, tests/test_codex_merge.py, tests/bats/codex-merge.bats. Add narrow lib/vendor exceptions to .gitignore while retaining the root runtime vendor ignore. Do not edit shell integration files.

Read the Spec completely. Implement its engine, receipt, provenance, migration, and failure contracts. Existing untracked-file adoption is controlled by flags below; shell policy is Task 2. The root will separately arrange guards and prerequisites in Task 3.

**CLI interface consumed by Task 2:**

```text
python3 lib/codex-merge.py plan|apply
  --source RENDERED_TOML --template RAW_TEMPLATE --dest DEST
  --clone BLUEPRINT_ROOT --profile host|container
  [--local] [--tracked] [--allow-adopt] [--provenance-git BARE_CACHE]
  [--expected PLAN_TOKEN] [--decisions DECISIONS_JSON_FILE]
```

No network in the engine. Infer repository origin/revision from the clone, or verify the Gitless release against the separately prepared canonical Git cache. --local means an explicit local blueprint invocation; a clean origin/main checkout selected explicitly can restore tracking provenance. A plan returns JSON with config_changed, state_changed, conflicts (array of objects with path arrays), error (null or a value-free diagnostic), unmanaged (boolean), token, changes (path/operation objects), and adoption_notices (profile-key differences only). Same fields for apply plus applied boolean. No raw config values or credential fingerprints on stdout. Exit 0 on valid plan/apply even with preserved conflicts; nonzero on errors. A refused untracked config returns unmanaged:true and no writes. --tracked describes a legacy local manifest entry; an existing valid shared receipt independently establishes management. --allow-adopt permits conservative adoption of a previously untracked file.

Decisions file is a JSON array of {path:[segments],choice:"local"|"blueprint"}. Require --expected for nonempty decisions; reject mismatched tokens or unknown/stale decision paths without writes. Decisions may address conflicts or profile-key adoption notices. Apply must replan under the shared lock and recheck both live file and state. Plans do not create directories/files. --source is already rendered in a private temporary file by shell code; never read the secrets store yourself.

**Example acceptance tests (derive fixture values literally):**

```python
# A test fixture installs model=sol and tui.alternate_screen=never.
# Local then selects astra and adds trusted/untrusted project tables.
# Incoming changes alternate_screen to auto.
# Applying keeps astra and both trust tables, changes alternate_screen,
# and produces no conflict; repeating produces no config write.

# Baseline x=1, local x=2, incoming x=3: preserve x=2 and conflict path ["x"].
# Explicit keep-local acknowledges incoming 3; repeat is silent.
# Incoming x=4 subsequently conflicts again.
```

- [ ] Write tests exercising the public CLI and pure merge behavior, including nested removals/type changes, rotation, first adoption, no-op, preview token, provenance, and receipt-write replay. Capture an expected failing run before implementation.
- [ ] Vendor only the pinned runtime/license after verifying the wheel SHA-256 from the spec. Do not vendor bytecode. The dependency download is development-time only.
- [ ] Implement typed fingerprints and mixed acknowledged-parent recomputation. Reject invalid TOML/receipt without revealing values. Keep files focused by the module split above.
- [ ] Test pure behavior with unittest; connect its suite to a bats wrapper so the standard runner covers it. Use fixture git clones with real revision ancestry for provenance checks, no network.
- [ ] Run bash tests/bats/run.sh codex-merge, inspect diff, commit task files, and write a report containing RED/GREEN evidence, exact CLI examples, and test output.

## Task 2: Integrate smart plans through sync and installation

**Files:** lib/blueprint-deploy.sh, lib/sync.sh, lib/provision-managed-files.sh; tests/bats/blueprint-deploy.bats, sync.bats, install.bats, install-host.bats, and new focused integration tests if useful. Do not change the engine interface without coordinating with root.

Consume Task 1 CLI above and its report. Keep wrappers in a focused new lib/codex-merge.sh if the existing files would otherwise grow excessively. It may be sourced from blueprint-deploy.sh using that file's actual location, not an assumed runtime clone.

Create managed_inventory_smart with the single Codex config target and toml_merge mode. Route classification, missing/untracked paths, install/adoption/reconcile, smart_update/conflict/error, generic removal retirement, receipts, and previews through it. Smart plans never fall into old overwrite, backup, or raw diff paths. Ensure pending conflicts remain visible even when no config changes. Preserve config bytes for state-only changes. Generic JSON merging and owned hook behavior stay unchanged.

Write manifest schema 2 when toml_merge is actually recorded; accept schema 1 in the new reader. Preserve legacy entry behavior until successful migration. Do not migrate every unrelated fixture's schema solely because this library was sourced.

Interactive choices are path-based and value-free by default. One existing overall apply confirmation may authorize safe updates; gather per-conflict local/blueprint decisions with EOF preserving without acknowledgment. Bind choices to Task 1 plan token. A --yes run does not auto-resolve actual conflicts. Profile adoption notices are distinct and cannot repeat once baseline creation succeeds. Unmanaged host configs remain untouched in boot/install reconcile; explicit --yes conservatively adopts.

**Integration reproduction:**

```bash
bash tests/bats/run.sh sync blueprint-deploy install-host --filter 'codex|smart|schema'
```

- [ ] Write failing behavioral tests for actual --yes preserving Astra/trust while receiving unrelated blueprint changes, no recurring local-only drift, and a conflict-only interactive plan.
- [ ] Update all relevant dispatch and bucket consumers; failure output must not claim a config was successfully merged.
- [ ] Adapt intentional old assertions expecting personal Codex replacement. Preserve the untracked host test's no-MCP-injection behavior on unattended reconcile.
- [ ] Verify supplied rendering and cleanup on engine errors; error diagnostics never show credentials or invoke a raw diff fallback.
- [ ] Run focused runner suites, inspect diff, commit task files, and report changes/tests/remaining integration requirements.

## Task 3: Guard coverage, prerequisites, documentation, full regression readiness

**Files:** configs/claude/hooks/bw-deny-files.sh and its relevant bats tests; lib/provision-system.sh and prerequisite tests; configs/codex/config.toml comments; README.md; bin/aicoding-sync help text; .github/workflows/tests.yml if needed. Documentation spec may be updated only for explicitly reported implementation decisions.

Consume Task 1 runtime and Task 2 installed behavior. Protect ~/.codex/.aicoding-sync and its children in existing deny logic without changing runtime configuration. Add real read/glob/shell-path fixture cases; no actual secret files. Existing allow-name exceptions in sensitive directories must not accidentally permit the new state files.

Add Python >=3.8 to container bootstrap and host prerequisite checks. Preserve host manual install policy. Existing containers that call sync before provisioning need a clear missing-runtime error and no overwrite fallback, not a network install inside planning. Ensure CI and bats run real engine paths, not only missing-dependency branches.

Update user documentation and template comments: model/effort default-only, preserved trust, true conflicts, conservative adoption, --blueprint return to tracking, schema and old-writer limits. Do not change the fleet default model. Do not update the parent submodule pointer or deploy live settings.

- [ ] Add failing guard/prerequisite tests, implement the narrow support changes, and run covering suites.
- [ ] Update human documentation to final behavior; no tests that merely mirror prose.
- [ ] Run bash tests/bats/run.sh in full, inspect leaked processes using repository conventions, fix any failures attributable to this branch, and report exact results. Coordinate unexpected failures with root rather than modifying unrelated behavior.
- [ ] Inspect diff, commit task files, and provide final regression/readiness report.

## Controller delivery

After every task, create a task review package and dispatch a fresh spec/quality reviewer. Resume the implementer for fixes. After all tasks, dispatch a whole-branch review; fix verified findings and run necessary checks. Push the feature branch and create a PR with a concrete behavior summary and validation. Merge remains a separate action under repo policy.
