#!/usr/bin/env bash
# citation_labels.py — the label↔fragment agreement gate.
#
# What this suite freezes:
#
#   1. The equivalence rule. A label's rendered range and its URL's fragment
#      agree when the starts match and either the ends match or the label is
#      single-sided against a degenerate fragment. `L3` and `#L3-L3` are one
#      range in two spellings, not drift — and a corpus citing single lines
#      would otherwise false-fail on every one of them.
#
#   2. The label grammar's reach. A range token is found anywhere inside the
#      label, not anchored to either end, because the corpora in this repo
#      write it leading (`[L260-L279]`), trailing (`` [`README.md` L15-L27] ``)
#      and enclosed (`` [`server.py` L129-L160 `Foo.__init__`] ``). Three
#      separators are accepted — ASCII hyphen, en dash, em dash — and an
#      optional leading `#` for the in-label fragment spelling
#      `` [`docs/tasks.md#L126`] ``. All four are live in examples/.
#
#   3. That a label rendering two range tokens is reported, never guessed at,
#      and does not gate: it is unverifiable by this grammar, not known-wrong.
#
#   4. The negative control. A planted disagreement must be flagged and must
#      exit non-zero. Without this, a green run proves nothing — a detector
#      that never fires and a corpus that never drifts look identical.
#
#   5. The standing gate: every corpus in this repository agrees today. This
#      is the part that has value past the defect that prompted it — it holds
#      for a hand edit and for any future rewriter, not just for
#      repin_citations.py.
#
# Fixtures are written to a throwaway tmpdir. Read-only over this repository.
#
# -e is intentionally omitted: every assertion must run and report, not
# abort at the first red one.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
TESTS_ROOT="$PLUGIN_ROOT/tests"

LABELS_PY="$TESTS_ROOT/citation_labels.py"

pass_count=0
fail_count=0
note_count=0

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

note() {
  local label="$1"
  shift
  printf '  NOTE  %s\n' "$label"
  if [ "$#" -gt 0 ]; then
    printf '        %s\n' "$@"
  fi
  note_count=$((note_count + 1))
}

