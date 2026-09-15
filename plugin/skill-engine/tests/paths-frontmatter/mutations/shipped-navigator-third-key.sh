#!/usr/bin/env bash
# Control for: every bundled example navigator still passes the
# navigator-frontmatter gate. A scratch copy of the bundled examples carries
# a third frontmatter key in one of them; the in-repo navigator and every
# other file still resolve to the real tree.
#
# The examples are copied as a set and enumerated from that copy, so the
# assertion under test is exercised over all of them, not just the mutated
# one.
#
# -e is intentionally omitted so both runs are reached and their exit codes
# read.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

examples_copy="$work/examples"
mkdir -p "$examples_copy"
cp -R "$REPO_ROOT/examples/." "$examples_copy/"

target="$(find "$examples_copy" -mindepth 2 -maxdepth 2 -name SKILL.md -not -path '*/.*' \
  | LC_ALL=C sort | head -n1)"
if [ -z "$target" ]; then
  echo "pristine copy is already red"
  exit 0
fi

if ! EXAMPLES_DIR="$examples_copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "pristine copy is already red"
  exit 0
fi

awk '
  /^---[[:space:]]*$/ { state++; if (state == 2) print "version: 1.0"; print; next }
  { print }
' "$target" > "$target.mutated" && mv "$target.mutated" "$target"

if EXAMPLES_DIR="$examples_copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "a bundled example carrying a third frontmatter key was accepted"
  exit 0
fi
echo "a bundled example carrying a third frontmatter key was rejected"
exit 1
