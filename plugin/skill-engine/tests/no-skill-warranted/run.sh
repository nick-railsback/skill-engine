#!/usr/bin/env bash
# Black-box oracle: DISCOVER's output vocabulary includes the null result.
# A registered, correctly covered source that legitimately warrants zero (or
# fewer than three) references is a nameable terminal outcome of a run —
# named on the proposal-threshold surface (the discover router's Proposal
# threshold section, or the reference file that section explicitly links),
# and given a concrete written shape inside the post-run summary's Coverage
# report component. That gives the "minimal-essence justification" the
# stamped verify.sh catalog-density WARN already sends a reviewer to find a
# defined form to be found, instead of a dangling pointer. The pipeline
# doctrine one-pager reflects the same vocabulary in its own post-run
# component list, and the existing proposal posture — default = propose, not
# exclude; Skip-reasoning reserved for clear non-fits — survives unchanged.
#
# All assertions are read-only greps over the three shipped prose files.
# Prose is normalized to a single line before matching (hard-wrapped
# markdown must never flip a result), and patterns match key terms plus
# co-occurrence within a window, never full sentences.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

DISCOVER_SKILL="$PLUGIN_ROOT/skills/discover/SKILL.md"
POST_RUN_REF="$PLUGIN_ROOT/skills/discover/references/proposal-and-post-run.md"
PIPELINE_DOC="$REPO_ROOT/plugin/skill-engine/docs/08-discover-pipeline.md"

pass_count=0
fail_count=0

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

# join_lines — collapse hard-wrapped markdown to one space-normalized line so
# a sentence split across wrapped lines is still matchable as one string.
join_lines() {
  tr '\n' ' ' | tr -s ' '
}

# extract_section <heading-text> <file> — the named "## " heading through
# (not including) the next "## " heading, or end of file.
extract_section() {
  awk -v want="$1" '
    $0 ~ ("^## " want) { f = 1; print; next }
    f && /^## / { exit }
    f { print }
  ' "$2"
}

# extract_between <start-substr> <end-substr> <file> — lines from the first
# line containing start (inclusive) to the next line containing end
# (exclusive). Both markers matched as literal substrings, not regexes.
extract_between() {
  awk -v s="$1" -v e="$2" '
    f && index($0, e) { exit }
    index($0, s) { f = 1 }
    f { print }
  ' "$3"
}

has_minimal_essence() {
  grep -qiE 'minimal[- ]essence' <<< "$1"
}

# me_windows <joined-text> — prints a lowercase window of text around every
# "minimal essence" / "minimal-essence" mention (≈300 chars before, ≈1300
# after each), concatenated. Empty when the term never appears. Windowing
# keeps co-occurrence checks anchored to the null-outcome material rather
# than satisfied by unrelated text elsewhere in the same file.
me_windows() {
  local rest prefix idx start
  rest="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  while :; do
    prefix="${rest%%minimal[ -]essence*}"
    [ "$prefix" = "$rest" ] && break
    idx="${#prefix}"
    start=$(( idx > 300 ? idx - 300 : 0 ))
    printf '%s ' "${rest:$start:1600}"
    rest="${rest:$(( idx + 15 ))}"
  done
}

echo
echo "── files under test exist ──"

for f in "$DISCOVER_SKILL" "$POST_RUN_REF" "$PIPELINE_DOC"; do
  if [ -f "$f" ]; then
    pass "shipped file present: ${f#"$REPO_ROOT"/}"
  else
    fail "shipped file present: ${f#"$REPO_ROOT"/}"
  fi
done

# ---------------------------------------------------------------------------
# The proposal-threshold surface: the router's Proposal threshold section,
# unioned with the reference file only when the section explicitly links it
# — the null outcome must be reachable from where the proposal posture is
# defined, in either location.
# ---------------------------------------------------------------------------

pt_section="$(extract_section 'Proposal threshold' "$DISCOVER_SKILL")"
pt_joined="$(join_lines <<< "$pt_section")"
surface="$pt_joined"
if grep -qF 'proposal-and-post-run.md' <<< "$pt_joined"; then
  surface="$surface $(join_lines < "$POST_RUN_REF")"
fi
surface_window="$(me_windows "$surface")"

echo
echo "── null-outcome vocabulary: reachable from the proposal-threshold surface ──"

if has_minimal_essence "$surface"; then
  pass "the proposal-threshold surface (section or its linked reference) names the minimal-essence outcome"
else
  fail "the proposal-threshold surface (section or its linked reference) names the minimal-essence outcome"
fi

if grep -qE 'zero|fewer than three' <<< "$surface_window" \
    && grep -qE 'legitimate|terminal|outcome' <<< "$surface_window"; then
  pass "zero (or fewer-than-three) references for a covered source is stated as a legitimate terminal outcome of a run"
else
  fail "zero (or fewer-than-three) references for a covered source is stated as a legitimate terminal outcome of a run"
