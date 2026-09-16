#!/usr/bin/env bash
# Control for: the checker names neither Python nor yq. A scratch copy of the
# checker gains an inert line that looks for python3 — behaviour unchanged,
# dependency introduced.
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

# Inserted after the navigator's relative-path assignment, inside the gate.
printf '%s\n' 'command -v python3 >/dev/null 2>&1 || true' > "$work/inject.txt"
sed '/^nav_rel="SKILL.md"$/r '"$work/inject.txt" "$copy" > "$copy.mutated" \
  && mv "$copy.mutated" "$copy"
chmod +x "$copy"

if cmp -s "$work/pristine.sh" "$copy"; then
  echo "injection did not apply"
  exit 0
fi

if VERIFY_SH="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "a checker that reaches for python3 was accepted"
  exit 0
fi
echo "a checker that reaches for python3 was rejected"
exit 1
