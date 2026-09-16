#!/usr/bin/env bash
# Control for: a commented `paths:` key over a non-empty block list is
# accepted. A scratch copy of the checker discounts the trailing comment on
# the extracted same-line value only — with the right comment rule, but
# after the key line has been read rather than before. The value goes empty,
# the run falls through to the block-list count, and that count recognizes
# only a key line with nothing after the colon, so it finds no items.
#
# Flow sequences and comma-separated strings with a comment keep their
# verdicts under this mutation; only the block-list cells can turn it red.
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

# Inserted after the line that extracts the key's same-line value.
printf '%s\n' \
  'fm_paths_value="$(printf '"'"'%s'"'"' "$fm_paths_value" | sed -E '"'"'s/(^|[[:space:]])#.*$//; s/[[:space:]]+$//'"'"')"' \
  > "$work/inject.txt"
sed '/fm_paths_value="\$(printf/r '"$work/inject.txt" "$copy" > "$copy.mutated" \
  && mv "$copy.mutated" "$copy"
chmod +x "$copy"

if cmp -s "$work/pristine.sh" "$copy"; then
  echo "injection did not apply"
  exit 0
fi

if VERIFY_SH="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "a comment discount applied to the extracted value only was accepted"
  exit 0
fi
echo "a comment discount applied to the extracted value only was rejected"
exit 1
