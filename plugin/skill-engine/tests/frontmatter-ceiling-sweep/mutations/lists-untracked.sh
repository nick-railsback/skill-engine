#!/usr/bin/env bash
# Control for: tracked is the rule, not present-on-disk. A scratch copy of the
# sweep also lists untracked files, so a draft that was never added is
# flagged.
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

# The one line replaced, matched whole. Read from here-documents so no quote
# or backslash in either line needs escaping.
IFS= read -r old <<'LINE'
  git -C "$root" ls-files -z -- '*.md' '*.md.template'
LINE
IFS= read -r new <<'LINE'
  git -C "$root" ls-files -z --cached --others -- '*.md' '*.md.template'
LINE
OLD="$old" NEW="$new" awk '
  $0 == ENVIRON["OLD"] { print ENVIRON["NEW"]; next }
  { print }
' "$work/pristine.sh" > "$copy"

if cmp -s "$work/pristine.sh" "$copy"; then
  echo "mutation did not apply"
  exit 0
fi

if SWEEP_SH="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "a sweep that reads untracked files was accepted"
  exit 0
fi
echo "a sweep that reads untracked files was rejected"
exit 1
