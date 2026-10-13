#!/usr/bin/env bash
# Control for: a flow sequence whose items sit on the lines after the key is
# accepted. A scratch copy of the checker also calls a sequence unclosed
# whenever the key line leaves it open, without looking for its `]` on the
# lines below, so every multi-line sequence is rejected: the shortcut that
# refuses a spelling YAML accepts.
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
# shellcheck source=../../lib/mutate.sh
. "$PLUGIN_ROOT/tests/lib/mutate.sh"

# Inserted after the whole-value unclosed test.

mutation_control VERIFY_SH "$PLUGIN_ROOT/engine-bootstrap-templates/verify.sh" \
  "$SUITE_DIR/preserved.sh" \
  "a gate that rejects every multi-line flow sequence" \
  insert_after 'unclosed = \(v ~' 'if (key ~ /^\[/ && key !~ /\]$/) unclosed = 1'
