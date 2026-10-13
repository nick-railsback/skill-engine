#!/usr/bin/env bash
# Control for: the comment-free fixture matrix in monorepo-config-check,
# which reaches the checker through VERIFY_SH, keeps its accept verdicts. A
# scratch copy of the checker keeps the key line's value out of the body it
# counts, so a flow sequence, a comma-separated string or a single glob
# leaves only the (absent) block items to count, finds none, and is
# rejected.
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
# shellcheck source=../../lib/mutate.sh
. "$PLUGIN_ROOT/tests/lib/mutate.sh"

# The counted body starts empty instead of with the key line's value.

mutation_control VERIFY_SH "$PLUGIN_ROOT/engine-bootstrap-templates/verify.sh" \
  "$PLUGIN_ROOT/tests/monorepo-config-check/run.sh" \
  "a gate that rejects non-empty same-line values" \
  sed 's/^\([[:space:]]*\)body = key$/\1body = ""/'
