#!/usr/bin/env bash
# Control for: the multi-source navigator template's Catalog container keeps
# its worked two-slice example and both per-source example slugs. A scratch
# copy renames the second per-source slug inside that container, leaving the
# abstract heading shapes above it untouched — so the control separates the
# container assertion from the whole-file one.
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

sed 's|<source-slug-2>|<another-source-slug>|g' "$copy" \
  > "$copy.mutated" && mv "$copy.mutated" "$copy"

if NAV_MULTI_TEMPLATE="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "a lost per-source worked-example slug was accepted"
  exit 0
fi
echo "a lost per-source worked-example slug was rejected"
exit 1
