---
name: cloudflare-browser
description: "Fetch web content via Cloudflare Browser Rendering API. Use as backup when firecrawl/playwright fail. Supports markdown, content, screenshot, links, scrape, json, pdf, crawl."
allowed-tools:
  - Bash
  - Read
argument-hint: "<url> [format: markdown|content|screenshot|links|scrape|json|pdf|crawl] (default: markdown)"
---

# Cloudflare Browser Rendering

Fetch web content through the Cloudflare Browser Rendering API. Use this when
firecrawl or playwright are unavailable or return errors.

## How the credential is handled

You do not have it, and you do not need it. `cloudflare-render` reads the API
token and account id from the estate's secrets store inside its own process,
sends one request to a pinned `api.cloudflare.com` origin, and prints only the
response. Nothing you write contains a credential, so nothing lands in this
transcript.

Do not reconstruct these calls with `curl` and a token. That is what this
command replaces.

## Usage

```bash
cloudflare-render <url> [format]
```

Parse `$ARGUMENTS` for the URL and an optional format. The default is
`markdown`.

| Format | Description |
|--------|-------------|
| markdown | Page as markdown (default, best for LLM consumption) |
| content | Fully rendered HTML after JS execution |
| screenshot | PNG screenshot; prints the file path |
| pdf | Rendered PDF; prints the file path |
| snapshot | Combined HTML and screenshot |
| scrape | Extract elements by CSS selector (needs `--selectors`) |
| json | Structured extraction (needs `--prompt`) |
| links | All links on the page |
| crawl | Async multi-page crawl |

### Examples

```bash
cloudflare-render https://example.com
cloudflare-render https://example.com content
cloudflare-render https://example.com links
cloudflare-render https://example.com scrape --selectors "h1,p,article"
cloudflare-render https://example.com json --prompt "extract the price"
```

For `screenshot` and `pdf` the command prints the path it wrote, so pass that
path to Read:

```bash
cloudflare-render https://example.com screenshot
cloudflare-render https://example.com pdf --output /tmp/report.pdf
```

Present the result to the user.
