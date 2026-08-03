#!/usr/bin/env bash
# Black-box oracle: the plugin manifest declares zero hooks, the manifest
# auditor mechanically enforces that (in both its exit behavior and its own
# prose), and no shipped file — script or doc — still claims a SessionStart
# hook exists, is planned, or backs a routing/state-tracking behavior.
#
# Runs entirely from a temp dir plus read-only greps against the real repo.
# Writes nothing to the repo itself (see the read-only section at the end).

# -e is intentionally omitted, same reasoning as the auditor this exercises:
# every assertion must run and report, not abort at the first red one.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

REAL_HOOKS_AUDIT="$REPO_ROOT/plugin/skill-engine/tests/hooks-audit.sh"
REAL_MANIFEST="$REPO_ROOT/plugin/skill-engine/.claude-plugin/plugin.json"
REAL_PLUGIN_DIR="$REPO_ROOT/plugin/skill-engine"
REAL_SECURITY="$REPO_ROOT/SECURITY.md"
REAL_README="$REPO_ROOT/README.md"
REAL_SETTINGS="$REPO_ROOT/.claude/settings.json"
REAL_DELIVERY="$REPO_ROOT/plugin/skill-engine/docs/04-delivery.md"
REAL_CONFIGSET_SKILL="$REPO_ROOT/plugin/skill-engine/skills/config-set/SKILL.md"
REAL_REVIEW_SKILL="$REPO_ROOT/plugin/skill-engine/skills/review/SKILL.md"

DOC_FILES="$REAL_SECURITY $REAL_README $REAL_SETTINGS $REAL_DELIVERY $REAL_CONFIGSET_SKILL $REAL_REVIEW_SKILL"
WATCHED_FILES="$REAL_SECURITY $REAL_README $REAL_SETTINGS $REAL_DELIVERY $REAL_CONFIGSET_SKILL $REAL_REVIEW_SKILL $REAL_HOOKS_AUDIT $REAL_MANIFEST"

TMP_BASE="$(mktemp -d)"
trap 'rm -rf "$TMP_BASE"' EXIT

PASS_COUNT=0
FAIL_COUNT=0

section() {
  printf '\n── %s ──\n' "$1"
}