fi

if grep -q 'skip-reasoning' <<< "$surface_window" \
    && grep -qE 'distinct|not|reserv|rather' <<< "$surface_window"; then
  pass "the null outcome is stated as distinct from Skip-reasoning, not folded into it"
else
  fail "the null outcome is stated as distinct from Skip-reasoning, not folded into it"
fi

# ---------------------------------------------------------------------------
# The post-run summary's Coverage report component: the justification has a
# concrete written shape, at explicitness parity with the component list's
# other documented cases (which carry quoted empty-case lines and a fenced
# example block).
# ---------------------------------------------------------------------------

coverage_component="$(extract_between '**Coverage report' '**Skip-reasoning' "$POST_RUN_REF")"
coverage_joined="$(join_lines <<< "$coverage_component")"
coverage_window="$(me_windows "$coverage_joined")"

echo
echo "── coverage-report shape: the justification has a defined written form ──"

if has_minimal_essence "$coverage_joined"; then
  pass "the Coverage report component names the minimal-essence case, so the stamped verify.sh WARN's pointer resolves to a defined form"
else
  fail "the Coverage report component names the minimal-essence case, so the stamped verify.sh WARN's pointer resolves to a defined form"
fi

if grep -q 'source_id' <<< "$coverage_window"; then
  pass "the shape names the source under justification by source_id"
else
  fail "the shape names the source under justification by source_id"
fi

if grep -qE 'file|corpus' <<< "$coverage_window" \
    && grep -qE '[0-9]|count|scale|n files' <<< "$coverage_window"; then
  pass "the shape carries the file count or corpus scale that triggered scrutiny"
else
  fail "the shape carries the file count or corpus scale that triggered scrutiny"
fi

if grep -qE 'rationale|justif|why|because' <<< "$coverage_window"; then
  pass "the shape carries the essence rationale for why few references cover the source"
else
  fail "the shape carries the essence rationale for why few references cover the source"
fi

if grep -qE 'e\.g\.|example|```|"' <<< "$coverage_window"; then
  pass "the shape is a concrete example form, at parity with the component list's other documented cases"
else
  fail "the shape is a concrete example form, at parity with the component list's other documented cases"
fi

# ---------------------------------------------------------------------------
# The pipeline doctrine one-pager: same vocabulary in both places it touches
# this contract — its own post-run component list, and the catalog-density
# heuristic bullet that names the justification.
# ---------------------------------------------------------------------------

doc_coverage_joined="$(extract_between '**Coverage report' '**Skip-reasoning' "$PIPELINE_DOC" | join_lines)"
catalog_density_joined="$(awk '
  /catalog-density/ { f = 1; print; next }
  f && (/^- / || /^$/) { exit }
  f { print }
' "$PIPELINE_DOC" | join_lines)"

echo
echo "── pipeline one-pager: vocabulary reflected in both touchpoints ──"

if has_minimal_essence "$doc_coverage_joined"; then
  pass "the one-pager's Coverage report component acknowledges the minimal-essence case"
else
  fail "the one-pager's Coverage report component acknowledges the minimal-essence case"
fi

if grep -qF '3 rows' <<< "$catalog_density_joined" \
    && has_minimal_essence "$catalog_density_joined" \
    && grep -qF 'post-run summary' <<< "$catalog_density_joined"; then
  pass "the catalog-density heuristic still offers a minimal-essence justification in the post-run summary as the alternative to ≥3 catalog rows"
else
  fail "the catalog-density heuristic still offers a minimal-essence justification in the post-run summary as the alternative to ≥3 catalog rows"
fi

# ---------------------------------------------------------------------------
# Proposal posture preserved: the null outcome joins the vocabulary without
# flipping the propose-by-default rule or repurposing Skip-reasoning.
# ---------------------------------------------------------------------------

skip_component_joined="$(extract_between '**Skip-reasoning' '**Proposed companions' "$POST_RUN_REF" | join_lines)"

echo
echo "── proposal posture preserved ──"

if grep -qF 'Default = propose, not exclude' <<< "$pt_joined"; then
  pass "the Proposal threshold section still carries the Default = propose, not exclude rule"
else
  fail "the Proposal threshold section still carries the Default = propose, not exclude rule"
fi

if grep -qiE 'skip-reasoning[^.]{0,120}non-fits' <<< "$pt_joined"; then
  pass "the Proposal threshold section still reserves Skip-reasoning for clear non-fits"
else
  fail "the Proposal threshold section still reserves Skip-reasoning for clear non-fits"
fi

if grep -qiE 'non-fits' <<< "$skip_component_joined" \
    && grep -qiE 'reserv|clear non-fits' <<< "$skip_component_joined"; then
  pass "the post-run summary's Skip-reasoning component still reserves the bucket for clear non-fits"
else
  fail "the post-run summary's Skip-reasoning component still reserves the bucket for clear non-fits"
fi

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
