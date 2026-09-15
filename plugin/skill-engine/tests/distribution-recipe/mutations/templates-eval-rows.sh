#!/usr/bin/env bash
# Control for: the three eval harness rows in the templates index are still
# recorded as ones bootstrap stamps. A scratch copy marks one of them as a
# copy-yourself row — the mistake a hand adding a new copy-yourself row to
# the same table is one line away from.
#
# -e is intentionally omitted so both runs are reached and their exit codes
# read.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

copy="$work/README.md"
cp "$PLUGIN_ROOT/engine-bootstrap-templates/README.md" "$copy"

if ! TEMPLATES_README_MD="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "pristine copy is already red"
  exit 0
fi

sed 's/| Eval harness/| Eval harness (**not** stamped by engine-bootstrap)/' "$copy" \
  > "$copy.mutated" && mv "$copy.mutated" "$copy"

if TEMPLATES_README_MD="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "an eval row marked copy-yourself was accepted"
  exit 0
fi
echo "an eval row marked copy-yourself was rejected"
exit 1
