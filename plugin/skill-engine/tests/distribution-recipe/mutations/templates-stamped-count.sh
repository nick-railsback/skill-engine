#!/usr/bin/env bash
# Control for: the templates index intro still states the same number of
# things bootstrap stamps. A copy-yourself row joins the table without
# changing that count, so the sentence must survive the edit; a scratch copy
# decrements it.
#
# -e is intentionally omitted so both runs are reached and their exit codes
# read.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

copy="$work/README.md"
cp "$PLUGIN_ROOT/engine-bootstrap-templates/README.md" "$copy"

if ! TEMPLATES_README_MD="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "pristine copy is already red"
  exit 0
fi

sed 's/stamps five things/stamps four things/' "$copy" > "$copy.mutated" && mv "$copy.mutated" "$copy"

if TEMPLATES_README_MD="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "a changed stamped count was accepted"
  exit 0
fi
echo "a changed stamped count was rejected"
exit 1
