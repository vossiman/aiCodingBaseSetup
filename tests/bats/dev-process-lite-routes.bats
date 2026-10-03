#!/usr/bin/env bats
# skills/dev-process-lite/routes.default.json: the default routes table.

bats_require_minimum_version 1.5.0

setup() {
  : "${BLUEPRINT_ROOT:?unset, run via tests/bats/run.sh}"
  F="$BLUEPRINT_ROOT/skills/dev-process-lite/routes.default.json"
}

@test "routes: version 1, three entries, five roles, valid fields" {
  run jq -e '
    .version == 1
    and (.routes | keys) == ["claude", "codex", "cursor"]
    and all(.routes[]; keys == ["assessor", "complex-implementer", "implementer", "overseer", "reviewer"])
    and all(.routes[][];
          (.harness | IN("claude", "codex", "cursor"))
          and (has("model") != has("family"))
          and (.effort | IN("low", "medium", "high", "xhigh", "max")))
  ' "$F"
  [ "$status" -eq 0 ]
}

@test "routes: implementer and complex-implementer share a harness, implementer has lower effort" {
  run jq -e '
    def rank: {"low": 0, "medium": 1, "high": 2, "xhigh": 3, "max": 4}[.];
    all(.routes[];
      .implementer.harness == .["complex-implementer"].harness
      and ((.implementer.effort | rank) < (.["complex-implementer"].effort | rank)))
  ' "$F"
  [ "$status" -eq 0 ]
}

@test "routes: balanced family implements, workhorse family does complex work" {
  run jq -e '
    .routes.claude.implementer.family == "sonnet"
    and .routes.claude["complex-implementer"].family == "opus"
    and .routes.codex.implementer.family == "luna"
    and .routes.codex["complex-implementer"].family == "sol"
  ' "$F"
  [ "$status" -eq 0 ]
}

@test "routes: every reviewer is from another harness than its entry" {
  run jq -e 'all(.routes | to_entries[]; .value.reviewer.harness != .key)' "$F"
  [ "$status" -eq 0 ]
}

@test "routes: a frontier family appears only in cursor.reviewer, which must have one" {
  run jq -e '
    def frontier: ((.family // "") | test("fable|astra")) or ((.model // "") | test("fable|astra"));
    [.routes | to_entries[] | .key as $e | .value | to_entries[]
      | select(.value | frontier) | "\($e).\(.key)"] == ["cursor.reviewer"]
  ' "$F"
  [ "$status" -eq 0 ]
}
