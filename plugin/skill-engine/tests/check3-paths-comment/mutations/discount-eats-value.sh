#!/usr/bin/env bash
# Control for: a key that names at least one glob is accepted with a trailing
# comment, in the block, flow and comma-separated spellings. A scratch copy of
# the checker empties the whole `paths:` value whenever its key line carries a
# whitespace-preceded `#` — a comment discount that swallows the globs along
# with the comment.
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
  'case "$fm_paths_line" in *[[:space:]]#*) fm_paths_value="" ;; esac' \
  > "$work/inject.txt"
sed '/fm_paths_value="\$(printf/r '"$work/inject.txt" "$copy" > "$copy.mutated" \
  && mv "$copy.mutated" "$copy"
chmod +x "$copy"

if cmp -s "$work/pristine.sh" "$copy"; then
  echo "injection did not apply"
  exit 0
fi

if VERIFY_SH="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "a comment discount that empties a non-empty value was accepted"
  exit 0
fi
echo "a comment discount that empties a non-empty value was rejected"
exit 1