json_field() {
  printf '%s' "$1" | jq -r "$2" 2>/dev/null || printf ''
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/citation-labels.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# scan <references-dir> — sets SCAN_OUT (JSON) and SCAN_RC.
SCAN_OUT=""
SCAN_RC=0
scan() {
  SCAN_OUT="$(python3 "$LABELS_PY" "$1" --json 2>&1)"
  SCAN_RC=$?
}

# assert_field <label> <jq-filter> <expected>
assert_field() {
  local label="$1" filter="$2" want="$3" got
  got="$(json_field "$SCAN_OUT" "$filter")"
  if [ "$got" = "$want" ]; then
    pass "$label"
  else
    fail "$label" "expected $filter = $want, got: $got"
  fi
}

section "helper present"

if [ -f "$LABELS_PY" ]; then
  pass "present: ${LABELS_PY#"$TESTS_ROOT"/}"
else
  fail "present: ${LABELS_PY#"$TESTS_ROOT"/}"
  printf '\n  %s passed, %s failed, %s noted\n' "$pass_count" "$fail_count" "$note_count"
  exit 1
fi

B="https://github.com/o/r/blob"
SHA="0123456789abcdef0123456789abcdef01234567"

# ---------------------------------------------------------------------------
section "every label shape in the corpora is read correctly"

AGREE="$WORK/agree"
mkdir -p "$AGREE"
{
  # Shapes that render a range and agree with it.
  echo "bare label: [L260-L279]($B/$SHA/verify.sh#L260-L279)."
  echo ""
  echo "backticked basename: [\`08-pipeline.md\` L3-L10]($B/$SHA/docs/08-pipeline.md#L3-L10)."
  echo ""
  echo "full path: [\`tests/doctrine.sh\` L381-L416]($B/$SHA/tests/doctrine.sh#L381-L416)."
  echo ""
  echo "en dash: [\`README.md\` L15–L27]($B/$SHA/README.md#L15-L27)."
  echo ""
  echo "em dash: [\`README.md\` L31—L64]($B/$SHA/README.md#L31-L64)."
  echo ""
  echo "no second L: [\`a.md\` L5-9]($B/$SHA/a.md#L5-L9)."
  echo ""
  echo "in-label fragment: [\`docs/tasks.md#L126\`]($B/$SHA/docs/tasks.md#L126)."
  echo ""
  echo "enclosed by a trailing symbol: [\`server.py\` L129-L160 \`Foo.__init__\`]($B/$SHA/server.py#L129-L160)."
  echo ""
  echo "single-sided against degenerate: [\`b.md\` L3]($B/$SHA/b.md#L3-L3)."
  echo ""
  echo "single-sided against single: [\`c.md\` L84]($B/$SHA/c.md#L84)."
  echo ""
  # Shapes that render no range: skipped, never guessed at.
  echo "heading label: [\`tool-and-output.md\` § Cache garbage collection]($B/$SHA/tool.md#L72-L133)."
  echo ""
  echo "path-only label: [\`bin/cache-git.sh\`]($B/$SHA/bin/cache-git.sh#L1-L33)."
  echo ""
  echo "bare url, no label at all: $B/$SHA/d.md#L1-L4"
} > "$AGREE/shapes.md"

scan "$AGREE"
assert_field "every citation with a fragment range is counted" '.citations_with_range' 13
assert_field "ten labels render a range" '.labels_with_range' 10
assert_field "all ten agree" '.agree' 10
assert_field "none disagree" '.disagree' 0
assert_field "none ambiguous" '.ambiguous' 0
if [ "$SCAN_RC" -eq 0 ]; then
  pass "exit 0 on an agreeing corpus"
else
  fail "exit 0 on an agreeing corpus" "got rc=$SCAN_RC"
fi

# ---------------------------------------------------------------------------
section "negative control: a planted disagreement is flagged"

DRIFT="$WORK/drift"
mkdir -p "$DRIFT"
{
  echo "stale label, correct href: [L1028-L1103]($B/$SHA/verify.sh#L1312-L1387)."
  echo ""
  echo "stale label with a path: [\`cache-and-clone.md\` L73-L179]($B/$SHA/cache.md#L226-L332)."
  echo ""
  echo "stale start only: [\`a.md\` L4-L9]($B/$SHA/a.md#L5-L9)."
  echo ""
  echo "stale end only: [\`b.md\` L5-L8]($B/$SHA/b.md#L5-L9)."
  echo ""
  echo "single-sided label, non-degenerate fragment: [\`c.md\` L5]($B/$SHA/c.md#L5-L9)."
  echo ""
  echo "agrees, to prove the detector is selective: [\`d.md\` L1-L2]($B/$SHA/d.md#L1-L2)."
} > "$DRIFT/drift.md"

scan "$DRIFT"
assert_field "all five disagreements are found" '.disagree' 5
assert_field "the agreeing citation is not swept up" '.agree' 1
if [ "$SCAN_RC" -eq 1 ]; then
  pass "exit 1 on a disagreeing corpus"
else
  fail "exit 1 on a disagreeing corpus" "got rc=$SCAN_RC"
fi

got="$(json_field "$SCAN_OUT" '.disagreements[0] | "\(.label_range[0])-\(.label_range[1]) vs \(.fragment_range[0])-\(.fragment_range[1])"')"
if [ "$got" = "1028-1103 vs 1312-1387" ]; then
  pass "the report names both ranges, so a reader can see which one moved"
else
  fail "the report names both ranges" "got: $got"
fi

reported="$(python3 "$LABELS_PY" "$DRIFT" 2>&1)"
if printf '%s' "$reported" | grep -q '^\[FAIL\]' \
  && printf '%s' "$reported" | grep -Fq 'label renders L1028-L1103, url resolves #L1312-L1387'; then
  pass "the human-readable report names the file, the label and the href"
else
  fail "the human-readable report names the file, the label and the href" "$reported"
fi

# ---------------------------------------------------------------------------
section "an ambiguous label is reported, not guessed, and does not gate"

MULTI="$WORK/multi"
mkdir -p "$MULTI"
{
  echo "two tokens: [\`a.md\` L3-L5 and L6-L7]($B/$SHA/a.md#L3-L5)."
  echo ""
  echo "a path that itself looks like a range: [\`src/L10.py\` L5-L9]($B/$SHA/src/L10.py#L5-L9)."
} > "$MULTI/multi.md"

scan "$MULTI"
assert_field "both ambiguous labels are surfaced" '.ambiguous' 2
assert_field "neither is counted as agreeing" '.agree' 0
assert_field "neither is counted as disagreeing" '.disagree' 0
if [ "$SCAN_RC" -eq 0 ]; then
  pass "an ambiguous label does not gate — unverifiable is not known-wrong"
else
  fail "an ambiguous label does not gate" "got rc=$SCAN_RC"
fi
if python3 "$LABELS_PY" "$MULTI" 2>&1 | grep -q '^\[NOTE\]'; then
  pass "the report says so on a NOTE line rather than staying silent"
else
  fail "the report says so on a NOTE line rather than staying silent"
fi

# ---------------------------------------------------------------------------
section "an empty corpus is N/A, not a pass"

EMPTY="$WORK/empty"
mkdir -p "$EMPTY"
printf 'Prose with no citation at all.\n' > "$EMPTY/none.md"
out="$(python3 "$LABELS_PY" "$EMPTY" 2>&1)"
if printf '%s' "$out" | grep -q '^\[N/A\]'; then
  pass "a corpus rendering no line range reports [N/A]"
else
  fail "a corpus rendering no line range reports [N/A]" "$out"
fi

# ---------------------------------------------------------------------------
section "standing gate: every corpus in this repository agrees"

CORPORA="$REPO_ROOT/.claude/skills/skill-engine-context/references"
for refs in "$CORPORA" "$REPO_ROOT"/examples/*/references; do
  [ -d "$refs" ] || continue
  rel="${refs#"$REPO_ROOT"/}"
  scan "$refs"
  if [ "$SCAN_RC" -ne 0 ] && [ "$SCAN_RC" -ne 1 ]; then
    fail "$rel scanned" "citation_labels.py exited $SCAN_RC: $SCAN_OUT"
    continue
  fi
  d="$(json_field "$SCAN_OUT" '.disagree')"
  n="$(json_field "$SCAN_OUT" '.labels_with_range')"
  a="$(json_field "$SCAN_OUT" '.ambiguous')"
  if [ "$d" = "0" ]; then
    pass "$rel: $n labels render a line range, 0 disagree"
  else
    fail "$rel: $d label(s) disagree with their own href" \
      "$(json_field "$SCAN_OUT" '.disagreements[] | "\(.reference):\(.line)  \(.label)"')"
  fi
  if [ "$a" != "0" ]; then
    note "$rel: $a label(s) render more than one range — agreement not decidable" \
      "$(json_field "$SCAN_OUT" '.ambiguous_labels[] | "\(.reference):\(.line)  \(.label)"')"
  fi
done

printf '\n  %s passed, %s failed, %s noted\n' "$pass_count" "$fail_count" "$note_count"
[ "$fail_count" -eq 0 ]
