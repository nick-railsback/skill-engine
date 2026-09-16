#!/usr/bin/env bash
# Control for: no top-level key beyond name, description and paths is
# admitted. A scratch copy of the checker widens its admitted-key list to
# include `version`.
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
# shellcheck source=../../lib/mutate.sh
. "$PLUGIN_ROOT/tests/lib/mutate.sh"

mutation_control VERIFY_SH "$PLUGIN_ROOT/engine-bootstrap-templates/verify.sh" \
  "$SUITE_DIR/preserved.sh" \
  "a gate that also admits version:" \
  sed 's/name|description|paths)/name|description|paths|version)/'
