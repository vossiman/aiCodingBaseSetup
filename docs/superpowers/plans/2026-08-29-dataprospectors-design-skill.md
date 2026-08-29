# dataprospectors-design Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the `dataprospectors-design` central skill (tokens, chart palette, logo assets, per-stack guidance) and extend aicoding's skill deployment to copy full skill directories safely.

**Architecture:** A new `overwrite_raw` deploy mode carries non-markdown skill files verbatim (no sed substitution, which corrupts binaries); one shared `enumerate_skill_files` helper feeds both deploy paths (install and sync) so the `to_remove` sweep can never delete files the other path deployed. The skill itself is data: SKILL.md + reference CSS/JSON + PNG assets already committed on this branch.

**Tech Stack:** bash (lib/blueprint-deploy.sh, lib/provision-managed-files.sh), bats tests, shadcn/Tailwind v4 CSS variables.

**Spec:** `docs/superpowers/specs/2026-08-29-dataprospectors-design-system-design.md`

## Global Constraints

- Never run `_substitute_file_to` (sed) over non-markdown skill files.
- Install path (`provision-managed-files.sh`) and sync inventory
  (`blueprint-deploy.sh` `classify_managed_files`) MUST enumerate skill
  files via the same helper.
- All color values verbatim from the spec (validated in the spike).
- Tests: `tests/bats/` conventions (`$BLUEPRINT_ROOT`, tmpdir HOME,
  `run` + status/output asserts). Run via `tests/bats/run.sh` or
  `bats tests/bats/<file>.bats`.

---

### Task 1: `enumerate_skill_files` helper

**Files:**
- Modify: `lib/blueprint-deploy.sh` (add helper near `classify_file`)
- Test: `tests/bats/blueprint-deploy.bats`

**Interfaces:**
- Produces: `enumerate_skill_files <skills_root>` — prints one path per
  line, relative to `<skills_root>` (e.g. `cloudflare-browser/SKILL.md`,
  `dataprospectors-design/assets/dp-logo-light.png`), sorted LC_ALL=C,
  files only, empty output when root missing.

- [ ] **Step 1: Write failing tests** (append to blueprint-deploy.bats)

```bash
@test "enumerate_skill_files: lists nested files relative to root, sorted" {
  mkdir -p "$TMPDIR/skills/b-skill/assets" "$TMPDIR/skills/a-skill"
  echo x > "$TMPDIR/skills/a-skill/SKILL.md"
  echo y > "$TMPDIR/skills/b-skill/SKILL.md"
  echo z > "$TMPDIR/skills/b-skill/assets/logo.png"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run enumerate_skill_files "$TMPDIR/skills"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "a-skill/SKILL.md" ]
  [ "${lines[1]}" = "b-skill/SKILL.md" ]
  [ "${lines[2]}" = "b-skill/assets/logo.png" ]
}

@test "enumerate_skill_files: empty for missing root" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run enumerate_skill_files "$TMPDIR/no-such-dir"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
```

- [ ] **Step 2: Run to verify failure**: `bats tests/bats/blueprint-deploy.bats -f enumerate_skill_files` → FAIL (command not found)

- [ ] **Step 3: Implement** in `lib/blueprint-deploy.sh`:

```bash
# enumerate_skill_files <skills_root> — one file path per line, relative to
# <skills_root>, sorted. The single source of truth for what a skill dir
# ships: install (provision-managed-files.sh) and sync inventory
# (classify_managed_files) both consume this, and MUST stay on it — if the
# two ever enumerate differently, the sync-side to_remove sweep deletes
# whatever install deployed.
enumerate_skill_files() {
  local root=$1 f
  [[ -d "$root" ]] || return 0
  while IFS= read -r f; do
    printf '%s\n' "${f#"$root"/}"
  done < <(find "$root" -type f | LC_ALL=C sort)
}
```

- [ ] **Step 4: Run tests** → PASS
- [ ] **Step 5: Commit** `feat(deploy): shared skill-file enumeration helper`

### Task 2: `overwrite_raw` mode (verbatim, substitution-free)

