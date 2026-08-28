#!/usr/bin/env bats
# bin/kanban-post: the homelab backlog's client. It exists so an agent can
# file a ticket without the bearer token ever appearing in a command it
# writes -- the secrets deny hook refuses `$KANBAN_TOKEN` expansion and
# cannot distinguish sending a credential from printing one.
#
# These tests are about the credential, not the board: every one runs
# against a throwaway local HTTP server with a fake token and a fake secrets
# store, so nothing here touches the real board or the real store.
#
# The script ships in a PUBLIC repo, which is why the leak paths are tested
# rather than merely commented: a server echoing the header back, a redirect
# to another origin, and a plaintext destination.

bats_require_minimum_version 1.5.0

FAKE_TOKEN="FAKE-TOKEN-cf4d1a9e-do-not-use"

setup() {
  TMPDIR=$(mktemp -d)
  export TMPDIR
  export HOME="$TMPDIR"
  KP="$BLUEPRINT_ROOT/bin/kanban-post"
  mkdir -p "$HOME/.aicodingsetup"
  printf 'OTHER=x\nKANBAN_TOKEN=%s\n' "$FAKE_TOKEN" > "$HOME/.aicodingsetup/.secrets.env"
}

teardown() {
  [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$TMPDIR"
}

# A server that echoes the Authorization header back in its error body, and
# 302s to another origin on /redirect. Both are things a real proxy or a
# hostile endpoint does; neither may cost us the credential.
_start_server() {
  python3 - "$TMPDIR" <<'EOF' &
import http.server, json, os, sys
tmp = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        with open(os.path.join(tmp, "seen"), "a") as f:
            f.write((self.headers.get("Authorization") or "-") + "\n")
        if self.path.startswith("/redirect"):
            self.send_response(302)
            self.send_header("Location", "http://127.0.0.1:1/stolen")
            self.end_headers()
            return
        body = json.dumps({"detail": self.headers.get("Authorization")}).encode()
        self.send_response(500)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    do_POST = do_GET
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
with open(os.path.join(tmp, "port"), "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
EOF
  SERVER_PID=$!
  for _ in $(seq 1 50); do
    [[ -s "$TMPDIR/port" ]] && break
    sleep 0.1
  done
  PORT=$(cat "$TMPDIR/port")
  export KANBAN_URL="http://127.0.0.1:$PORT"
}

@test "a server echoing the credential back does not get it printed" {
  _start_server
  run "$KP" --list-tickets
  [[ "$output" != *"$FAKE_TOKEN"* ]]
  [[ "$output" == *"<redacted>"* ]]
}

@test "the POST path redacts too" {
  _start_server
  run "$KP" "a title"
  [[ "$output" != *"$FAKE_TOKEN"* ]]
}

@test "a redirect to another origin is refused, not followed" {
  _start_server
  export KANBAN_URL="$KANBAN_URL/redirect"
  run "$KP" --list-tickets
  [[ "$output" == *"refusing to follow"* ]]
  # Exactly one request reached the server: the redirect target never saw
  # an Authorization header, because we never went there.
  [ "$(wc -l < "$TMPDIR/seen")" -eq 1 ]
}

@test "a non-loopback plaintext destination is refused" {
  export KANBAN_URL="http://kanban.example.com"
  run "$KP" --list-tickets
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be https"* ]]
}

@test "an https destination is accepted" {
  export KANBAN_URL="https://kanban.example.invalid"
  run "$KP" --list-tickets
  # Cannot resolve, which is the point: it got past the scheme check and
  # failed on the network rather than being refused outright.
  [[ "$output" == *"cannot reach the board"* ]]
}

@test "a missing token is a clear error, not a traceback" {
  rm "$HOME/.aicodingsetup/.secrets.env"
  run "$KP" --list-tickets
  [ "$status" -ne 0 ]
  [[ "$output" == *"no secrets store"* ]]
  [[ "$output" != *"Traceback"* ]]
}

@test "an empty KANBAN_TOKEN is reported, not sent" {
  printf 'KANBAN_TOKEN=\n' > "$HOME/.aicodingsetup/.secrets.env"
  run "$KP" --list-tickets
  [ "$status" -ne 0 ]
  [[ "$output" == *"not set"* ]]
}

@test "the shipped file carries no credential of its own" {
  run grep -nE '(TOKEN|SECRET|KEY) *= *["'"'"'][A-Za-z0-9_-]{16,}' "$KP"
  [ "$status" -ne 0 ]
}

@test "its own selftest passes" {
  run "$KP" --selftest
  [ "$status" -eq 0 ]
  [[ "$output" == *"selftest: ok"* ]]
}
