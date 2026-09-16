#!/usr/bin/env bash
# Control for: a blockquote does not hide a hard-wrapped match. A scratch
# copy of the sweep keeps each line's leading `>`, so the join puts one
# inside a phrase split across two quoted lines.
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
# shellcheck source=../../lib/mutate.sh
. "$PLUGIN_ROOT/tests/lib/mutate.sh"

# The one line replaced, matched whole. Read from here-documents so no quote
# or backslash in either line needs escaping.
IFS= read -r old <<'LINE'
    { sub(/\r$/, ""); sub(/^([[:space:]]*>)+/, "") }
LINE
IFS= read -r new <<'LINE'
    { sub(/\r$/, "") }
LINE

mutation_control SWEEP_SH "$SUITE_DIR/sweep.sh" "$SUITE_DIR/preserved.sh" \
  "a sweep that keeps blockquote markers" \
  swap_line "$old" "$new"
