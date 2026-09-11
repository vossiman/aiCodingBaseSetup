#!/usr/bin/env bats

@test "codex merge Python behavior suite" {
  run python3 "$BLUEPRINT_ROOT/tests/test_codex_merge.py"
  [ "$status" -eq 0 ]
}
