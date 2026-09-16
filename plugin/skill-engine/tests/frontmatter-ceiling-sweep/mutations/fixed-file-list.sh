#!/usr/bin/env bash
# Control for: the file set is derived, not listed. A scratch copy of the
# sweep replaces its git listing with a fixed list of the two docs this
# repository's drift was first found in.
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
# shellcheck source=../../lib/mutate.sh
. "$PLUGIN_ROOT/tests/lib/mutate.sh"

# The one line replaced, matched whole. Read from here-documents so no quote
# or backslash in either line needs escaping.
IFS= read -r old <<'LINE'
  git -C "$root" ls-files -z -- '*.md' '*.md.template'
LINE
IFS= read -r new <<'LINE'
  printf '%s\0' plugin/skill-engine/docs/02-artifact-contract.md plugin/skill-engine/docs/11-walkthrough.md
LINE

mutation_control SWEEP_SH "$SUITE_DIR/sweep.sh" "$SUITE_DIR/preserved.sh" \
  "a sweep that reads a fixed file list" \
  swap_line "$old" "$new"
