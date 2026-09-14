#!/usr/bin/env bash
# Control for: the capability ledger's what-this-is-not section keeps all
# three of its claims. One of the three is dropped from a scratch copy of
# the file; every other file the suite reads stays pointed at the real tree,
# so the pristine run is a real baseline and not an artefact of copying too
# little.
#
# -e is intentionally omitted so both runs are reached and their exit codes
# read.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

copy="$work/CAPABILITIES.md"
cp "$REPO_ROOT/CAPABILITIES.md" "$copy"

if ! CAPABILITIES_MD="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "pristine copy is already red"
  exit 0
fi

sed 's/federation layer/aggregation tier/g' "$copy" > "$copy.mutated" && mv "$copy.mutated" "$copy"

if CAPABILITIES_MD="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "a dropped claim was accepted"
  exit 0
fi
echo "a dropped claim was rejected"
exit 1
