#!/usr/bin/env bash
# Control for: the navigator-frontmatter suite that shipped with the
# `paths:` key still holds against the checker — a two-field frontmatter
# and a `paths:` block list are accepted, a `version:` third key is
# rejected. That suite reaches the checker through the same VERIFY_SH
# variable, so it can be pointed at a scratch copy. The copy stops
# gathering block items into the counted body, so a non-empty block list is
# rejected.
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
# shellcheck source=../../lib/mutate.sh
. "$PLUGIN_ROOT/tests/lib/mutate.sh"

mutation_control VERIFY_SH "$PLUGIN_ROOT/engine-bootstrap-templates/verify.sh" \
  "$PLUGIN_ROOT/tests/paths-frontmatter/preserved.sh" \
  "a gate that counts no block-list items" \
  sed 's/{ body = body "\\n" uncomment(\$0) }/{ body = body }/'
