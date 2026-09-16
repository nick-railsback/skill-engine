#!/usr/bin/env bash
# Control for: a flow sequence that opens on the line under the key and never
# closes is rejected. A scratch copy of the checker never calls a sequence
# unclosed, so the lone `[` of `[a/**,` counts toward a glob and the value
# is accepted.
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
# shellcheck source=../../lib/mutate.sh
. "$PLUGIN_ROOT/tests/lib/mutate.sh"

# The whole-value unclosed test always answers no.

mutation_control VERIFY_SH "$PLUGIN_ROOT/engine-bootstrap-templates/verify.sh" \
  "$SUITE_DIR/preserved.sh" \
  "a gate that never flags an unclosed sequence" \
  sed 's/unclosed = (v ~ .*$/unclosed = 0/'
