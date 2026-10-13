#!/usr/bin/env bash
# Control for: an empty flow sequence written on the line under the key is
# rejected. A scratch copy of the checker strips a flow sequence's brackets
# only when the key line opened it, so `[]` under a bare key survives as a
# token and counts as a glob.
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
# shellcheck source=../../lib/mutate.sh
. "$PLUGIN_ROOT/tests/lib/mutate.sh"

# The bracket strip asks whether the key line, not the value, opens `[`.

mutation_control VERIFY_SH "$PLUGIN_ROOT/engine-bootstrap-templates/verify.sh" \
  "$SUITE_DIR/preserved.sh" \
  "a gate that reads flow brackets on the key line only" \
  sed 's|if (s ~ /^\\\[/ \&\& s ~|if (key ~ /^\\[/ \&\& s ~|'
