#!/usr/bin/env bash
# Control for: a hard-wrap does not hide a match. A scratch copy of the sweep
# stops joining a line to the next at an ordinary break, so a phrase split
# there is matched line by line and missed.
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
# shellcheck source=../../lib/mutate.sh
. "$PLUGIN_ROOT/tests/lib/mutate.sh"

# The one line replaced, matched whole. Read from here-documents so no quote
# or backslash in either line needs escaping.
IFS= read -r old <<'LINE'
    { printf "%s ", $0 }
LINE
IFS= read -r new <<'LINE'
    { print }
LINE

mutation_control SWEEP_SH "$SUITE_DIR/sweep.sh" "$SUITE_DIR/preserved.sh" \
  "a sweep that matches line by line" \
  swap_line "$old" "$new"
