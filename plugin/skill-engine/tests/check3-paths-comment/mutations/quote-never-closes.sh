#!/usr/bin/env bash
# Control for: a comment after a closed quoted scalar is still discounted. A
# scratch copy of the checker opens a quote in the comment discount but
# never closes it, so `""  # "x/**"` keeps its comment and counts it as a
# glob.
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
# shellcheck source=../../lib/mutate.sh
. "$PLUGIN_ROOT/tests/lib/mutate.sh"

# The branch that closes an open quote stops clearing it.

mutation_control VERIFY_SH "$PLUGIN_ROOT/engine-bootstrap-templates/verify.sh" \
  "$SUITE_DIR/preserved.sh" \
  "a gate whose quotes never close" \
  sed 's/else if (c == q) q = ""$/else if (c == q) q = q/'
