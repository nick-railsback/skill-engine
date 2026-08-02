#!/usr/bin/env bash
# Black-box oracle for the self-referential reference corpus at
# .claude/skills/skill-engine-context/references/ and its
# research/source-paths.json pin: the corpus's own GitHub permalinks (and
# the source-paths.json entry they all derive from) must be pinned to the
# *current* commit, not a commit frozen in the past with nothing noticing
# drift afterward. Every assertion below is read-only over the live repo —
# git plumbing and file/JSON inspection only, no network I/O, no writes to
# anything outside a throwaway tmpdir.
#
# -e is intentionally omitted: every assertion must run and report, not
# abort at the first red one.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

SOURCE_PATHS_JSON="$REPO_ROOT/.claude/skills/skill-engine-context/research/source-paths.json"
REFERENCES_DIR="$REPO_ROOT/.claude/skills/skill-engine-context/references"
CI_LOCAL_SH="$REPO_ROOT/scripts/ci-local.sh"
PERMALINK_SCAN="$SCRIPT_DIR/permalink_scan.py"
WIRING_SCAN="$SCRIPT_DIR/staleness_wiring_scan.py"

SOURCE_ID="nick-railsback-skill-engine"
# The recorded date this same pin held before a refresh — a literal fact
# about this repo's current (unrefreshed) state, used only to prove the
# date actually moved rather than merely re-affirming a value that was
# already true.
OLD_RECORDED_DATE="2026-07-17"

pass_count=0
fail_count=0

section() {
  printf '\n── %s ──\n' "$1"
}

pass() {
  printf '  PASS  %s\n' "$1"
  pass_count=$((pass_count + 1))
}

fail() {
  local label="$1"
  shift
  printf '  FAIL  %s\n' "$label"
  if [ "$#" -gt 0 ]; then
    printf '        %s\n' "$@"
  fi
  fail_count=$((fail_count + 1))
}

sha256_of_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# jq_check <json> <jq-boolean-program> — true (rc 0) only when the input is
# valid JSON AND the boolean program evaluates true.
jq_check() {
  local json="$1" program="$2"
  printf '%s' "$json" | jq -e "$program" >/dev/null 2>&1
}

# jq_field <json> <jq-program> — the raw text of a jq scalar extraction, or
# empty on any parse/eval failure.
jq_field() {
  local json="$1" program="$2"
  printf '%s' "$json" | jq -r "$program" 2>/dev/null || printf ''
}

section "supporting files present"

for f in "$SOURCE_PATHS_JSON" "$CI_LOCAL_SH" "$PERMALINK_SCAN" "$WIRING_SCAN"; do
  if [ -f "$f" ]; then
    pass "present: ${f#"$REPO_ROOT"/}"
  else
    fail "present: ${f#"$REPO_ROOT"/}"
  fi
done

if [ -d "$REFERENCES_DIR" ]; then
  pass "present: ${REFERENCES_DIR#"$REPO_ROOT"/}"
else
  fail "present: ${REFERENCES_DIR#"$REPO_ROOT"/}"
fi

