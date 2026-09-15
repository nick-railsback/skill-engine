#!/usr/bin/env bash
# Control for: neither navigator template restates a retired single-grammar
# claim. A scratch copy of the multi-source template carries one of the two
# retired sentences back in, hand-wrapped across two lines so the control
# also exercises the wrap normalization the check depends on.
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

copy="$work/navigator-multi-domain.md.template"
cp "$TEMPLATES_DIR/navigator-multi-domain.md.template" "$copy"

if ! NAV_MULTI_TEMPLATE="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "pristine copy is already red"
  exit 0
fi

{
  printf '\n'
  printf 'Unpinned `blob/main/...` URLs and non-GitHub URLs do not\n'
  printf 'satisfy the density check.\n'
} >> "$copy"

if NAV_MULTI_TEMPLATE="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "a retired single-grammar claim was accepted"
  exit 0
fi
echo "a retired single-grammar claim was rejected"
exit 1
