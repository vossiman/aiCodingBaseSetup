#!/usr/bin/env bash
set -u
exec "$HOME/.local/bin/kanban-work" hook --harness "$1" --event "$2"
