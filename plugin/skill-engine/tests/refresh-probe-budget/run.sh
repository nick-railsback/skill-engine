#!/usr/bin/env bash
# Black-box oracle for chunk 06-refresh-probe-budget: REFRESH orders
# promoted sources by descending `importance` (tie-break: oldest recorded
# probe timestamp, never-probed first, further tie-break ascending source
# id), gates how many proceed to re-crawl behind `probe_budget`, names the
# skipped ones in a fixed sentence, fails loudly on an invalid budget
# before any network call, and STATUS renders importance and the budget's
# projected skip count. Prose-only skills get prose oracles (feature.md's
# own constraint): REFRESH is executed by the model, not by this harness,
# so criteria 2-6 are wrap-normalized text-presence checks against the
# three reference docs the model reads, not a live REFRESH run. Criterion
# 1 is the one piece with a concrete, executable artifact -- "the
# reference ... carries the jq or shell that produces the order" -- so it
# alone is extracted from the doc and RUN, never hand-reimplemented here
# (same "extract from the doc, don't reimplement" discipline
# tests/sparse-clone/run.sh uses for its git recipe).
#
# THE INVARIANTS (spec.md's six acceptance criteria):
#   1. Phase 1 orders promoted sources by descending importance (absent =>
#      3), ties broken by oldest recorded probe timestamp (never-probed
#      first), further ties by ascending source id; the doc states the
#      rule AND carries the jq/shell that produces the order.
#   2. probe_budget=N caps how many promoted sources proceed to re-crawl;
#      every in-scope source still gets its Phase 1 probe regardless; the
#      skip line "M of K sources skipped this session due to
#      probe_budget=N (next-eligible: <list>)" is documented.
#   3. probe_budget of 0, negative, or non-integer fails REFRESH at
#      activation, naming the field and the offending value, before any
#      network call.
#   4. probe_budget absent => every promoted source is re-crawled, in
#      criterion-1 order, and no skip line prints.
#   5. STATUS renders each source's importance (3 (default) when absent)
#      and, when a budget is set, the count of sources it would skip next
#      refresh.
#   6. refresh/SKILL.md is byte-identical to the pre-chunk baseline (it is
#      NOT in this chunk's declared scope -- 4 bytes of headroom per
#      feature.md's router-ceiling constraint).
#
# JUDGMENT CALLS -- spec.md is silent or ambiguous on these; the choices
# below are this oracle's, not the spec's, and are flagged in Track V's
# report as candidate ## Questions for the plan gate:
#
#   A. WHICH FIELD RECORDS THE LAST-PROBE TIMESTAMP. spec.md's own
#      `## Size class` note says this is deliberately open: "the state
#      field that records the last probe is a plan decision worth
#      predicting." The doctrine's literal text ties the tie-break field
#      to telemetry ("missing-from-telemetry" => `.engine-stats.json`'s
#      `sources_probed[].probed_at`), but that file is this chunk's own
#      declared Out-of-scope item ("Not shipped, not started here"). The
#      only per-source, already-shipped timestamp in `source-paths.json`
#      is `lifecycle.last_checked` (02-artifact-contract.md: "the
#      upstream HEAD SHA for git-managed sources at the most recent
#      successful probe" -- updated by REFRESH "on every freshness
#      pass"). This oracle's fixture uses `lifecycle.last_checked`,
#      matching the one field that already exists and that
#      tests/sparse-clone/run.sh's own fixture-writer already uses for
#      the same purpose. If the plan picks a different field, the fixture
#      is a plan-gate `adjust`, not a silent edit here.
#   B. "SOURCE ID" VS "PATH". spec.md's own criterion-1 prose says
#      "ascending source id"; the doctrine text it quotes says
#      "lexicographic ascending path" (`path` is not a universal field --
#      only `local-path`-kind sources carry one; `id` is). The prose check
#      below accepts either spelling ("id" or "path") near "ascending"
#      rather than picking a side.
#   C. THE SKIP LINE'S SURROUNDING QUOTE MARKS. 03-engine.md's own text
#      wraps the rendered sentence in a literal pair of double quotes
#      inside the backticks; two paragraphs later (REFRESH temporal-delta
#      verbiage) two other verbatim REFRESH lines are NOT double-quoted
#      that way. Read as a citation-formatting inconsistency, not part of
#      the literal stdout, so this oracle matches the sentence's static
#      substrings without requiring surrounding `"` characters.
#   D. WHICH FILE(S) HOUSE WHICH PIECE OF PROSE. Neither reference doc
#      says anything about probe_budget/importance yet, so there is no
#      existing anchor to pin exactly. Criterion 1 pins to Phase 1
#      specifically (spec.md's own words: "In Phase 1 the promoted
#      sources are ordered..."). Criteria 2-4 (budget cap, skip line,
#      absent-budget behavior) are checked against the UNION of three
#      windows -- Pre-flight, Phase 1, and Post-run summary, across both
#      reference docs -- since any of the three is a plausible, doctrine-
#      consistent home and spec.md does not say which. Criterion 5 is
#      checked against status/SKILL.md's whole (currently short) file,
#      for the same reason.
#
# EXPECTED RED RIGHT NOW: neither reference file mentions "importance" or
# "probe_budget" anywhere (confirmed by hand before writing this file), so
# every criterion-1..5 prose check below fails for genuine absence, and
# criterion 1's fenced-block extraction finds no block to extract at all
# (a clean, named FAIL -- "no snippet found" -- not a harness crash;
# nothing downstream of it runs). Criterion 6 is a PRESERVATION check and
# is expected to PASS right now and to keep passing through this chunk's
# own diff (refresh/SKILL.md is not in scope) -- see the retirement note
# at REFRESH_SKILL_BASELINE_SHA256 below for when it will legitimately go
# red for a reason that has nothing to do with this chunk.
#
# -e is intentionally omitted: every assertion runs and reports, not abort
# at the first red one. The scratch directory this file creates is
# removed on exit.
set -uo pipefail

