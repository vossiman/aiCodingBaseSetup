#!/usr/bin/env bats
# bin/clip-x11-bridge: X11 selection owner for the dvw clipboard bridge —
# makes codex (arboard: direct X11 protocol, no exec) paste work. Owns the
# CLIPBOARD selection on a virtual display and answers every image/png
# selection request with FRESH bytes fetched from the bridge socket.
#
# Integration tests: real Xvfb, real /usr/bin/xclip as the paste client
# (call it by absolute path — ~/.local/bin/xclip is the exec-shim), stub
# bridge server. Requires uv (daemon runs via `uv run --with python-xlib`).

bats_require_minimum_version 1.5.0

setup() {
  command -v uv >/dev/null || skip "uv not available"
  [[ -x /usr/bin/xclip ]] || skip "real xclip not installed"
  command -v Xvfb >/dev/null || skip "Xvfb not installed"
  # Unique display per test: a dying Xvfb from the previous test can
  # linger long enough for a shared display number to hand the next
  # test a stale server (and with it a stale selection owner).
  DISPLAY_NUM=":$((9300 + BATS_TEST_NUMBER))"
  TMPDIR=$(mktemp -d)
  export TMPDIR
  CLIPX_TMPDIR="$TMPDIR"   # teardown's only license to delete (see below)
  # Keep uv's package cache across the HOME override — the daemon runs via
  # `uv run --with python-xlib`, and a cold cache per test means a network
  # download inside the selection-ownership wait window.
  export UV_CACHE_DIR="${UV_CACHE_DIR:-$HOME/.cache/uv}"
  export HOME="$TMPDIR"
  export DVW_CLIP_SOCK="$TMPDIR/clip.sock"
  PNG="$TMPDIR/fixture.png"
  printf '\x89PNG\r\n\x1a\n' > "$PNG"
  head -c 300000 /dev/urandom >> "$PNG"   # ~300KB: beyond one small X transfer unit
  python3 - "$DVW_CLIP_SOCK" "$TMPDIR" <<'EOF' &
import http.server, socketserver, sys, os
sock, tmp = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path.startswith("/clip?type=image/png"):
            body = open(os.path.join(tmp, "fixture.png"), "rb").read()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers(); self.wfile.write(body); return
        if self.path == "/targets":
            self.send_response(200); self.send_header("Content-Length", "10")
            self.end_headers(); self.wfile.write(b"image/png\n"); return
        self.send_response(403); self.send_header("Content-Length", "0"); self.end_headers()
class S(socketserver.UnixStreamServer): pass
S(sock, H).serve_forever()
EOF
  STUB_PID=$!
  Xvfb "$DISPLAY_NUM" -screen 0 64x64x24 -nolisten tcp 2>/dev/null &
  XVFB_PID=$!
  for _ in $(seq 1 50); do [[ -S "/tmp/.X11-unix/X${DISPLAY_NUM#:}" ]] && break; sleep 0.1; done
}

teardown() {
  # setup() can `skip` BEFORE creating anything (uv/xclip/Xvfb missing —
  # the bare CI runner). teardown still runs then, and an unguarded
  # `rm -rf "$TMPDIR"` deletes whatever TMPDIR the environment handed us —
  # on CI that held bats's own run dir and killed the whole suite
  # (2026-08-28, run 33156070786). Only ever remove the dir WE created.
  [[ -n "${CLIPX_TMPDIR:-}" ]] || return 0
  [[ -n "${BRIDGE_PID:-}" ]] && kill "$BRIDGE_PID" 2>/dev/null || true
  if [[ -f "$HOME/.dvw/x11-bridge.pid" ]]; then
    kill "$(cat "$HOME/.dvw/x11-bridge.pid")" 2>/dev/null || true
  fi
  [[ -n "${STUB_PID:-}" ]] && kill "$STUB_PID" 2>/dev/null || true
  [[ -n "${XVFB_PID:-}" ]] && kill "$XVFB_PID" 2>/dev/null || true
  rm -rf "$CLIPX_TMPDIR"
}

_start_bridge() {
  DISPLAY="$DISPLAY_NUM" "$BLUEPRINT_ROOT/bin/clip-x11-bridge" --run &
  BRIDGE_PID=$!
  # Selection ownership is the readiness signal.
  for _ in $(seq 1 100); do
    owner=$(DISPLAY="$DISPLAY_NUM" /usr/bin/xclip -selection clipboard -t TARGETS -o 2>/dev/null || true)
    [[ "$owner" == *image/png* ]] && return 0
    sleep 0.1
  done
  echo "bridge never owned the selection" >&2
  return 1
}

@test "x11-bridge: TARGETS advertises image/png" {
  _start_bridge
  run -0 env DISPLAY="$DISPLAY_NUM" /usr/bin/xclip -selection clipboard -t TARGETS -o
  [[ "$output" == *image/png* ]]
}

@test "x11-bridge: image/png request serves the bridge bytes exactly" {
  _start_bridge
  DISPLAY="$DISPLAY_NUM" /usr/bin/xclip -selection clipboard -t image/png -o > "$TMPDIR/got.png"
  cmp "$TMPDIR/got.png" "$TMPDIR/fixture.png"
}

@test "x11-bridge: each paste fetches fresh bytes (no caching)" {
  _start_bridge
  DISPLAY="$DISPLAY_NUM" /usr/bin/xclip -selection clipboard -t image/png -o > /dev/null
  printf '\x89PNG\r\n\x1a\nCHANGED' > "$TMPDIR/fixture.png"
  DISPLAY="$DISPLAY_NUM" /usr/bin/xclip -selection clipboard -t image/png -o > "$TMPDIR/got2.png"
  cmp "$TMPDIR/got2.png" "$TMPDIR/fixture.png"
}

@test "x11-bridge: dead bridge socket refuses the selection request gracefully" {
  _start_bridge
  kill "$STUB_PID"; wait "$STUB_PID" 2>/dev/null || true
  rm -f "$DVW_CLIP_SOCK"
  run env DISPLAY="$DISPLAY_NUM" /usr/bin/xclip -selection clipboard -t image/png -o
  [ "$status" -ne 0 ]
}

@test "x11-bridge: --ensure is pidfile-idempotent and --stop cleans up" {
  export DISPLAY="$DISPLAY_NUM"
  # This test exercises the daemon start deliberately — lift the suite-wide
  # no-daemons guard for it (cleanup in teardown).
  unset AICODINGSETUP_SKIP_NETWORK
  run -0 "$BLUEPRINT_ROOT/bin/clip-x11-bridge" --ensure
  pid1=$(cat "$HOME/.dvw/x11-bridge.pid")
  run -0 "$BLUEPRINT_ROOT/bin/clip-x11-bridge" --ensure
  [[ "$(cat "$HOME/.dvw/x11-bridge.pid")" == "$pid1" ]]
  run -0 "$BLUEPRINT_ROOT/bin/clip-x11-bridge" --stop
  if kill -0 "$pid1" 2>/dev/null; then false; fi
  [[ ! -f "$HOME/.dvw/x11-bridge.pid" ]]
}

@test "x11-bridge: --ensure no-ops under AICODINGSETUP_SKIP_NETWORK" {
  export DISPLAY="$DISPLAY_NUM"
  AICODINGSETUP_SKIP_NETWORK=1 run -0 "$BLUEPRINT_ROOT/bin/clip-x11-bridge" --ensure
  [[ ! -f "$HOME/.dvw/x11-bridge.pid" ]]
}
