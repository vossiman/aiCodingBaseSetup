#!/usr/bin/env bats
@test "activity fixture regressions" {
  run python3 "$BLUEPRINT_ROOT/tests/test_dvw_activity.py"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "probe emits additive activity schema with explicit unknown measurements" {
  run "$BLUEPRINT_ROOT/bin/dvw-probe"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["schema"] == 1; a=d["activity"]; m={"tmux_sessions","terminals","cursor_connections","vscode_connections"}; assert m <= set(a) <= m | {"tmux_unmeasured"}; assert all(v is None or type(v) is int and v >= 0 for k,v in a.items() if k in m); w=a.get("tmux_unmeasured"); assert w is None or (type(w) is str and w and a["tmux_sessions"] is None)'
}
