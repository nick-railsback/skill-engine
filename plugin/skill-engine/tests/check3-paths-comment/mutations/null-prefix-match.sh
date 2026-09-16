#!/usr/bin/env bash
# Control for: only a token that is exactly a YAML null or an empty mapping
# is no value. A scratch copy of the checker drops any token that merely
# starts like one, so `nullable/**` and `~vendor/**` count as nothing.
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
# shellcheck source=../../lib/mutate.sh
. "$PLUGIN_ROOT/tests/lib/mutate.sh"

# The no-value match loses its end anchor.

mutation_control VERIFY_SH "$PLUGIN_ROOT/engine-bootstrap-templates/verify.sh" \
  "$SUITE_DIR/preserved.sh" \
  "a gate that drops globs starting like a null" \
  sed 's/|NULL|\[{\]\[}\])\$\//|NULL|[{][}])\//'
