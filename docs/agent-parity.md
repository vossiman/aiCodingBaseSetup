# Claude / Codex workflow parity

AICODINGBASESETUP-26. Target: equivalent development workflows with native
integration for each CLI. This does not promise identical model decisions,
UI, permission prompts, or third-party plugin inventories.

## Managed capabilities

| Capability | Claude Code | Codex |
|---|---|---|
| Superpowers | `superpowers@claude-plugins-official` | `superpowers@openai-curated-remote` |
| Estate skills | `~/.claude/skills` | Same files via `~/.agents/skills` |
| Independent PR review | Defaults to Codex | Defaults to Claude |
| Review/fix handback | Shared throwaway-worktree driver, no commits/pushes | Same driver |
| Housekeeping | `/housekeep` delegates to shared skill | `$housekeep` |
| New project layout | `templates/project/` | Same reference templates |
| Memory retrieval | memory-router MCP + prompt hints | Same MCP + prompt hints |
| Secret-deny hook | PreToolUse | Same script, managed PreToolUse |
| Transcript redaction | Stop/SessionEnd + startup notice | Same scripts, managed hooks |
| Archive reminder | SessionStart | Same script, managed SessionStart |
| Phone notification | PermissionRequest hook | Turn-complete notify; tmux fallback for waiting |
| Branch isolation | Shared `worktree-session` skill and `aicoding-worktree` | Same helper and location |
| Independent session messages | Native Claude peers | No equivalent cross-harness transport; AICODINGBASESETUP-29 |
| Subagents | Native Claude tools | Native Codex multi-agent feature |

`install.sh` and `aicoding-sync` install/update Superpowers using native
`codex plugin add`, then verify `installed` and `enabled` through the CLI.
Offline tests skip these network operations. Missing/old Codex or catalog
failures produce a warning without breaking provisioning. Existing plugins
are preserved; no Claude cache paths are copied or pinned into Codex.
Codex 0.153.4's remote catalog can report enabled while omitting skills from
fresh-session discovery. A Codex-only `~/.codex/skills/superpowers` symlink
points to the native install result's `installedPath/skills` (or under
`CODEX_HOME` when set). This legacy discovery root remains supported by the
CLI; the link updates when the native package version changes. A user-owned
directory or unrelated symlink is preserved with a warning. The fresh-session
check discovered all 14 Superpowers skills after this bridge was added.
Start a fresh session after installing plugins to pick up their skills.
The existing skill bridge preserves a real user-owned `~/.agents/skills`
directory; users who adopted that layout must link the desired estate skills
into it themselves. Standard blueprint installs get the shared directory link.

The managed hooks live under `/etc/codex` so they take effect without a
per-user `/hooks` trust step. The memory wrapper tags retrieval as
`hook:claude-code` or `hook:codex`. All reminder paths fail open.

## Worktree isolation and coordination

Both agents create implementation worktrees under
`<repo-root>/.claude/worktrees/<branch>` and keep shared checkouts unchanged.
`aicoding-worktree <branch> [base-ref]` handles creation and the local ignore
rule. Existing paths/branches are never reset. Already-linked worktrees are
reused for their current branch. The shared skill adds overlap checks and
handoff guidance.

Claude ListAgents/SendMessage is independent-session messaging. Codex's
subagent tools are coordination inside a task tree. Neither is a native
Claude↔Codex message bridge. AICODINGBASESETUP-29 tracks that separate feature;
this change does not use private session sockets or wake unrelated sessions.

## Review from either CLI

```bash
~/.claude/skills/review-by-harness/run.sh 123 /path/to/repo --caller codex --review-only
~/.claude/skills/review-by-harness/run.sh 123 /path/to/repo --caller claude --review-only
```

Explicit `--harness claude|codex|cursor` overrides caller-based selection.
Without `--caller`, the driver recognizes `CLAUDECODE` / `CODEX_THREAD_ID`;
unknown callers retain the historical Codex default. `REVIEW_MODEL` and
`REVIEW_EFFORT` override adapter defaults; a model override must be valid for
the selected harness. Claude defaults to `opus`, Codex to `gpt-5.6-sol`.

Claude review exposes only Read/Glob/Grep, with MCP tools excluded and
`dontAsk` permission mode. The driver verifies that review left the worktree
unchanged. Fix uses native sandboxing when user namespaces work. When they
do not, Claude honors the existing explicit full-access opt-in
`REVIEW_SANDBOX='-s danger-full-access'`; Cursor's `--force` is not enough.
The adapters retain existing user/managed hooks. As with the original
adapters, the worktree is a working location, not an OS security boundary.
Always verify findings and inspect actual changes and test output.

## Differences that remain

- Claude's background wiki distiller and memory-lanes transcript tee consume
  Claude JSONL. Codex retrieval is shared, but automated transcript ingestion
  needs a format adapter in the memory-lanes pipeline before wiring its Stop
  hook. Do not feed Codex JSONL to a Claude-format ingester unchanged.
- Claude's Opus/Fable-specific guidance, statusline and plugin agents remain
  Claude-specific. Codex uses its own model guidance and UI. Claude's
  `pyright-lsp` plugin does not imply a Codex LSP integration; CLI type checks
  remain available to both.
- Claude's additional plugins (frontend-design, code-simplifier, code-review,
  claude-code-setup) are not wholesale copied. Estate design guidance and
  review workflows are shared; setup advice must target the actual CLI.
- Permission events and interactive questions differ by harness. Shared skills
  describe the task rather than requiring a Claude-only tool name.
- OpenCode and Cursor extensions beyond existing shared MCP/skill wiring are
  outside this Claude/Codex change.

## Validation

Automated coverage exercises native plugin install/activation/failure paths,
reviewer routing, the Claude adapter tool and sandbox modes, instruction-file
restoration, unexpected review writes, and managed hook deployment. Run:

```bash
bash tests/bats/run.sh codex-plugins claude-review-adapter review-by-harness codex-managed-hooks memory-hint-hook
bash tests/bats/run.sh
```

Live validation should check `codex plugin list --json`, skill discovery in a
fresh session, housekeeping on disposable docs (including an archive name
collision), and review/fix on a disposable repository. Stubbed tests alone
cannot prove model behavior or account access.

References: [Codex skills](https://learn.chatgpt.com/docs/build-skills),
[Codex hooks](https://learn.chatgpt.com/docs/hooks), and the installed
Superpowers 6.3.0 README / Codex plugin manifest. CLI installation syntax
verified with `codex-cli 0.153.4`; Claude adapter flags with Claude Code 2.1.263.
