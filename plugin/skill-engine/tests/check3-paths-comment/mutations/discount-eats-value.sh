#!/usr/bin/env bash
# Control for: a key that names at least one glob is accepted with a trailing
# comment, in the flow and comma-separated spellings. A scratch copy of the
# checker's comment discount throws away everything before the `#` along
# with the comment, so the globs go with it.
#
# The mutation sits inside the discount itself. An injection placed after
# the discount has run (on the key line or the value extracted from it)
# finds no `#` left to act on and changes nothing, which is how an earlier
# version of this control went dead without failing.
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
# shellcheck source=../../lib/mutate.sh
. "$PLUGIN_ROOT/tests/lib/mutate.sh"

mutation_control VERIFY_SH "$PLUGIN_ROOT/engine-bootstrap-templates/verify.sh" \
  "$SUITE_DIR/preserved.sh" \
  "a comment discount that empties a non-empty value" \
  sed 's/if (c == "#" \&\& p ~ \/\[\[:space:\]\]\/) break$/if (c == "#" \&\& p ~ \/[[:space:]]\/) { out = ""; break }/'
