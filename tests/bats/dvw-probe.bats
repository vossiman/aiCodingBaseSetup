#!/usr/bin/env bats
# bin/dvw-probe: one exec, one JSON document describing the container from
# the inside (tmux, agents, git, cgroup). Everything external is faked: tmux
# and git are stubs on PATH, /proc and /sys/fs/cgroup are fixture trees.

bats_require_minimum_version 1.5.0

setup() {
  : "${BLUEPRINT_ROOT:?unset, run via tests/bats/run.sh}"
  PROBE="$BLUEPRINT_ROOT/bin/dvw-probe"
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  mkdir -p "$TMPDIR/stubs" "$TMPDIR/proc" "$TMPDIR/cgroup" "$TMPDIR/ws" "$TMPDIR/tmux-sockets"
  export PATH="$TMPDIR/stubs:$PATH"
  # Isolate from any tmux server already running for this very shell/session
  # (this devcontainer runs its own harness inside tmux): a fresh, private
  # socket dir means "list-sessions with the tmux stub removed" really means
  # "no server", not an accidental hit on the real one. The directory must
  # already exist, or tmux silently falls back to the default socket path.
  export TMUX_TMPDIR="$TMPDIR/tmux-sockets"
  unset TMUX
  export DVW_PROBE_PROC="$TMPDIR/proc"
  export DVW_PROBE_CGROUP="$TMPDIR/cgroup"
  export DVW_PROBE_WORKSPACE="$TMPDIR/ws"

  cat > "$TMPDIR/stubs/tmux" <<'STUB'
#!/bin/sh
case "$*" in
  *list-sessions*) printf 'work\t1\t1756799990\nother\t0\t1756700000\n' ;;
  *list-windows*)  printf '@7\tclaude\t1\t1756799990\t\tnode\n@8\tshell\t0\t1756790000\t1756795000\tbash\n' ;;
esac
exit "${TMUX_STUB_EXIT:-0}"
STUB
  cat > "$TMPDIR/stubs/git" <<'STUB'
#!/bin/sh
case "$*" in
  *"--abbrev-ref HEAD"*) echo "feat/x" ;;
  *"--short HEAD"*)      echo "abc1234" ;;
  *"status --porcelain"*) printf ' M file\n' ;;
  *"rev-list --left-right --count"*) printf '2\t0\n' ;;
  *) exit 1 ;;
esac
exit 0
STUB
  chmod +x "$TMPDIR/stubs/tmux" "$TMPDIR/stubs/git"

  # cgroup v2 fixture
  echo 1234 > "$TMPDIR/cgroup/memory.current"
  echo 8589934592 > "$TMPDIR/cgroup/memory.max"
  printf 'usage_usec 123456\nuser_usec 100\n' > "$TMPDIR/cgroup/cpu.stat"
  echo 42 > "$TMPDIR/cgroup/pids.current"

  # /proc fixture: pid 4242 is claude, pid 77 is bash (ignored)
  mkdir -p "$TMPDIR/proc/4242" "$TMPDIR/proc/77"
  echo claude > "$TMPDIR/proc/4242/comm"
  printf 'claude\0--dangerously\0' > "$TMPDIR/proc/4242/cmdline"
  printf '4242 (claude) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 500 0 0\n' > "$TMPDIR/proc/4242/stat"
  ln -s "$TMPDIR/ws" "$TMPDIR/proc/4242/cwd"
  echo bash > "$TMPDIR/proc/77/comm"
  printf 'bash\0' > "$TMPDIR/proc/77/cmdline"
  printf '77 (bash) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 100 0 0\n' > "$TMPDIR/proc/77/stat"
  ln -s / "$TMPDIR/proc/77/cwd"
  printf 'btime 1756700000\n' > "$TMPDIR/proc/stat"
}

teardown() { case "${TMPDIR:-}" in */tmp.*) rm -rf "$TMPDIR" ;; esac }

