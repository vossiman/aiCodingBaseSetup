#!/usr/bin/env bats
# bin/dokploy-api and bin/kuma-admin: the Dokploy panel and Uptime Kuma
# clients. Both exist so an agent can change monitors and app envs without
# the credential ever appearing in a command it writes or in output that
# lands in a transcript.
#
# Nothing here touches a real panel or a real Kuma. dokploy-api runs against
# a throwaway HTTP server with a fake token; kuma-admin's socket layer needs
# a live server, so its tests cover what protects the credential and what
# can be checked without one (destination pinning, test-mode store refusal,
# redaction). Each helper's --selftest carries the same checks so they can
# be rerun on any host.

bats_require_minimum_version 1.5.0

FAKE_TOKEN="FAKE-DOKPLOY-TOKEN-5b1c8e-do-not-use"
APP_SECRET="APP-DB-PASSWORD-9f2a-do-not-use"
FAKE_PW="FAKE-KUMA-PW-do-not-use"

setup() {
  TMPDIR=$(mktemp -d)
  export TMPDIR
  export HOME="$TMPDIR"
  DA="$BLUEPRINT_ROOT/bin/dokploy-api"
  KA="$BLUEPRINT_ROOT/bin/kuma-admin"
  mkdir -p "$HOME/.aicodingsetup"
  {
    echo "DOKPLOY_API_TOKEN=$FAKE_TOKEN"
    echo "KUMA_ADMIN_USER=fakeuser"
    echo "KUMA_ADMIN_PASSWORD=$FAKE_PW"
  } > "$HOME/.aicodingsetup/.secrets.env"
  export DOKPLOY_TEST_TOKEN="$FAKE_TOKEN"
}

teardown() {
  [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$TMPDIR"
}

# A panel-shaped server: echoes x-api-key and an env block with a secret in
# its body, 302s on /redirect, and records every request.
_start_server() {
  python3 - "$TMPDIR" "$APP_SECRET" <<'EOF' &
import http.server, json, os, sys
tmp, app_secret = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _handle(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n).decode() if n else ""
        with open(os.path.join(tmp, "requests"), "a") as f:
            f.write(f"{self.command} {self.path} {raw}\n")
        if self.path.startswith("/redirect"):
            self.send_response(302)
            self.send_header("Location", "http://127.0.0.1:1/stolen")
            self.end_headers()
            return
        body = json.dumps({
            "echo": self.headers.get("x-api-key"),
            "env": f"DB_PASSWORD={app_secret}\nPLAIN=1",
            "destinations": [{"accessKey": app_secret, "name": "keep"}],
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    do_GET = do_POST = _handle
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
  export DOKPLOY_URL="http://127.0.0.1:$(cat "$TMPDIR/port")"
}

@test "dokploy-api: token and response secrets never reach the output" {
  _start_server
  run "$DA" get compose.one --input '{"composeId":"x"}'
  [ "$status" -eq 0 ]
  [[ "$output" != *"$FAKE_TOKEN"* ]]
  [[ "$output" != *"$APP_SECRET"* ]]
  [[ "$output" == *'DB_PASSWORD=<redacted>'* ]]
  [[ "$output" == *'PLAIN=<redacted>'* ]]
  [[ "$output" == *'"accessKey": "<redacted>"'* ]]
  [[ "$output" == *'"name": "keep"'* ]]
}

@test "dokploy-api: a GET sends its input as query parameters, a POST as JSON" {
  _start_server
  "$DA" get project.one --input '{"projectId":"p1"}' >/dev/null
  "$DA" post compose.deploy --input '{"composeId":"c1"}' >/dev/null
  grep -q '^GET /api/project.one?projectId=p1 $' "$TMPDIR/requests"
  grep -q '^POST /api/compose.deploy {"composeId": "c1"}$' "$TMPDIR/requests"
}

@test "dokploy-api: set-env reads the value from stdin and prints only names" {
  _start_server
  run bash -c "echo 'https://kuma.example/api/push/PIPED-URL-TOKEN' | '$DA' set-env compose c1 KUMA_PUSH_X"
  [ "$status" -eq 0 ]
  [[ "$output" != *"PIPED-URL-TOKEN"* ]]
  [[ "$output" == *"added KUMA_PUSH_X"* ]]
  [[ "$output" == *"DB_PASSWORD, PLAIN, KUMA_PUSH_X"* ]]
  grep -q 'POST /api/compose.update .*"env": "DB_PASSWORD=.*PLAIN=1\\nKUMA_PUSH_X=https://kuma.example/api/push/PIPED-URL-TOKEN"' "$TMPDIR/requests"
}

@test "dokploy-api: set-env refuses an empty or multi-line value" {
  _start_server
  run bash -c "printf '' | '$DA' set-env compose c1 X"
  [ "$status" -ne 0 ]
  run bash -c "printf 'a\nb\n' | '$DA' set-env compose c1 X"
  [ "$status" -ne 0 ]
  if grep -q 'compose.update' "$TMPDIR/requests" 2>/dev/null; then false; fi
}

@test "dokploy-api: a redirect is refused and the header is not re-sent" {
  _start_server
  export DOKPLOY_URL="$DOKPLOY_URL/redirect"
  run "$DA" get project.all
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to follow"* ]]
  [ "$(grep -c . "$TMPDIR/requests")" -eq 1 ]
}

@test "dokploy-api: a non-loopback override is refused before any request" {
  export DOKPLOY_URL="https://panel.example.invalid"
  run "$DA" get project.all
  [ "$status" -ne 0 ]
  [[ "$output" == *"loopback"* ]]
  [[ "$output" != *"$FAKE_TOKEN"* ]]
}

@test "dokploy-api: --selftest passes" {
  unset DOKPLOY_TEST_TOKEN
  run "$DA" --selftest
  [ "$status" -eq 0 ]
  [[ "$output" == *"selftest: ok"* ]]
}

@test "kuma-admin: a non-loopback override is refused and the password stays out of the output" {
  command -v uv >/dev/null || skip "uv not installed"
  export KUMA_URL="https://kuma.example.invalid"
  run "$KA" list
  [ "$status" -ne 0 ]
  [[ "$output" == *"loopback"* ]]
  [[ "$output" != *"$FAKE_PW"* ]]
}

@test "kuma-admin: test mode does not read the store" {
  command -v uv >/dev/null || skip "uv not installed"
  export KUMA_URL="http://127.0.0.1:1"
  run "$KA" list
  [ "$status" -ne 0 ]
  [[ "$output" == *"KUMA_TEST_USER"* ]]
  [[ "$output" != *"$FAKE_PW"* ]]
}

@test "kuma-admin: --selftest passes" {
  command -v uv >/dev/null || skip "uv not installed"
  run "$KA" --selftest
  [ "$status" -eq 0 ]
  [[ "$output" == *"selftest: ok"* ]]
}
