#!/usr/bin/env bash
set -u
# kanban-work runs from an immutable, digest-checked release: no bytecode.
export PYTHONDONTWRITEBYTECODE=1
exec "$HOME/.local/bin/kanban-work" hook --harness "$1" --event "$2"
