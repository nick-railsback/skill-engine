#!/usr/bin/env bash
# Hooks-audit: mechanical enforcement of the no-silent-hooks doctrine.
# Asserts two committed facts:
#   (a) the bundled .claude/settings.json ships an explicitly empty hooks
#       block (zero hooks injected into the user's settings); and
#   (b) the plugin manifest declares zero hooks. Any hook at all —
#       restored or newly added, any event key, any matcher group, any
#       command — fails.
# The check is two jq reads of small committed files — trivially
# sub-second. A failure is meant to be self-explaining (names the file
# and the unexpected shape) so a red CI run needs no spelunking.

# -e is intentionally omitted: the script accumulates failures in `fail` and
# must run every assertion (and print every diagnostic) before exiting with
# the aggregate code. `set -e` would abort on the first failing check and
# defeat that. Do not add -e.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

SETTINGS_FILE="$REPO_ROOT/.claude/settings.json"
MANIFEST_FILE="$PLUGIN_ROOT/.claude-plugin/plugin.json"

if ! command -v jq >/dev/null 2>&1; then
  echo "hooks-audit: FAIL — jq is required but not on PATH. Install jq via your package manager (e.g. 'brew install jq' or 'apt-get install jq')." >&2
  exit 1
fi

fail=0

# Assertion (a): bundled settings ship zero hooks.
# Strict '== {}' (not '.hooks // {}') so removing the explicit empty block
# also fails — the visible commitment must stay present, not just absent.
if [ ! -f "$SETTINGS_FILE" ]; then
  echo "hooks-audit: FAIL — settings file not found at $SETTINGS_FILE" >&2
  fail=1
elif ! jq -e '.hooks == {}' "$SETTINGS_FILE" >/dev/null 2>&1; then
  echo "hooks-audit: FAIL — $SETTINGS_FILE: .hooks is not an explicit empty object. Found: $(jq -c '.hooks' "$SETTINGS_FILE" 2>/dev/null)" >&2
  fail=1
fi

# Assertion (b): plugin manifest declares zero hooks.
# Tolerant '(.hooks // {}) == {}', not strict — spec.md criterion 1 allows
# either an explicit empty object or the key's outright absence, unlike
# assertion (a)'s settings file, where the empty block itself is the
# visible commitment. Deleting the manifest's hooks key entirely (this
# chunk's own approach) must pass this check, not just emptying it.
if [ ! -f "$MANIFEST_FILE" ]; then
  echo "hooks-audit: FAIL — plugin manifest not found at $MANIFEST_FILE" >&2
  fail=1
elif ! jq -e '(.hooks // {}) == {}' "$MANIFEST_FILE" >/dev/null 2>&1; then
  echo "hooks-audit: FAIL — $MANIFEST_FILE: .hooks is not empty. Found: $(jq -c 'try .hooks catch "<.hooks is not an object>"' "$MANIFEST_FILE" 2>/dev/null)" >&2
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "hooks-audit: OK — settings ship zero hooks; manifest declares zero hooks."
fi
exit "$fail"
