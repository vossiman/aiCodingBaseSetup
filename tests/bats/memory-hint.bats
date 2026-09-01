#!/usr/bin/env bats
# memory-hint must be silent-and-zero on every failure path. The router is
# stubbed with a one-shot python http server on a random port.
#
# MEMORY_ROUTER_URL is a loopback-only test hook (see router_base() in the
# script): whenever it is set, the protected store is not read at all and
# MEMORY_ROUTER_TEST_TOKEN must supply the credential instead. setup()
# exports a fake test token so tests that stub the router over MEMORY_ROUTER_URL
# keep working; tests that exercise the real store path unset MEMORY_ROUTER_URL.

bats_require_minimum_version 1.5.0

setup() {
  : "${BLUEPRINT_ROOT:?unset — run via tests/bats/run.sh}"
  CLI="$BLUEPRINT_ROOT/configs/memory/memory-hint"
  MH="$CLI"
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  unset MEMORY_ROUTER_TOKEN MEMORY_ROUTER_URL
  mkdir -p "$HOME/.aicodingsetup"
  printf 'MEMORY_ROUTER_TOKEN=test-token\n' > "$HOME/.aicodingsetup/.secrets.env"
  export MEMORY_ROUTER_TEST_TOKEN="test-token"
}

teardown() { rm -rf "$TMPDIR"; }

@test "short prompt: no output, exit 0, no network" {
  export MEMORY_ROUTER_URL="http://127.0.0.1:1"   # would fail if contacted
  run bash -c "printf 'fix bug' | '$CLI' --client hook:test"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "slash command prompt: no output, exit 0" {
  export MEMORY_ROUTER_URL="http://127.0.0.1:1"
  run bash -c "printf '/housekeep the docs folder now' | '$CLI'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "missing token: no output, exit 0" {
  rm "$HOME/.aicodingsetup/.secrets.env"
  run bash -c "printf 'which ports are in use on vossisrv' | '$CLI'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "router down: no output, exit 0" {
  export MEMORY_ROUTER_URL="http://127.0.0.1:1"
  run bash -c "printf 'which ports are in use on vossisrv' | '$CLI'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "results are rendered as a memory-hints block" {
  port=$(python3 - <<'PY'
import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()
PY
)
  python3 - "$port" <<'PY' &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        assert self.headers["Authorization"] == "Bearer test-token"
        body = json.dumps({"query_id": "qid-1", "source": "wiki-grep",
            "results": [{"citation": "ports.md § vossisrv", "text": "8091 router"}]})
        self.send_response(200); self.end_headers()
        self.wfile.write(body.encode())
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).handle_request()
PY
  server=$!
  export MEMORY_ROUTER_URL="http://127.0.0.1:$port"
  run bash -c "printf 'which ports are in use on vossisrv' | '$CLI' --client hook:test"
  wait "$server"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<memory-hints"* ]]
  [[ "$output" == *"ports.md § vossisrv"* ]]
  [[ "$output" == *"qid-1"* ]]
}

@test "default MEMORY_ROUTER_URL points at the vossisrv router" {
  grep -q 'DEFAULT_ROUTER = "http://10.0.0.249:8091"' "$CLI"
}

@test "empty results: no output, exit 0" {
  port=$(python3 - <<'PY'
import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()
PY
)
  python3 - "$port" <<'PY' &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        self.send_response(200); self.end_headers()
        self.wfile.write(json.dumps({"query_id": "q", "results": [], "source": "wiki-grep"}).encode())
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).handle_request()
PY
  server=$!
  export MEMORY_ROUTER_URL="http://127.0.0.1:$port"
  run bash -c "printf 'which ports are in use on vossisrv' | '$CLI'"
  wait "$server"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "non-conforming router JSON (array instead of object): no output, exit 0" {
  port=$(python3 - <<'PY'
import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()
PY
)
  python3 - "$port" <<'PY' &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        self.send_response(200); self.end_headers()
        self.wfile.write(json.dumps([1, 2, 3]).encode())
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).handle_request()
PY
  server=$!
  export MEMORY_ROUTER_URL="http://127.0.0.1:$port"
  run bash -c "printf 'which ports are in use on vossisrv' | '$CLI'"
  wait "$server"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "multiple MEMORY_ROUTER_TOKEN lines: uses last (corrected) value" {
  # Store parsing only runs when MEMORY_ROUTER_URL is unset (the production
  # path); with an override present the store is not consulted at all, so
  # this exercises read_token() directly rather than through a stub server.
  printf 'MEMORY_ROUTER_TOKEN=stale-token\nMEMORY_ROUTER_TOKEN=correct-token\n' > "$HOME/.aicodingsetup/.secrets.env"
  unset MEMORY_ROUTER_URL MEMORY_ROUTER_TEST_TOKEN
  run python3 -c "
import runpy
mod = runpy.run_path('$CLI')
print(mod['read_token']())
"
  [ "$status" -eq 0 ]
  [ "$output" = "correct-token" ]
}

