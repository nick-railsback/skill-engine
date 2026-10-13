#!/usr/bin/env bash
# Control for: CHANGELOG.md is the only changelog-shaped exclusion. A scratch
# copy of the sweep excludes any path containing CHANGELOG, which also drops
# docs/CHANGELOG-notes.md.
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
# shellcheck source=../../lib/mutate.sh
. "$PLUGIN_ROOT/tests/lib/mutate.sh"

# The one line replaced, matched whole. Read from here-documents so no quote
# or backslash in either line needs escaping.
IFS= read -r old <<'LINE'
    CHANGELOG.md) return 0 ;;
LINE
IFS= read -r new <<'LINE'
    *CHANGELOG*) return 0 ;;
LINE

mutation_control SWEEP_SH "$SUITE_DIR/sweep.sh" "$SUITE_DIR/preserved.sh" \
  "a sweep that excludes by CHANGELOG substring" \
  swap_line "$old" "$new"
