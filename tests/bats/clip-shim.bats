#!/usr/bin/env bats
# bin/clip-shim: container-side half of the dvw clipboard bridge. Installed
# as ~/.local/bin/xclip and ~/.local/bin/wl-paste, it translates exactly the
# invocations agent CLIs use for image paste into HTTP GETs on the bridge
# socket (/tmp/dvw-clip.sock, reverse-forwarded to the client's dvw-clipd).
# Everything else fails like "no image in clipboard" so agent UX stays sane.
#
# The HTTP tests run against a REAL unix-socket server (python3 stdlib), not
# a curl stub — the shim's curl flags are part of the contract under test.

bats_require_minimum_version 1.5.0

setup() {
  TMPDIR=$(mktemp -d)
  export TMPDIR
  export HOME="$TMPDIR"
  SHIM="$BLUEPRINT_ROOT/bin/clip-shim"
  export DVW_CLIP_SOCK="$TMPDIR/clip.sock"
  BINDIR="$TMPDIR/bin"
  mkdir -p "$BINDIR"
  ln -sf "$SHIM" "$BINDIR/xclip"
  ln -sf "$SHIM" "$BINDIR/wl-paste"
}

teardown() {
  [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$TMPDIR"
}

_start_server() {
  python3 - "$DVW_CLIP_SOCK" "$TMPDIR" <<'EOF' &
import http.server, socketserver, sys, os
sock, tmp = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        with open(os.path.join(tmp, "requests"), "a") as f:
            f.write(self.path + "\n")
        if self.path == "/targets":
            body = b"image/png\n"
        elif self.path.startswith("/clip?type=image/png"):
            body = b"PNGBYTES"
        else:
            self.send_response(403); self.send_header("Content-Length", "0"); self.end_headers(); return
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
class S(socketserver.UnixStreamServer): pass
S(sock, H).serve_forever()
EOF
  SERVER_PID=$!
  for _ in $(seq 1 50); do [[ -S "$DVW_CLIP_SOCK" ]] && return 0; sleep 0.1; done
  return 1
}

@test "xclip TARGETS probe maps to /targets" {
  _start_server
  run -0 "$BINDIR/xclip" -selection clipboard -t TARGETS -o
  [[ "$output" == "image/png" ]]
  grep -qx '/targets' "$TMPDIR/requests"
}

@test "xclip image/png fetch maps to /clip and streams bytes" {
  _start_server
  run -0 "$BINDIR/xclip" -selection clipboard -t image/png -o
  [[ "$output" == "PNGBYTES" ]]
  grep -qx '/clip?type=image/png' "$TMPDIR/requests"
}

@test "wl-paste -l and --list-types map to /targets" {
  _start_server
  run -0 "$BINDIR/wl-paste" -l
  [[ "$output" == "image/png" ]]
  run -0 "$BINDIR/wl-paste" --list-types
  [[ "$output" == "image/png" ]]
}

@test "wl-paste --type image/png maps to /clip" {
  _start_server
  run -0 "$BINDIR/wl-paste" --type image/png
  [[ "$output" == "PNGBYTES" ]]
  run -0 "$BINDIR/wl-paste" -t image/png
  [[ "$output" == "PNGBYTES" ]]
}

@test "dead socket fails fast like an empty clipboard" {
  run -1 "$BINDIR/xclip" -selection clipboard -t image/png -o
  [[ "$stderr" == *"no image"* ]] || [[ "$output" == *"no image"* ]]
}

@test "unrecognized invocation fails rather than pretending" {
  _start_server
  run -1 "$BINDIR/xclip" -selection clipboard -o
  run -1 "$BINDIR/wl-paste" --watch cat
  run -1 "$BINDIR/xclip" -i
}

@test "server 403 (non-image request path) surfaces as failure" {
  _start_server
  run -1 "$BINDIR/xclip" -selection clipboard -t text/plain -o
}
