#!/usr/bin/env bats
# A full scheduled pass must not restart, stop, kill or delete outside its own
# directories. Stubs RECORD every forbidden invocation (also through sudo), so
# a caller that swallows failures with `|| true` still leaves evidence.

setup() {
  : "${BLUEPRINT_ROOT:?run via run.sh}"
  export TMP; TMP=$(mktemp -d); export HOME="$TMP/home" TMPDIR="$TMP/tmp"
  mkdir -p "$HOME/.local/bin" "$TMPDIR" "$TMP/stubs" "$TMP/prefix/bin" "$TMP/prefix/share/aicoding" "$TMP/terminfo/x"
  export AICODING_BLUEPRINT_CLONE="$BLUEPRINT_ROOT" AICODING_BLUEPRINT_LOCAL=1
  export AICODING_MANIFEST="$HOME/.aicodingsetup/manifest.json"
  export AICODING_UPDATE_STATE="$TMP/state/updates"
  export CODEX_MANAGED_DIR="$TMP/etc-codex" AICODINGSETUP_NONINTERACTIVE=1
  export AICODING_SYSTEM_PROVISION_RUN_OFFLINE=1
  # CI runs on a bare VM, not a container: force the runtime seam so step 5
  # (gated by _sync_system_provision_allowed in lib/sync.sh) actually runs
  # instead of being silently skipped, which would make this test pass
  # vacuously.
  export AICODING_CONTAINER_RUNTIME=1
  export AICODING_SYSTEM_PREFIX="$TMP/prefix" AICODING_TMUX_PREFIX="$TMP/prefix"
  export AICODING_TMUX_COMMIT_FILE="$TMP/prefix/share/aicoding/tmux-commit"
  export AICODING_UV_OPT_DIR="$TMP/opt-uv" AICODING_TERMINFO_DIRS="$TMP/terminfo" AICODING_GO_ROOT="$TMP/go"
  export FORBIDDEN="$TMP/forbidden" RMLOG="$TMP/rm.log"
  : > "$FORBIDDEN"; : > "$RMLOG"
  local c
  for c in docker devpod dvw reboot shutdown poweroff pkill killall; do
    printf '#!/bin/sh\necho "%s $*" >> "$FORBIDDEN"\nexit 0\n' "$c" > "$TMP/stubs/$c"
  done
  # Read-only systemctl queries are legitimate (scheduler probes); only
  # state-changing verbs are forbidden.
  cat > "$TMP/stubs/systemctl" <<'EOF'
#!/bin/sh
case " $* " in
  *" restart "*|*" stop "*|*" kill "*|*" reboot "*|*" poweroff "*|*" try-restart "*|*" reload-or-restart "*)
    echo "systemctl $*" >> "$FORBIDDEN" ;;
esac
exit 1
EOF
  # Never reach the network for frogmouth; create the launcher like uv would.
  cat > "$TMP/stubs/uv" <<'EOF'
#!/bin/sh
[ -n "${UV_TOOL_BIN_DIR:-}" ] && { printf '#!/bin/sh\nexit 0\n' > "$UV_TOOL_BIN_DIR/frogmouth"; chmod +x "$UV_TOOL_BIN_DIR/frogmouth"; }
exit 0
EOF
  cat > "$TMP/stubs/tmux" <<'EOF'
#!/bin/sh
case "$1" in
  -V) echo "tmux next-3.8" ;;
  kill-server|kill-session|kill-pane|kill-window) echo "tmux $*" >> "$FORBIDDEN" ;;
esac
exit 0
EOF
  cat > "$TMP/stubs/rm" <<'EOF'
#!/bin/sh
echo "$*" >> "$RMLOG"
exec /bin/rm "$@"
EOF
  cat > "$TMP/stubs/sudo" <<'EOF'
#!/bin/sh
[ "${1:-}" != -n ] || shift
exec "$@"
EOF
  for c in apt-get npm npx bwrap cursor-agent nohup opencode agent codex; do
    printf '#!/bin/sh\nexit 0\n' > "$TMP/stubs/$c"
  done
  printf '#!/bin/sh\ncase "$*" in --version) echo 2.1.0;; esac\nexit 0\n' > "$TMP/stubs/claude"
  cat > "$TMP/stubs/make" <<'EOF'
#!/bin/sh
printf '#!/bin/sh\necho tmux next-3.9\n' > tmux; chmod +x tmux; : > tmux.1
EOF
  mkdir -p "$TMP/src/tmux-x"
  printf '#!/bin/sh\nexit 0\n' > "$TMP/src/tmux-x/autogen.sh"
  printf '#!/bin/sh\nexit 0\n' > "$TMP/src/tmux-x/configure"; chmod +x "$TMP/src/tmux-x/configure"
  tar -czf "$TMP/tmux.tgz" -C "$TMP/src" tmux-x
  cat > "$TMP/stubs/curl" <<'EOF'
#!/bin/sh
case "$*" in *tmux/tmux/archive/*) cat "$TMP/tmux.tgz" ;; *) exit 22 ;; esac
EOF
  chmod +x "$TMP"/stubs/*
  printf '%s\n' 5356c62eadf8650ad1ffc95f52755d6f66029a20 > "$AICODING_TMUX_COMMIT_FILE"
  printf '#!/bin/sh\necho old-tmux\n' > "$TMP/prefix/bin/tmux"; chmod +x "$TMP/prefix/bin/tmux"
  export PATH="$TMP/stubs:$PATH"
  cd "$TMP"
}

teardown() { cd /; /bin/rm -rf "$TMP"; }

@test "a full scheduled pass that rebuilds tmux records no forbidden call and deletes only below its roots" {
  bash "$BLUEPRINT_ROOT/install.sh" </dev/null
  : > "$FORBIDDEN"; : > "$RMLOG"
  run env AICODING_UPDATE_TTL=0 "$BLUEPRINT_ROOT/bin/aicoding-sync" --boot
  # The pass itself may report deferrals or unrelated offline failures; this
  # test is about side effects only.
  [ ! -s "$FORBIDDEN" ] || { cat "$FORBIDDEN"; false; }
  [ "$(cat "$AICODING_TMUX_COMMIT_FILE")" != 5356c62eadf8650ad1ffc95f52755d6f66029a20 ]
  local line arg bad=0
  while IFS= read -r line; do
    for arg in $line; do
      case "$arg" in
        -*) ;;
        "$TMP"/*) ;;
        *) echo "rm outside the test root: $arg"; bad=1 ;;
      esac
    done
  done < "$RMLOG"
  [ "$bad" -eq 0 ]
}
