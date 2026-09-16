#!/usr/bin/env bash
# Control for: a `#` not preceded by whitespace is part of the glob. A
# scratch copy of the checker strips every frontmatter line from its first
# `#`, whatever precedes it, before either the same-line or the block-list
# branch reads the key.
#
# Applied ahead of both branches, the strip still handles every genuine
# trailing comment the way the right rule does, so only the hash-inside-glob
# cells can turn it red. `docs/#-anchors/**` cannot: stripped, it is still
# `docs/`, one non-blank field. A quoted glob that opens with `#` can:
# stripped, it is a lone quote, and quotes are not counted.
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
# shellcheck source=../../lib/mutate.sh
. "$PLUGIN_ROOT/tests/lib/mutate.sh"

# Inserted after the admitted-key loop, which is the last reader of the
# frontmatter before the `paths:` logic. Read from a here-document so no
# quote in the line needs escaping.
IFS= read -r strip <<'LINE'
fm="$(printf '%s\n' "$fm" | sed 's/#.*$//')"
LINE

mutation_control VERIFY_SH "$PLUGIN_ROOT/engine-bootstrap-templates/verify.sh" \
  "$SUITE_DIR/preserved.sh" \
  "a comment strip that begins at the first hash" \
  insert_after 'done < <\(printf .* grep -oE ' "$strip"
