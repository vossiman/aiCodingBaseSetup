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
  # A loopback override with no injected credential must not fall back to
  # the store, and must stay silent about it.
  export MEMORY_ROUTER_URL="http://127.0.0.1:9"
  unset MEMORY_ROUTER_TEST_TOKEN
  run bash -c 'printf "what did we decide about backups" | "$1" --client test' _ "$MH"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
