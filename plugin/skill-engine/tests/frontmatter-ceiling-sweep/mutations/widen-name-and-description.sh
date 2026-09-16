#!/usr/bin/env bash
# Control for: correct statements are not flagged. A scratch copy of the
# sweep adds a bare `name and description` to its phrase family, which
# flags "name and description are required" and the optional-third-field
# statement along with the ceiling.
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
# shellcheck source=../../lib/mutate.sh
. "$PLUGIN_ROOT/tests/lib/mutate.sh"

# The array opener, matched whole, gains one family member after it. Read
# from here-documents so no quote in either line needs escaping.
IFS= read -r old <<'LINE'
PHRASES=(
LINE
IFS= read -r extra <<'LINE'
  'name and description'
LINE
new="$(printf '%s\n%s' "$old" "$extra")"

mutation_control SWEEP_SH "$SUITE_DIR/sweep.sh" "$SUITE_DIR/preserved.sh" \
  "a phrase family that matches a bare 'name and description'" \
  swap_line "$old" "$new"
