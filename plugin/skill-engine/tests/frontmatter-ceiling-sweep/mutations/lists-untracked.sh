#!/usr/bin/env bash
# Control for: tracked is the rule, not present-on-disk. A scratch copy of the
# sweep also lists untracked files, so a draft that was never added is
# flagged.
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
  git -C "$root" ls-files -z --cached --others -- '*.md' '*.md.template'
LINE

mutation_control SWEEP_SH "$SUITE_DIR/sweep.sh" "$SUITE_DIR/preserved.sh" \
  "a sweep that reads untracked files" \
  swap_line "$old" "$new"
