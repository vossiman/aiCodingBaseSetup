# Auto-Pin Image Digest Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The build workflow self-pins the blueprint `devcontainer.json` to each freshly published devbox-base digest; devMachine's mirror copy syncs during the routine submodule bump.

**Architecture:** Task 1 (repo aiCodingBaseSetup): a final workflow step, gated non-PR, that rebases, seds the digest into root `devcontainer.json`, commits as github-actions[bot], and pushes to `main` — failing loudly on any error. Task 2 (repo devMachine): `scripts/update-submodules.sh` copies the blueprint's `image` value into `.devcontainer/devcontainer.json` as part of the bump commit. Spec: `docs/superpowers/specs/2026-08-09-auto-pin-image-digest-design.md` (in aiCodingBaseSetup).

**Tech Stack:** GitHub Actions YAML, bash, bats (aicoding only), jq/sed.

## Global Constraints

- Task 1 works in `/var/tmp/aicoding-wt-autopin` (worktree, branch `feat/auto-pin-image-digest`); Task 2 works in a devMachine worktree (created in its Step 0) — never switch branches in shared checkouts (`/workspaces/devmachine`, `/workspaces/devmachine/devpod/aicoding`).
- aicoding tests ALWAYS via `bash tests/bats/run.sh [file]`, never bare `bats`; run the FULL suite before every push — no change is "docs-only".
- Never assert with bare `! cmd`; `[ ! -e f ]`-style test flags are fine.
- The pin step must be gated `github.event_name != 'pull_request'` and must fail the workflow loudly on error — no silent fallback.
- Commit messages end with trailer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Both repos integrate via PR (the bump-direct-to-main exemptions do not cover these code changes).

---

### Task 1: Workflow auto-pin step + guard tests (aiCodingBaseSetup)

**Files:**
- Modify: `.github/workflows/build-base-image.yml` (header comment, `permissions`, checkout, Push step, new step)
- Modify: `tests/bats/image.bats` (extend the workflow guard tests, after the "PR builds never push" test at ~line 106)

**Interfaces:**
- Consumes: `DATE_TAG` (already exported to `GITHUB_ENV` by the Build step) and `DIGEST` (newly exported by the Push step).
- Produces: pushed commits on `main` titled `chore(image): pin devbox-base <DATE_TAG> (<DIGEST>)` — Task 2's sync consumes their effect via the submodule bump.

- [ ] **Step 1: Write the failing guard test**

Append to `tests/bats/image.bats` (directly after the "image workflow: build step passes --config image/devcontainer.json" test):

```bash
@test "image workflow: auto-pins the blueprint after publish (non-PR only)" {
  WORKFLOW="$BLUEPRINT_ROOT/.github/workflows/build-base-image.yml"
  # Push permission for the pin commit
  grep -q 'contents: write' "$WORKFLOW"
  # The pin step: sed rewrite of the digest + the commit message contract
  grep -qF 'sha256:[0-9a-f]{64}' "$WORKFLOW"
  grep -qF 'chore(image): pin devbox-base' "$WORKFLOW"
  # Loud failure is the contract — no silent fallback wording
  run grep -qiE 'continue-on-error: *true' "$WORKFLOW"
  [ "$status" -ne 0 ]
  # Gate appears on login, push, AND pin steps
  [ "$(grep -c "github.event_name != 'pull_request'" "$WORKFLOW")" -ge 3 ]
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd /var/tmp/aicoding-wt-autopin && bash tests/bats/run.sh tests/bats/image.bats`
Expected: the new test FAILS (`contents: write` absent); all other image tests pass.

- [ ] **Step 3: Edit the workflow**

In `.github/workflows/build-base-image.yml`:

3a. Header comment — append after the existing sentence about manual dispatch:

```yaml
# After each publish the workflow pins the blueprint devcontainer.json to
# the new digest and pushes that commit to main itself (machine-generated,
# smoke-tested — same class as the other direct-to-main mechanical bumps).
# devcontainer.json is outside this workflow's paths filter, so the pin
# commit cannot retrigger the build.
```

3b. Permissions block becomes:

```yaml
permissions:
  contents: write
  packages: write
```

3c. Checkout step gains full history (needed for the rebase+push):

```yaml
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0
```

3d. Push step: append one line inside its `run:` block, after the `DIGEST=` line:

```yaml
          echo "DIGEST=$DIGEST" >> "$GITHUB_ENV"
```

Also replace the summary's last line `echo "Pin the blueprint with the digest ref above (rollout step 2)."` with:

```yaml
            echo "Blueprint pin is automated (next step); on pin failure, pin manually with the ref above."
```

3e. New final step after Push:

```yaml
      - name: Pin blueprint to published digest
        if: github.event_name != 'pull_request'
        run: |
          git pull --rebase origin main
          sed -i -E "s|(ghcr\.io/vossiman/devbox-base@)sha256:[0-9a-f]{64}|\1$DIGEST|" devcontainer.json
          if git diff --quiet devcontainer.json; then
            echo "digest unchanged ($DIGEST) — nothing to pin"
            exit 0
          fi
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git add devcontainer.json
          git commit -m "chore(image): pin devbox-base $DATE_TAG ($DIGEST)"
          git push origin HEAD:main
```

