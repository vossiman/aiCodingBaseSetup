# Setup Verification Prompt

Paste the following into Claude Code or opencode to test that all MCPs, skills, and hooks are working.

---

## Prompt

```
I just ran my AI coding setup installer and need to verify everything works. Run through each test below, one at a time, and report PASS/FAIL for each. If something fails, tell me what's wrong. For each test you must actually EXECUTE the action, not just check if the tool exists.

### 1. MCP: Brave Search
Search the web for "Anthropic Claude Code CLI" and return the top 3 results with titles and URLs.

### 2. MCP: Firecrawl
Use firecrawl to scrape https://example.com and return the page content as markdown.

### 3. MCP: Context7
Look up the documentation for the "jq" library using context7. Return a snippet of what you find.

### 4. MCP: Playwright
Use playwright to navigate to https://example.com, take a screenshot, and describe what you see.

### 5. Skill: Cloudflare Browser Rendering
Invoke the cloudflare-browser skill and use it to fetch https://example.com as markdown. Actually run the `cloudflare-render` command and show the result.
(If the skill contains a token, a token placeholder, or any `curl` with an `Authorization` header, report FAIL — the skill must document the broker command only, never a credential.)

### 6. Skill: Superpowers
Invoke the brainstorming skill and confirm it loads successfully. You don't need to complete the brainstorming flow — just confirm it activates and gives you instructions. List at least 5 other superpowers skills you can see.
- In Claude Code: invoke superpowers:brainstorming via the Skill tool
- In opencode: the skill should be auto-discovered from ~/.claude/skills/ — check if brainstorming SKILL.md is available

### 7. Hook: secrets deny (bw-deny-files)
Do not just check that the file exists — an installed hook that no-ops is exactly the bug this test now guards (see docs/agent-release-audits.md, 2026-08-21).
1. `ls -la ~/.claude/hooks/bw-deny-files.sh` — present and executable.
2. Exercise it: `echo '{"tool_name":"Bash","tool_input":{"command":"cat ~/.aicodingsetup/.secrets.env"}}' | bash ~/.claude/hooks/bw-deny-files.sh` — must print a JSON object with `"permissionDecision": "deny"`. Empty output is a FAIL.
3. Confirm no false positive: same command with `~/.aicodingsetup/manifest.json` must print nothing (allow).
4. Try to read the secrets file with your own Read tool — the attempt must be blocked. Report the refusal message; never report the file's contents.
5. `secrets-check` — must list key names with STATUS/LEN/FINGERPRINT and no values.
6. Codex side: `test -f /etc/codex/requirements.toml && grep -q PreToolUse /etc/codex/requirements.toml` — the managed hook must be installed. If the file is missing, the install could not get root; report FAIL with that reason rather than SKIP.
7. In codex, ask it to `cat ~/.aicodingsetup/.secrets.env`. It must be refused by the hook (codex prints `Command blocked by PreToolUse hook`). Report the refusal, never the contents.

### 8. Project layout: copy the reference templates
Create a fresh directory with `mkdir -p /tmp/layout-test-$$ && cd /tmp/layout-test-$$` (in Bash), then ask the agent to set up the project layout per the global CLAUDE.md (copy `templates/project/` from `/tmp/aicoding`, substitute placeholders, strip `.tpl`, rename `dot-claude/` to `.claude/`). Verify the resulting tree contains: CLAUDE.md, AGENTS.md, README.md, TODO.md, .claude/settings.json, and docs/{specs,plans,notes}/{active,archive}/.gitkeep. Clean up the tmp dir after.

### 9. Housekeep: mark a doc done and sweep
Inside a project with the reference layout, create a file `docs/specs/active/fake-spec.md` with YAML frontmatter including `status: done`. Invoke the `/housekeep` slash command. Verify the file is now at `docs/specs/archive/fake-spec.md` and is no longer in `active/`.

### 10. SessionStart hook: archive banner
In a project (reference layout) that has at least one `status: done` doc in `docs/*/active/`, start a new Claude Code session. Verify the SessionStart banner appears: `📦 N docs ready to archive — run /housekeep to sweep.` (Cannot be tested from within the same session — note as PASS if mechanism verified another way, e.g., by running `bash ~/.claude/hooks/check-archived-docs.sh` with `CLAUDE_PROJECT_DIR` set and seeing the banner on stdout.)

---

After all tests, print a summary table:

| # | Component | Type | Status |
|---|-----------|------|--------|
| 1 | brave-search | MCP | PASS/FAIL/SKIP |
| 2 | firecrawl | MCP | PASS/FAIL/SKIP |
| 3 | context7 | MCP | PASS/FAIL/SKIP |
| 4 | playwright | MCP | PASS/FAIL/SKIP |
| 5 | cloudflare-browser | Skill | PASS/FAIL/SKIP |
| 6 | superpowers | Skill | PASS/FAIL/SKIP |
| 7 | secrets deny (bw-deny-files + secrets-check) | Hook | PASS/FAIL/SKIP |
| 8 | project layout templates | Layout | PASS/FAIL/SKIP |
| 9 | /housekeep | Command | PASS/FAIL/SKIP |
| 10 | check-archived-docs (SessionStart) | Hook | PASS/FAIL/SKIP |

Report the overall score: X/10 passed, Y skipped, Z failed.

Finally: can you see the custom powerline statusline at the bottom of the terminal? It should show model name, directory, git branch, context usage, and rate limits. Let me know what you see.
```
