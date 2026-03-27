---
name: logfire-reader
description: "Query and read logs from Pydantic Logfire via REST API. Use when debugging or investigating application behavior."
allowed-tools:
  - Bash
  - Read
argument-hint: "<query> [--project <name>] [--limit <n>]"
---

# Logfire Reader

Query and read application logs from Pydantic Logfire via REST API.

## Configuration

- API Token: `{{LOGFIRE_TOKEN}}`

## Usage

Parse `$ARGUMENTS` to extract the query and optional flags.

### Execution

<!-- TODO: Research exact Logfire REST API endpoints and query format -->
<!-- Expected base URL: https://logfire-api.pydantic.dev/v1/ or similar -->
<!-- Auth header: Authorization: Bearer {{LOGFIRE_TOKEN}} -->

Use Bash to query the Logfire REST API:

```bash
curl -s "https://logfire-api.pydantic.dev/v1/query" \
  -H "Authorization: Bearer {{LOGFIRE_TOKEN}}" \
  -H "Content-Type: application/json" \
  -d '{"query": "<QUERY>", "limit": <LIMIT>}'
```

Present the results to the user, formatted for readability.
