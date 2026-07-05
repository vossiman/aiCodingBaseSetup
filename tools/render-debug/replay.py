#!/usr/bin/env python3
"""Replay a raw terminal byte recording to stdout in paced chunks.

Usage: replay.py <rawfile> <donefile> [chunk_bytes] [delay_ms]
Touches <donefile> when finished, then sleeps forever (keeps pane alive).
Used by harness.py inside the test pane.
"""
import sys, time, pathlib

raw = pathlib.Path(sys.argv[1]).read_bytes()
done = pathlib.Path(sys.argv[2])
chunk = int(sys.argv[3]) if len(sys.argv) > 3 else 2048
delay = (int(sys.argv[4]) if len(sys.argv) > 4 else 20) / 1000.0

out = sys.stdout.buffer
# Enter alt screen + clear, since recordings usually start mid-alt-screen.
out.write(b"\x1b[?1049h\x1b[2J\x1b[H")
out.flush()
time.sleep(0.3)

for i in range(0, len(raw), chunk):
    out.write(raw[i:i + chunk])
    out.flush()
    time.sleep(delay)

time.sleep(1.0)
done.touch()
time.sleep(3600)