- [ ] **Step 4: Run the file, then the full suite**

Run: `cd /var/tmp/aicoding-wt-autopin && bash tests/bats/run.sh tests/bats/image.bats`
Expected: all image tests PASS (including the new one and the untouched "PR builds never push").

Run: `cd /var/tmp/aicoding-wt-autopin && bash tests/bats/run.sh`
Expected: full suite PASS (currently 224 + 1 new = 225).

- [ ] **Step 5: Commit**

```bash
cd /var/tmp/aicoding-wt-autopin
git add .github/workflows/build-base-image.yml tests/bats/image.bats
git commit -m "feat(ci): auto-pin blueprint devcontainer.json to each published digest

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Sync devMachine's devcontainer pin during submodule bump (devMachine)

**Files:**
- Create (worktree): devMachine worktree on branch `feat/sync-devcontainer-pin`
- Modify: `scripts/update-submodules.sh:24-45` (sync block + commit set)

**Interfaces:**
- Consumes: the blueprint's `image` value at `devpod/aicoding/devcontainer.json` (kept current on `main` by Task 1's workflow step).
- Produces: bump commits that also carry `.devcontainer/devcontainer.json` when the pin moved.

- [ ] **Step 0: Create the devMachine worktree**

```bash
git -C /workspaces/devmachine fetch origin --quiet
git -C /workspaces/devmachine worktree add /var/tmp/devmachine-wt-pinsync -b feat/sync-devcontainer-pin origin/main
cd /var/tmp/devmachine-wt-pinsync && git submodule update --init devpod/aicoding
```

- [ ] **Step 1: Edit `scripts/update-submodules.sh`**

Insert between `git submodule update --remote --merge` (line 25) and the `mapfile -t PATHS` block (line 28):

```bash
# Keep .devcontainer/devcontainer.json's image pin in lockstep with the
# blueprint's — the aicoding build workflow self-bumps the blueprint after
# each publish (spec: aicoding 2026-08-09-auto-pin-image-digest-design.md),
# so the mirror here would silently drift without this.
BP_IMAGE="$(jq -r '.image // empty' devpod/aicoding/devcontainer.json)"
if [[ -n "$BP_IMAGE" ]]; then
    sed -i -E "s|\"image\": \"[^\"]+\"|\"image\": \"${BP_IMAGE}\"|" .devcontainer/devcontainer.json
fi
```

Replace the CHANGED computation and empty-check (lines 28-34) with:

```bash
# Which submodule pointers actually moved? (restrict to declared submodule paths)
mapfile -t PATHS < <(git config -f .gitmodules --get-regexp '\.path$' | awk '{print $2}')
mapfile -t CHANGED < <(git diff --name-only -- "${PATHS[@]}" .devcontainer/devcontainer.json)

if [[ ${#CHANGED[@]} -eq 0 ]]; then
    echo "==> already up to date — nothing to commit"
    exit 0
fi
```

(The later `git add -- "${CHANGED[@]}"` then picks the devcontainer file up automatically; dry-run mode already exits before committing, and the sed edit is shown by `git submodule status`/diff — add `git diff --stat -- .devcontainer/devcontainer.json` right before the DRY check so dry-run output mentions it:)

```bash
git diff --stat -- .devcontainer/devcontainer.json
```

- [ ] **Step 2: Commit the script change (before any scenario runs dirty the branch)**

```bash
cd /var/tmp/devmachine-wt-pinsync
git add scripts/update-submodules.sh
git commit -m "feat(scripts): sync .devcontainer image pin from blueprint during submodule bump

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
SCRIPT_COMMIT=$(git rev-parse HEAD)
```

- [ ] **Step 3: Verify with a drift scenario (no framework in this repo — scripted check)**

```bash
cd /var/tmp/devmachine-wt-pinsync
# Force drift: corrupt the local pin
sed -i -E 's|(devbox-base@)sha256:[0-9a-f]{64}|\1sha256:0000000000000000000000000000000000000000000000000000000000000000|' .devcontainer/devcontainer.json
bash scripts/update-submodules.sh
# Assert: local pin now equals the blueprint's again
diff <(jq -r .image .devcontainer/devcontainer.json) <(jq -r .image devpod/aicoding/devcontainer.json) && echo SYNC-OK
git show --stat HEAD | grep devcontainer.json   # scenario commit carries the file
```

Expected: `SYNC-OK`, and the commit stat lists `.devcontainer/devcontainer.json` (a scenario-only commit — dropped next).
Then drop the scenario commit and verify a clean run is a no-op:

```bash
git reset --hard "$SCRIPT_COMMIT" && git submodule update devpod/aicoding
git checkout -- .devcontainer/devcontainer.json 2>/dev/null || true
bash scripts/update-submodules.sh --dry-run
```

Expected: either "already up to date" or a pointer-bump preview — no error, no drift shown for `.devcontainer/devcontainer.json`.

- [ ] **Step 4: Push (only the script commit ships)**

```bash
cd /var/tmp/devmachine-wt-pinsync
git log --oneline origin/main..HEAD   # exactly one commit: the script change
git push -u origin feat/sync-devcontainer-pin
```
