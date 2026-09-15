#!/usr/bin/env bash
# Control for the must-reject input: a plugin manifest template that
# declares a `hooks` key.
#
# `jq empty` accepts such a manifest — it is valid JSON — so syntax
# validation cannot be what rejects it. This runs the zero-hooks check in
# isolation against a scratch manifest: conforming first, so a green
# baseline is established rather than assumed, then the same file with the
# key added, which must flip the check red.
#
# -e is intentionally omitted so the two runs are both reached and their
# exit codes read, rather than the first non-zero one aborting the script.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fixture="$work/contextualizer-plugin.json.template"

cat > "$fixture" <<'JSON'
{
  "name": "<slug>-context",
  "version": "0.1.0",
  "description": "On-demand <area-domain> context, answered from reviewed sources.",
  "author": { "name": "<your-team>" },
  "license": "UNLICENSED"
}
JSON

if ! PLUGIN_MANIFEST_TEMPLATE="$fixture" bash "$SUITE_DIR/hooks-check.sh" >/dev/null 2>&1; then
  echo "pristine copy is already red"
  exit 0
fi

cat > "$fixture" <<'JSON'
{
  "name": "<slug>-context",
  "version": "0.1.0",
  "description": "On-demand <area-domain> context, answered from reviewed sources.",
  "author": { "name": "<your-team>" },
  "license": "UNLICENSED",
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "echo hello" } ] }
    ]
  }
}
JSON

if jq empty "$fixture" >/dev/null 2>&1; then
  echo "the mutated manifest is still valid JSON, as expected"
else
  echo "the mutated manifest is not valid JSON; this control is not testing what it claims"
  exit 0
fi

if PLUGIN_MANIFEST_TEMPLATE="$fixture" bash "$SUITE_DIR/hooks-check.sh" >/dev/null 2>&1; then
  echo "a manifest declaring hooks was accepted"
  exit 0
fi
echo "a manifest declaring hooks was rejected"
exit 1
