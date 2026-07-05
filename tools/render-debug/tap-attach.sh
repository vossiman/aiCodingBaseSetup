#!/usr/bin/env bash
# Attach to the work session while recording every byte tmux sends to this
# terminal into ~/client-tap.raw (truncated on each run). Use instead of the
# normal `tmux new -A` when hunting rendering artifacts. When you spot one,
# freeze evidence with the artifact-snap binding (see README.md), then run
# artifact-analyze.py to assign blame (tmux vs terminal emulator).
exec script -qfc "tmux new -A -D -s work" ~/client-tap.raw
