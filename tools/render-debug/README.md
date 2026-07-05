# render-debug — tmux/terminal rendering-artifact forensics

Tooling built during the July 2026 hunt for "stale fragments in the first
columns when Claude Code streams inside tmux" (fixed: tmux ≤3.7b sync-redraw
bugs → pinned master build in `install.sh`; residual: Windows Terminal glyph
atlas × bitmap font → font change). Kept because the *method* generalizes to
any "terminal shows garbage but a forced redraw cleans it" bug.

## The core idea

That symptom means the terminal's **displayed** screen diverged from tmux's
**internal** grid. There are exactly three places the divergence can arise,
and each tool isolates one:

| Layer | Question | Tool |
|---|---|---|
| app → tmux | Does the app write garbage? (redraw would NOT clean it) | `tmux capture-pane -p` — garbage in the grid = app bug |
| tmux → terminal | Does tmux send bytes that don't match its own grid? | `harness.py` (offline replay) or the live tap (below) |
| terminal renderer | Does the terminal misrender correct bytes? | live tap: `diff == 0` while the screen shows junk |

## Live tap — blame assignment on a real terminal (the decisive test)

1. Attach through the recorder instead of your normal attach:
   `bash tap-attach.sh`   (records everything tmux sends → `~/client-tap.raw`)
2. Bind the freeze key once per server:
   `tmux bind-key S run-shell '<abs-path-to>/artifact-snap.sh'`
3. The moment you SEE an artifact: press `prefix + S`. It snapshots tmux's
   grid + geometry + the tap byte-offset to `~/artifact-snaps/` without
   repainting anything. (Don't type into the TUI first — that repaints and
   destroys the evidence.)
4. `pip install --user pyte && python3 artifact-analyze.py`
   - `diff_rows=0` → tmux sent correct bytes; the terminal emulator
     misrendered them (renderer/atlas/font bug). The tap file is a
     self-contained repro for an upstream report — but it contains your whole
     session content, so review before sharing.
   - `diff_rows>0` → tmux bug, and the report shows the exact rows.

## Offline harness — reproduce/regression-test tmux server behavior

`harness.py` replays a recorded byte stream inside an isolated tmux server
(own socket, your config) against a fake pty client (pyte), and diffs
capture-pane vs the emulated screen. Useful to A/B tmux versions, config
options, terminal feature sets (`--responder kitty|wt` fakes DA/XTVERSION so
tmux enables sync/margins paths), slow clients (`--slow-reader`), and
width-disagreeing terminals (`--ambiguous-wide`).

Record a workload from a live pane (raw bytes the app writes):

    tmux pipe-pane -t %0 -O 'cat >> ~/workload.raw'    # arm
    tmux pipe-pane -t %0                                # disarm

Build a test config from the real one, neutering anything that touches real
daemons or saved state (resurrect restores, continuum saves — hard lesson,
see tests/bats/run.sh for the same philosophy):

    cp ~/.tmux.conf test.conf   # then, BEFORE the tpm run line, add:
    # set -g @continuum-restore 'off'
    # set -g @continuum-save-interval '0'
    # set -g @resurrect-dir '/tmp/somewhere-disposable'

Run (match --width/--client-height to the recording's pane geometry, client
height = pane height + status/border lines):

    python3 harness.py --config test.conf --recording ~/workload.raw \
        --width 165 --client-height 45 --label mytest

Exit 0 = converged; exit 1 = divergence, with a per-row report in
`out/<label>/report.txt` and the raw client stream in `outer-terminal.raw`.

## Width probe

`termprobe.py` prints each risky glyph (spinners, bullets, box chars — all
East-Asian-Ambiguous or symbol-block) and asks the terminal where the cursor
landed (CPR). Run it inside tmux (measures tmux's bookkeeping) and outside
(measures the real terminal). Any mismatch = cursor-drift class corruption.

## pyte gotchas (already handled in these scripts)

- Colon-form SGR (`38:2::r:g:b`) and private DSR queries (tmux master's theme
  probe `CSI ?996n`) crash/garble pyte — both are stripped before feeding.
- `screen.display` crashes on orphaned wide-char stubs; render cells manually
  with `row[x].data or " "`.

## Case study (July 2026) — what each verdict looked like

- Heavy scroll-correlated corruption, kitty + Windows Terminal, Termius clean:
  offline harness showed tmux 3.5a *server-side clean*, live symptom persisted
  with every config override → tmux **version** bug (≤3.7b sync-redraw, fixed
  on master; `ensure_tmux` now pins it).
- Rare residue on tmux master: live tap `diff_rows=0` → Windows Terminal
  renderer at fault; vanished after swapping the bitmap font (GohuFont uni11
  NF) for a vector font. WT 1.24.11321.0.
