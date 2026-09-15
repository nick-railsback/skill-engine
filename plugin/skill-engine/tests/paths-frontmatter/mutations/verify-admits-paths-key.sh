#!/usr/bin/env bash
# Control for: the navigator-frontmatter gate accepts a two-field
# frontmatter and a `paths:` block list, and rejects any other third key. A
# scratch copy of the shipped checker drops `paths` from its admitted-key
# list — the state the templates' documentation would be teaching a shape
# the gate refuses.
#
# This is the one property here with no failure mode on the template side:
# the checker is a different file. The control therefore shows the assertion
# is live, not that a template edit could trip it.
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
chmod +x "$copy"

if ! VERIFY_SH="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "pristine copy is already red"
  exit 0
fi

sed 's/name|description|paths)/name|description)/' "$copy" > "$copy.mutated" \
  && mv "$copy.mutated" "$copy"
chmod +x "$copy"

if VERIFY_SH="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "a gate that no longer admits paths: was accepted"
  exit 0
fi
echo "a gate that no longer admits paths: was rejected"
exit 1
