#!/usr/bin/env bash
# Control for: neither navigator template names one forge as the citation
# shape. A scratch copy adds the banned phrase inside the frontmatter block
# — the place new frontmatter documentation is written, and a spelling a
# hand reaching for a familiar name is one word away from.
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
    if (state == 2) print "# Globs follow the GitHub permalink conventions."
    print; next
  }
  { print }
' "$copy" > "$copy.mutated" && mv "$copy.mutated" "$copy"

if NAV_TEMPLATE="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "a single-forge phrase in the frontmatter was accepted"
  exit 0
fi
echo "a single-forge phrase in the frontmatter was rejected"
exit 1
