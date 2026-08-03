#!/usr/bin/env bash
# Feature-scoped test runner for the eval-results renderer's parsing of a
# results-*.json file:
#
#   engine-bootstrap-templates/eval/render-eval-results.sh.template
#   .claude/skills/skill-engine-context/evals/render-eval-results.sh
#
# Both are exercised. The second is the first with <area-domain> substituted,
# and a parsing defect fixed in one and not the other ships to every user of
# the engine while this repo's own dogfood instance stays broken (or the
# reverse). Every assertion below runs against both.
#
# What is under test. run-eval.sh writes each entry on ONE line:
#
#   {"query": "...", "expected": "...", "persona": "...", "runs": [...]}
#
# so the renderer's awk has to find the runs array on a line that also
# carries three free-text values authored by whoever wrote the eval corpus.
# Locating it by "the first [ on the line" is not a parse of that shape: any
# bracket inside a query, expected, or persona value comes first and takes
# the field's place. The consequence is worse than a garbled line — a runs
# value that is neither pass, fail, nor error votes nothing, so the entry
# leaves the pass-rate denominator entirely and the report quietly
# understates both the pass rate and the corpus size.
#
# Fixtures are hand-authored JSON with outcomes known by construction; the
# expected pass rates below are counted by hand from the fixture, never by
# re-deriving what the renderer computes.
#
# -e is intentionally omitted: every assertion must run and report, not
# abort at the first red one.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

TEMPLATE="$PLUGIN_ROOT/engine-bootstrap-templates/eval/render-eval-results.sh.template"
DOGFOOD="$REPO_ROOT/.claude/skills/skill-engine-context/evals/render-eval-results.sh"

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

TMPDIR_CASE="$(mktemp -d "${TMPDIR:-/tmp}/eval-renderer.XXXXXX")"
cleanup() { rm -rf "$TMPDIR_CASE"; }
trap cleanup EXIT

section "renderers present"

for f in "$TEMPLATE" "$DOGFOOD"; do
  if [ -f "$f" ]; then
    pass "present: ${f#"$REPO_ROOT"/}"
  else
    fail "present: ${f#"$REPO_ROOT"/}"
  fi
done

# The template carries the <area-domain> placeholder and refuses to run
# until it is substituted, so it is materialised once here exactly the way
# engine-bootstrap stamps it.
RENDER_FROM_TEMPLATE="$TMPDIR_CASE/render-from-template.sh"
if [ -f "$TEMPLATE" ]; then
  sed 's/<area-domain>/fixture/g' "$TEMPLATE" > "$RENDER_FROM_TEMPLATE"
fi

# render <renderer> <results-json> — the renderer's stdout, or empty on any
# non-zero exit (asserted separately where it matters).
render() {
  bash "$1" "$2" 2>/dev/null || printf ''
}

# each_renderer <label> <results-json> <predicate> — runs <predicate> with
# the rendered output for both renderers and records one assertion covering
# the pair, so a fix landing in only one of them cannot go green.
each_renderer() {
  local label="$1" results="$2" predicate="$3"
  local r out why=""
  for r in "$RENDER_FROM_TEMPLATE" "$DOGFOOD"; do
    if [ ! -f "$r" ]; then
      why="$why [${r##*/}: renderer not present]"
      continue
    fi
    out="$(render "$r" "$results")"
    if ! "$predicate" "$out"; then
      why="$why [${r##*/}: $(printf '%s' "$out" | tr '\n' '~')]"
    fi
  done
  if [ -z "$why" ]; then
    pass "$label"
  else
    fail "$label" "$why"
  fi
}

# ---------------------------------------------------------------------------
# A two-entry corpus. Both entries pass all three runs, so the only correct
# report is `overall: 2 / 2` with both marked [pass]. The first entry's
# query carries a bracketed token — the shape any eval corpus documenting a
# marker, a citation, or an optional argument will contain sooner or later.
# ---------------------------------------------------------------------------

BRACKET_QUERY="$TMPDIR_CASE/results-bracket-query.json"
cat > "$BRACKET_QUERY" <<'JSON'
{
  "schema_version": 1,
  "started_at": "2026-01-01T00:00:00Z",
  "runs_per_query": 3,
  "entries": [
    {"query": "what does the [FLICKER] marker mean?", "expected": "evaluation-and-audit", "persona": "domain-expert", "runs": ["pass","pass","pass"]},
    {"query": "plain query with no brackets", "expected": "evaluation-and-audit", "persona": "domain-expert", "runs": ["pass","pass","pass"]}
  ]
}
JSON

