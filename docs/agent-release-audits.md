# Agent-CLI release audits

Recurring audit of the coding-agent CLIs this blueprint installs (claude,
codex, cursor-agent, opencode): what changed upstream since the last
checkpoint, measured against how `configs/` actually uses each tool.

## How to run the next audit

1. Read the checkpoint table below — audit only the gap from each CLI's
   "audited up to" version/date to its current release.
2. Sources: Claude Code `CHANGELOG.md` (anthropics/claude-code), openai/codex
   GitHub releases, Cursor CLI docs changelog (cursor.com/docs/cli/changelog —
   the main cursor.com/changelog barely covers the CLI), sst/opencode GitHub
   releases.
3. Focus: permission/approval/auto modes, subagent delegation, hooks, MCP,
   new config keys we don't set, deprecations of keys we do set.
4. **Verify before adopting**: research-agent reports have contained fabricated
   version attributions (see 2026-08-18 notes) — spot-check load-bearing
   claims against the primary changelog, and spike behavioral claims locally.
5. Record decisions here (adopted/skipped and why), update the checkpoint
   table, land config changes in the same PR.

## Checkpoint table

| CLI | Audited up to | Released | Audit date | Result |
| --- | --- | --- | --- | --- |
| claude | 2.1.234 | 2026-08-17 | 2026-08-18 | installed = latest |
| codex | 0.147.0 | 2026-08-07 | 2026-08-18 | installed = latest |
| cursor-agent | 2026.08.11-e8db854 | 2026-08-11 | 2026-08-18 | installed = latest |
| opencode | 1.18.18 | 2026-08-13 | 2026-08-18 | installed = latest |

## 2026-08-18 audit (window ≈ 2026-07-18 → 2026-08-18)

### codex 0.147.0 (window: 0.145.0, 0.146.0, 0.146.1, 0.147.0)

- **Regression found & fixed sync-side: trust_level writes are back.**
  0.147.0 auto-trusts local projects and persists `[projects."<dir>"]
  trust_level = "trusted"` into `config.toml` even with both
  `approval_policy` and `sandbox_mode` set (the 0.144-era suppression no
  longer holds; spike-verified 2026-08-18 with a fresh dir + `codex exec`).
  Handled in this repo: `compute_managed_hash` in `lib/blueprint-deploy.sh`
  strips `[projects.*]` sections before drift comparison (used by classify,
  deploy, and adopt), so these writes never count as drift. Side effect:
  when the blueprint config changes, redeploy wipes accumulated trust
  entries — harmless, codex re-adds them.
- **Adopted: `[features] multi_agent_v2 = true`** — codex-side subagent
  delegation (stabilized 0.145, default-off). Tunables live under `[agents]`
  (default subagent model/reasoning/concurrency) if ever needed.
- **notify/#11808**: closed upstream in favor of the `[hooks]` feature
  (stable + default-on in 0.147; events include `PermissionRequest`,
  `PreToolUse`, `Stop`, …). With `approval_policy = "never"` the missing
  approval-notification tier is moot; migrating agent-notify from `notify`
  to hooks is a candidate for a future change, not adopted now.
