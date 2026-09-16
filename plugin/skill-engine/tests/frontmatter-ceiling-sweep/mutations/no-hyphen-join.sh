#!/usr/bin/env bash
# Control for: a phrase broken at its own hyphen is still matched. A scratch
# copy of the sweep joins a line ending in a hyphen with a space like any
# other, so `two-` over `field` reads `two- field`.
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
# shellcheck source=../../lib/mutate.sh
. "$PLUGIN_ROOT/tests/lib/mutate.sh"

# The one line replaced, matched whole. Read from here-documents so no quote
# or backslash in either line needs escaping.
IFS= read -r old <<'LINE'
    $0 ~ /[[:alpha:]]-$/ { printf "%s", $0; next }
LINE
IFS= read -r new <<'LINE'
    $0 ~ /[[:alpha:]]-$/ { printf "%s ", $0; next }
LINE

mutation_control SWEEP_SH "$SUITE_DIR/sweep.sh" "$SUITE_DIR/preserved.sh" \
  "a sweep that spaces a hyphen break" \
  swap_line "$old" "$new"
