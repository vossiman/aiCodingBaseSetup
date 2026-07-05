#!/usr/bin/env python3
"""Assign blame for a rendering artifact: tmux vs the terminal emulator.

Takes a snapshot made by artifact-snap.sh (tmux grid + geometry + byte offset
into the client tap recorded by tap-attach.sh), replays the recorded client
stream up to that offset through an independent VT emulator (pyte), and diffs
the result against tmux's grid.

  0 differing rows -> tmux emitted bytes sufficient to render the correct
                      screen; the terminal emulator misrendered them.
  >0 differing rows -> tmux's output diverged from its own grid; tmux bug
                       (the report shows exactly where).

Usage: artifact-analyze.py [--snap ID|latest] [--tap ~/client-tap.raw]
Requires: pip install --user pyte
"""
import argparse, pathlib, re, sys

import pyte

HOME = pathlib.Path.home()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--snap", default="latest", help="snapshot id (timestamp) or 'latest'")
    ap.add_argument("--snapdir", default=str(HOME / "artifact-snaps"))
    ap.add_argument("--tap", default=str(HOME / "client-tap.raw"))
    args = ap.parse_args()

    snapdir = pathlib.Path(args.snapdir)
    if args.snap == "latest":
        grids = sorted(snapdir.glob("grid-*.txt"))
        if not grids:
            sys.exit(f"no snapshots in {snapdir}")
        snap = grids[-1].stem.removeprefix("grid-")
    else:
        snap = args.snap

    geom = (snapdir / f"geom-{snap}.txt").read_text().split()
    W, H = map(int, geom[0].split("x"))
    pane_top = int(geom[2].split("=")[1])
    grid = (snapdir / f"grid-{snap}.txt").read_text().split("\n")
    pane_h = len(grid) if grid[-1] else len(grid) - 1

    offset_txt = (snapdir / f"offset-{snap}.txt").read_text().strip()
    if offset_txt == "no-tap":
        sys.exit("snapshot has no tap offset — attach via tap-attach.sh first")
    offset = int(offset_txt)
    data = pathlib.Path(args.tap).read_bytes()[:offset]

    # pyte can't parse colon-form SGR or private DSR queries (e.g. tmux
    # master's theme probe CSI ?996n) — sanitize; text comparison only.
    data = re.sub(rb"\x1b\[\?[0-9;]*n", b"", data)
    sgr_colon = re.compile(rb"\x1b\[([0-9;:]*?):([0-9;:]*)m")
    prev = None
    while prev != data:
        prev = data
        data = sgr_colon.sub(lambda m: b"\x1b[" + m.group(1) + b";" + m.group(2) + b"m", data)

    screen = pyte.Screen(W, H)
    pyte.ByteStream(screen).feed(data)

    def render(y):
        row = screen.buffer[y]
        return "".join((row[x].data or " ") for x in range(W)).rstrip()

    diffs = []
    for i in range(pane_h):
        g = (grid[i] if i < len(grid) else "").rstrip()
        o = render(pane_top + i)
        if g != o:
            j = 0
            while j < min(len(g), len(o)) and g[j] == o[j]:
                j += 1
            diffs.append((i, j, g, o))

    print(f"snap={snap} client={W}x{H} pane_top={pane_top} pane_h={pane_h} tap_bytes={offset}")
    print(f"diff_rows={len(diffs)}")
    for i, j, g, o in diffs[:12]:
        print(f"--- pane row {i} first-diff col {j}")
        print(f"grid  |{g[:150]}|")
        print(f"outer |{o[:150]}|")
    print()
    if diffs:
        print("VERDICT: tmux's client stream diverges from its grid -> tmux bug.")
    else:
        print("VERDICT: stream reproduces tmux's grid exactly -> the terminal")
        print("emulator misrendered correct bytes (renderer/atlas/font bug).")
    return 1 if diffs else 0


if __name__ == "__main__":
    sys.exit(main())
