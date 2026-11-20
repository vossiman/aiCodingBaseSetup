#!/usr/bin/env bats

@test "leaniptv-diag reads uploads by code without leaking tokens" {
  run python3 "$BLUEPRINT_ROOT/tests/python/test_leaniptv_diag.py"
  [ "$status" -eq 0 ]
}
