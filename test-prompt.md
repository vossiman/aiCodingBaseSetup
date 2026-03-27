# Setup Verification Prompt

Paste the following into Claude Code or opencode to test that all MCPs, skills, and plugins are working.

---

## Prompt

```
I just ran my AI coding setup installer and need to verify everything works. Run through each test below, one at a time, and report PASS/FAIL for each. If something fails, tell me what's wrong.

### 1. MCP: Brave Search
Search the web for "Anthropic Claude Code CLI" and return the top 3 results with titles and URLs.

### 2. MCP: Firecrawl
Use firecrawl to scrape https://example.com and return the page content as markdown.

### 3. MCP: Context7
Look up the documentation for the "jq" library using context7.

### 4. MCP: Playwright
Use playwright to navigate to https://example.com, take a screenshot, and describe what you see.

### 5. Skill: Cloudflare Browser Rendering
Use the cloudflare-browser skill to fetch https://example.com as markdown. This tests the Cloudflare Browser Rendering REST API.
(If the API token is not set, just confirm the skill is loaded and report SKIP)

### 6. Skill: Logfire Reader
Confirm the logfire-reader skill is loaded and accessible.
(This is a placeholder skill — just confirm it appears in your available skills. Report SKIP for actual usage)

### 7. Hook: Custom Statusline
Confirm you can see the powerline statusline at the bottom of the terminal showing model name, directory, git branch, and context usage.
(If running headless/non-interactive, report SKIP)

### 8. Hook: bubblewrap (bw-deny-files)
Try to read a file called "secrets.env" — the bw-deny-files hook should block this if BW_DENY_PATTERNS_FILE is set. Confirm the hook is installed at ~/.claude/hooks/bw-deny-files.sh.
Just check if the file exists, don't actually trigger it.

### 9. Plugin: Superpowers
Confirm superpowers skills are available (brainstorming, writing-plans, TDD, code-review, etc). List at least 5 superpowers skills you can see.

### 10. Plugin: Playwright (plugin)
Confirm the playwright plugin is enabled and provides browser automation tools (browser_navigate, browser_snapshot, etc).

### 11. Plugin: Frontend Design
Confirm the frontend-design skill is available.

### 12. Plugin: Code Review
Confirm the code-review skill is available.

### 13. Plugin: Code Simplifier
Confirm the code-simplifier/simplify skill is available.

### 14. Plugin: Skill Creator
Confirm the skill-creator skill is available.

### 15. Plugin: Claude Code Setup
Confirm the claude-code-setup/automation-recommender skill is available.

### 16. Plugin: Pyright LSP
Confirm the pyright-lsp plugin is enabled.

---

After all tests, print a summary table:

| # | Component | Type | Status |
|---|-----------|------|--------|
| 1 | brave-search | MCP | PASS/FAIL/SKIP |
| 2 | firecrawl | MCP | PASS/FAIL/SKIP |
| ... | ... | ... | ... |

And report the overall score: X/16 passed, Y skipped, Z failed.
```
