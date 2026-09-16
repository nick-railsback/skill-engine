#!/usr/bin/env bash
# Control for: a quoted `"null"` is a string, not a YAML null. A scratch copy
# of the checker lets the no-value match see through double quotes, as a
# match made after the quotes are deleted would.
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
# shellcheck source=../../lib/mutate.sh
. "$PLUGIN_ROOT/tests/lib/mutate.sh"

# The no-value match admits a double quote on either side.

mutation_control VERIFY_SH "$PLUGIN_ROOT/engine-bootstrap-templates/verify.sh" \
  "$SUITE_DIR/preserved.sh" \
  "a gate that reads a quoted null as no value" \
  sed 's/\^(~|null|Null|NULL|\[{\]\[}\])\$/^"?(~|null|Null|NULL|[{][}])"?$/'
