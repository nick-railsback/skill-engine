#!/usr/bin/env bash
# Control for: the local install check's required template list names both
# navigator templates and every listed file is on disk. A scratch bundle
# root holds every required template except one navigator template — the
# state a rename or a move of a template file leaves behind, which is how
# this list goes stale.
#
# -e is intentionally omitted so both runs are reached and their exit codes
# read.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

listed="$(awk '
  /^template_bundle=\(/ { cap = 1; next }
  cap && /^[[:space:]]*\)[[:space:]]*$/ { exit }
  cap {
    line = $0
    sub(/^[[:space:]]*"/, "", line)
    sub(/"[[:space:]]*$/, "", line)
    if (line != "") print line
  }
' "$PLUGIN_ROOT/bin/install-locally.sh")"

if [ -z "$listed" ]; then
  echo "pristine copy is already red"
  exit 0
fi

root="$work/bundle"
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  [ -f "$PLUGIN_ROOT/$rel" ] || continue
  mkdir -p "$root/$(dirname "$rel")"
  cp "$PLUGIN_ROOT/$rel" "$root/$rel"
done <<< "$listed"

if ! BUNDLE_ROOT="$root" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "pristine copy is already red"
  exit 0
fi

rm -f "$root/engine-bootstrap-templates/navigator.md.template"

if BUNDLE_ROOT="$root" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "a required template missing from the bundle was accepted"
  exit 0
fi
echo "a required template missing from the bundle was rejected"
exit 1