section "a bracket in the query does not hijack the runs array"

has_overall_2_of_2() { printf '%s' "$1" | grep -qF 'overall: 2 / 2'; }
each_renderer "an entry whose query contains a bracket stays in the pass-rate denominator (overall: 2 / 2)" \
  "$BRACKET_QUERY" has_overall_2_of_2

bracketed_entry_passes() {
  printf '%s' "$1" | grep -qF '[pass] what does the [FLICKER] marker mean?'
}
each_renderer "the bracketed entry's three passing runs are read as passes, not discarded" \
  "$BRACKET_QUERY" bracketed_entry_passes

bracketed_entry_runs_verbatim() {
  printf '%s' "$1" | grep -qF 'marker mean? -> evaluation-and-audit | pass,pass,pass'
}
each_renderer "the bracketed entry's per-entry line reports its real outcomes, not text lifted out of the query" \
  "$BRACKET_QUERY" bracketed_entry_runs_verbatim

no_bracket_text_as_outcome() {
  ! printf '%s' "$1" | grep -qF '| FLICKER'
}
each_renderer "no text from inside the query is ever emitted as a run outcome" \
  "$BRACKET_QUERY" no_bracket_text_as_outcome

# ---------------------------------------------------------------------------
# The same hijack from the other two free-text fields on the line, and from
# a bracket that appears AFTER the runs array. `expected` in particular is a
# reference filename, which is exactly where a bracketed qualifier lands.
# ---------------------------------------------------------------------------

BRACKET_OTHERS="$TMPDIR_CASE/results-bracket-others.json"
cat > "$BRACKET_OTHERS" <<'JSON'
{
  "schema_version": 1,
  "started_at": "2026-01-01T00:00:00Z",
  "runs_per_query": 3,
  "entries": [
    {"query": "first", "expected": "refs/a [primary]", "persona": "domain-expert", "runs": ["pass","pass","fail"]},
    {"query": "second", "expected": "refs/b", "persona": "newcomer [first-week]", "runs": ["fail","fail","fail"]},
    {"query": "third", "expected": "refs/c", "persona": "domain-expert", "runs": ["pass","pass","pass"], "note": "see [12-evaluation.md]"}
  ]
}
JSON

section "brackets in expected, persona, and trailing fields are equally inert"

# Counted by hand from the fixture: entry 1 votes pass (2 of 3), entry 2
# votes fail (0 of 3), entry 3 votes pass (3 of 3) — 2 of 3 overall.
others_overall_2_of_3() { printf '%s' "$1" | grep -qF 'overall: 2 / 3'; }
each_renderer "a bracket in expected, in persona, or in a field after runs leaves every entry countable (overall: 2 / 3)" \
  "$BRACKET_OTHERS" others_overall_2_of_3

others_personas_intact() {
  printf '%s' "$1" | grep -qF 'domain-expert: 2 / 2' \
    && printf '%s' "$1" | grep -qF 'newcomer [first-week]: 0 / 1'
}
each_renderer "per-persona rows keep their bracketed persona names and their real counts" \
  "$BRACKET_OTHERS" others_personas_intact

others_flicker_flagged() {
  printf '%s' "$1" | grep -qF '[FLICKER] first'
}
each_renderer "the mixed-outcome entry is still flagged as flickering once its runs are read correctly" \
  "$BRACKET_OTHERS" others_flicker_flagged

# ---------------------------------------------------------------------------
# The silent-loss half of the same defect. An entry whose runs carry no
# recognised outcome votes nothing: it is neither in the pass-rate
# denominator nor on the errored-entries line, so the corpus shrinks with
# nothing in the report saying so. Whatever the cause — a mangled parse, a
# hand-edited results file, a future run-eval.sh writing an outcome this
# renderer does not know — the report must not quietly get smaller.
# ---------------------------------------------------------------------------

UNRECOGNISED="$TMPDIR_CASE/results-unrecognised.json"
cat > "$UNRECOGNISED" <<'JSON'
{
  "schema_version": 1,
  "started_at": "2026-01-01T00:00:00Z",
  "runs_per_query": 3,
  "entries": [
    {"query": "countable", "expected": "refs/a", "persona": "domain-expert", "runs": ["pass","pass","pass"]},
    {"query": "unaccounted", "expected": "refs/b", "persona": "domain-expert", "runs": ["skipped","skipped","skipped"]}
  ]
}
JSON

