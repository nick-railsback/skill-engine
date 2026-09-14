#!/usr/bin/env bash
# Control for: the capability ledger keeps the enumeration flag within reach
# of the three workflows and the table it is stated for. The flag is renamed
# throughout a scratch copy, which is the regression shape — the ledger
# still reads fine to a human and the proximity binding is gone.
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

sed 's/--all/--every-one/g' "$copy" > "$copy.mutated" && mv "$copy.mutated" "$copy"

if CAPABILITIES_MD="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "a renamed enumeration flag was accepted"
  exit 0
fi
echo "a renamed enumeration flag was rejected"
exit 1
