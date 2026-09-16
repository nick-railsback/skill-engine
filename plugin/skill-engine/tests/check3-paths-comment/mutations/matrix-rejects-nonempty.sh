#!/usr/bin/env bash
# Control for: the comment-free fixture matrix keeps its accept verdicts. A
# scratch copy of the checker keeps the key line's value out of the body it
# counts, so a flow sequence, a comma-separated string or a single glob
# leaves only the (absent) block items to count, finds none, and is
# rejected.
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

# The counted body starts empty instead of with the key line's value.
sed 's/^\([[:space:]]*\)body = key$/\1body = ""/' "$copy" > "$copy.mutated" \
  && mv "$copy.mutated" "$copy"
chmod +x "$copy"

if cmp -s "$work/pristine.sh" "$copy"; then
  echo "injection did not apply"
  exit 0
fi

if VERIFY_SH="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "a gate that rejects non-empty same-line values was accepted"
  exit 0
fi
echo "a gate that rejects non-empty same-line values was rejected"
exit 1
