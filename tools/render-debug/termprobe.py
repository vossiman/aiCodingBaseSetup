#!/usr/bin/env python3
"""Terminal width probe — measures how many columns YOUR terminal advances
for each glyph Claude Code draws, vs what tmux/wcwidth assume.

Run it twice and compare:
  1. INSIDE tmux (any pane):                    python3 termprobe.py
  2. OUTSIDE tmux (fresh terminal tab, no tmux): python3 termprobe.py

A glyph whose 'cols' differs between the two runs (or from 'expect') means the
terminal and tmux disagree on cursor position after drawing it -> exactly the
kind of drift that leaves stale fragments which only a full redraw cleans.
"""
import os, re, sys, termios, tty

GLYPHS = [
    ("A", 1, "ASCII control"),
    ("你", 2, "CJK control (wide)"),
    ("✻", 1, "spinner *"),
    ("✽", 1, "spinner * (heavy, EAW=A)"),
    ("✢", 1, "spinner +"),
    ("✶", 1, "spinner star"),
    ("●", 1, "bullet (EAW=A)"),
    ("⏺", 1, "record mark"),
    ("…", 1, "ellipsis (EAW=A)"),
    ("·", 1, "middle dot (EAW=A)"),
    ("↓", 1, "down arrow (EAW=A)"),
    ("⎿", 1, "tool-result elbow"),
    ("▐", 1, "half block"),
    ("▛", 1, "quadrant block (logo)"),
    ("◼", 1, "black medium square"),
    ("❯", 1, "prompt chevron"),
]

def probe(ch):
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        # carriage return, print glyph, ask cursor position
        os.write(1, b"\r" + ch.encode() + b"\x1b[6n")
        buf = b""
        while not buf.endswith(b"R"):
            b1 = os.read(fd, 1)
            if not b1:
                break
            buf += b1
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
    m = re.search(rb"\x1b\[(\d+);(\d+)R", buf)
    return int(m.group(2)) - 1 if m else -1

in_tmux = "TMUX" in os.environ
print(f"probing ({'INSIDE tmux' if in_tmux else 'OUTSIDE tmux — raw terminal'})\r")
bad = 0
for ch, expect, label in GLYPHS:
    cols = probe(ch)
    mark = "ok" if cols == expect else "MISMATCH"
    if cols != expect:
        bad += 1
    print(f"\r\x1b[KU+{ord(ch):04X} {ch}  cols={cols} expect={expect}  {mark:8s} {label}")
print(f"\r\x1b[K\n{'ALL OK - terminal agrees with wcwidth' if not bad else str(bad) + ' MISMATCH(ES) - width disagreement found'}")
