#!/usr/bin/env bash
# Control for: the navigator template keeps its forge-grammar Claims-policy
# first item and both byte-pinned sentences. A scratch copy reflows one of
# those sentences by a single word — a reflow counts as a change, and the
# oracle that owns it matches raw bytes.
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

sed 's/grounded-citation eval/grounded citation eval/' "$copy" > "$copy.mutated" \
  && mv "$copy.mutated" "$copy"

if NAV_TEMPLATE="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "a reflowed claims-policy sentence was accepted"
  exit 0
fi
echo "a reflowed claims-policy sentence was rejected"
exit 1
