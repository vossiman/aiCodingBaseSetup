#!/usr/bin/env bats
# configs/bash/env.sh: DISPLAY default for the clipboard bridge. cursor-agent
# only enumerates its xclip paste candidates `if (process.env.DISPLAY)`, so a
# container without DISPLAY never asks the clip-shim at all. :0 is also where
# a future Xvfb (codex/arboard route) would live.

bats_require_minimum_version 1.5.0

setup() {
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
}

teardown() { rm -rf "$TMPDIR"; }

@test "env.sh sets DISPLAY=:0 when unset" {
  run -0 env -u DISPLAY bash -c "source '$BLUEPRINT_ROOT/configs/bash/env.sh'; printf %s \"\$DISPLAY\""
  [[ "$output" == ":0" ]]
}

@test "env.sh leaves an existing DISPLAY alone" {
  run -0 env DISPLAY=:7 bash -c "source '$BLUEPRINT_ROOT/configs/bash/env.sh'; printf %s \"\$DISPLAY\""
  [[ "$output" == ":7" ]]
}