jq_probe() { "$PROBE" | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

@test "emits valid JSON with schema 1 and exit 0" {
  run "$PROBE"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -m json.tool >/dev/null
  [ "$(echo "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["schema"])')" = "1" ]
}

@test "tmux section carries sessions and work windows with waiting_since" {
  [ "$(jq_probe 'd["tmux"]["sessions"][0]["name"]')" = "work" ]
  [ "$(jq_probe 'd["tmux"]["sessions"][0]["attached"]')" = "1" ]
  [ "$(jq_probe 'd["tmux"]["windows"][0]["id"]')" = "@7" ]
  [ "$(jq_probe 'd["tmux"]["windows"][0]["waiting_since"]')" = "None" ]
  [ "$(jq_probe 'd["tmux"]["windows"][1]["waiting_since"]')" = "1756795000" ]
  [ "$(jq_probe 'd["tmux"]["windows"][1]["command"]')" = "bash" ]
}

@test "agents lists claude with pid, cwd and a start epoch, ignores bash" {
  [ "$(jq_probe 'len(d["agents"])')" = "1" ]
  [ "$(jq_probe 'd["agents"][0]["cli"]')" = "claude" ]
  [ "$(jq_probe 'd["agents"][0]["pid"]')" = "4242" ]
  [ "$(jq_probe 'd["agents"][0]["cwd"]')" = "$TMPDIR/ws" ]
  # starttime 500 ticks at 100 Hz = 5 s after btime
  [ "$(jq_probe 'd["agents"][0]["started"]')" = "1756700005" ]
}

@test "git section reports branch, head, dirty, ahead and behind" {
  [ "$(jq_probe 'd["git"]["branch"]')" = "feat/x" ]
  [ "$(jq_probe 'd["git"]["head"]')" = "abc1234" ]
  [ "$(jq_probe 'd["git"]["dirty"]')" = "True" ]
  [ "$(jq_probe 'd["git"]["ahead"]')" = "2" ]
  [ "$(jq_probe 'd["git"]["behind"]')" = "0" ]
}

@test "cgroup section reads memory, cpu and pids" {
  [ "$(jq_probe 'd["cgroup"]["mem_current"]')" = "1234" ]
  [ "$(jq_probe 'd["cgroup"]["mem_max"]')" = "8589934592" ]
  [ "$(jq_probe 'd["cgroup"]["cpu_usec"]')" = "123456" ]
  [ "$(jq_probe 'd["cgroup"]["nr_procs"]')" = "42" ]
}

@test "memory.max of 'max' becomes null" {
  echo max > "$TMPDIR/cgroup/memory.max"
  [ "$(jq_probe 'd["cgroup"]["mem_max"]')" = "None" ]
}

@test "missing tmux gives tmux null, still exit 0 and not partial" {
  rm "$TMPDIR/stubs/tmux"
  run "$PROBE"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["tmux"], d["partial"])')" = "None False" ]
}

@test "tmux failing exit code gives tmux null" {
  export TMUX_STUB_EXIT=1
  [ "$(jq_probe 'd["tmux"]')" = "None" ]
}

@test "no workspace dir gives git null" {
  export DVW_PROBE_WORKSPACE="$TMPDIR/does-not-exist"
  [ "$(jq_probe 'd["git"]')" = "None" ]
}

@test "a hanging tmux is cut off: tmux null, partial true, exit 0" {
  cat > "$TMPDIR/stubs/tmux" <<'STUB'
#!/bin/sh
sleep 10
STUB
  chmod +x "$TMPDIR/stubs/tmux"
  export DVW_PROBE_BUDGET=1
  run "$PROBE"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["tmux"], d["partial"], d["cgroup"]["nr_procs"])')" = "None True 42" ]
}

@test "refuses arguments with exit 0 and an error object" {
  run "$PROBE" --anything
  [ "$status" -eq 0 ]
  [[ "$output" == *'"error"'* ]]
}

@test "a pid owned by another uid is skipped" {
  mkdir -p "$TMPDIR/proc/9999"
  echo claude > "$TMPDIR/proc/9999/comm"
  printf 'claude\0' > "$TMPDIR/proc/9999/cmdline"
  printf '9999 (claude) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 500 0 0\n' > "$TMPDIR/proc/9999/stat"
  ln -s "$TMPDIR/ws" "$TMPDIR/proc/9999/cwd"
  if ! chown 1:1 "$TMPDIR/proc/9999" 2>/dev/null; then
    skip "cannot fake process ownership without root in this environment"
  fi
  [ "$(jq_probe 'len(d["agents"])')" = "1" ]
}

@test "DVW_PROBE_UID override: a foreign uid skips every fixture pid, own uid keeps them" {
  # bats never runs as root, so the chown-based test above is always
  # skipped and the uid filter's skip branch was never executed by the
  # suite. The override stands in for "what uid am I" so the branch can be
  # driven from an unprivileged run. Every fixture pid is owned by the
  # test's own uid.
  export DVW_PROBE_UID=$(( $(id -u) + 1 ))
  # scanned > 0 and cut == False, so the answer is an empty list, not null.
  [ "$(jq_probe 'd["agents"]')" = "[]" ]
  export DVW_PROBE_UID=$(id -u)
  [ "$(jq_probe 'len(d["agents"])')" = "1" ]
}

