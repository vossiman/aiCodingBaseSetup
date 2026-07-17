# aiCodingBaseSetup

Devbox blueprint: machine provisioning (`install.sh`, `lib/`) plus the configs
it deploys (`configs/`). `main` is protected — integrate via PR; ask before
merging; delete merged branches.

## Delivery channels

- **Dev / parent submodule** — editable checkout (e.g. `devMachine` →
  `devpod/aicoding`), pinned to a SHA.
- **Runtime** — containers clone/sync from GitHub `main` into `/tmp/aicoding`
  (`postCreate`, `aicoding-install`, `aicoding-sync` refresh). Submodule edits
  do not affect running containers until merged to `main` (or you override
  `AICODING_BLUEPRINT_CLONE` / `AICODING_BLUEPRINT_REMOTE`).

## Tests

- ALWAYS run the suite via `bash tests/bats/run.sh`, never bare `bats`. run.sh
  locates bats itself (npx fallback), runs parallel (~70s wall), and exports
  the guard env (`AICODINGSETUP_SKIP_NETWORK=1`, fail-fast git-SSH, LFS stub).
- Tests execute the REAL `install.sh`/`sync.sh` — anything those scripts can
  launch, the tests will launch. Two rules paid for by incidents:
  - Gate every new network call or daemon start behind
    `AICODINGSETUP_SKIP_NETWORK` (2026-06-12: an ungated paseo daemon start
    spawned ~35 real daemons under bats and took the host down).
  - Stub every new external binary in the bats stub loops in the SAME commit
    that introduces the reference, and check for leaked processes after runs.
- Tests must never write into `$BLUEPRINT_ROOT` (the real checkout); use the
  `blueprint_copy` helper. Mutations look fine serially but poison parallel
  runs and killed runs leak edits into the working tree.
- Suite silently runs 0 tests under `--jobs`? moreutils' `parallel` is
  shadowing GNU parallel (run.sh probes for this; install.sh provisions GNU).

## tmux artifact regression

If stale-fragment artifacts return on some box: check the running SERVER
version (`tmux display -p '#{version}'`), not just `tmux -V` — a pre-3.8
server keeps the bug alive. Re-run `ensure_tmux`, then `tmux kill-server`.
Background: `install.sh` `ensure_tmux` comments.