**Files:**
- Modify: `lib/blueprint-deploy.sh` — `classify_file` (mode branch),
  `_apply_deploy` (new case), `_incoming_matches_dest` (raw compare)
- Test: `tests/bats/blueprint-deploy.bats`

**Interfaces:**
- Consumes: `enumerate_skill_files` (Task 1) — not directly, but Task 3
  routes files into this mode.
- Produces: `classify_file <dest> <src> overwrite_raw` classifies against
  the RAW source hash; `_apply_deploy overwrite_raw <dest> <src>` deploys
  via existing `deploy_overwrite_file` (plain cp).

- [ ] **Step 1: Write failing tests**

```bash
@test "classify_file: overwrite_raw does not substitute placeholders" {
  # A file whose bytes contain {{HOME}} must classify up_to_date after a
  # verbatim deploy — substitution during classify would see phantom drift.
  printf 'binary-ish {{HOME}} content' > "$TMPDIR/src"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  manifest_stage_begin
  deploy_overwrite_file "$TMPDIR/src" "$TMPDIR/dest" "skills/x/a.png"
  manifest_stage_commit
  run classify_file "$TMPDIR/dest" "$TMPDIR/src" overwrite_raw
  [ "$status" -eq 0 ]
  [ "$output" = "up_to_date" ]
  cmp -s "$TMPDIR/src" "$TMPDIR/dest"
}

@test "classify_file: overwrite (substituted) sees drift for same file" {
  printf 'binary-ish {{HOME}} content' > "$TMPDIR/src"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  manifest_stage_begin
  deploy_overwrite_file "$TMPDIR/src" "$TMPDIR/dest" "skills/x/a.png"
  manifest_stage_commit
  run classify_file "$TMPDIR/dest" "$TMPDIR/src" overwrite
  [ "$output" = "will_update" ]
}

@test "_apply_deploy: overwrite_raw copies bytes verbatim" {
  printf 'raw {{HOME}} bytes' > "$TMPDIR/clone-src"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  declare -A FILE_SOURCE
  FILE_SOURCE[$TMPDIR/dest]="skills/x/a.png"
  manifest_stage_begin
  _apply_deploy overwrite_raw "$TMPDIR/dest" "$TMPDIR/clone-src"
  manifest_stage_commit
  cmp -s "$TMPDIR/clone-src" "$TMPDIR/dest"
}
```

- [ ] **Step 2: Run** → first test FAILS (classify_file substitutes; sees `will_update`), third FAILS (mode unhandled, no file written)

- [ ] **Step 3: Implement**
  - `classify_file`: where `new` is computed, branch:

```bash
  local current new deployed
  current=$(compute_managed_hash "$dest")
  if [ "$mode" = "overwrite_raw" ]; then
    # Verbatim files (skill assets/references): classify against the raw
    # source — running sed substitution over binaries corrupts them.
    new=$(compute_hash "$src")
  else
    # (existing substituted-hash block unchanged)
  fi
```

  - `_apply_deploy`: add case:

```bash
    overwrite_raw)
      deploy_overwrite_file "$src" "$dest" "${FILE_SOURCE[$dest]}"
      ;;
```

  - `_incoming_matches_dest`: accept both modes; compare raw for raw:

```bash
_incoming_matches_dest() {
  local mode=$1 src=$2 dest=$3
  [[ -f "$src" ]] || return 1
  case "$mode" in
    overwrite)
      local tmp rc
      tmp=$(mktemp)
      _substitute_file_to "$src" "$tmp" 2>/dev/null
      cmp -s "$tmp" "$dest"; rc=$?
      rm -f "$tmp"
      return "$rc"
      ;;
    overwrite_raw) cmp -s "$src" "$dest" ;;
    *) return 1 ;;
  esac
}
```

- [ ] **Step 4: Run tests** → PASS; also full file: `bats tests/bats/blueprint-deploy.bats`
- [ ] **Step 5: Commit** `feat(deploy): overwrite_raw mode for substitution-free files`

### Task 3: wire full-directory skill deployment into both paths