@test "a garbage DVW_PROBE_UID is ignored, real uid is used" {
  export DVW_PROBE_UID=garbage
  [ "$(jq_probe 'len(d["agents"])')" = "1" ]
}

@test "an agent CLI run through a wrapper interpreter is detected" {
  # `node /home/u/.local/bin/claude --resume`: comm is the wrapper, argv[0]
  # is the wrapper, argv[1] is the agent CLI. A wrapper running something
  # else must stay ignored.
  mkdir -p "$TMPDIR/proc/5150" "$TMPDIR/proc/5151"
  echo node > "$TMPDIR/proc/5150/comm"
  printf 'node\0/home/u/.local/bin/claude\0--resume\0' > "$TMPDIR/proc/5150/cmdline"
  printf '5150 (node) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 700 0 0\n' > "$TMPDIR/proc/5150/stat"
  ln -s "$TMPDIR/ws" "$TMPDIR/proc/5150/cwd"
  echo node > "$TMPDIR/proc/5151/comm"
  printf 'node\0/srv/app/server.js\0' > "$TMPDIR/proc/5151/cmdline"
  printf '5151 (node) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 700 0 0\n' > "$TMPDIR/proc/5151/stat"
  ln -s "$TMPDIR/ws" "$TMPDIR/proc/5151/cwd"
  result="$(jq_probe '[(a["pid"], a["cli"]) for a in d["agents"]]')"
  [ "$result" = "[(4242, 'claude'), (5150, 'claude')]" ]
}

@test "a read that never returns is cut by the hard deadline with a partial document" {
  # The per-pid budget check only gates the START of each iteration; a
  # single blocked read used to hold the whole probe for as long as the
  # kernel liked. A FIFO with no writer blocks open() forever, which is the
  # worst case. The backstop must fire, write what was collected before the
  # walk (cgroup) and exit 0 well inside the outer timeout.
  slow="$TMPDIR/proc/99998"
  mkdir -p "$slow"
  printf 'bash\n' > "$slow/comm"
  printf '99998 (bash) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 100 0 0\n' > "$slow/stat"
  mkfifo "$slow/cmdline"
  export DVW_PROBE_BUDGET=1
  start=$(date +%s)
  run timeout 8 "$PROBE"
  elapsed=$(( $(date +%s) - start ))
  [ "$status" -eq 0 ]
  [ "$elapsed" -le 4 ]
  result="$(echo "$output" | python3 -c 'import json,sys
d=json.loads(sys.stdin.read(), strict=True)
print(d["schema"], d["partial"], d["cgroup"]["nr_procs"], d["agents"], d["tmux"])')"
  [ "$result" = "1 True 42 None None" ]
}

@test "a garbage budget falls back to a default instead of crashing" {
  export DVW_PROBE_BUDGET=garbage
  run "$PROBE"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -m json.tool >/dev/null
}

@test "a non-finite budget also falls back to a default" {
  export DVW_PROBE_BUDGET=nan
  run "$PROBE"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -m json.tool >/dev/null
}

@test "collect_agents is cut off by its own share of the budget, tmux still answers" {
  # A fixture pid whose cmdline is a FIFO gives a real, bounded wall-clock
  # delay (a background writer only opens it after a fixed sleep) instead
  # of racing fixture volume against machine speed: a pid-count fixture
  # that reliably overruns on a slow CI runner finishes instantly on a
  # fast one and never triggers the cutoff, and a fixture big enough to be
  # safe on a fast runner turned this single test into a 2-minute outlier
  # under parallel load in this repo's suite (verified: ~200k fixture pids
  # took 126s wall here under `tests/bats/run.sh`'s parallel jobs, versus
  # ~8s run alone). The FIFO trades that flakiness/cost for one guaranteed
  # ~1.5s block on a single pid, independent of CPU speed or contention.
  for pid in 10 11 12 13 14; do
    d="$TMPDIR/proc/$pid"
    mkdir -p "$d"
    printf 'bash\n' > "$d/comm"
    printf 'bash\0' > "$d/cmdline"
    printf '%d (bash) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 100 0 0\n' "$pid" > "$d/stat"
  done
  slow="$TMPDIR/proc/99999"
  mkdir -p "$slow"
  printf 'bash\n' > "$slow/comm"
  printf '99999 (bash) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 100 0 0\n' > "$slow/stat"
  mkfifo "$slow/cmdline"
  ( sleep 1.5; printf 'bash\0' > "$slow/cmdline" ) &
  # Default (3 s) total budget: collect_agents' own 1 s cap is what must be
  # exceeded by the 1.5 s FIFO delay; the rest of the default budget is what
  # is left over for tmux to still answer from.
  run "$PROBE"
  [ "$status" -eq 0 ]
  result="$(echo "$output" | python3 -c 'import json,sys
d=json.load(sys.stdin)
print(d["partial"], d["tmux"] is not None)')"
  [ "$result" = "True True" ]
}