section "an entry carrying no recognised outcome is reported, never dropped"

unrecognised_reported() {
  printf '%s' "$1" | grep -qE 'unaccounted entries \(no recognised run outcome\): 1'
}
each_renderer "an entry whose runs carry no recognised outcome is surfaced on its own line" \
  "$UNRECOGNISED" unrecognised_reported

unrecognised_overall_1_of_1() {
  printf '%s' "$1" | grep -qF 'overall: 1 / 1'
}
each_renderer "the one countable entry still reports correctly alongside it" \
  "$UNRECOGNISED" unrecognised_overall_1_of_1

# An all-error entry keeps its own existing line and must not be relabelled
# as unaccounted: "the runner failed" and "this outcome means nothing to me"
# are different reports.
ERRORED="$TMPDIR_CASE/results-errored.json"
cat > "$ERRORED" <<'JSON'
{
  "schema_version": 1,
  "started_at": "2026-01-01T00:00:00Z",
  "runs_per_query": 3,
  "entries": [
    {"query": "countable", "expected": "refs/a", "persona": "domain-expert", "runs": ["pass","pass","pass"]},
    {"query": "infra down", "expected": "refs/b", "persona": "domain-expert", "runs": ["error","error","error"]}
  ]
}
JSON

errored_still_errored() {
  printf '%s' "$1" | grep -qF 'errored entries (excluded from pass rate): 1' \
    && ! printf '%s' "$1" | grep -qF 'unaccounted entries'
}
each_renderer "an all-error entry keeps its existing errored-entries line and is not relabelled" \
  "$ERRORED" errored_still_errored

# ---------------------------------------------------------------------------
# The deltas path reads the same records stream, so a query that parses
# correctly on one side and not the other would fabricate a regression.
# ---------------------------------------------------------------------------

section "the delta path reads the same corrected records"

BASELINE="$TMPDIR_CASE/results-baseline.json"
cat > "$BASELINE" <<'JSON'
{
  "schema_version": 1,
  "started_at": "2026-01-01T00:00:00Z",
  "runs_per_query": 3,
  "entries": [
    {"query": "what does the [FLICKER] marker mean?", "expected": "evaluation-and-audit", "persona": "domain-expert", "runs": ["pass","pass","pass"]},
    {"query": "plain query with no brackets", "expected": "evaluation-and-audit", "persona": "domain-expert", "runs": ["pass","pass","pass"]}
  ]
}
JSON

delta_out=""
delta_why=""
for r in "$RENDER_FROM_TEMPLATE" "$DOGFOOD"; do
  [ -f "$r" ] || { delta_why="$delta_why [${r##*/}: renderer not present]"; continue; }
  delta_out="$(bash "$r" "$BRACKET_QUERY" "$BASELINE" 2>/dev/null || printf '')"
  if printf '%s' "$delta_out" | grep -qE 'REGRESSION|ERRORED|NEW'; then
    delta_why="$delta_why [${r##*/}: $(printf '%s' "$delta_out" | tr '\n' '~')]"
  fi
done
if [ -z "$delta_why" ]; then
  pass "an identical bracketed entry on both sides produces no regression, no [NEW], and no [ERRORED]"
else
  fail "an identical bracketed entry on both sides produces no regression, no [NEW], and no [ERRORED]" \
    "$delta_why"
fi

# ---------------------------------------------------------------------------
# The two renderers must not diverge: the dogfood copy is the template with
# <area-domain> substituted, and nothing else.
# ---------------------------------------------------------------------------

section "template and dogfood copy agree"

if [ -f "$TEMPLATE" ] && [ -f "$DOGFOOD" ]; then
  if diff -q <(sed 's/<area-domain>/skill-engine/g' "$TEMPLATE") "$DOGFOOD" >/dev/null 2>&1; then
    pass "the dogfood renderer is the template with <area-domain> substituted, byte for byte"
  else
    fail "the dogfood renderer is the template with <area-domain> substituted, byte for byte" \
      "$(diff <(sed 's/<area-domain>/skill-engine/g' "$TEMPLATE") "$DOGFOOD" | head -20 | tr '\n' '~')"
  fi
else
  fail "the dogfood renderer is the template with <area-domain> substituted, byte for byte" \
    "one of the two files is missing"
fi

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"

[ "$fail_count" -eq 0 ]