**Files:**
- Modify: `lib/provision-managed-files.sh` (skill loop ~line 36-49;
  `MANAGED_SKILLS` line 75)
- Modify: `lib/blueprint-deploy.sh` (`classify_managed_files` skill loop
  ~line 746-757)
- Test: `tests/bats/blueprint-deploy.bats`

**Interfaces:**
- Consumes: `enumerate_skill_files` (Task 1), `overwrite_raw` (Task 2).
- Produces: both paths deploy every file of every skill; `.md` →
  substituted `overwrite`, everything else → `overwrite_raw`.

- [ ] **Step 1: Write failing test** (inventory side — the one that guards deletion symmetry)

```bash
@test "classify_managed_files: inventories every skill file with per-mode routing" {
  mkdir -p "$TMPDIR/clone/skills/demo/assets"
  echo '# demo' > "$TMPDIR/clone/skills/demo/SKILL.md"
  printf 'png {{HOME}} bytes' > "$TMPDIR/clone/skills/demo/assets/logo.png"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  export AICODING_BLUEPRINT_CLONE="$TMPDIR/clone"
  declare -A FILE_MODE FILE_SOURCE BUCKETS
  # minimal stand-in for the parts of classify_managed_files we exercise:
  # call the real function; it needs a manifest file to exist
  echo '{"schema_version":1,"files":{}}' > "$AICODING_MANIFEST"
  classify_managed_files
  [ "${FILE_MODE[$TMPDIR/.claude/skills/demo/SKILL.md]}" = "overwrite" ]
  [ "${FILE_MODE[$TMPDIR/.claude/skills/demo/assets/logo.png]}" = "overwrite_raw" ]
  [ "${FILE_SOURCE[$TMPDIR/.claude/skills/demo/assets/logo.png]}" = "skills/demo/assets/logo.png" ]
}
```

(If `classify_managed_files` needs more fixture scaffolding to run — other
inventory entries point into the clone — mirror whatever existing tests in
`aicoding-sync.bats`/`blueprint-deploy.bats` stage for it; the assertion
set stays the same. If no existing test invokes it directly, stage the
minimum the function reads: the clone dir and an empty manifest.)

- [ ] **Step 2: Run** → FAIL (logo.png not in FILE_MODE)

- [ ] **Step 3: Implement**
  - `blueprint-deploy.sh` `classify_managed_files`, replace the
    SKILL.md-only loop:

```bash
  # Skills enumerated from the blueprint clone — every file, not just
  # SKILL.md. Markdown keeps substitution; everything else is verbatim.
  local skill_rel
  while IFS= read -r skill_rel; do
    [[ -z "$skill_rel" ]] && continue
    dest="$HOME/.claude/skills/$skill_rel"
    source="skills/$skill_rel"
    if [[ "$skill_rel" == *.md ]]; then
      FILE_MODE[$dest]=overwrite
    else
      FILE_MODE[$dest]=overwrite_raw
    fi
    FILE_SOURCE[$dest]=$source
    BUCKETS[$dest]=$(classify_file "$dest" "$AICODING_BLUEPRINT_CLONE/$source" "${FILE_MODE[$dest]}")
  done < <(enumerate_skill_files "$AICODING_BLUEPRINT_CLONE/skills")
```

  - `provision-managed-files.sh`, replace the skill loop:

```bash
  # Skills — every file of every skill dir, via the same enumeration the
  # sync inventory uses (divergence would get files to_remove'd by sync).
  mkdir -p "$CLAUDE_DIR/skills"
  local skill_rel src_file dest_file
  while IFS= read -r skill_rel; do
    [[ -z "$skill_rel" ]] && continue
    src_file="$SCRIPT_DIR/skills/$skill_rel"
    dest_file="$CLAUDE_DIR/skills/$skill_rel"
    mkdir -p "$(dirname "$dest_file")"
    if [[ "$skill_rel" == *.md ]]; then
      deploy_overwrite_file_substituted "$src_file" "$dest_file" "skills/$skill_rel"
    else
      deploy_overwrite_file "$src_file" "$dest_file" "skills/$skill_rel"
    fi
    ok "skill file $skill_rel installed"
  done < <(enumerate_skill_files "$SCRIPT_DIR/skills")
```

  - `MANAGED_SKILLS=("cloudflare-browser")` →
    `MANAGED_SKILLS=("cloudflare-browser" "dataprospectors-design")`

