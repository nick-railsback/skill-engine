#!/usr/bin/env bash
# Control for: the checker names neither Python nor yq. A scratch copy of the
# checker gains an inert line that looks for python3 — behaviour unchanged,
# dependency introduced.
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
# shellcheck source=../../lib/mutate.sh
. "$PLUGIN_ROOT/tests/lib/mutate.sh"

# Inserted after the navigator's relative-path assignment, inside the gate.

mutation_control VERIFY_SH "$PLUGIN_ROOT/engine-bootstrap-templates/verify.sh" \
  "$SUITE_DIR/preserved.sh" \
  "a checker that reaches for python3" \
  insert_after '^nav_rel="SKILL.md"$' 'command -v python3 >/dev/null 2>&1 || true'
