# Update Notifier — Phase 2 Implementation Plan (tmux badge)

**Goal:** Surface the behind-main CTA continuously in the tmux status line via a
compact badge (`⬆aicoding ⬆dvw`), empty when everything is up-to-date/unknown.
Purely additive on top of Phase 1 (already merged + live).

**Architecture:** Add a `--tmux` mode to `bin/update-status` that, like
`--banner`, kicks a throttled detached refresh then reads the per-tool cache —
emitting one `⬆<tool>` token per `behind` tool joined by spaces, nothing
otherwise. Wire it into the catppuccin status line in `configs/tmux/tmux.conf`
as a `#(...)` segment appended **after** TPM loads (catppuccin builds
`status-right` from its modules at TPM-run time, so appending avoids fighting the
theme). Reading the cache is cheap, so it is safe on every `status-interval`.

Spec: `docs/superpowers/specs/2026-06-05-update-notifier-cta-design.md` (§3 modes,
§5 surfaces). CTA-only, fail-open, no daemon.

---

## File structure

- Modify: `bin/update-status` — add `_print_tmux` + `--tmux` case arm; update usage.
- Modify: `tests/bats/update-status.bats` — `--tmux` behind/empty/multi-tool tests.
- Modify: `configs/tmux/tmux.conf` — append the badge segment after TPM init.

---

### Task 1: `--tmux` mode (TDD)

- [ ] **Step 1 — failing tests** in `tests/bats/update-status.bats`:
  - behind single tool → `--tmux` prints `⬆demo` (uses TESTONLY registry).
  - all up-to-date → `--tmux` prints empty.
  - two behind tools seeded in cache → `⬆aicoding ⬆dvw` (alphabetical, space-sep,
    no trailing newline / no leading space). Reads cache directly, registry-agnostic.
- [ ] **Step 2 — run, verify RED** (`--tmux` unknown arg → exit 2 today).
- [ ] **Step 3 — implement** `_print_tmux` (glob `$STATE/*.json`, filter
  `status == behind`, accumulate `⬆<tool>` space-joined, print with no trailing
  newline) + `--tmux) _refresh_detached; _print_tmux ;;` + usage strings.
- [ ] **Step 4 — verify GREEN**, then full suite.

### Task 2: wire into catppuccin status line

- [ ] Append after `run '~/.tmux/plugins/tpm/tpm'` (so it survives catppuccin's
  module-driven `status-right`):
  ```
  set -ga status-right '#[fg=#f9e2af]#(~/.local/bin/update-status --tmux)#[default]'
  ```
  `#f9e2af` = catppuccin mocha yellow (already used for activity) → reads as a
  warning without introducing a new color. `~` is tilde-expanded by `/bin/sh -c`.
  `status-interval` stays at 5s (sane; cache read is negligible).

### Task 3: full suite + PR

- [ ] `bash tests/bats/run.sh` green (93 + new --tmux tests).
- [ ] Branch `feat/update-notifier-tmux` → PR to `vossiman/aiCodingBaseSetup` main.

---

## Self-review

**Spec coverage:** `--tmux` mode ✔ (§3), compact `⬆tool` badge / empty when
current ✔ (§5), throttled detached refresh + cache-read (never blocks) ✔ (mirrors
`--banner`), catppuccin integration without fighting modules ✔ (append after TPM),
CTA-only / fail-open ✔ (reuses Phase-1 machinery, exit 0). Out: counts, styling
beyond one segment, status-interval change.
