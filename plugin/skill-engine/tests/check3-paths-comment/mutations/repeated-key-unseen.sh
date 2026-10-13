#!/usr/bin/env bash
# Control for: a repeated top-level key fails on its own. A scratch copy of
# the checker deduplicates the keys before looking for repeats, so it never
# finds one, and a named `paths:` over an empty one fails on the paths:
# count alone.
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
# shellcheck source=../../lib/mutate.sh
. "$PLUGIN_ROOT/tests/lib/mutate.sh"

# The repeated-key loop's input line, matched whole. Read from
# here-documents so no quote in either line needs escaping.
IFS= read -r old <<'LINE'
    done < <(printf '%s\n' "$fm" | grep -oE '^[A-Za-z0-9_.-]+:' | sed 's/:$//' | sort | uniq -d)
LINE
IFS= read -r new <<'LINE'
    done < <(printf '%s\n' "$fm" | grep -oE '^[A-Za-z0-9_.-]+:' | sed 's/:$//' | sort -u | uniq -d)
LINE

mutation_control VERIFY_SH "$PLUGIN_ROOT/engine-bootstrap-templates/verify.sh" \
  "$SUITE_DIR/preserved.sh" \
  "a repeated-key check that never sees a repeat" \
  swap_line "$old" "$new"
