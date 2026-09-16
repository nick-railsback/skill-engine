#!/usr/bin/env bash
# Control for: contextualizer references are excluded. A scratch copy of the
# sweep keeps the pattern but no longer skips on it.
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
# shellcheck source=../../lib/mutate.sh
. "$PLUGIN_ROOT/tests/lib/mutate.sh"

# The one line replaced, matched whole. Read from here-documents so no quote
# or backslash in either line needs escaping.
IFS= read -r old <<'LINE'
    *-context/references/*) return 0 ;;
LINE
IFS= read -r new <<'LINE'
    *-context/references/*) ;;
LINE

mutation_control SWEEP_SH "$SUITE_DIR/sweep.sh" "$SUITE_DIR/preserved.sh" \
  "a sweep that reads contextualizer references" \
  swap_line "$old" "$new"
