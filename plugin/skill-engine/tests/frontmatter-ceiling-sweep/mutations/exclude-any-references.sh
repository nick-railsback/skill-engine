#!/usr/bin/env bash
# Control for: only `-context/references/` is excluded, not every
# `references/`. A scratch copy of the sweep skips any `references/` path
# segment, which also drops a hand-authored skills/<x>/references/ file.
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
    references/*|*/references/*) return 0 ;;
LINE

mutation_control SWEEP_SH "$SUITE_DIR/sweep.sh" "$SUITE_DIR/preserved.sh" \
  "a sweep that excludes every references/ directory" \
  swap_line "$old" "$new"
