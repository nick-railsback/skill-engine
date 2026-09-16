#!/usr/bin/env bash
# Control for: a quoted `"null"` is a string, not a YAML null. A scratch copy
# of the checker lets the no-value match see through double quotes, as a
# match made after the quotes are deleted would.
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

copy="$work/verify.sh"
cp "$TEMPLATES_DIR/verify.sh" "$copy"
cp "$copy" "$work/pristine.sh"
chmod +x "$copy"

if ! VERIFY_SH="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "pristine copy is already red"
  exit 0
fi

# The no-value match admits a double quote on either side.
sed 's/\^(~|null|Null|NULL|\[{\]\[}\])\$/^"?(~|null|Null|NULL|[{][}])"?$/' "$copy" > "$copy.mutated" \
  && mv "$copy.mutated" "$copy"
chmod +x "$copy"

if cmp -s "$work/pristine.sh" "$copy"; then
  echo "injection did not apply"
  exit 0
fi

if VERIFY_SH="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "a gate that reads a quoted null as no value was accepted"
  exit 0
fi
echo "a gate that reads a quoted null as no value was rejected"
exit 1
