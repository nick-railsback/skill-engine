#!/usr/bin/env bash
# Control for: exclusions read the repo-relative path. A scratch copy of the
# sweep tests the absolute path instead; the fixture repository lives under a
# `-context/references/` pair, so every fixture is then skipped.
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
# shellcheck source=../../lib/mutate.sh
. "$PLUGIN_ROOT/tests/lib/mutate.sh"

# The one line replaced, matched whole. Read from here-documents so no quote
# or backslash in either line needs escaping.
IFS= read -r old <<'LINE'
  is_excluded "$rel" && continue
LINE
IFS= read -r new <<'LINE'
  is_excluded "$root/$rel" && continue
LINE

mutation_control SWEEP_SH "$SUITE_DIR/sweep.sh" "$SUITE_DIR/preserved.sh" \
  "a sweep that excludes by absolute path" \
  swap_line "$old" "$new"
