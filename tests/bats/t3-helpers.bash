# Shared harness for the t3 tests. No network: npm, findmnt and t3 are fakes.
# The fake t3 `serve` runs a small Python server that binds a real port,
# writes server-runtime.json like upstream (serverRuntimeState.ts) and starts
# a fake cloudflared plus any children named in T3_TEST_CHILDREN.

t3_test_setup() {
  : "${BLUEPRINT_ROOT:?run via tests/bats/run.sh}"
  TMP=$(mktemp -d)
  export HOME="$TMP/home" PYTHONDONTWRITEBYTECODE=1
  mkdir -p "$HOME" "$TMP/stubs" "$TMP/bin" "$TMP/work"
  export DEVPOD_WORKSPACE_ID=demo
  export T3_ENVS_ROOT="$HOME/.t3-envs" T3_RUNTIME_ROOT="$HOME/.local/share/t3-runtime"
  export T3_MIGRATE_DIR="$TMP/aicodingsetup/t3-migrate" T3_MIGRATE_PARENT="$TMP/aicodingsetup"
  export T3_STUB_LOG="$TMP/calls.log" T3_TEST_BIN="$TMP/bin" T3_DEFAULT_SERVE_DIR="$TMP/work"
  export T3_QUIET_SECONDS=3600 T3_IDLE_WINDOW=2 T3_READY_TIMEOUT=15 T3_READY_SETTLE=1
  export T3_STOP_GRACE=2 T3_CONTROL_WAIT=3 T3_BOOT_RETRY_INTERVAL=1 T3_BOOT_RETRY_MAX=10
  export T3_TEST_LATEST=0.0.50
  mkdir -p "$T3_ENVS_ROOT" "$T3_MIGRATE_PARENT"
  t3_bin_as cloudflared sleep

  cat > "$TMP/stubs/findmnt" <<'STUB'
#!/usr/bin/env bash
case " $* " in *" TARGET,FSTYPE "*) both=1 ;; *) both=0 ;; esac
last=""; for a; do last=$a; done
case "$last" in
  "$T3_ENVS_ROOT"|"$T3_ENVS_ROOT"/*)
    t=$T3_ENVS_ROOT fs=${T3_TEST_FSTYPE:-ext4}
    [ "${T3_TEST_UNMOUNTED:-0}" = 1 ] && { t=/; fs=overlay; } ;;
  "$T3_MIGRATE_PARENT"|"$T3_MIGRATE_PARENT"/*)
    t=$T3_MIGRATE_PARENT fs=ext4
    [ "${T3_TEST_MIGRATE_UNMOUNTED:-0}" = 1 ] && { t=/; fs=overlay; } ;;
  *) t=/ fs=overlay ;;
esac
if [ "$both" = 1 ]; then echo "$t $fs"; else echo "$t"; fi
STUB

  cat > "$TMP/fake-t3" <<'FAKE'
#!/usr/bin/env bash
printf 't3@VERSION@ %s\n' "$*" >> "$T3_STUB_LOG"
u="${T3CODE_HOME:-$HOME/.t3}/userdata"
case "$1" in
  --version) echo "t3 v@VERSION@" ;;
  serve)
    [ "${T3_TEST_SERVE_FAIL:-}" = "@VERSION@" ] && exit 3
    mkdir -p "$u"
    # argv[0] stays this script's path and "serve" stays in the command line,
    # as for the real binary, so /proc-based detection sees a t3 server.
    exec -a "$0" python3 -B "$T3_FAKE_SERVER" serve "$u" "@VERSION@" ;;
  connect)
    case "$2" in
      login|link|publish)
        mkdir -p "$u/secrets"
        [ -s "$u/environment-id" ] || echo env-test-1 > "$u/environment-id"
        : > "$u/secrets/cloud-cli-oauth-token.bin" ;;
      status)
        echo "T3 Connect"
        if [ -n "${T3_TEST_CONNECT_RED:-}" ]; then echo "  Environment link: pending"; exit 0; fi
        printf '%s\n' "  Exposure: enabled" "  Authorization: stored credential" \
          "  Environment link: provisioned" "  Publish agent activity: enabled" ;;
      *) exit 97 ;;
    esac ;;
  *) exit 97 ;;
esac
FAKE

  cat > "$TMP/fake-server.py" <<'PY'
import datetime, json, os, signal, socket, subprocess, sys, time
u, ver = sys.argv[2], sys.argv[3]
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(8)
bindir = os.environ["T3_TEST_BIN"]
kids = []
if os.environ.get("T3_TEST_NO_TUNNEL") != "1":
    kids.append(subprocess.Popen([f"{bindir}/cloudflared", "3600"]))
for spec in filter(None, os.environ.get("T3_TEST_CHILDREN", "").split("|")):
    name, _, cmd = spec.partition("=")
    argv = [f"{bindir}/{name}", "-c", cmd] if cmd else [f"{bindir}/{name}", "3600"]
    kids.append(subprocess.Popen(argv))
if os.environ.get("T3_TEST_PTY_SHELL") == "1":
    import pty
    pid, fd = pty.fork()
    if pid == 0:
        os.execv(f"{bindir}/bash", ["bash", "--norc", "--noprofile"])
if os.environ.get("T3_TEST_CHANGE_ENVID") == ver:
    open(f"{u}/environment-id", "w").write("env-changed\n")
now = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
tmp = f"{u}/.server-runtime.tmp"
with open(tmp, "w") as f:
    json.dump({"version": 1, "pid": os.getpid(), "port": s.getsockname()[1],
               "origin": "http://127.0.0.1", "startedAt": now}, f)
os.replace(tmp, f"{u}/server-runtime.json")
import threading
def serve_accepts():
    while True:
        try:
            c, _ = s.accept(); c.close()
        except OSError:
            return
threading.Thread(target=serve_accepts, daemon=True).start()
def stop(*_):
    for k in kids:
        k.terminate()
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
while True:
    time.sleep(3600)
PY

  cat > "$TMP/stubs/npm" <<'STUB'
#!/usr/bin/env bash
printf 'npm %s\n' "$*" >> "$T3_STUB_LOG"
case "$1" in
  view) [ "${T3_TEST_NPM_VIEW_FAIL:-0}" = 1 ] && exit 1; echo "$T3_TEST_LATEST"; exit 0 ;;
  install) ;;
  *) exit 90 ;;
esac
prefix=""; spec=""
while [ $# -gt 0 ]; do
  case "$1" in --prefix) prefix=$2; shift 2 ;; t3@*) spec=$1; shift ;; *) shift ;; esac
done
[ "${T3_TEST_NPM_FAIL:-0}" = 1 ] && exit 1
v=${T3_TEST_NPM_REPORTS:-${spec#t3@}}
case "$(uname -m)" in aarch64|arm64) a=arm64 ;; *) a=x64 ;; esac
d="$prefix/node_modules/@t3code/t3-linux-$a"
mkdir -p "$prefix/node_modules/.bin" "$d"
sed "s/@VERSION@/$v/g" "$T3_FAKE_TEMPLATE" > "$d/t3"
cp "$d/t3" "$prefix/node_modules/.bin/t3"
chmod +x "$d/t3" "$prefix/node_modules/.bin/t3"
STUB

  export T3_FAKE_TEMPLATE="$TMP/fake-t3" T3_FAKE_SERVER="$TMP/fake-server.py"
  chmod +x "$TMP/stubs/"* "$TMP/fake-t3"
  export PATH="$TMP/stubs:$PATH"
  B="$BLUEPRINT_ROOT/bin"
}

t3_test_teardown() {
  local f sid pid
  for f in "$T3_ENVS_ROOT"/*/aicoding/owner.json; do
    [ -f "$f" ] || continue
    sid=$(jq -r '.sid // empty' "$f" 2>/dev/null)
    pid=$(jq -r '.pid // empty' "$f" 2>/dev/null)
    # command -p: some tests put a recording pkill stub first on PATH
    [[ "$sid" =~ ^[0-9]+$ ]] && command -p pkill -KILL -s "$sid" 2>/dev/null
    [[ "$pid" =~ ^[0-9]+$ ]] && kill -KILL "$pid" 2>/dev/null
  done
  command -p pkill -KILL -f "$TMP/" 2>/dev/null || true
  rm -rf "$TMP"
}

