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
Invoke the cloudflare-browser skill and use it to fetch https://example.com as markdown via the Cloudflare Browser Rendering REST API. Actually run the curl command and show the result.
(If the API token placeholder {{CLOUDFLARE_API_TOKEN}} is still in the skill, report FAIL — tokens should have been substituted by the installer.)

### 6. Skill: Superpowers
Invoke the brainstorming skill and confirm it loads successfully. You don't need to complete the brainstorming flow — just confirm it activates and gives you instructions. List at least 5 other superpowers skills you can see.
- In Claude Code: invoke superpowers:brainstorming via the Skill tool
- In opencode: the skill should be auto-discovered from ~/.claude/skills/ — check if brainstorming SKILL.md is available

### 7. Hook: bubblewrap (bw-deny-files)
Verify the hook is installed by checking that ~/.claude/hooks/bw-deny-files.sh exists and is executable. Run: ls -la ~/.claude/hooks/bw-deny-files.sh

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
| 7 | bw-deny-files | Hook | PASS/FAIL/SKIP |

Report the overall score: X/7 passed, Y skipped, Z failed.

Finally: can you see the custom powerline statusline at the bottom of the terminal? It should show model name, directory, git branch, context usage, and rate limits. Let me know what you see.
```
