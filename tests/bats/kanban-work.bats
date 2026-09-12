#!/usr/bin/env bats

@test "kanban-work Python contract" {
  run env PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -v \
    -s "$BLUEPRINT_ROOT/tests/python" -p 'test_kanban_work*.py'
  [ "$status" -eq 0 ]
}
