#!/usr/bin/env bash
# Control for: the multi-source navigator template still documents both
# abstract catalog heading shapes. A scratch copy renames the slice heading
# shape everywhere it appears — the kind of loss a rewrite of the same file
# can take without noticing, since the concrete worked examples below it
# still read correctly.
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

copy="$work/navigator-multi-domain.md.template"
cp "$TEMPLATES_DIR/navigator-multi-domain.md.template" "$copy"

if ! NAV_MULTI_TEMPLATE="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "pristine copy is already red"
  exit 0
fi

sed 's|## Catalog: <slug>/<slice-id>|## Catalog: <slice-heading>|g' "$copy" \
  > "$copy.mutated" && mv "$copy.mutated" "$copy"

if NAV_MULTI_TEMPLATE="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "a lost abstract slice heading shape was accepted"
  exit 0
fi
echo "a lost abstract slice heading shape was rejected"
exit 1
