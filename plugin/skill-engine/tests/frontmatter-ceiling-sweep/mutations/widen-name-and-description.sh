#!/usr/bin/env bash
# Control for: correct statements are not flagged. A scratch copy of the
# sweep adds a bare `name and description` to its phrase family, which
# flags "name and description are required" and the optional-third-field
# statement along with the ceiling.
#
# -e is intentionally omitted so both runs are reached and their exit codes
# read.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

copy="$work/sweep.sh"
cp "$SUITE_DIR/sweep.sh" "$copy"
cp "$copy" "$work/pristine.sh"

if ! SWEEP_SH="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "pristine copy is already red"
  exit 0
fi

# The array opener, matched whole, gains one family member after it. Read
# from here-documents so no quote in either line needs escaping.
IFS= read -r old <<'LINE'
PHRASES=(
LINE
IFS= read -r extra <<'LINE'
  'name and description'
LINE
new="$(printf '%s\n%s' "$old" "$extra")"
OLD="$old" NEW="$new" awk '
  $0 == ENVIRON["OLD"] { print ENVIRON["NEW"]; next }
  { print }
' "$work/pristine.sh" > "$copy"

if cmp -s "$work/pristine.sh" "$copy"; then
  echo "mutation did not apply"
  exit 0
fi

if SWEEP_SH="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "a phrase family that matches a bare 'name and description' was accepted"
  exit 0
fi
echo "a phrase family that matches a bare 'name and description' was rejected"
exit 1