# ---------------------------------------------------------------------------
# Setup: locate the repo, load the surfaces under test.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ROOT_MARKER="plugin/skill-engine/docs/02-artifact-contract.md"
find_root() {
  local d="$1"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    if [ -f "$d/$ROOT_MARKER" ]; then
      printf '%s\n' "$d"
      return 0
    fi
    d="$(dirname "$d")"
  done
  return 1
}
REPO_ROOT="$(find_root "$SCRIPT_DIR" || find_root "$PWD")"
if [ -z "$REPO_ROOT" ]; then
  echo "ERROR: cannot locate the repository root — no $ROOT_MARKER above $SCRIPT_DIR or $PWD." >&2
  exit 69
fi
PLUGIN_ROOT="$REPO_ROOT/plugin/skill-engine"

DRIFT_MD="$PLUGIN_ROOT/skills/refresh/references/drift-detection-and-phases.md"
MECHANICS_MD="$PLUGIN_ROOT/skills/refresh/references/tool-and-output-mechanics.md"
STATUS_SKILL="$PLUGIN_ROOT/skills/status/SKILL.md"
REFRESH_SKILL="$PLUGIN_ROOT/skills/refresh/SKILL.md"
FIXTURE="$SCRIPT_DIR/fixtures/source-paths.json"

for f in "$DRIFT_MD" "$MECHANICS_MD" "$STATUS_SKILL" "$REFRESH_SKILL" "$FIXTURE"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: expected surface is missing entirely: $f" >&2
    exit 69
  fi
done

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: '$1' not found on PATH (required for this oracle)." >&2
    exit 69
  }
}
need jq

pass_count=0
fail_count=0

banner() { printf '\n== %s ==\n' "$1"; }

pass() {
  printf '  PASS  %s\n' "$1"
  pass_count=$((pass_count + 1))
}

fail() {
  local label="$1"
  shift
  printf '  FAIL  %s\n' "$label"
  local detail
  for detail in "$@"; do
    printf '%s\n' "$detail" | sed 's/^/        /'
  done
  fail_count=$((fail_count + 1))
}