@test "an undecodable cwd still yields a document a strict parser accepts" {
  # /proc symlinks come back through surrogateescape, so one invalid byte in
  # a cwd used to travel into the JSON as a lone surrogate and cost the
  # consumer the whole document.
  rm "$TMPDIR/proc/4242/cwd"
  ln -s "$TMPDIR/"$'ws/bad\xff' "$TMPDIR/proc/4242/cwd"
  run "$PROBE"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read(), strict=True)
cwd = d["agents"][0]["cwd"]
cwd.encode("utf-8")  # raises on a lone surrogate, which is the bug
assert "�" in cwd, cwd
'
}

@test "a long string is truncated to the consumer limit" {
  # 900 chars of path, split into components a filesystem will accept.
  long=$(python3 -c 'print("/".join(["w" * 100] * 9))')
  mkdir -p "$TMPDIR/$long"
  rm "$TMPDIR/proc/4242/cwd"
  ln -s "$TMPDIR/$long" "$TMPDIR/proc/4242/cwd"
  [ "$(jq_probe 'len(d["agents"][0]["cwd"])')" = "512" ]
}

@test "more agents than the consumer accepts are capped and flagged partial" {
  for i in $(seq 0 69); do
    d="$TMPDIR/proc/2$(printf '%04d' "$i")"
    mkdir -p "$d"
    printf 'claude\n' > "$d/comm"
    printf 'claude\0' > "$d/cmdline"
    printf '1 (claude) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 500 0 0\n' > "$d/stat"
    ln -s "$TMPDIR/ws" "$d/cwd"
  done
  run "$PROBE"
  [ "$status" -eq 0 ]
  result="$(echo "$output" | python3 -c 'import json,sys
d=json.load(sys.stdin)
print(len(d["agents"]), d["partial"])')"
  [ "$result" = "64 True" ]
}

@test "serialized output stays within the consumer byte cap" {
  cat > "$TMPDIR/stubs/tmux" <<'STUB'
#!/usr/bin/env python3
import sys
if "list-sessions" in sys.argv:
    print("work\t1\t1756799999")
else:
    name = "😀" * 512
    for i in range(256):
        print(f"@{i}\t{name}\t0\t1756799999\t\tpython")
STUB
  chmod +x "$TMPDIR/stubs/tmux"

  run "$PROBE"
  [ "$status" -eq 0 ]
  result="$(printf '%s\n' "$output" | python3 -c 'import json,sys
raw=sys.stdin.buffer.read()
d=json.loads(raw)
print(len(raw), d["partial"], len(d["tmux"]["windows"]))')"
  [ "${result%% *}" -le 262144 ]
  [[ "$result" == *" True "* ]]
  [ "${result##* }" -lt 256 ]
}

@test "a git call that times out keeps the fields already collected" {
  cat > "$TMPDIR/stubs/git" <<'STUB'
#!/bin/sh
case "$*" in
  *"--abbrev-ref HEAD"*) echo "feat/x" ;;
  *"--short HEAD"*)      echo "abc1234" ;;
  *"status --porcelain"*) sleep 10 ;;
  *) exit 1 ;;
esac
exit 0
STUB
  chmod +x "$TMPDIR/stubs/git"
  export DVW_PROBE_BUDGET=1
  run "$PROBE"
  [ "$status" -eq 0 ]
  result="$(echo "$output" | python3 -c 'import json,sys
d=json.load(sys.stdin)
g=d["git"]
print(g["branch"], g["head"], g["dirty"], d["partial"])')"
  [ "$result" = "feat/x abc1234 None True" ]
}

@test "git status runs with --no-optional-locks so it never takes index.lock" {
  log="$TMPDIR/git.log"
  cat > "$TMPDIR/stubs/git" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$log"
case "\$*" in
  *"--abbrev-ref HEAD"*) echo "feat/x" ;;
  *"--short HEAD"*)      echo "abc1234" ;;
  *"status --porcelain"*) printf ' M file\n' ;;
  *"rev-list --left-right --count"*) printf '2\t0\n' ;;
  *) exit 1 ;;
esac
exit 0
STUB
  chmod +x "$TMPDIR/stubs/git"
  run "$PROBE"
  [ "$status" -eq 0 ]
  grep -q -- "--no-optional-locks status --porcelain" "$log"
  # ... and never as a plain "git -C <root> status".
  if grep -qE '^-C [^ ]+ status' "$log"; then false; fi
}
