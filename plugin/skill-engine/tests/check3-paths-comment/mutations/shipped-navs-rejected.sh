#!/usr/bin/env bash
# Control for: the in-repo navigator and the bundled examples pass the
# navigator-frontmatter gate. A scratch copy of the checker lowers the
# description cap to 100 bytes. Every shipped navigator's description is far
# longer and is rejected; the scratch fixtures' one-sentence description is
# not, so only the shipped-navigator cells can turn this red.
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

sed 's/^NAV_DESCRIPTION_MAX_BYTES=[0-9][0-9]*$/NAV_DESCRIPTION_MAX_BYTES=100/' "$copy" > "$copy.mutated" \
  && mv "$copy.mutated" "$copy"
chmod +x "$copy"

if cmp -s "$work/pristine.sh" "$copy"; then
  echo "injection did not apply"
  exit 0
fi

if VERIFY_SH="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "a gate that rejects every shipped navigator was accepted"
  exit 0
fi
echo "a gate that rejects every shipped navigator was rejected"
exit 1
