# aiCodingBaseSetup — interactive-shell aliases.
# Deployed to ~/.bashrc.d/aicoding-aliases.sh and sourced from ~/.bashrc via
# the aicoding managed block. Aliases only expand in interactive shells, so
# scripts (sync.sh's `cursor-agent update`, hooks, CI) are unaffected.

# Cursor CLI automode: the devpod container is the isolation boundary.
# --force allows all commands EXCEPT permissions.deny entries in
# ~/.cursor/cli-config.json (deny survives --force; the blueprint merges in
# deny rules for ~/.aicodingsetup). --approve-mcps auto-approves MCP servers,
# which come from the blueprint's own cursor/mcp.json anyway.
alias cursor-agent='cursor-agent --force --approve-mcps'
alias agent='agent --force --approve-mcps'

# Bare `cursor` is an IDE-launcher shim; with no IDE in a container it execs
# whatever other `cursor` is on PATH (universal:6 ships an unrelated
# /usr/local/jupyter/cursor) and hangs. Interactive shells should get the
# agent instead — bash chains alias expansion, so this also picks up the
# automode flags above. Shell-level only: the system binaries and script
# PATH resolution are untouched.
alias cursor='cursor-agent'
