#!/usr/bin/env bash
# THE INVARIANT. A contextualizer plugin manifest template declares no
# `hooks` key. A contextualizer ships skills and reference text; nothing in
# it executes on a session event, and a template that hands a builder a
# `hooks` key hands them the opposite posture by default.
#
# WHY THIS IS A SEPARATE FILE. Syntax validation is not this property.
# `jq empty` accepts a manifest carrying `hooks` — it is valid JSON — so the
# rejection has to come from a structural read, and that read has to be
# runnable on its own against an arbitrary file: the must-reject case is
# exercised by pointing PLUGIN_MANIFEST_TEMPLATE at a scratch manifest that
# carries the key. Sourced by the suite beside it so one run reports in one
# format; executable on its own for the isolated case.
#
# -e is intentionally omitted: every assertion runs and reports, rather than
# the run aborting at the first failure.

set -uo pipefail

_HOOKS_CHECK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_HOOKS_PLUGIN_ROOT="$(cd "$_HOOKS_CHECK_DIR/../.." && pwd)"

PLUGIN_MANIFEST_TEMPLATE="${PLUGIN_MANIFEST_TEMPLATE:-$_HOOKS_PLUGIN_ROOT/engine-bootstrap-templates/contextualizer-plugin.json.template}"

# manifest_is_json <path> — 0 when the file exists, is non-empty, parses as
# JSON, and is a JSON object. Each step gates the next: a negative property
# read off a file that is absent or unparseable is not an answer.
manifest_is_json() {
  local f="$1"
  [ -f "$f" ] || return 1
  [ -s "$f" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq empty "$f" >/dev/null 2>&1 || return 1
  jq -e 'type == "object"' "$f" >/dev/null 2>&1 || return 1
  return 0
}

# manifest_declares_no_hooks <path> — 0 when the file is a readable JSON
# object in which no key named `hooks` is declared at any depth. Structural,
# not textual: a manifest whose description happens to use the word in a
# sentence is not declaring one, and a manifest that buries the key one
# level down is.
manifest_declares_no_hooks() {
  local f="$1"
  manifest_is_json "$f" || return 1
  jq -e '[paths | select(.[-1] == "hooks")] | length == 0' "$f" >/dev/null 2>&1 || return 1
  return 0
}

# Standalone run: the two assertions in the same shape the suite reports
# them, so the isolated case reads like any other run.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _hc_pass=0
  _hc_fail=0
  _hc_report() {
    if [ "$1" -eq 1 ]; then
      printf '  PASS  %s\n' "$2"
      _hc_pass=$((_hc_pass + 1))
    else
      printf '  FAIL  %s\n' "$2"
      _hc_fail=$((_hc_fail + 1))
    fi
  }

  ok=1
  manifest_is_json "$PLUGIN_MANIFEST_TEMPLATE" || ok=0
  _hc_report "$ok" "plugin manifest: the contextualizer manifest template is a JSON object"

  ok=1
  manifest_declares_no_hooks "$PLUGIN_MANIFEST_TEMPLATE" || ok=0
  _hc_report "$ok" "zero hooks: the contextualizer manifest template declares no hooks key"

  echo
  echo "Passed: $_hc_pass"
  echo "Failed: $_hc_fail"
  [ "$_hc_fail" -eq 0 ]
fi
