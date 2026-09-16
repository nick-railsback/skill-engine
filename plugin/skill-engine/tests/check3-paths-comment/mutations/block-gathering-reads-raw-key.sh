#!/usr/bin/env bash
# Control for: a commented `paths:` key over a non-empty block list is
# accepted. A scratch copy of the checker decides whether to gather the
# lines under the key from the raw key line, before its comment is
# discounted: only a key line with nothing after the colon opens the
# gathering, so a commented key reads no items and is rejected.
#
# Single-line flow sequences and comma-separated strings keep their
# verdicts under this mutation. The cells it turns red are the commented
# keys over block lists, and the multi-line flow sequences, whose key lines
# are not empty either.
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

# Gathering opens only under a raw key line that is empty after the colon.
sed 's/^\([[:space:]]*\)inpaths = 1$/\1inpaths = ($0 ~ \/^paths:[[:space:]]*$\/)/' "$copy" > "$copy.mutated" \
  && mv "$copy.mutated" "$copy"
chmod +x "$copy"

if cmp -s "$work/pristine.sh" "$copy"; then
  echo "injection did not apply"
  exit 0
fi

if VERIFY_SH="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "a gate that gathers block items only under an uncommented key was accepted"
  exit 0
fi
echo "a gate that gathers block items only under an uncommented key was rejected"
exit 1
