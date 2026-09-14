#!/usr/bin/env bash
# Control for: no single-inline-hook claim has come back to the delivery
# chapter. The retired sentence is restored in a scratch copy — the exact
# thing the zero-hooks prose written next door could reintroduce.
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

printf '\nA future engine plugin will ship exactly one inline SessionStart hook.\n' >> "$copy"

if DELIVERY_MD="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "a restored single-inline-hook claim was accepted"
  exit 0
fi
echo "a restored single-inline-hook claim was rejected"
exit 1
