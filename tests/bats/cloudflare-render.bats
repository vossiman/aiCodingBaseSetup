#!/usr/bin/env bats
# configs/cloudflare/cloudflare-render: the Cloudflare Browser Rendering
# broker. It exists so the skill can document a COMMAND instead of a
# credential -- an agent must read a skill to use it, so a value in that
# prose lands in model context and transcripts on every routine use.
#
# Every test runs against a loopback server with a fake credential; nothing
# here reads the real secrets store or reaches api.cloudflare.com.

bats_require_minimum_version 1.5.0

FAKE_CF="FAKE-CF-TOKEN-7b31de-do-not-use"

setup() {
  : "${BLUEPRINT_ROOT:?unset — run via tests/bats/run.sh}"
  TMPDIR=$(mktemp -d)
  export TMPDIR
  export HOME="$TMPDIR"
  CR="$BLUEPRINT_ROOT/configs/cloudflare/cloudflare-render"
  mkdir -p "$HOME/.aicodingsetup"
  # A fake store, so the tests that assert the store is NOT read have
  # something they would have found had the refusal failed.
  printf 'CLOUDFLARE_API_TOKEN=%s\nCLOUDFLARE_ACCOUNT_ID=acct-123\n' "$FAKE_CF" \
    > "$HOME/.aicodingsetup/.secrets.env"
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
    def do_POST(self):
        with open(os.path.join(tmp, "seen"), "a") as f:
            f.write((self.headers.get("Authorization") or "-") + "\n")
        if self.path.endswith("/redirect"):
            self.send_response(302)
            self.send_header("Location", "http://127.0.0.1:1/stolen")
            self.end_headers()
            return
        body = json.dumps({"detail": self.headers.get("Authorization")}).encode()
        self.send_response(500)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        # A server echoing the credential back must not cost us the value.
        self.wfile.write(body)
    do_GET = do_POST
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
  export CF_API_BASE="http://127.0.0.1:$(cat "$TMPDIR/port")"
  export CF_TEST_TOKEN="$FAKE_CF"
}

@test "an arbitrary destination is refused" {
  export CF_API_BASE="https://api.cloudflare.com.evil.example"
  run "$CR" https://example.com markdown
  [ "$status" -ne 0 ]
  [[ "$output" == *"loopback"* ]]
  # It must fail on the destination rule, not on DNS.
  [[ "$output" != *"cannot reach"* ]]
}

@test "a plaintext non-loopback destination is refused too" {
  export CF_API_BASE="http://api.cloudflare.com"
  run "$CR" https://example.com markdown
  [ "$status" -ne 0 ]
  [[ "$output" == *"loopback"* ]]
}

@test "the credential never reaches stdout even when echoed back" {
  _start_server
  run "$CR" https://example.com markdown
  [[ "$output" != *"$FAKE_CF"* ]]
  [[ "$output" == *"<redacted>"* ]]
}

@test "a redirect is refused, not followed" {
  _start_server
  run "$CR" https://example.com redirect
  [[ "$output" == *"refusing to follow"* ]]
  [ "$(wc -l < "$TMPDIR/seen")" -eq 1 ]
}

@test "an override refuses to read the protected store" {
  _start_server
  unset CF_TEST_TOKEN
  run "$CR" https://example.com markdown
  [ "$status" -ne 0 ]
  [[ "$output" == *"CF_TEST_TOKEN"* ]]
  [[ "$output" != *"$FAKE_CF"* ]]
}

@test "an unknown format is refused before any request" {
  run "$CR" https://example.com not-a-format
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown format"* ]]
  [ ! -f "$TMPDIR/seen" ]
}

@test "a missing store is a clear error, not a traceback" {
  rm "$HOME/.aicodingsetup/.secrets.env"
  run "$CR" https://example.com markdown
  [ "$status" -ne 0 ]
  [[ "$output" == *"no secrets store"* ]]
  [[ "$output" != *"Traceback"* ]]
}

@test "the shipped file carries no credential of its own" {
  run grep -nE '(TOKEN|SECRET|KEY|ACCOUNT) *= *["'"'"'][A-Za-z0-9_-]{16,}' "$CR"
  [ "$status" -ne 0 ]
}

@test "the skill documents the command and no placeholder" {
  local skill="$BLUEPRINT_ROOT/skills/cloudflare-browser/SKILL.md"
  grep -q 'cloudflare-render' "$skill"
  # This is the defect that made CAF-003 real: a placeholder here is a live
  # value in the deployed copy an agent must read.
  run grep -n 'CLOUDFLARE_API_TOKEN\|CLOUDFLARE_ACCOUNT_ID' "$skill"
  [ "$status" -ne 0 ]
  run grep -n 'Authorization: Bearer' "$skill"
  [ "$status" -ne 0 ]
}
