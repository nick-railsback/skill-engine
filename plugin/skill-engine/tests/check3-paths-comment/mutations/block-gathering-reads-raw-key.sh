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
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
# shellcheck source=../../lib/mutate.sh
. "$PLUGIN_ROOT/tests/lib/mutate.sh"

mutation_control VERIFY_SH "$PLUGIN_ROOT/engine-bootstrap-templates/verify.sh" \
  "$SUITE_DIR/preserved.sh" \
  "a gate that gathers block items only under an uncommented key" \
  sed 's/^\([[:space:]]*\)inpaths = 1$/\1inpaths = ($0 ~ \/^paths:[[:space:]]*$\/)/'
