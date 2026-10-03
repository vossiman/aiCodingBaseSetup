{
  "version": 1,
  "_comment": "Defaults for dev-process-lite. A repo pins its own in .dev-process/routes.json. A route names a family (resolved to the newest installed model by routes.sh) or an exact model, which wins.",
  "routes": {
    "claude": {
      "overseer": { "harness": "claude", "family": "opus", "effort": "high" },
      "implementer": { "harness": "claude", "family": "sonnet", "effort": "low", "note": "low since 2026-10-03: phase 1 low/medium pairs were byte-identical for plans that carry the code; use medium when the brief leaves design to the implementer." },
      "complex-implementer": { "harness": "claude", "family": "opus", "effort": "high" },
      "reviewer": { "harness": "codex", "family": "sol", "effort": "high" },
      "assessor": { "harness": "claude", "family": "opus", "effort": "high" }
    },
    "codex": {
      "overseer": { "harness": "codex", "family": "sol", "effort": "high" },
      "implementer": { "harness": "codex", "family": "luna", "effort": "medium", "note": "Owner choice as the Sonnet-level counterpart; unproven, revisit with own evals." },
      "complex-implementer": { "harness": "codex", "family": "sol", "effort": "high" },
      "reviewer": { "harness": "claude", "family": "opus", "effort": "high" },
      "assessor": { "harness": "codex", "family": "sol", "effort": "high" }
    },
    "cursor": {
      "overseer": { "harness": "cursor", "family": "grok", "effort": "xhigh" },
      "implementer": { "harness": "cursor", "family": "grok", "effort": "medium" },
      "complex-implementer": { "harness": "cursor", "family": "grok", "effort": "xhigh" },
      "reviewer": { "harness": "codex", "family": "astra", "effort": "high", "note": "Owner override 2026-10-03: the only frontier row. Alternative: harness claude, family fable." },
      "assessor": { "harness": "cursor", "family": "grok", "effort": "xhigh" }
    }
  }
}