t3_lib() { bash -c '. "$BLUEPRINT_ROOT/lib/t3.sh"; "$@"' t3lib "$@"; }

# A copied `sleep` breaks where coreutils is a multi-call binary that
# dispatches on argv[0] (uutils): it exits at once under another name. A
# python sleeper keeps the process name (comm) without forking a child.
t3_bin_as() {
  if [ "$2" = sleep ]; then
    # Absolute interpreter path: via /usr/bin/env the process renames itself
    # to python3, and scope code identifies processes by comm.
    printf '#!%s\nimport sys, time\ntime.sleep(float(sys.argv[1]) if len(sys.argv) > 1 else 3600)\n' \
      "$(command -v python3)" > "$TMP/bin/$1"
  else
    cp "$(command -v "$2")" "$TMP/bin/$1"
  fi
  chmod +x "$TMP/bin/$1"
}

t3_db() { printf '%s\n' "$T3_ENVS_ROOT/$DEVPOD_WORKSPACE_ID/userdata/state.sqlite"; }

t3_make_db() {
  mkdir -p "$(dirname "$(t3_db)")"
  python3 -B -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.executescript(open(sys.argv[2]).read()); c.commit()' \
    "$(t3_db)" "$BLUEPRINT_ROOT/tests/fixtures/t3/schema.sql"
}

t3_sql() {
  python3 -B -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.executescript(sys.argv[2]); c.commit()' \
    "$(t3_db)" "$1"
}

t3_iso() { date -u -d "${1:-now}" +%Y-%m-%dT%H:%M:%S.000Z; }

t3_ready_workspace() { "$B/t3-setup" >/dev/null 2>&1; }


t3_fake_setup() {
  local v=${1:-0.0.42} h="$T3_ENVS_ROOT/$DEVPOD_WORKSPACE_ID"
  mkdir -p "$h/aicoding" "$h/userdata/secrets"
  echo env-test-1 > "$h/userdata/environment-id"
  : > "$h/userdata/secrets/cloud-cli-oauth-token.bin"
  printf '{"mode":"latest","version":"%s"}\n' "$v" > "$h/aicoding/version.json"
  echo on > "$h/aicoding/auto"
  echo env-test-1 > "$h/aicoding/setup-done"
  t3_lib t3_install "$v" >/dev/null 2>&1
}

t3_owner() { jq -r ".$1" "$T3_ENVS_ROOT/$DEVPOD_WORKSPACE_ID/aicoding/owner.json"; }