@test "malformed invocation (unknown flag): no output, exit 0" {
  export MEMORY_ROUTER_URL="http://127.0.0.1:1"
  run bash -c "printf 'which ports are in use on vossisrv' | '$CLI' --bogus"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "malformed invocation (non-integer --k): no output, exit 0" {
  export MEMORY_ROUTER_URL="http://127.0.0.1:1"
  run bash -c "printf 'which ports are in use on vossisrv' | '$CLI' --k notanumber"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "an arbitrary http destination is refused and stays silent" {
  export MEMORY_ROUTER_URL="http://evil.example.com"
  run bash -c 'printf "what did we decide about backups" | "$1" --client test' _ "$MH"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an arbitrary https destination is refused too" {
  export MEMORY_ROUTER_URL="https://router.example.invalid"
  run bash -c 'printf "what did we decide about backups" | "$1" --client test' _ "$MH"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an override refuses to read the protected store" {
  # A closed port would prove nothing here: a regressed read_token() that
  # fell back to the store (seeded by setup() with MEMORY_ROUTER_TOKEN=
  # test-token) would also throw on connect and get swallowed silently,
  # passing this test for the wrong reason. Use a real loopback listener
  # that records the Authorization header it receives instead, the same
  # pattern bin/kanban-post's --selftest uses to prove a credential never
  # travels somewhere it shouldn't.
  seen="$TMPDIR/seen-auth"
  port=$(python3 - <<'PY'
import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()
PY
)
  python3 - "$port" "$seen" <<'PY' &
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
port, seen_path = int(sys.argv[1]), sys.argv[2]
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        with open(seen_path, "a") as f:
            f.write((self.headers.get("Authorization") or "-") + "\n")
        self.send_response(200); self.end_headers()
        self.wfile.write(b"{}")
    def log_message(self, *a): pass
srv = HTTPServer(("127.0.0.1", port), H)
srv.timeout = 3
srv.handle_request()  # returns after one request, or after the timeout
PY
  server=$!
  export MEMORY_ROUTER_URL="http://127.0.0.1:$port"
  unset MEMORY_ROUTER_TEST_TOKEN
  run bash -c 'printf "what did we decide about backups" | "$1" --client test' _ "$MH"
  wait "$server" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # The listener must never have been contacted at all: with no injected
  # override token, read_token() returns "" and main() returns before ever
  # building a request. A regression that fell back to the store would send
  # "Bearer test-token" here instead, which this catches either way.
  [ ! -s "$seen" ]
}

@test "a redirect is refused: the token never reaches the second host, silent exit 0" {
  # Both sibling brokers (bin/kanban-post, configs/cloudflare/cloudflare-render)
  # refuse 3xx because following one re-sends Authorization to whatever host
  # the response names, and this router's default is PLAINTEXT http. Unlike
  # them, memory-hint must degrade SILENTLY: it runs on the prompt path.
  seen="$TMPDIR/seen-auth"
  first=$(python3 - <<'PY'
import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()
PY
)
  second=$(python3 - <<'PY'
import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()
PY
)
  # The redirect target: records any Authorization header it is handed.
  python3 - "$second" "$seen" <<'PY' &
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
port, seen_path = int(sys.argv[1]), sys.argv[2]
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        with open(seen_path, "a") as f:
            f.write((self.headers.get("Authorization") or "-") + "\n")
        self.send_response(200); self.end_headers(); self.wfile.write(b"{}")
    do_GET = do_POST
    def log_message(self, *a): pass
srv = HTTPServer(("127.0.0.1", port), H); srv.timeout = 3; srv.handle_request()
PY
  sink=$!
  python3 - "$first" "$second" <<'PY' &
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
first, second = int(sys.argv[1]), int(sys.argv[2])
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        self.send_response(302)
        self.send_header("Location", f"http://127.0.0.1:{second}/hint")
        self.end_headers()
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", first), H).handle_request()
PY
  redirector=$!
  export MEMORY_ROUTER_URL="http://127.0.0.1:$first"
  run bash -c "printf 'which ports are in use on vossisrv' | '$CLI' --client hook:test"
  wait "$redirector" 2>/dev/null || true
  wait "$sink" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # The redirect target must never have seen the bearer token.
  [ ! -s "$seen" ]
}

@test "memory-hint builds a redirect-refusing opener, like its sibling brokers" {
  grep -q 'build_opener(NoRedirects)' "$CLI"
  run grep -n 'urllib.request.urlopen' "$CLI"
  [ "$status" -eq 1 ]
}

@test "a router that echoes the bearer token back has it scrubbed from stdout" {
  # memory-hint's stdout is injected straight into agent context, so an
  # error page or proxy that quotes request headers would otherwise put a
  # live credential in the transcript.
  port=$(python3 - <<'PY'
import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()
PY
)
  python3 - "$port" <<'PY' &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        echoed = self.headers.get("Authorization") or ""
        body = json.dumps({"query_id": "qid-echo", "results": [
            {"citation": "router.md", "text": "your request said " + echoed}]})
        self.send_response(200); self.end_headers(); self.wfile.write(body.encode())
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).handle_request()
PY
  server=$!
  export MEMORY_ROUTER_URL="http://127.0.0.1:$port"
  run bash -c "printf 'which ports are in use on vossisrv' | '$CLI' --client hook:test"
  wait "$server"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<memory-hints"* ]]
  [[ "$output" != *"test-token"* ]]
  [[ "$output" == *"<redacted>"* ]]
}
