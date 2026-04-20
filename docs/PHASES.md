# Personal Development Harness — Phases & Status

**Canonical, up-to-date roadmap for the project-level harness work.**

Original design spec: `~/.claude/plans/i-want-to-brainstorm-pure-oasis.md`
(frozen at brainstorming time; this file is the living status doc).

---

## Context (short)

`aiCodingBaseSetup` has always been solid for configuring a *machine* (Claude
Code, OpenCode, MCPs, plugins, sandbox, statusline). It did nothing for
*projects*, so each new project meant re-typing the same bootstrap: CLAUDE.md,
TODO.md, docs layout, housekeeping rules.

The harness codifies those recurring rituals in three phases. Phase 1 is
shipped. Phases 2 and 3 are intentionally deferred until Phase 1 has been
lived-with.

**Two cross-cutting principles adopted from research (Reddit `ClaudeCode`
threads):**

- **Hooks must fail open.** A misfiring hook must never block Claude — the
  cost of a 45-min autonomous session stalled by a bad hook is higher than
  anything a hook gains you.
- **Agents bypass prompts; hooks stop them.** Use hooks for deterministic
  enforcement, prompts for suggestion. Pick the right tool per rule.

---

## Phase 1 — Project scaffolding + housekeeping  **[SHIPPED on `develop` — commit `860dcaf`]**

Smallest useful slice: a one-command project bootstrap, a housekeeping sweeper,
and a gentle session-start reminder.

### Delivered

| Artifact | Path in repo | Deployed to (by `install.sh`) |
|---|---|---|
| Slash command: interactive project scaffold | `commands/scaffold-project.md` | `~/.claude/commands/scaffold-project.md` |
| Slash command: archive sweep + TODO prune | `commands/housekeep.md` | `~/.claude/commands/housekeep.md` |
| SessionStart hook: archive-eligible banner (fail-open) | `hooks/check-archived-docs.sh` | `~/.claude/hooks/check-archived-docs.sh` |
| Project templates (CLAUDE/README/TODO + .claude + docs tree) | `templates/project/` | `~/.aicodingsetup/templates/project/` (mirrored) |
| Settings integration (SessionStart entry) | `configs/claude/settings.json` | merged into `~/.claude/settings.json` |
| Installer wiring (`install_commands`, `install_templates`, SessionStart hook copy, unmanaged-commands detection) | `install.sh` | run by user |
| Docs: new test-prompt entries + README section | `test-prompt.md`, `README.md` | — |

### Canonical layout materialized by `/scaffold-project`

```
my-project/
├── CLAUDE.md           # project conventions + frontmatter + /housekeep rule
├── README.md
├── TODO.md             # Now / Next / Later, ~10 lines/section
├── .claude/settings.json
└── docs/
    ├── specs/{active,archive}/
    ├── plans/{active,archive}/
    └── notes/{active,archive}/
```

Every `docs/*/active/*.md` carries frontmatter:

```yaml
---
title: ...
status: active   # active | done
created: YYYY-MM-DD
---
```

Flipping to `status: done` is the trigger; `/housekeep` does the move.

### Verification status

| Check | Status |
|---|---|
| `install.sh` passes `bash -n` | automated ✓ |
| `configs/claude/settings.json` valid JSON | automated ✓ |
| `json_merge` preserves existing `PreToolUse`, adds `SessionStart` cleanly | automated ✓ |
| `install_commands` + `install_templates` deploy correctly into sandbox `$HOME` | automated ✓ |
| `check-archived-docs.sh` — 4 scenarios (2 done / 0 / non-scaffolded / 1 done) | automated ✓ |
| `check-archived-docs.sh` — fail-open under syntax error | automated ✓ |
| User runs `./install.sh` on live machine | **pending user** |
| `/scaffold-project` in fresh tmp dir produces full tree | **pending user (needs real Claude session)** |
| `/housekeep` moves a `status: done` doc to sibling `archive/` | **pending user** |
| SessionStart banner appears on session restart in scaffolded project | **pending user** |

---

## Phase 2 — Process enforcement & wider reach  **[NOT STARTED]**

Layer on hooks that change *behavior*, not just *structure*. Only pursue after
Phase 1 has been used in anger for long enough to tell which of these actually
earn their keep.

Candidate work items:

1. **LSP enforcement hook** (inspired by `nesaminua/claude-code-lsp-enforcement-kit`).
   `PreToolUse` on `Grep`/`Read` that routes "find this symbol" style queries
   through a Language Server for precise answers instead of text search.
   Claimed ~80% token savings; subject to real-world confirmation.
   - **Must fail open** to grep on LSP unavailability.
   - Decision: vendor the upstream kit, or reimplement tighter to our needs.
     Prefer vendoring first, reimplement if we fight it.

2. **Conditional `Stop` hook for housekeeping nudges.**
   Only if SessionStart-only cadence proves too quiet. Gate: emit a nudge
   only if ≥30 min since last `/housekeep` AND ≥1 `status: done` doc exists.
   Store last-run timestamp under `~/.aicodingsetup/state/last-housekeep` per
   project dir hash.

3. **OpenCode parity for slash commands.**
   `commands/*.md` copy cleanly into OpenCode's command directory. No hook
   equivalent possible (OpenCode lacks them today). Extend `install.sh` with
   an `install_opencode_commands` function that mirrors `~/.claude/commands`
   into whatever OpenCode uses.

4. **Frontmatter lint helper (optional).**
   A quick `lint-frontmatter` command or non-blocking PostToolUse hook that
   warns when a new doc in `active/` lacks required fields. Only if users
   actually forget the fields in practice.

---

## Phase 3 — Behavioral override  **[NOT STARTED]**

The most invasive surgery; requires confidence in Phase 1/2 first.

1. **Custom Claude Code system prompt.**
   Curate from `Piebald-AI/claude-code-system-prompts`. Slim the default
   kitchen-sink to what actually helps. Encode our housekeeping conventions
   at the system-prompt level (above CLAUDE.md), since the Reddit thread
   shows a custom system prompt raises CLAUDE.md adherence by framing it as
   non-optional.

2. **`cgo`-style wrapper.**
   Small shell script that runs:
   ```
   claude --system-prompt ~/.aicodingsetup/system-prompt.md "$@"
   ```
   Install side-by-side with `claude` initially so the escape hatch is
   trivial (rename later if happy).

3. **Decision point not yet made:**
   whether the wrapper becomes the default or stays opt-in. Re-evaluate
   after a few weeks of wrapped use.

---

## Open questions / deferred decisions

- **Versioning user's live templates.** Today `install.sh` mirrors
  `templates/project/` over `~/.aicodingsetup/templates/project/`. If the
  user hand-edits the installed copy, the edit is lost on next install. Not
  a problem yet; revisit if we ever start customizing post-install.
- **`.claude/settings.json` in scaffolded projects.** Currently empty
  permissions `allow: []`. We might want a sensible default allowlist once
  we see what per-project permissions actually matter.
- **Phase 2 ordering.** LSP vs OpenCode parity vs conditional Stop — the
  order should be driven by pain. Revisit once Phase 1 has real usage data.

---

## How to update this file

When a work item moves (e.g., Phase 2 item starts), edit the section in place.
Flip the bracketed status marker at the section heading. Keep items terse —
this is a roadmap, not a diary. Detailed per-task plans should go under
`docs/plans/active/` in whatever project is doing the work.
