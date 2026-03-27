# Setup Verification Prompt

Paste the following into Claude Code or opencode to test that all MCPs, skills, and plugins are working.

---

## Prompt

```
I just ran my AI coding setup installer and need to verify everything works. Run through each test below, one at a time, and report PASS/FAIL for each. If something fails, tell me what's wrong. For each test you must actually EXECUTE the action, not just check if the tool exists.

**Note:** If you are running in opencode, tests 7-14 are Claude Code marketplace plugins. opencode does not have a plugin/marketplace system, so report those as SKIP (expected). The MCP and skill tests (1-6) should work in both tools.

### 1. MCP: Brave Search
Search the web for "Anthropic Claude Code CLI" and return the top 3 results with titles and URLs.

### 2. MCP: Firecrawl
Use firecrawl to scrape https://example.com and return the page content as markdown.

### 3. MCP: Context7
Look up the documentation for the "jq" library using context7. Return a snippet of what you find.

### 4. MCP: Playwright
Use playwright to navigate to https://example.com, take a screenshot, and describe what you see.

### 5. Skill: Cloudflare Browser Rendering
Invoke the cloudflare-browser skill and use it to fetch https://example.com as markdown via the Cloudflare Browser Rendering REST API. Actually run the curl command and show the result.
(If the API token placeholder {{CLOUDFLARE_API_TOKEN}} is still in the skill, report FAIL — tokens should have been substituted by the installer.)

### 6. Hook: bubblewrap (bw-deny-files)
Verify the hook is installed by checking that ~/.claude/hooks/bw-deny-files.sh exists and is a symlink pointing into the bw-AICode vendor directory. Run: ls -la ~/.claude/hooks/bw-deny-files.sh

### 7. Plugin: Superpowers (Claude Code only)
Invoke the brainstorming skill (superpowers:brainstorming) and confirm it loads successfully. You don't need to complete the brainstorming flow — just confirm it activates and gives you instructions. List at least 5 other superpowers skills you can see.

### 8. Plugin: Playwright plugin (Claude Code only)
Use the playwright plugin to take a snapshot of the current browser state (browser_snapshot). This confirms the plugin is enabled and the MCP tools are callable.

### 9. Plugin: Frontend Design (Claude Code only)
Invoke the frontend-design skill and confirm it loads with instructions. You don't need to build anything — just confirm activation.

### 10. Plugin: Code Review (Claude Code only)
Invoke the code-review skill and confirm it loads. You don't need to run a full review.

### 11. Plugin: Code Simplifier (Claude Code only)
Invoke the simplify skill and confirm it loads with instructions.

### 12. Plugin: Skill Creator (Claude Code only)
Invoke the skill-creator skill and confirm it loads.

### 13. Plugin: Claude Code Setup (Claude Code only)
Invoke the claude-code-setup:claude-automation-recommender skill and confirm it loads.

### 14. Plugin: Pyright LSP (Claude Code only)
Confirm the pyright-lsp plugin is enabled by checking if LSP tools are available.

---

After all tests, print a summary table:

| # | Component | Type | Status |
|---|-----------|------|--------|
| 1 | brave-search | MCP | PASS/FAIL/SKIP |
| 2 | firecrawl | MCP | PASS/FAIL/SKIP |
| 3 | context7 | MCP | PASS/FAIL/SKIP |
| 4 | playwright | MCP | PASS/FAIL/SKIP |
| 5 | cloudflare-browser | Skill | PASS/FAIL/SKIP |
| 6 | bw-deny-files | Hook | PASS/FAIL/SKIP |
| 7 | superpowers | Plugin | PASS/FAIL/SKIP |
| 8 | playwright-plugin | Plugin | PASS/FAIL/SKIP |
| 9 | frontend-design | Plugin | PASS/FAIL/SKIP |
| 10 | code-review | Plugin | PASS/FAIL/SKIP |
| 11 | code-simplifier | Plugin | PASS/FAIL/SKIP |
| 12 | skill-creator | Plugin | PASS/FAIL/SKIP |
| 13 | claude-code-setup | Plugin | PASS/FAIL/SKIP |
| 14 | pyright-lsp | Plugin | PASS/FAIL/SKIP |

Report the overall score: X/14 passed, Y skipped, Z failed.
For opencode: 6/6 shared components passed is a perfect score (plugins are Claude Code only).

Finally: can you see the custom powerline statusline at the bottom of the terminal? It should show model name, directory, git branch, context usage, and rate limits. Let me know what you see.
```
