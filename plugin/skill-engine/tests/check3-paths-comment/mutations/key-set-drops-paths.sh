#!/usr/bin/env bash
# Control for: name, description and paths are the admitted top-level keys.
# A scratch copy of the checker drops `paths` from its admitted-key list, so
# every frontmatter that carries the key is rejected.
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
# shellcheck source=../../lib/mutate.sh
. "$PLUGIN_ROOT/tests/lib/mutate.sh"

mutation_control VERIFY_SH "$PLUGIN_ROOT/engine-bootstrap-templates/verify.sh" \
  "$SUITE_DIR/preserved.sh" \
  "a gate that no longer admits paths:" \
  sed 's/name|description|paths)/name|description)/'
