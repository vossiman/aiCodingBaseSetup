---
name: cloudflare-browser
description: "Fetch web content via Cloudflare Browser Rendering API. Use as backup when firecrawl/playwright fail. Supports markdown, content, screenshot, links, scrape, json, pdf, crawl."
allowed-tools:
  - Bash
  - Read
argument-hint: "<url> [format: markdown|content|screenshot|links|scrape|json|pdf|crawl] (default: markdown)"
---

# Cloudflare Browser Rendering

Fetch web content using the Cloudflare Browser Rendering REST API. Use this when firecrawl or playwright are unavailable or return errors.

## Configuration

- Account ID: `{{CLOUDFLARE_ACCOUNT_ID}}`
- API Token: `{{CLOUDFLARE_API_TOKEN}}`
- Base URL: `https://api.cloudflare.com/client/v4/accounts/{{CLOUDFLARE_ACCOUNT_ID}}/browser-rendering`

## Usage

Parse `$ARGUMENTS` to extract the URL and optional format. Default format is `markdown`.

### Supported Formats

| Format | Endpoint | Description |
|--------|----------|-------------|
| markdown | `/markdown` | Convert page to markdown (default, best for LLM consumption) |
| content | `/content` | Fully rendered HTML after JS execution |
| screenshot | `/screenshot` | Capture PNG screenshot |
| pdf | `/pdf` | Render page as PDF |
| snapshot | `/snapshot` | Combined HTML + screenshot |
| scrape | `/scrape` | Extract elements via CSS selectors (requires selectors in args) |
| json | `/json` | AI-powered structured data extraction (requires prompt in args) |
| links | `/links` | Extract all links from a page |
| crawl | `/crawl` | Async multi-page crawl |

### Execution

1. Parse the URL and format from `$ARGUMENTS`
2. Run the appropriate curl command via Bash:

**For markdown (default):**
```bash
curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/{{CLOUDFLARE_ACCOUNT_ID}}/browser-rendering/markdown" \
  -H "Authorization: Bearer {{CLOUDFLARE_API_TOKEN}}" \
  -H "Content-Type: application/json" \
  -d '{"url": "<URL>"}'
```

**For content:**
```bash
curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/{{CLOUDFLARE_ACCOUNT_ID}}/browser-rendering/content" \
  -H "Authorization: Bearer {{CLOUDFLARE_API_TOKEN}}" \
  -H "Content-Type: application/json" \
  -d '{"url": "<URL>"}'
```

**For screenshot:**
```bash
curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/{{CLOUDFLARE_ACCOUNT_ID}}/browser-rendering/screenshot" \
  -H "Authorization: Bearer {{CLOUDFLARE_API_TOKEN}}" \
  -H "Content-Type: application/json" \
  -d '{"url": "<URL>", "fullPage": true}' \
  --output /tmp/cf-screenshot.png
```
Then use Read to display the screenshot.

**For links:**
```bash
curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/{{CLOUDFLARE_ACCOUNT_ID}}/browser-rendering/links" \
  -H "Authorization: Bearer {{CLOUDFLARE_API_TOKEN}}" \
  -H "Content-Type: application/json" \
  -d '{"url": "<URL>"}'
```

**For scrape (requires CSS selectors):**
```bash
curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/{{CLOUDFLARE_ACCOUNT_ID}}/browser-rendering/scrape" \
  -H "Authorization: Bearer {{CLOUDFLARE_API_TOKEN}}" \
  -H "Content-Type: application/json" \
  -d '{"url": "<URL>", "selectors": ["h1", "p", "article"]}'
```

**For json (requires prompt):**
```bash
curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/{{CLOUDFLARE_ACCOUNT_ID}}/browser-rendering/json" \
  -H "Authorization: Bearer {{CLOUDFLARE_API_TOKEN}}" \
  -H "Content-Type: application/json" \
  -d '{"url": "<URL>", "prompt": "<extraction prompt>"}'
```

**For pdf:**
```bash
curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/{{CLOUDFLARE_ACCOUNT_ID}}/browser-rendering/pdf" \
  -H "Authorization: Bearer {{CLOUDFLARE_API_TOKEN}}" \
  -H "Content-Type: application/json" \
  -d '{"url": "<URL>"}' \
  --output /tmp/cf-page.pdf
```
Then use Read to display the PDF.

**For crawl (async):**
```bash
# Start crawl job
JOB=$(curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/{{CLOUDFLARE_ACCOUNT_ID}}/browser-rendering/crawl" \
  -H "Authorization: Bearer {{CLOUDFLARE_API_TOKEN}}" \
  -H "Content-Type: application/json" \
  -d '{"url": "<URL>", "limit": 10, "formats": ["markdown"]}')
echo "$JOB"

# Check status (extract job ID from response)
JOB_ID=$(echo "$JOB" | jq -r '.id // .result.id // empty')
curl -s "https://api.cloudflare.com/client/v4/accounts/{{CLOUDFLARE_ACCOUNT_ID}}/browser-rendering/crawl/$JOB_ID" \
  -H "Authorization: Bearer {{CLOUDFLARE_API_TOKEN}}"
```

3. Present the results to the user
