#!/usr/bin/env bash
# Run all aiCodingBaseSetup bats tests. Exports BLUEPRINT_ROOT so tests can
# locate the library being tested.
set -euo pipefail
cd "$(dirname "$0")/../.."
export BLUEPRINT_ROOT="$PWD"
exec bats tests/bats/*.bats
