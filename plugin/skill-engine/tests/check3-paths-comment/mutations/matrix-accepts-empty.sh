#!/usr/bin/env bash
# Control for: the comment-free fixture matrix in monorepo-config-check,
# which reaches the checker through VERIFY_SH, keeps its reject verdicts. A
# scratch copy of the checker turns the same-line emptiness failure into a
# no-op, so an empty flow sequence, a separator-only flow sequence and a bare
# comma are all accepted.
#
# -e is intentionally omitted so both runs are reached and their exit codes
# read.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
TEMPLATES_DIR="$PLUGIN_ROOT/engine-bootstrap-templates"
MATRIX="$PLUGIN_ROOT/tests/monorepo-config-check/run.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

copy="$work/verify.sh"
cp "$TEMPLATES_DIR/verify.sh" "$copy"
cp "$copy" "$work/pristine.sh"
chmod +x "$copy"

if ! VERIFY_SH="$copy" bash "$MATRIX" >/dev/null 2>&1; then
  echo "pristine copy is already red"
  exit 0
fi

# `fail "…names no glob…"` becomes `: "…names no glob…"`.
sed 's/fail \("\$nav_rel frontmatter: paths: names no glob\)/: \1/' "$copy" > "$copy.mutated" \
  && mv "$copy.mutated" "$copy"
chmod +x "$copy"

if cmp -s "$work/pristine.sh" "$copy"; then
  echo "injection did not apply"
  exit 0
fi

if VERIFY_SH="$copy" bash "$MATRIX" >/dev/null 2>&1; then
  echo "a gate that accepts empty same-line values was accepted"
  exit 0
fi
echo "a gate that accepts empty same-line values was rejected"
exit 1
