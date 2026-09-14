#!/usr/bin/env bash
# Control for: the delivery chapter still states who signs what, spot-checks
# and ticks which tier. The spot-check sentence is reworded out of a scratch
# copy; the chapter still reads as prose, and the property is gone.
#
# -e is intentionally omitted so both runs are reached and their exit codes
# read.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

copy="$work/04-delivery.md"
cp "$PLUGIN_ROOT/docs/04-delivery.md" "$copy"

if ! DELIVERY_MD="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "pristine copy is already red"
  exit 0
fi

sed 's/spot-check/sample-check/g' "$copy" > "$copy.mutated" && mv "$copy.mutated" "$copy"

if DELIVERY_MD="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "a reworded spot-check sentence was accepted"
  exit 0
fi
echo "a reworded spot-check sentence was rejected"
exit 1
