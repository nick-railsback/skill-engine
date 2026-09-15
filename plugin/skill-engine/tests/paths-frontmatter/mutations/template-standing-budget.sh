#!/usr/bin/env bash
# Control for: a navigator template costs a stamped navigator no more
# standing-instruction bytes than it does today, and documents no
# frontmatter key below the closing delimiter. A scratch copy writes the
# same documentation one line lower — just under the closing `---` instead
# of just above it. That is the single most likely misplacement when adding
# frontmatter documentation, and it is the one that lands on every stamped
# navigator's standing instructions.
#
# -e is intentionally omitted so both runs are reached and their exit codes
# read.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
TEMPLATES_DIR="$PLUGIN_ROOT/engine-bootstrap-templates"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

copy="$work/navigator.md.template"
cp "$TEMPLATES_DIR/navigator.md.template" "$copy"

if ! NAV_TEMPLATE="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "pristine copy is already red"
  exit 0
fi

awk '
  /^---[[:space:]]*$/ {
    state++
    print
    if (state == 2) {
      print ""
      print "The optional paths: frontmatter key scopes a nested or per-slice"
      print "contextualizer to its own file globs. A contextualizer installed at"
      print "one of the fixed skills roots omits it."
    }
    next
  }
  { print }
' "$copy" > "$copy.mutated" && mv "$copy.mutated" "$copy"

if NAV_TEMPLATE="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "frontmatter documentation placed below the delimiter was accepted"
  exit 0
fi
echo "frontmatter documentation placed below the delimiter was rejected"
exit 1
