#!/usr/bin/env bash
# Freeze evidence at the moment a rendering artifact is visible on screen:
#  - tmux's internal grid of the active pane (what SHOULD be on screen)
#  - client/pane geometry
#  - current byte offset into ~/client-tap.raw (what WAS sent to the terminal)
# Bind to a key so pressing it doesn't repaint anything (see README.md):
#   tmux bind-key S run-shell '<path>/artifact-snap.sh'
# Then diff the two with artifact-analyze.py.
d="$HOME/artifact-snaps"; mkdir -p "$d"
t=$(date +%Y%m%d-%H%M%S)
tmux capture-pane -p > "$d/grid-$t.txt"
tmux display-message -p '#{client_width}x#{client_height} pane=#{pane_width}x#{pane_height} top=#{pane_top}' > "$d/geom-$t.txt"
stat -c%s "$HOME/client-tap.raw" > "$d/offset-$t.txt" 2>/dev/null || echo "no-tap" > "$d/offset-$t.txt"
tmux display-message "artifact snapshot $t saved"