- Skipped/no action: granular `approval_policy = { granular = ... }` and
  `--approve-for-me` (don't change container posture);
  `approval_policy = "on-failure"` deprecated (we use `never`);
  `codex exec --full-auto` removed (unused here); MCP 2026-07-28 protocol
  opt-in flag; streamable-HTTP/OAuth MCP options (our 4 servers are stdio);
  experimental `memories` feature (**deliberately skip — conflicts with the
  wiki-based memory system**); agent plugins/marketplaces; `/import`.
  `status_line` item enum byte-identical 0.144.6→0.147.0, all our items
  valid. 0.147 code mode runs exclusively via the standalone host and
  prefers the bundled sidecar over external installs — the
  `_ensure_codex_code_mode_host` pairing (PR #75) still applies; re-check
  if code mode errors return.

### claude 2.1.234 (window: 2.1.214 → 2.1.234, 21 releases)

- **Auto-mode environment interview** (the prompt that triggered this
  audit): intended flow; it saves an `autoMode.environment` block into
  `~/.claude/settings.json`, which the auto-mode classifier consumes.
  Verified on this devbox: block content accurate, sync-safe (settings.json
  deploys as `merge`, user keys preserved), rebuild-safe (`~/.claude` is a
  host bind mount). Kept host-local, NOT upstreamed into
  `configs/claude/settings.json`: it is interview-derived and partly
  repo-specific; a fresh host should answer its own interview.
- **Adopted: `CLAUDE_CODE_ENABLE_TODO_TOOLS=1`** in settings `env` —
  2.1.233 removed todo/task-tracking tools (TaskCreate/…/TodoWrite) on
  Opus 4.8/Sonnet 5/Fable 5/Mythos 5+; this restores them (changelog-verified).
- Notable defaults changed (no action, awareness): 2.1.232 — subagent
  forking on by default (forks inherit full conversation + prompt cache) and
  non-teammate agent spawns in interactive sessions run in the background by
  default; 2.1.218 — `/code-review` runs as a background subagent; 2.1.234 —
  sessions auto-continue when a claude.ai usage limit resets (disable in
  `/config` if unwanted), and a fix for auto mode re-denying sandboxed
  network access after mid-session compaction (changelog-verified).
- 2.1.224 added sandbox credential-masking options (`extract`,
  `decode: "jwt"`, SigV4 re-signing; needs `network.tlsTerminate`) — skipped,
  the `bw-deny-files.sh` PreToolUse hook already guards the secrets path.
  **Correction 2026-08-21: that premise was false when written.** The hook
  self-disabled unless `BW_DENY_PATTERNS_FILE` was set, which only happens
  inside the bubblewrap sandbox — so in the container and on hosts it guarded
  nothing, and any agent could `cat ~/.aicodingsetup/.secrets.env`. Fixed by
  forking the hook to always enforce a built-in deny list (see README →
  Secrets). The skip itself still stands, but now on a true premise. Lesson:
  do not record a control as "already covered" without exercising it — feed
  the hook a sample tool call and read the decision it emits.
- Research-agent claims **refuted** during verification (recorded so the
  next audit doesn't re-import them): "2.1.222 fixed hook exit-code-2 /
  timeout / glob semantics" — not in the real changelog;
  `autoMode.classifyAllShell` / `sandbox.network.strictAllowlist` as
  in-window additions — not found in the window's changelog.

### cursor-agent 2026.08.11 (window releases: 2026-07-20, 2026-08-11)

- **Adopted: `approvalMode: "unrestricted"` + `autoAcceptWebSearch: true`**
  in `cli-config.json`. Container is the isolation boundary (same posture
  as codex). **Deny-rule safety spike-verified 2026-08-18**: with
  unrestricted mode active (both via `--force` and via the config key), a
  read of `~/.aicodingsetup/manifest.json` was still denied by the
  `permissions.deny` rules — deny is tool-level, not approval-mode-level.
  `autoAcceptWebSearch` (added 2026-07-13, default off) stops per-search
  prompts in all run modes.
- No action: sandbox.json read-access boundary + SOCKS git-over-SSH
  (2026-08-11) — only relevant under auto-review; subagents are file-based
  (`.cursor/agents/`, also discovers `.claude/agents`), nothing to enable in
  cli-config.json; headless runs now drain delegated subagents before exit;
  statusLine streaming-throttle fix benefits our custom statusline as-is;
  hooks (`.cursor/hooks.json`) exist but our Claude-side hooks cover the
  need. Operational note: project-level `.cursor/cli.json` may contain
  ONLY permissions; the CLI self-rewrites some cli-config.json fields
  (`model`, …) — the blueprint owns only its own keys, which merge-deploy
  already tolerates.

### opencode 1.18.18 (window: 1.18.4 → 1.18.18, 15 patch releases)

- **Adopted: `"doom_loop": "ask"`** under `permission` — the blanket
  `"*": "allow"` was silently disabling the repeated-identical-tool-call
  guard, which protects token spend, not the sandbox. (Blanket allow also
  overrides `.env`-read deny and outside-project ask — accepted, container
  is the boundary.)
- `permission: {"*": "allow"}` remains valid schema; zero permission-system
  changes in window. `agent: {}` harmless; per-agent `tools` booleans are
  deprecated in favor of per-agent `permission` (unused here).
- Model: kept `anthropic/claude-opus-5` on cost ($5/$25 vs Fable's $10/$50
  per Mtok at equal listed limits). Note: the models.dev registry's release
  dates suggested "Opus 5 is newer than Fable 5" — treat that as unreliable;
  cost is the actual rationale.
- No action: unknown top-level config fields no longer hard-fail parsing
  (1.18.16); MCP reconnect fixes (1.18.8–1.18.11) benefit our servers
  automatically; `share` stays at default `"manual"` (user chose not to
  disable); window was dominated by Desktop-app work.

## Out-of-band adoptions

Settings adopted outside an audit window. Listed here so a future audit
recognises them as deliberate rather than drift.

### `CLAUDE_CODE_SIMPLE_SYSTEM_PROMPT=0` (2026-08-28, claude 2.1.250)

Forces Claude Code's **long** system-prompt preset on every model.
Claude Code ships two presets and picks per model; Opus 5 gets the short
one (~11k chars) while Sonnet 5 gets the long one (~29k), and nearly all
the response-shaping rules — verbosity, narration cadence, lead-with-the-
outcome — live only in the long one. Result: on Opus 5 the `Concise`
output style and the `Be concise` line in `configs/claude/CLAUDE.md` were
competing against a missing scaffold rather than reinforcing one, and
user-facing answers came back stuffed with function names, line numbers
and library internals, with no closing summary.

The selector in the 2.1.250 binary:

```js
function B(e){ if(!e) return !1;
  if(Pe(a.CLAUDE_CODE_SIMPLE_SYSTEM_PROMPT)) return !0;   // truthy  -> short preset
  if(Eo(a.CLAUDE_CODE_SIMPLE_SYSTEM_PROMPT)) return !1;   // "0"     -> long preset
  if(!w(e)) return !0;
  if(x("tengu_velvet_tide",!1)) return !0;
  return L("simple_system_prompt", Ye(e)); }              // else: server-side flag
```

So `"0"` is a supported override, not a hack — but note the third line:
unset, the choice is a **server-side flag**, so the default can move under
us without a release note. That is the second reason to pin it.

Corroborating evidence, not just the code: a session running
`claude-opus-5` had the short preset verbatim in context (single line
`Write code that reads like the surrounding code…` in place of the long
preset's verbosity ruleset). Anthropic's own [Opus 5 prompting
guide](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5)
confirms the behaviour is model-specific ("Claude Opus 5's default
user-facing responses run longer than prior Opus models'… narrates readily
during agentic work") and that **effort level is not the lever** — effort
controls thinking, not visible output. Setting `effortLevel` lower will
not fix verbosity.

Trade-off, accepted knowingly: the key is global, so models that were
already getting the long preset see no change, and any that were on the
short preset by design now pay ~18k extra prompt chars. Cached, so the
marginal cost is small.

**Do not remove without a replacement.** If a future audit wants this
gone, the fallback is a `UserPromptSubmit` hook that reads the model from
`transcript_path` and injects the anti-verbosity guidance only for
`claude-opus-5` — deliberately *not* a `CLAUDE.md` edit, since codex,
cursor-agent and opencode read those files unconditionally and would
inherit Opus-specific tuning they don't need.
