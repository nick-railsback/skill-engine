#!/usr/bin/env bash
# Control for: the in-repo navigator and the bundled examples pass the
# navigator-frontmatter gate. A scratch copy of the checker lowers the
# description cap to 100 bytes. Every shipped navigator's description is far
# longer and is rejected; the scratch fixtures' one-sentence description is
# not, so only the shipped-navigator cells can turn this red.
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
# shellcheck source=../../lib/mutate.sh
. "$PLUGIN_ROOT/tests/lib/mutate.sh"

mutation_control VERIFY_SH "$PLUGIN_ROOT/engine-bootstrap-templates/verify.sh" \
  "$SUITE_DIR/preserved.sh" \
  "a gate that rejects every shipped navigator" \
  sed 's/^NAV_DESCRIPTION_MAX_BYTES=[0-9][0-9]*$/NAV_DESCRIPTION_MAX_BYTES=100/'
