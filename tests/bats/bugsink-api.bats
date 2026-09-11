#!/usr/bin/env bats

@test "bugsink-api reads issues and submits smoke events without leaking credentials" {
  run python3 "$BLUEPRINT_ROOT/tests/python/test_bugsink_api.py"
  [ "$status" -eq 0 ]
}