sha256_of_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# norm — collapse every run of whitespace, newlines included, to one
# space, then trim the ends. Every multi-word phrase assertion below runs
# against normalized text so a hand-wrapped line break can never hide a
# phrase from a naive line-oriented grep.
norm() { tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'; }
norm_str() { printf '%s' "$1" | norm; }

assert_str() {
  local label="$1" text="$2" lit="$3"
  if printf '%s' "$text" | grep -qF -- "$lit"; then
    pass "$label"
  else
    fail "$label" "string not found: $lit"
  fi
}

line_of() {
  local file="$1" pat="$2"
  grep -n -E -- "$pat" "$file" | head -n1 | cut -d: -f1
}

# section_lines <file> <start-ere> [<end-ere>] — lines from the first line
# matching <start-ere> (inclusive) to the line before the first
# subsequent match of <end-ere> (exclusive); to EOF when <end-ere> is
# omitted. Returns non-zero (empty stdout) when <start-ere> is not found.
section_lines() {
  local file="$1" start_pat="$2" end_pat="${3:-}"
  local start_line end_line
  start_line="$(line_of "$file" "$start_pat")"
  [ -n "${start_line:-}" ] || return 1
  end_line=""
  if [ -n "$end_pat" ]; then
    end_line="$(grep -n -E -- "$end_pat" "$file" | awk -F: -v s="$start_line" '$1 > s {print $1; exit}')"
  fi
  if [ -n "${end_line:-}" ]; then
    sed -n "${start_line},$((end_line - 1))p" "$file"
  else
    sed -n "${start_line},\$p" "$file"
  fi
}

# near <text> <anchor-ere> <needle-ere> <window> — true when <needle>
# occurs within <window> characters of some occurrence of <anchor> in
# <text>. 200/250/300, never above 255: BSD/macOS grep -E rejects an
# interval bound above 255, and the window applies on both sides of the
# anchor.
near() {
  local text="$1" anchor="$2" needle="$3" window="$4"
  printf '%s' "$text" \
    | grep -oiE ".{0,${window}}${anchor}.{0,${window}}" \
    | grep -qiE -- "$needle"
}

# near_all <text> <anchor-ere> <window> <needle-ere>... — every given
# needle occurs somewhere within <window> characters of some occurrence
# of <anchor> (not necessarily the same occurrence).
near_all() {
  local text="$1" anchor="$2" window="$3"
  shift 3
  local needle
  for needle in "$@"; do
    near "$text" "$anchor" "$needle" "$window" || return 1
  done
  return 0
}

# extract_fenced_lang <file> <needle> — prints the language tag ("bash",
# "sh", "shell", or "jq" — spec.md says "the jq or shell the reference
# carries") of the first matching fenced block in <file> whose body
# contains <needle> as a literal substring; prints nothing when none does.
extract_fenced_lang() {
  local file="$1" needle="$2"
  awk -v needle="$needle" '
    /^[[:space:]]*```(bash|sh|shell|jq)[[:space:]]*$/ {
      lang = $0
      sub(/^[[:space:]]*```/, "", lang)
      gsub(/[[:space:]]/, "", lang)
      infence = 1; buf = ""; next
    }
    /^[[:space:]]*```[[:space:]]*$/ {
      if (infence) {
        if (index(buf, needle) > 0 && !found) { print lang; found = 1; exit }
        infence = 0
      }
      next
    }
    infence { buf = buf $0 "\n" }
  ' "$file"
}

# extract_fenced_body <file> <needle> — prints the body of the first
# matching fenced block in <file> whose body contains <needle>; empty
# output (rc 1) when none does. Same file/needle as extract_fenced_lang,
# called separately for clarity over an encoding trick to smuggle two
# values through one command substitution.
extract_fenced_body() {
  local file="$1" needle="$2"
  awk -v needle="$needle" '
    /^[[:space:]]*```(bash|sh|shell|jq)[[:space:]]*$/ { infence = 1; buf = ""; next }
    /^[[:space:]]*```[[:space:]]*$/ {
      if (infence) {
        if (index(buf, needle) > 0 && !found) { printf "%s", buf; found = 1 }
        infence = 0
      }
      next
    }
    infence { buf = buf $0 "\n" }
    END { exit (found ? 0 : 1) }
  ' "$file"
}

WORK="$(mktemp -d -t skill-engine-refresh-probe-budget.XXXXXX)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Locate the three prose windows. Judgment call D (see header): criterion 1
# is pinned to Phase 1 specifically; criteria 2-4 are checked against the
# union of all three windows across both reference docs.
# ---------------------------------------------------------------------------

banner "locating prose windows"

PREFLIGHT_RAW="$(section_lines "$DRIFT_MD" '^## Pre-flight' '^## Phases')"
if [ -z "${PREFLIGHT_RAW:-}" ]; then
  echo "ERROR: cannot locate '## Pre-flight' in $DRIFT_MD" >&2
  exit 69
fi

PHASE1_RAW="$(section_lines "$DRIFT_MD" '^### Phase 1' '^### Re-read scoping')"
if [ -z "${PHASE1_RAW:-}" ]; then
  echo "ERROR: cannot locate '### Phase 1' in $DRIFT_MD" >&2
  exit 69
fi

POSTRUN_RAW="$(section_lines "$MECHANICS_MD" '^## Post-run summary')"
if [ -z "${POSTRUN_RAW:-}" ]; then
  echo "ERROR: cannot locate '## Post-run summary' in $MECHANICS_MD" >&2
  exit 69
fi

STATUS_RAW="$(cat "$STATUS_SKILL")"

PREFLIGHT_N="$(norm_str "$PREFLIGHT_RAW")"
PHASE1_N="$(norm_str "$PHASE1_RAW")"
POSTRUN_N="$(norm_str "$POSTRUN_RAW")"
STATUS_N="$(norm_str "$STATUS_RAW")"
COMBINED_N="$PREFLIGHT_N $PHASE1_N $POSTRUN_N"

pass "prose_windows_located"

# ===========================================================================
# Criterion 1 — Phase 1 orders promoted sources by descending importance,
# tie-break oldest probe timestamp (never-probed first), further tie-break
# ascending id; the doc states the rule and carries the jq/shell for it.
# ===========================================================================

banner "criterion 1 — ordering rule stated in prose (Phase 1)"

assert_str "c1_phase1_names_importance" "$PHASE1_N" 'importance'

if near "$PHASE1_N" 'importance' 'descend' 250; then
  pass "c1_ordered_by_descending_importance"
else
  fail "c1_ordered_by_descending_importance" \
    "expected 'importance' documented near 'descend(ing)' in the Phase 1 section"
fi

if near "$PHASE1_N" 'tie' 'oldest' 200; then
  pass "c1_ties_broken_by_oldest"
else
  fail "c1_ties_broken_by_oldest" \
    "expected a tie-break rule documented near 'oldest' in the Phase 1 section"
fi

if near "$PHASE1_N" '(never.probed|never probed)' '(first|front)' 150; then
  pass "c1_never_probed_sorts_first"
else
  fail "c1_never_probed_sorts_first" \
    "expected 'never-probed'/'never probed' documented near 'first'/'front' in the Phase 1 section"
fi

# Judgment call B: accept either "id" or "path" — spec.md's own criterion
# text says "ascending source id"; the doctrine text it quotes says
# "lexicographic ascending path". Flagged in Track V's report.
if near "$PHASE1_N" 'ascending' '(source ?id|\bid\b|path)' 150; then
  pass "c1_further_tiebreak_ascending_id_or_path"
else
  fail "c1_further_tiebreak_ascending_id_or_path" \
    "expected a further tie-break documented near 'ascending' and 'id' or 'path' in the Phase 1 section"
fi

banner "criterion 1 — executable ordering snippet (extracted from the doc, not reimplemented)"

NEEDLE='importance'
FENCE_LANG="$(extract_fenced_lang "$DRIFT_MD" "$NEEDLE")"
FENCE_SRC="$DRIFT_MD"
if [ -z "${FENCE_LANG:-}" ]; then
  FENCE_LANG="$(extract_fenced_lang "$MECHANICS_MD" "$NEEDLE")"
  FENCE_SRC="$MECHANICS_MD"
fi

if [ -z "${FENCE_LANG:-}" ]; then
  fail "c1_ordering_snippet_present_in_doc" \
    "no fenced \`\`\`bash/sh/shell/jq block mentioning 'importance' found in $DRIFT_MD or $MECHANICS_MD -- expected once the ordering recipe is documented"
  fail "c1_executed_order_matches_expected" \
    "skipped: no ordering snippet was extracted (see previous failure)"
  fail "c1_executed_no_skip_line_when_budget_absent" \
    "skipped: no ordering snippet was extracted (see previous failure)"
else
  pass "c1_ordering_snippet_present_in_doc"
  FENCE_BODY="$(extract_fenced_body "$FENCE_SRC" "$NEEDLE")"

  # Unsubstituted-placeholder guard, same discipline
  # tests/sparse-clone/run.sh's run_whole_block uses: if the extracted
  # block still carries a `<token>` (this doc's own convention for a
  # value the caller must substitute, e.g. cache-and-clone.md's
  # <source_id>/<url>), running it verbatim would misreport a doc
  # convention mismatch as "no ordering logic" instead of naming the
  # unsubstituted token.
  leftover_placeholder="$(printf '%s' "$FENCE_BODY" | grep -oE '<[A-Za-z_][^>]*>' | sort -u | tr '\n' ' ')"

  if [ -n "$leftover_placeholder" ]; then
    fail "c1_executed_order_matches_expected" \
      "extracted block from $FENCE_SRC (\`\`\`$FENCE_LANG) carries unsubstituted placeholder(s) this oracle does not know how to fill: $leftover_placeholder"
    fail "c1_executed_no_skip_line_when_budget_absent" \
      "skipped: unsubstituted placeholder(s) in the extracted block (see previous failure)"
  else
    SCRATCH="$WORK/exec"
    mkdir -p "$SCRATCH/research"
    cp "$FIXTURE" "$SCRATCH/research/source-paths.json"

    ORDER_OUT=""
    ORDER_RC=0
    if [ "$FENCE_LANG" = "jq" ]; then
      ORDER_OUT="$(cd "$SCRATCH" && CTX_ROOT="$SCRATCH" jq "$FENCE_BODY" research/source-paths.json 2>&1 < research/source-paths.json)"
      ORDER_RC=$?
    else
      ORDER_OUT="$(cd "$SCRATCH" && CTX_ROOT="$SCRATCH" bash -c "$FENCE_BODY" 2>&1 < research/source-paths.json)"
      ORDER_RC=$?
    fi

    # assert_order <id>... — every id must appear in $ORDER_OUT, at
    # strictly increasing byte offsets, tolerant of output shape (JSON
    # array, plain lines, a table) since spec.md does not pin the
    # snippet's output format.
    EXPECTED_ORDER=(zzz-high-importance beta-never-probed gamma-never-probed alpha-probed-recent)
    order_ok=1
    order_detail=""
    prev_off=-1
    for id in "${EXPECTED_ORDER[@]}"; do
      off="$(printf '%s' "$ORDER_OUT" | grep -bo -- "$id" | head -n1 | cut -d: -f1)"
      if [ -z "${off:-}" ]; then
        order_detail="${order_detail}'$id' not found in output. "
        order_ok=0
        continue
      fi
      if [ "$off" -le "$prev_off" ]; then
        order_detail="${order_detail}'$id' at offset $off is not after the previous id's offset $prev_off. "
        order_ok=0
      fi
      prev_off="$off"
    done

    if [ "$order_ok" -eq 1 ]; then
      pass "c1_executed_order_matches_expected"
    else
      fail "c1_executed_order_matches_expected" \
        "extracted from $FENCE_SRC (\`\`\`$FENCE_LANG); exit=$ORDER_RC" \
        "$order_detail" \
        "full output: ${ORDER_OUT:-<empty>}"
    fi

    # Cheap corroboration of criterion 4's "no skip line" half, for free
    # on this same execution: the fixture carries no probe_budget.
    if printf '%s' "$ORDER_OUT" | grep -qi 'skipped this session'; then
      fail "c1_executed_no_skip_line_when_budget_absent" \
        "no probe_budget was set in the fixture, but the output mentions a skip line: $ORDER_OUT"
    else
      pass "c1_executed_no_skip_line_when_budget_absent"
    fi
  fi
fi

# ===========================================================================
# Criterion 2 — probe_budget=N caps how many promoted sources proceed to
# re-crawl; every in-scope source still gets its Phase 1 probe; the skip
# line is documented as a template.
# ===========================================================================

banner "criterion 2 — probe_budget caps proceeding sources; every source still probed; skip line documented"

assert_str "c2_names_probe_budget" "$COMBINED_N" 'probe_budget'

if near_all "$COMBINED_N" 'probe_budget' 250 'at most' '(re-crawl|re-emit|proceed)'; then
  pass "c2_budget_caps_proceeding_sources"
else
  fail "c2_budget_caps_proceeding_sources" \
    "expected 'probe_budget' documented near 'at most' and 're-crawl'/'re-emit'/'proceed'"
fi

# Anchored on '(every|all) in-scope', not bare 'in-scope': the latter
# already occurs three times in the existing Pre-flight steps (3, 4, 6),
# none preceded by every/all ("A source is in-scope if all hold" has
# 'all' AFTER 'in-scope'), so a validation step landing near an existing
# 'in-scope' occurrence cannot false-PASS this the way c4's original
# 'absent' anchor did.
if near "$COMBINED_N" '(every|all) in-scope' '(ls-remote|phase 1 probe|head probe|probed)' 250; then
  pass "c2_every_in_scope_source_still_probed"
else
  fail "c2_every_in_scope_source_still_probed" \
    "expected '(every|all) in-scope' documented near a Phase 1 probe reference (ls-remote / Phase 1 probe / HEAD probe / probed)"
fi

# Judgment call C: static substrings only, no surrounding literal quote
# marks required (see header).
assert_str "c2_skip_line_static_prefix" "$COMBINED_N" 'sources skipped this session due to probe_budget='
assert_str "c2_skip_line_next_eligible" "$COMBINED_N" '(next-eligible:'

if near "$COMBINED_N" 'probe_budget' '(only.{0,20}probe step|model.token cost)' 250; then
  pass "c2_only_probe_step_budgeted_documented"
else
  fail "c2_only_probe_step_budgeted_documented" \
    "expected 'probe_budget' documented near 'only the probe step'/'model-token cost' (fetch cost is not budgeted)"
fi

# ===========================================================================
# Criterion 3 — invalid probe_budget (0, negative, non-integer) fails
# REFRESH at activation, naming the field and value, before any network
# call.
# ===========================================================================

banner "criterion 3 — invalid probe_budget fails at activation, before any network call"

# '(\b0\b|zero)', not a bare '0': a bare digit risks matching an
# unrelated ISO timestamp (e.g. 1970-01-01T00:00:00Z, the doctrine's own
# epoch value for "missing", which a doc author paraphrasing criterion 1
# nearby would plausibly reuse) within 250 chars of 'probe_budget'.
if near_all "$COMBINED_N" 'probe_budget' 250 '(\b0\b|zero)' 'negative' '(non.integer|not an integer)'; then
  pass "c3_rejects_zero_negative_noninteger"
else
  fail "c3_rejects_zero_negative_noninteger" \
    "expected 'probe_budget' documented near '0'/'zero', 'negative', and 'non-integer'/'not an integer'"
fi

if near "$COMBINED_N" 'probe_budget' '(fail|reject).{0,30}activation' 250; then
  pass "c3_fails_at_activation"
else
  fail "c3_fails_at_activation" \
    "expected 'probe_budget' documented near a fail/reject-at-activation phrase"
fi

if near "$COMBINED_N" 'probe_budget' '(names?|naming).{0,40}(value|offending)' 250; then
  pass "c3_names_field_and_value"
else
  fail "c3_names_field_and_value" \
    "expected 'probe_budget' documented near 'names'/'naming' the field and the offending value"
fi

if near "$COMBINED_N" 'probe_budget' '(before any network|no network call|before.{0,20}network)' 250; then
  pass "c3_before_any_network_call"
else
  fail "c3_before_any_network_call" \
    "expected 'probe_budget' documented near a before-any-network-call phrase"
fi

# ===========================================================================
# Criterion 4 — probe_budget absent: every promoted source is re-crawled,
# in criterion-1 order, and no skip line is printed.
# ===========================================================================

banner "criterion 4 — absent probe_budget processes every source, no skip line"

# Anchored on 'probe_budget', not the bare word 'absent': 'absent' alone
# already occurs several times in both docs today for unrelated fields
# (branch, archived), and near_all's "not necessarily the same
# occurrence" tolerance let one such unrelated 'absent' satisfy one
# needle while another satisfied the other -- a genuine false PASS caught
# by running this file (fixed here; 'probe_budget' does not exist in
# either doc yet, so this anchor alone guarantees the current red).
# '(all sources|every (source|promoted|in-scope))', not bare
# '(all|every)': the bare alternation matches as a substring of 'fall',
# 'small', 'call', 'installed', 'allow', etc., degrading the check to
# "'absent' is near 'probe_budget'" the moment any such word appears
# nearby — likely, in ordinary prose.
if near_all "$COMBINED_N" 'probe_budget' 250 'absent' '(all sources|every (source|promoted|in-scope))'; then
  pass "c4_absent_budget_processes_all_sources"
else
  fail "c4_absent_budget_processes_all_sources" \
    "expected 'probe_budget' documented near 'absent' and 'all sources'/'every source(s)'"
fi

if near_all "$COMBINED_N" 'probe_budget' 250 'absent' '(no skip|not.{0,15}print|skip line.{0,20}(not|never))'; then
  pass "c4_no_skip_line_when_absent_documented"
else
  fail "c4_no_skip_line_when_absent_documented" \
    "expected 'probe_budget' documented near 'absent' and a no-skip-line phrase"
fi

# ===========================================================================
# Criterion 5 — STATUS renders each source's importance (3 (default) when
# absent) and, when a budget is set, the projected skip count.
# ===========================================================================

banner "criterion 5 — STATUS renders importance and budget skip count"

assert_str "c5_status_names_importance" "$STATUS_N" 'importance'
assert_str "c5_status_names_probe_budget" "$STATUS_N" 'probe_budget'

if near "$STATUS_N" 'importance' '((default|⇒|=>).{0,15}3|3.{0,15}default)' 200; then
  pass "c5_importance_default_3_rendered"
else
  fail "c5_importance_default_3_rendered" \
    "expected 'importance' documented near a '3 (default)'-style phrase"
fi

if near "$STATUS_N" 'probe_budget' '(skip|would skip).{0,40}(count|number|sources)' 250; then
  pass "c5_budget_skip_count_rendered"
else
  fail "c5_budget_skip_count_rendered" \
    "expected 'probe_budget' documented near a skip-count rendering phrase"
fi

# ===========================================================================
# Criterion 6 — refresh/SKILL.md (not in this chunk's declared scope) is
# byte-identical to the pre-chunk baseline.
#
# RETIREMENT NOTE: a later chunk on this same feature branch rewrites
# refresh/SKILL.md by roadmap design (a router-file edit unrelated to this
# chunk's own probe_budget/importance scope). Once that lands, this pin
# goes permanently red for a reason that has nothing to do with chunk 06 —
# same shape as tests/sparse-clone/run.sh's own retired verify.sh pin (see
# that file's "Preservation" section comment). Retire this check then, the
# same way.
# ===========================================================================

banner "criterion 6 — refresh/SKILL.md is byte-identical to the pre-chunk baseline"

REFRESH_SKILL_BASELINE_SHA256="d5c3a569b61feb20a4f34df059c2dfb59d513161bb8e8380405807b63e2f4f8b"
refresh_skill_hash="$(sha256_of_file "$REFRESH_SKILL")"
if [ "$refresh_skill_hash" = "$REFRESH_SKILL_BASELINE_SHA256" ]; then
  pass "c6_refresh_skill_md_byte_identical_to_baseline"
else
  fail "c6_refresh_skill_md_byte_identical_to_baseline" \
    "expected sha256 $REFRESH_SKILL_BASELINE_SHA256, got $refresh_skill_hash"
fi

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------

banner "summary"
printf 'passed: %d   failed: %d\n' "$pass_count" "$fail_count"

if [ "$fail_count" -gt 0 ]; then
  exit 1
fi
exit 0