- [ ] **Step 4: Run** the new test and the FULL bats suite (`tests/bats/run.sh`) — install.bats/sync.bats/e2e.bats exercise these loops; fix any fixture fallout
- [ ] **Step 5: Commit** `feat(deploy): deploy full skill directories on both paths`

### Task 4: skill content

**Files:**
- Create: `skills/dataprospectors-design/SKILL.md`
- Create: `skills/dataprospectors-design/references/theme.css`
- Create: `skills/dataprospectors-design/references/registry.json`
- Create: `skills/dataprospectors-design/references/dp-tokens.css`
- (assets/ already committed on this branch)

**Interfaces:**
- Produces: the deployable skill. SKILL.md frontmatter `name:
  dataprospectors-design`, description triggering on
  styling/theming/branding dataprospectors surfaces.

Content requirements (values verbatim from the spec — the executor copies
the token tables from
`docs/superpowers/specs/2026-08-29-dataprospectors-design-system-design.md`
and the spike's token mapping; every value is already in the spec):

- `theme.css`: full shadcn variable set `:root` (light) + `.dark`,
  including `--sidebar-*`, `--chart-1..5`, `--radius`, fonts comment.
- `registry.json`: `{"$schema":"https://ui.shadcn.com/schema/registry-item.json",
  "name":"dp-theme","type":"registry:theme","cssVars":{"light":{...},"dark":{...}}}`
  with the same values minus the `--` prefixes (shadcn cssVars convention).
- `dp-tokens.css`: same variables under `:root` /
  `@media (prefers-color-scheme: dark)` + `[data-theme]` guards, no
  Tailwind assumptions.
- `SKILL.md`: decision tree (shadcn → theme.css/registry; plain HTML →
  dp-tokens.css; artifact → inline block), the nine rules from the spec
  (gold-as-text `#7a5c05` on light; navy sidebar both modes; fixed chart
  order + per-mode values + direct-label requirement; status colors
  reserved; Archivo/IBM Plex Mono with per-stack loading; logo usage
  incl. never ink-on-navy; asset paths). No `{{...}}` sequences.

- [ ] **Step 1: Write the four files** (content above; token values from spec)
- [ ] **Step 2: Sanity checks**: `jq . references/registry.json` parses;
  `grep -c '{{' SKILL.md references/*.css` → 0; CSS braces balanced
  (`node -e` or eyeball); every hex from the spec's tables present in
  theme.css (`grep -c '#243943\|#f5c249\|#0f7fbe\|#2f8ec7' ...` ≥ 4).
- [ ] **Step 3: Commit** `feat(skills): dataprospectors-design central skill`

### Task 5: end-to-end verification on this container

- [ ] **Step 1**: full suite green: `tests/bats/run.sh`
- [ ] **Step 2**: from the devMachine checkout:
  `aicoding-sync --blueprint <worktree-path> --dry-run` — expect the new
  skill files listed as new_file, `cloudflare-browser` untouched
  (up_to_date), NOTHING in to_remove.
- [ ] **Step 3**: apply (`aicoding-sync --blueprint <worktree-path>`);
  verify: `ls ~/.claude/skills/dataprospectors-design/` shows SKILL.md,
  references/, assets/; `cmp` deployed PNGs against the branch copies
  (byte-identical); SKILL.md contains no `{{`.
- [ ] **Step 4**: run `aicoding-sync --blueprint <worktree-path> --dry-run`
  again — everything up_to_date (idempotent, no re-drift).
- [ ] **Step 5: Commit** any fixes; then push branch and open PR against
  aicoding `main` (title: "dataprospectors design system skill + full-dir
  skill deploys"), body linking spec + plan, PR checklist from Step 1-4
  evidence.
