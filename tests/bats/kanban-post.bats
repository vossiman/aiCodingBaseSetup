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

# A checkout whose github.com origin names $1, and cd into it. The repo
# name kanban-post derives is read from this remote, so the tests that care
# about --repo need a real one rather than whatever directory bats sits in.
_fake_checkout() {
  local dir="$TMPDIR/checkout-$1"
  mkdir -p "$dir"
  git init -q "$dir"
  git -C "$dir" remote add origin "${2:-https://github.com/vossiman/$1.git}"
  cd "$dir" || return 1
}

# A board-shaped server: it knows which repos are registered, 400s an
# unknown one the way resolve_repo does, and appends "METHOD PATH BODY" to
# $TMPDIR/requests so a test can assert what was actually sent.
_start_api_server() {
  python3 - "$TMPDIR" "$1" <<'EOF' &
import http.server, json, os, sys
tmp, registered = sys.argv[1], set(filter(None, sys.argv[2].split(",")))
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _reply(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def _handle(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n).decode() if n else ""
        with open(os.path.join(tmp, "requests"), "a") as f:
            f.write(f"{self.command} {self.path} {raw}\n")
        payload = json.loads(raw) if raw else {}
        if self.command == "POST" and self.path == "/api/repos":
            registered.add(payload["name"])
            return self._reply(201, {"name": payload["name"], "archived": False})
        if self.command == "POST" and self.path == "/api/tickets":
            if payload.get("status") == "nonesuch":
                return self._reply(400, {"detail": "Unknown status 'nonesuch'. Valid statuses: backlog, done"})
            if payload["repo"] not in registered:
                return self._reply(400, {"detail": f"Unknown repo '{payload['repo']}'. Valid repos: {', '.join(sorted(registered))}"})
            # The real board derives a key this way and returns it; kanban-post
            # surfaces whatever comes back rather than deriving its own.
            key = "".join(c for c in payload["repo"] if c.isalnum()).upper() + "-1"
            return self._reply(201, {"id": "new-id", "key": key, **payload})
        if self.command == "PATCH" and self.path.startswith("/api/tickets/"):
            return self._reply(200, {"id": self.path.rsplit("/", 1)[1], **payload})
        self._reply(404, {"detail": "not found"})
    do_GET = do_POST = do_PATCH = _handle
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
  export KANBAN_URL="http://127.0.0.1:$(cat "$TMPDIR/port")"
}

@test "a server echoing the credential back does not get it printed" {
  _start_server
  run "$KP" --list-tickets
  [[ "$output" != *"$FAKE_TOKEN"* ]]
  [[ "$output" == *"<redacted>"* ]]
}

@test "the POST path redacts too" {
  _start_server
  _fake_checkout myrepo
  run "$KP" "a title" --repo myrepo
  [[ "$output" != *"$FAKE_TOKEN"* ]]
}

@test "the PATCH path redacts too" {
  _start_server
  run "$KP" --done some-ticket-id
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

# --repo: mandatory, and checked against the checkout
#
# The board tags every ticket with a repo, and that tag is the filter the
# phone view leans on. A default silently made everything devMachine, so
# --repo is required AND must equal the name derived from the checkout's
# github.com origin -- the flag states the intent, the remote proves it.

@test "filing without --repo is refused before any request is made" {
  _start_api_server myrepo
  _fake_checkout myrepo
  run "$KP" "a title"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--repo"* ]]
  [ ! -f "$TMPDIR/requests" ]
}

@test "a --repo that does not match the checkout is refused, and says what would" {
  _start_api_server myrepo,devMachine
  _fake_checkout dataEnv
  run "$KP" "a title" --repo devMachine
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not match this checkout"* ]]
  [[ "$output" == *"dataEnv"* ]]
  [ ! -f "$TMPDIR/requests" ]
}

@test "the match is case-sensitive: dataenv is not dataEnv" {
  _start_api_server dataEnv
  _fake_checkout dataEnv
  run "$KP" "a title" --repo dataenv
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not match this checkout"* ]]
  [ ! -f "$TMPDIR/requests" ]
}

@test "a directory that is not a git repo cannot file at all" {
  _start_api_server myrepo
  mkdir -p "$TMPDIR/plain"
  cd "$TMPDIR/plain"
  run "$KP" "a title" --repo myrepo
  [ "$status" -ne 0 ]
  [[ "$output" == *"github.com"* ]]
  [ ! -f "$TMPDIR/requests" ]
}

@test "a checkout whose origin is not github.com cannot file either" {
  _start_api_server myrepo
  _fake_checkout myrepo "https://gitlab.com/vossiman/myrepo.git"
  run "$KP" "a title" --repo myrepo
  [ "$status" -ne 0 ]
  [[ "$output" == *"github.com"* ]]
  [ ! -f "$TMPDIR/requests" ]
}

@test "an ssh remote derives the same name as an https one" {
  _start_api_server myrepo
  _fake_checkout myrepo "git@github.com:vossiman/myrepo.git"
  run "$KP" "a title" --repo myrepo
  [ "$status" -eq 0 ]
  grep -q "POST /api/tickets" "$TMPDIR/requests"
}

@test "a matching --repo files the ticket" {
  _start_api_server myrepo
  _fake_checkout myrepo
  run "$KP" "a title" --repo myrepo --body "some detail"
  [ "$status" -eq 0 ]
  [[ "$output" == *"201"* ]]
  grep -q '"repo": "myrepo"' "$TMPDIR/requests"
  grep -q '"body": "some detail"' "$TMPDIR/requests"
}

# Registering a repo the board does not know yet
#
# Safe only because --repo is already proven equal to the remote: the name
# that gets created can never be a typo, it is whatever GitHub calls this
# checkout.

@test "an unknown repo is registered from the checkout, then the ticket lands" {
  _start_api_server devMachine
  _fake_checkout dataEnv
  run "$KP" "a finding" --repo dataEnv
  [ "$status" -eq 0 ]
  [[ "$output" == *"registered repo dataEnv"* ]]
  # tried, registered, retried -- in that order
  run cat "$TMPDIR/requests"
  [[ "${lines[0]}" == "POST /api/tickets"* ]]
  [[ "${lines[1]}" == "POST /api/repos"*'"name": "dataEnv"'* ]]
  [[ "${lines[2]}" == "POST /api/tickets"* ]]
}

@test "a 400 that is not about the repo never registers anything" {
  _start_api_server myrepo
  _fake_checkout myrepo
  run "$KP" "a title" --repo myrepo --status nonesuch
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown status"* ]]
  run grep -c "POST /api/repos" "$TMPDIR/requests"
  [ "$output" -eq 0 ]
}

# Updating a ticket
#
# Takes a ticket id, not a repo, so the checkout rule above does not apply.

@test "--done moves a ticket to done" {
  _start_api_server myrepo
  run "$KP" --done abc123
  [ "$status" -eq 0 ]
  grep -q 'PATCH /api/tickets/abc123 .*"status": "done"' "$TMPDIR/requests"
}

@test "--patch sends only the fields given" {
  _start_api_server myrepo
  run "$KP" --patch abc123 --priority high
  [ "$status" -eq 0 ]
  grep -q '"priority": "high"' "$TMPDIR/requests"
  run grep -c '"status"\|"title"\|"body"' "$TMPDIR/requests"
  [ "$output" -eq 0 ]
}

@test "--patch takes a new title as the positional argument" {
  _start_api_server myrepo
  run "$KP" --patch abc123 "a better title" --body "and a new body"
  [ "$status" -eq 0 ]
  grep -q '"title": "a better title"' "$TMPDIR/requests"
  grep -q '"body": "and a new body"' "$TMPDIR/requests"
}

@test "--patch with no fields to change is refused" {
  _start_api_server myrepo
  run "$KP" --patch abc123
  [ "$status" -ne 0 ]
  [ ! -f "$TMPDIR/requests" ]
}

@test "--patch does not accept --repo: moving repos is not its job" {
  _start_api_server myrepo
  _fake_checkout myrepo
  run "$KP" --patch abc123 --repo myrepo
  [ "$status" -ne 0 ]
  [[ "$output" == *"--repo"* ]]
  [ ! -f "$TMPDIR/requests" ]
}

# Issue keys (DEVMACHINE-12)
#
# The board accepts a key anywhere it accepts a uuid, so kanban-post needs no
# parsing of its own — but it must pass the key through untouched, and must
# not swallow the key the board sends back.

@test "an issue key is passed through to the board verbatim" {
  _start_api_server myrepo
  run "$KP" --done DEVMACHINE-12
  [ "$status" -eq 0 ]
  # Not url-encoded, not uppercased, not rewritten into a uuid lookup.
  grep -q "PATCH /api/tickets/DEVMACHINE-12 " "$TMPDIR/requests"
}

@test "a lowercase key is left for the board to normalise" {
  _start_api_server myrepo
  run "$KP" --patch devmachine-12 --status doing
  [ "$status" -eq 0 ]
  grep -q "PATCH /api/tickets/devmachine-12 " "$TMPDIR/requests"
}

@test "the key is printed on its own line, not buried in the body" {
  _start_api_server myrepo
  _fake_checkout myrepo
  run "$KP" "a title" --repo myrepo
  [ "$status" -eq 0 ]
  # The fake board echoes the payload back; a real one adds "key".
  [[ "${lines[1]}" == "MYREPO-1" ]]
}

@test "a board that sends no key still works" {
  # Until the issue-keys release is deployed, responses have no key field.
  _start_api_server myrepo
  run "$KP" --done abc123
  [ "$status" -eq 0 ]
  [[ "$output" != *"None"* ]]
}

@test "--patch and --done together is refused" {
  _start_api_server myrepo
  run "$KP" --patch abc123 --done abc123
  [ "$status" -ne 0 ]
  [ ! -f "$TMPDIR/requests" ]
}
