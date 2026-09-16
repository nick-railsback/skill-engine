#!/usr/bin/env bash
# Control for: the comment-free fixture matrix in monorepo-config-check,
# which reaches the checker through VERIFY_SH, keeps its reject verdicts. A
# scratch copy of the checker turns the same-line emptiness failure into a
# no-op, so an empty flow sequence, a separator-only flow sequence and a bare
# comma are all accepted.
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
# shellcheck source=../../lib/mutate.sh
. "$PLUGIN_ROOT/tests/lib/mutate.sh"

# `fail "…names no glob…"` becomes `: "…names no glob…"`.

mutation_control VERIFY_SH "$PLUGIN_ROOT/engine-bootstrap-templates/verify.sh" \
  "$PLUGIN_ROOT/tests/monorepo-config-check/run.sh" \
  "a gate that accepts empty same-line values" \
  sed 's/fail \("\$nav_rel frontmatter: paths: names no glob\)/: \1/'
