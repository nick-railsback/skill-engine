#!/usr/bin/env bash
# Control for: a key that names at least one glob is accepted with a trailing
# comment, in the flow and comma-separated spellings. A scratch copy of the
# checker's comment discount throws away everything before the `#` along
# with the comment, so the globs go with it.
#
# The mutation sits inside the discount itself. An injection placed after
# the discount has run (on the key line or the value extracted from it)
# finds no `#` left to act on and changes nothing, which is how an earlier
# version of this control went dead without failing.
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

# The discount's comment branch empties what it has kept so far.
sed 's/if (c == "#" \&\& p ~ \/\[\[:space:\]\]\/) break$/if (c == "#" \&\& p ~ \/[[:space:]]\/) { out = ""; break }/' "$copy" > "$copy.mutated" \
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
