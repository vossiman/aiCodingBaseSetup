#!/usr/bin/env bats
# memory-hint must be silent-and-zero on every failure path. The router is
# stubbed with a one-shot python http server on a random port.

setup() {
  : "${BLUEPRINT_ROOT:?unset — run via tests/bats/run.sh}"
  CLI="$BLUEPRINT_ROOT/configs/memory/memory-hint"
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  unset MEMORY_ROUTER_TOKEN MEMORY_ROUTER_URL
  mkdir -p "$HOME/.aicodingsetup"
  printf 'MEMORY_ROUTER_TOKEN=test-token\n' > "$HOME/.aicodingsetup/.secrets.env"
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
  grep -q 'MEMORY_ROUTER_URL", "http://10.0.0.249:8091"' "$CLI"
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
  printf 'MEMORY_ROUTER_TOKEN=stale-token\nMEMORY_ROUTER_TOKEN=correct-token\n' > "$HOME/.aicodingsetup/.secrets.env"
  port=$(python3 - <<'PY'
import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()
PY
)
  python3 - "$port" <<'PY' &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        assert self.headers["Authorization"] == "Bearer correct-token", f"Expected Bearer correct-token, got {self.headers['Authorization']}"
        body = json.dumps({"query_id": "qid-2", "source": "wiki-grep",
            "results": [{"citation": "test.md", "text": "test result"}]})
        self.send_response(200); self.end_headers()
        self.wfile.write(body.encode())
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).handle_request()
PY
  server=$!
  export MEMORY_ROUTER_URL="http://127.0.0.1:$port"
  run bash -c "printf 'which ports are in use on vossisrv' | '$CLI'"
  wait "$server"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<memory-hints"* ]]
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
