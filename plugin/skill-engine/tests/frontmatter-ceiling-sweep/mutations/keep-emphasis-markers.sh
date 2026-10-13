#!/usr/bin/env bash
# Control for: markdown emphasis does not hide a match. A scratch copy of the
# sweep stops deleting `*` and `_` before matching, so `**only** the two` and
# `__two-field__` no longer read as one phrase. Backticks are still deleted,
# so only the emphasis fixtures can turn this red.
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
# shellcheck source=../../lib/mutate.sh
. "$PLUGIN_ROOT/tests/lib/mutate.sh"

# The one line replaced, matched whole. Read from here-documents so no quote
# or backslash in either line needs escaping.
IFS= read -r old <<'LINE'
    tr -d '*`_' |
LINE
IFS= read -r new <<'LINE'
    tr -d '`' |
LINE

mutation_control SWEEP_SH "$SUITE_DIR/sweep.sh" "$SUITE_DIR/preserved.sh" \
  "a sweep that keeps emphasis markers" \
  swap_line "$old" "$new"
