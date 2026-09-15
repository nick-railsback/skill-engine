#!/usr/bin/env bash
# Control for: neither navigator template shows a forge URL template that is
# not introduced as an example. A scratch copy puts one inside the
# frontmatter block, where the scan's 200-character look-behind window is
# nearly empty — the exact position new frontmatter documentation occupies,
# and the reason a URL-shaped example there cannot pass where the same URL
# lower in the file does.
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
    if (state == 2) print "# See https://github.com/<owner>/<repo>/blob/<sha>/README.md"
    print; next
  }
  { print }
' "$copy" > "$copy.mutated" && mv "$copy.mutated" "$copy"

if NAV_TEMPLATE="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "an unexampled forge URL template in the frontmatter was accepted"
  exit 0
fi
echo "an unexampled forge URL template in the frontmatter was rejected"
exit 1