# Read-only guarantee: hash every file this oracle inspects before running
# anything else, compared again at the very end.
WATCHED_FILES="$SOURCE_PATHS_JSON $CI_LOCAL_SH"
hash_watched() {
  local f
  for f in $WATCHED_FILES; do
    [ -f "$f" ] && sha256_of_file "$f" || printf 'MISSING %s\n' "$f"
  done
  if [ -d "$REFERENCES_DIR" ]; then
    local md
    for md in "$REFERENCES_DIR"/*.md; do
      [ -f "$md" ] && sha256_of_file "$md"
    done
  fi
}
BEFORE_HASH="$(hash_watched)"

HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"

ENTRY_JSON="$(jq -c --arg id "$SOURCE_ID" '.sources[] | select(.id == $id)' "$SOURCE_PATHS_JSON" 2>/dev/null || true)"
ENTRY_SHA="$(jq_field "$ENTRY_JSON" '.lifecycle.last_checked_sha // empty')"
ENTRY_DATE="$(jq_field "$ENTRY_JSON" '.lifecycle.last_checked // empty')"

# ---------------------------------------------------------------------------
# pin refreshed: source-paths.json's own record of the corpus's upstream
# commit points at the repo's actual current HEAD, and the date attached to
# that record moved off its old value.
# ---------------------------------------------------------------------------

section "pin refreshed"

if [ -n "$HEAD_SHA" ] && [ -n "$ENTRY_SHA" ] && [ "$ENTRY_SHA" = "$HEAD_SHA" ]; then
  pass "source-paths.json's $SOURCE_ID entry: lifecycle.last_checked_sha equals current HEAD"
else
  fail "source-paths.json's $SOURCE_ID entry: lifecycle.last_checked_sha equals current HEAD" \
    "lifecycle.last_checked_sha=${ENTRY_SHA:-<missing>} HEAD=${HEAD_SHA:-<unresolved>}"
fi

if [ -n "$ENTRY_DATE" ] && [ "$ENTRY_DATE" != "$OLD_RECORDED_DATE" ]; then
  pass "source-paths.json's $SOURCE_ID entry: lifecycle.last_checked date moved off its old recorded value"
else
  fail "source-paths.json's $SOURCE_ID entry: lifecycle.last_checked date moved off its old recorded value" \
    "lifecycle.last_checked=${ENTRY_DATE:-<missing>} (old recorded value: $OLD_RECORDED_DATE)"
fi

# ---------------------------------------------------------------------------
# no stale sha / single consistent sha / permalinks resolve structurally:
# every GitHub permalink in the 9 flat reference files shares one sha, that
# sha is the one source-paths.json now records, none of them still name the
# old superseded sha, and each one's path + line range is structurally real
# at the sha it cites (path exists; start <= end <= that blob's line count).
# No semantic/content matching is attempted here — structural resolution
# only, by design.
# ---------------------------------------------------------------------------

section "reference corpus permalinks: pin consistency"

SCAN_OUT=""
if [ -f "$PERMALINK_SCAN" ] && [ -d "$REFERENCES_DIR" ]; then
  SCAN_OUT="$(python3 "$PERMALINK_SCAN" "$REFERENCES_DIR" --repo-root "$REPO_ROOT" \
    --expected-sha "${ENTRY_SHA:-__no_pin_recorded__}" 2>/dev/null || true)"
fi

if jq_check "$SCAN_OUT" '.file_count == 9'; then
  pass "reference corpus: exactly 9 primary files scanned under references/"
else
  fail "reference corpus: exactly 9 primary files scanned under references/" \
    "scan output: ${SCAN_OUT:-<empty — scan did not run>}"
fi

if jq_check "$SCAN_OUT" '.permalink_count > 0'; then
  pass "reference corpus: the scan found GitHub permalinks to check (non-vacuous)"
else
  fail "reference corpus: the scan found GitHub permalinks to check (non-vacuous)" \
    "scan output: ${SCAN_OUT:-<empty — scan did not run>}"
fi

if jq_check "$SCAN_OUT" '.stale_hits == 0'; then
  pass "reference corpus: no permalink still cites the superseded pin"
else
  fail "reference corpus: no permalink still cites the superseded pin" \
    "stale hits: $(jq_field "$SCAN_OUT" '.stale_hits // "?"') of $(jq_field "$SCAN_OUT" '.permalink_count // "?"') permalinks still cite $(jq_field "$SCAN_OUT" '.old_pinned_sha // "?"')"
fi

if jq_check "$SCAN_OUT" '.single_consistent_sha == true'; then
  pass "reference corpus: every permalink shares one sha, and it is source-paths.json's recorded pin"
else
  fail "reference corpus: every permalink shares one sha, and it is source-paths.json's recorded pin" \
    "distinct shas found: $(jq_field "$SCAN_OUT" '.distinct_shas // [] | join(", ")') — expected only: $(jq_field "$SCAN_OUT" '.expected_sha // "?"')"
fi

if jq_check "$SCAN_OUT" '.structural_fail_count == 0'; then
  pass "reference corpus: every permalink's path + line range resolves structurally at the sha it cites"
else
  fail "reference corpus: every permalink's path + line range resolves structurally at the sha it cites" \
    "$(jq_field "$SCAN_OUT" '.structural_fail_count // "?"') of $(jq_field "$SCAN_OUT" '.permalink_count // "?"') permalinks failed; sample: $(jq_field "$SCAN_OUT" '[.structural_failures_sample[]? | "\(.file):\(.path)#L\(.start)-L\(.end) — \(.reason)"] | join(" | ")')"
fi

# ---------------------------------------------------------------------------
# staleness check wired and report-only: scripts/ci-local.sh's run_examples
# invokes some script under plugin/skill-engine/tests/ that plausibly
# reports how far this same corpus's pin has drifted from HEAD, and that
# script always exits 0 (report-only — it must never gate the suite) while
# printing a numeric drift measure. Nothing pins the script's name or path
# ahead of time; it is discovered by grep, not assumed.
# ---------------------------------------------------------------------------

section "staleness/drift visibility wired into ci-local.sh, report-only"

WIRE_OUT=""
if [ -f "$WIRING_SCAN" ] && [ -f "$CI_LOCAL_SH" ]; then
  WIRE_OUT="$(python3 "$WIRING_SCAN" "$CI_LOCAL_SH" --repo-root "$REPO_ROOT" 2>/dev/null || true)"
fi

WIRED="$(jq_field "$WIRE_OUT" '.wired // false')"

if [ "$WIRED" = "true" ]; then
  pass "ci-local.sh's run_examples invokes a script plausibly named for this corpus's pin staleness/drift"
else
  fail "ci-local.sh's run_examples invokes a script plausibly named for this corpus's pin staleness/drift" \
    "wiring scan output: ${WIRE_OUT:-<empty — scan did not run>}"
fi

if [ "$WIRED" = "true" ]; then
  if jq_check "$WIRE_OUT" '.ran == true and .exit_code == 0'; then
    pass "the wired-in script exits 0 against the current repo (report-only, never gates)"
  else
    fail "the wired-in script exits 0 against the current repo (report-only, never gates)" \
      "ran=$(jq_field "$WIRE_OUT" '.ran // "?"') exit_code=$(jq_field "$WIRE_OUT" '.exit_code // "?"') command=$(jq_field "$WIRE_OUT" '.command // "?"')"
  fi

  if jq_check "$WIRE_OUT" '.stdout_has_digit == true'; then
    pass "the wired-in script prints a numeric drift measure"
  else
    fail "the wired-in script prints a numeric drift measure" \
      "stdout: $(jq_field "$WIRE_OUT" '.stdout // "?"')"
  fi
else
  fail "the wired-in script exits 0 against the current repo (report-only, never gates)" \
    "no wiring found in run_examples yet; nothing to run"
  fail "the wired-in script prints a numeric drift measure" \
    "no wiring found in run_examples yet; nothing to run"
fi

# ---------------------------------------------------------------------------
# Read-only: this run never modifies source-paths.json, any reference file,
# or ci-local.sh.
# ---------------------------------------------------------------------------

section "read-only: files under test untouched"

AFTER_HASH="$(hash_watched)"

if [ "$BEFORE_HASH" = "$AFTER_HASH" ]; then
  pass "this run left source-paths.json, the reference files, and ci-local.sh byte-for-byte unchanged"
else
  fail "this run left source-paths.json, the reference files, and ci-local.sh byte-for-byte unchanged"
fi

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"

[ "$fail_count" -eq 0 ]