pass() {
  printf 'PASS: %s\n' "$1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  printf 'FAIL: %s\n' "$1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

# --- assertion helpers -------------------------------------------------

# assert_absent DESC FILE SUBSTRING — FILE must not contain the literal SUBSTRING.
assert_absent() {
  local desc="$1" file="$2" needle="$3"
  if [ ! -f "$file" ]; then
    fail "$desc (file not found: $file)"
    return
  fi
  if grep -F -q -- "$needle" "$file"; then
    fail "$desc"
  else
    pass "$desc"
  fi
}

# assert_absent_re DESC FILE EXTENDED_REGEX (case-insensitive) — must not match.
assert_absent_re() {
  local desc="$1" file="$2" pattern="$3"
  if [ ! -f "$file" ]; then
    fail "$desc (file not found: $file)"
    return
  fi
  if grep -Eiq -- "$pattern" "$file"; then
    fail "$desc"
  else
    pass "$desc"
  fi
}

# Builds a fixture repo layout under a fresh temp dir mirroring just enough
# of the real tree (.claude/settings.json, plugin manifest, a copy of the
# real hooks-audit.sh under plugin/skill-engine/tests/) for hooks-audit.sh's
# own BASH_SOURCE-relative path resolution to find the fixtures instead of
# the real repo files. Runs the copied script and records its exit code in
# LAST_CODE.
run_fixture() {
  local manifest_json="$1"
  local workdir
  workdir="$(mktemp -d "$TMP_BASE/fixture.XXXXXX")"
  mkdir -p "$workdir/.claude"
  mkdir -p "$workdir/plugin/skill-engine/.claude-plugin"
  mkdir -p "$workdir/plugin/skill-engine/tests"
  printf '%s' '{"hooks": {}}' >"$workdir/.claude/settings.json"
  printf '%s' "$manifest_json" >"$workdir/plugin/skill-engine/.claude-plugin/plugin.json"
  cp "$REAL_HOOKS_AUDIT" "$workdir/plugin/skill-engine/tests/hooks-audit.sh"
  bash "$workdir/plugin/skill-engine/tests/hooks-audit.sh" >/dev/null 2>&1
  LAST_CODE=$?
  rm -rf "$workdir"
}

# assert_eventual_exit DESC MANIFEST_JSON EXPECTED_POST_FIX_EXIT_CODE
# Runs the real (currently unmodified) hooks-audit.sh against a fixture
# manifest and checks it against the exit code the manifest shape should
# produce once the auditor enforces zero declared hooks. Until that
# rewrite lands, several of these are expected to disagree with today's
# script — that disagreement is the point of this file.
assert_eventual_exit() {
  local desc="$1" manifest_json="$2" expected="$3"
  run_fixture "$manifest_json"
  if [ "$LAST_CODE" -eq "$expected" ]; then
    pass "$desc"
  else
    fail "$desc (hooks-audit.sh currently exits $LAST_CODE for this manifest, not $expected)"
  fi
}

# --- read-only guarantee: snapshot before any real-file work ----------

hash_watched() {
  local f
  for f in $WATCHED_FILES; do
    if [ -f "$f" ]; then
      shasum -a 256 "$f"
    else
      printf 'MISSING %s\n' "$f"
    fi
  done
}

BEFORE_HASH="$(hash_watched)"

# --- manifest hooks: zero declared -------------------------------------

section "manifest hooks: zero declared"

MANIFEST_EMPTY_OBJECT='{"hooks": {}}'
MANIFEST_KEY_ABSENT='{}'
MANIFEST_ONE_SESSIONSTART='{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "echo test"}]}]}}'
MANIFEST_OTHER_EVENT='{"hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": "echo test"}]}]}}'

assert_eventual_exit \
  "manifest with an explicit empty hooks object is accepted" \
  "$MANIFEST_EMPTY_OBJECT" 0

assert_eventual_exit \
  "manifest with the hooks key absent entirely is accepted" \
  "$MANIFEST_KEY_ABSENT" 0

assert_eventual_exit \
  "manifest carrying a restored single SessionStart hook is rejected" \
  "$MANIFEST_ONE_SESSIONSTART" 1

assert_eventual_exit \
  "manifest carrying any other single event hook is rejected" \
  "$MANIFEST_OTHER_EVENT" 1

# --- audit script prose: zero-hook language -----------------------------

section "audit script prose: zero-hook language"

assert_absent_re \
  "hooks-audit.sh's own text no longer describes the manifest check as 'exactly one'" \
  "$REAL_HOOKS_AUDIT" 'exactly one'

assert_absent_re \
  "hooks-audit.sh's own text no longer names a required SessionStart bootstrap" \
  "$REAL_HOOKS_AUDIT" 'SessionStart bootstrap'

# Split on clause boundaries (period/semicolon) before matching so a line
# that happens to mention both words in two unrelated clauses — e.g. today's
# OK message, "settings ship zero hooks; manifest declares only the
# allowlisted SessionStart bootstrap" — isn't mistaken for the manifest
# clause itself using zero-hook language.
if tr ';.' '\n\n' <"$REAL_HOOKS_AUDIT" | grep -iE 'manifest' | grep -qiE 'zero'; then
  pass "hooks-audit.sh's own text states the manifest check enforces zero hooks"
else
  fail "hooks-audit.sh's own text states the manifest check enforces zero hooks"
fi

# --- no stray routing claims --------------------------------------------

section "no stray routing claims"

# --exclude-dir scoped to this oracle's own directory: this file's source
# necessarily contains the literal search string below (it is the search
# argument), so an unscoped recursive grep over $REAL_PLUGIN_DIR would match
# the oracle itself regardless of what the shipped plugin does.
if grep -rFl --exclude-dir=sessionstart-hook-decision 'first interaction will route to' "$REAL_PLUGIN_DIR" >/dev/null 2>&1; then
  fail "no shipped file under plugin/skill-engine prints a first-interaction routing claim"
else
  pass "no shipped file under plugin/skill-engine prints a first-interaction routing claim"
fi

# --- doc consistency: forbidden substrings absent -----------------------

section "doc consistency: forbidden substrings absent"

for f in $DOC_FILES; do
  rel="${f#"$REPO_ROOT"/}"
  assert_absent "$rel: no state/current.json reference" "$f" 'state/current.json'
  assert_absent "$rel: no workflow_set reference" "$f" 'workflow_set'
done

# --- doc consistency: stale hook-decision sentences removed -------------

section "doc consistency: stale hook-decision sentences removed"

assert_absent \
  "SECURITY.md: no 'declares exactly one hook' claim" \
  "$REAL_SECURITY" 'The plugin declares exactly one hook'

assert_absent \
  "README.md: no 'declares only the single SessionStart bootstrap' claim" \
  "$REAL_README" 'the plugin declares only the single'

assert_absent \
  ".claude/settings.json: no 'one narrow SessionStart bootstrap hook' claim" \
  "$REAL_SETTINGS" 'one narrow SessionStart bootstrap hook'

assert_absent \
  "04-delivery.md: no 'will ship exactly one inline SessionStart hook' claim" \
  "$REAL_DELIVERY" 'A future engine plugin will ship exactly one inline'

assert_absent \
  "config-set/SKILL.md: no 'the existing SessionStart hook' claim" \
  "$REAL_CONFIGSET_SKILL" 'the existing `SessionStart` hook'

assert_absent \
  "review/SKILL.md: no 'the SessionStart hook already uses for state/current.json' claim" \
  "$REAL_REVIEW_SKILL" 'the `SessionStart` hook already uses for `state/current.json`'

# --- read-only: repo untouched ------------------------------------------

section "read-only: repo untouched"

AFTER_HASH="$(hash_watched)"

if [ "$BEFORE_HASH" = "$AFTER_HASH" ]; then
  pass "this run left the manifest, the auditor, and the six doc files byte-for-byte unchanged"
else
  fail "this run left the manifest, the auditor, and the six doc files byte-for-byte unchanged"
fi

# --- summary --------------------------------------------------------------

printf '\nPassed: %d\n' "$PASS_COUNT"
printf 'Failed: %d\n' "$FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
