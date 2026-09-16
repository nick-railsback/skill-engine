#!/usr/bin/env bash
# Control for: a flow sequence whose items sit on the lines after the key is
# accepted. A scratch copy of the checker never sees the closing `]` of a
# sequence the key line leaves open, so every multi-line sequence reads as
# unclosed and is rejected, the shortcut that refuses a spelling YAML
# accepts.
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

# The line that closes an open sequence stops closing it.
sed 's|if (t ~ /\\]\$/) inflow = 0|t = t|' "$copy" > "$copy.mutated" \
  && mv "$copy.mutated" "$copy"
chmod +x "$copy"

if cmp -s "$work/pristine.sh" "$copy"; then
  echo "injection did not apply"
  exit 0
fi

if VERIFY_SH="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "a gate that rejects every multi-line flow sequence was accepted"
  exit 0
fi
echo "a gate that rejects every multi-line flow sequence was rejected"
exit 1
