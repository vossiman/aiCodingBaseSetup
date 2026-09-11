#!/usr/bin/env bats

setup() {
  : "${BLUEPRINT_ROOT:?run via tests/bats/run.sh}"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.local/bin"
  export PATH="$HOME/.local/bin:$PATH" _NVS_STRIPPED=1
  printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/aicoding-sync"
  chmod +x "$HOME/.local/bin/aicoding-sync"
}

@test "boot returns with pipes closed while one detached sweep continues to completion" {
  # Real process boundaries: a slow sweep must not hold the startup pipes open,
  # receive a session hangup, or run twice when another boot happens.
  cat > "$HOME/.local/bin/redact-sessions" <<'PY'
#!/usr/bin/env python3
import os, pathlib, time
home = pathlib.Path.home()
with (home / 'started').open('a') as f:
    f.write(f'{os.getpid()} {os.getsid(0)}\n')
for _ in range(500):
    if (home / 'release').exists():
        (home / 'finished').touch()
        break
    time.sleep(0.02)
PY
  chmod +x "$HOME/.local/bin/redact-sessions"
  run env AICODINGSETUP_SKIP_NETWORK= python3 - <<'PY'
import os, pathlib, signal, subprocess, time
home = pathlib.Path.home()
script = pathlib.Path(os.environ['BLUEPRINT_ROOT']) / 'on-start.sh'
def await_file(name):
    deadline = time.monotonic() + 3
    while not (home / name).exists():
        assert time.monotonic() < deadline, f'{name} never appeared'
        time.sleep(0.02)
def boot():
    return subprocess.run(['bash', str(script)], cwd=home, capture_output=True,
                          timeout=2, check=True)
try:
    boot()
    await_file('started')
    pid, sid = map(int, (home / 'started').read_text().split())
    assert sid != os.getsid(0), 'sweep still shares the startup session'
    os.kill(pid, signal.SIGHUP)
    assert not (home / 'finished').exists(), 'fixture did not stay running'
    boot()
    time.sleep(0.2)
    assert len((home / 'started').read_text().splitlines()) == 1, 'duplicate sweep'
    (home / 'release').touch()
    await_file('finished')
finally:
    (home / 'release').touch()
    if (home / 'started').exists():
        for line in (home / 'started').read_text().splitlines():
            try:
                os.kill(int(line.split()[0]), signal.SIGTERM)
            except ProcessLookupError:
                pass
PY
  [ "$status" -eq 0 ]
}

@test "boot skips the background sweep when provisioning side effects are disabled" {
  printf '#!/bin/sh\ntouch "$HOME/sweep-started"\n' > "$HOME/.local/bin/redact-sessions"
  chmod +x "$HOME/.local/bin/redact-sessions"
  run env AICODINGSETUP_SKIP_NETWORK=1 bash "$BLUEPRINT_ROOT/on-start.sh"
  [ "$status" -eq 0 ]
  sleep 0.2
  [ ! -e "$HOME/sweep-started" ]
}
