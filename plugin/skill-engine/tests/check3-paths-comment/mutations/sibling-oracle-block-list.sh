#!/usr/bin/env bash
# Control for: the navigator-frontmatter suite that shipped with the
# `paths:` key still holds against the checker — a two-field frontmatter
# and a `paths:` block list are accepted, a `version:` third key is
# rejected. That suite reaches the checker through the same VERIFY_SH
# variable, so it can be pointed at a scratch copy. The copy stops
# gathering block items into the counted body, so a non-empty block list is
# rejected.
#
# -e is intentionally omitted so both runs are reached and their exit codes
# read.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
TEMPLATES_DIR="$PLUGIN_ROOT/engine-bootstrap-templates"
SIBLING="$PLUGIN_ROOT/tests/paths-frontmatter/preserved.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

copy="$work/verify.sh"
cp "$TEMPLATES_DIR/verify.sh" "$copy"
cp "$copy" "$work/pristine.sh"
chmod +x "$copy"

if ! VERIFY_SH="$copy" bash "$SIBLING" >/dev/null 2>&1; then
  echo "pristine copy is already red"
  exit 0
fi

sed 's/{ body = body "\\n" uncomment(\$0) }/{ body = body }/' "$copy" > "$copy.mutated" \
  && mv "$copy.mutated" "$copy"
chmod +x "$copy"

if cmp -s "$work/pristine.sh" "$copy"; then
  echo "injection did not apply"
  exit 0
fi

if VERIFY_SH="$copy" bash "$SIBLING" >/dev/null 2>&1; then
  echo "a gate that counts no block-list items was accepted"
  exit 0
fi
echo "a gate that counts no block-list items was rejected"
exit 1
