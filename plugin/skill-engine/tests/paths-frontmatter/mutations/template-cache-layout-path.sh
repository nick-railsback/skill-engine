#!/usr/bin/env bash
# Control for: neither navigator template introduces an unmarked flat
# clone-cache path. A scratch copy writes one into the frontmatter block
# without the marker that exempts a deliberate historical mention.
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
    if (state == 2) print "# Globs resolve under cache/skill-engine/<source_id>."
    print; next
  }
  { print }
' "$copy" > "$copy.mutated" && mv "$copy.mutated" "$copy"

if NAV_TEMPLATE="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "an unmarked flat cache path was accepted"
  exit 0
fi
echo "an unmarked flat cache path was rejected"
exit 1
