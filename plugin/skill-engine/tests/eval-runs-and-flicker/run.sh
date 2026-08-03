#!/usr/bin/env bash
# Feature-scoped test runner for grounded_rate.py's multi-run grading path
# (SELF-AUDIT Check 8): each corpus prompt is graded from three runs instead
# of one, a prompt whose three runs disagree is surfaced as flickering
# rather than folded silently into the aggregate, and the published
# grounded_rate is a per-prompt majority vote over those three runs rather
# than a single-trial number. No live API calls, no network: the mocked
# cases replay pre-recorded responses via --mock-responses, and the one
# live-shaped case (below) swaps in a local, in-process fake SDK so the
# real per-prompt call loop runs end-to-end offline.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$PLUGIN_ROOT/tests/grounded_rate.py"
FIXTURES="$SCRIPT_DIR/fixtures"

pass_count=0
fail_count=0
created_dirs=()

cleanup_tmp() {
  local d
  for d in "${created_dirs[@]}"; do
    [ -e "$d" ] && rm -rf "$d"
  done
}
trap cleanup_tmp EXIT

# ----- fixture builders ---------------------------------------------------

write_skill_md() {
  local dir="$1"
  cat > "$dir/SKILL.md" <<'EOF'
---
name: example-context
description: Test contextualizer.
---

# Context navigator

Body content here.
EOF
}

write_references() {
  local dir="$1"
  local ref
  for ref in alpha beta gamma; do
    cat > "$dir/references/${ref}.md" <<EOF
# ${ref}

Reference body.
EOF
  done
}

# Three needs_reference prompts, ids n01-n03. Every three-run mock fixture
# below whose name doesn't say otherwise is sized to match this corpus.
fx_3prompts() {
  local dir="$1"
  write_skill_md "$dir"
  write_references "$dir"
  cat > "$dir/research/eval-prompts.json" <<'EOF'
{
  "schema_version": 1,
  "prompts": [
    {"id": "n01", "category": "needs_reference", "text": "Q1: what is Alpha's import path?"},
    {"id": "n02", "category": "needs_reference", "text": "Q2: list the v1->v2 migration steps."},
    {"id": "n03", "category": "needs_reference", "text": "Q3: signature of Gamma's interface."}
  ]
}
EOF
}

# Same three prompts plus a fourth (n04), for the "flicker survives an
# overall PASS" case.
fx_4prompts() {
  local dir="$1"
  write_skill_md "$dir"
  write_references "$dir"
  cat > "$dir/research/eval-prompts.json" <<'EOF'
{
  "schema_version": 1,
  "prompts": [
    {"id": "n01", "category": "needs_reference", "text": "Q1: what is Alpha's import path?"},
    {"id": "n02", "category": "needs_reference", "text": "Q2: list the v1->v2 migration steps."},
    {"id": "n03", "category": "needs_reference", "text": "Q3: signature of Gamma's interface."},
    {"id": "n04", "category": "needs_reference", "text": "Q4: what does Delta's constructor accept?"}
  ]
}
EOF
}

# A single prompt, for the case that isolates majority-vote aggregation
# from any cross-prompt averaging.
fx_1prompt() {
  local dir="$1"
  write_skill_md "$dir"
  write_references "$dir"
  cat > "$dir/research/eval-prompts.json" <<'EOF'
{
  "schema_version": 1,
  "prompts": [
    {"id": "n01", "category": "needs_reference", "text": "Q1: what is Alpha's import path?"}
  ]
}
EOF
}

# ----- assertion helpers ---------------------------------------------------

# Args: 1=case-name, 2=expected-rc, 3=expected-substring, 4=fixture-builder-fn, 5..=extra runner args
run_case() {
  local name="$1" exp_rc="$2" exp_substr="$3" builder="$4"
  shift 4
  local ctx_root
  ctx_root="$(mktemp -d -t skill-engine-eval-runs.XXXXXX)"
  created_dirs+=("$ctx_root")
  mkdir -p "$ctx_root/research" "$ctx_root/references"

  "$builder" "$ctx_root"

  local out rc
  out="$(python3 "$RUNNER" "$ctx_root" --threshold 0.80 "$@" 2>&1)" && rc=0 || rc=$?

  if [ "$rc" -eq "$exp_rc" ] && printf '%s' "$out" | grep -qF -- "$exp_substr"; then
    printf '  PASS  %s\n' "$name"
    pass_count=$((pass_count + 1))
  else
    printf '  FAIL  %s\n        expected rc=%d substr=%q\n        got rc=%d:\n%s\n' \
      "$name" "$exp_rc" "$exp_substr" "$rc" "$out"
    fail_count=$((fail_count + 1))
  fi
  rm -rf "$ctx_root"
}

# Like run_case, but additionally requires one or more substrings' ABSENCE
# (pipe-separated in $4). The rc check still gates the pass -- a wrong exit
# code fails the case on its own merits, so this can never pass merely
# because new vocabulary that doesn't exist yet also doesn't appear
# anywhere.
# Args: 1=case-name, 2=expected-rc, 3=must-contain-substring, 4=pipe-separated must-NOT-contain substrings, 5=fixture-builder-fn, 6..=extra runner args
run_case2() {
  local name="$1" exp_rc="$2" must="$3" deny_list="$4" builder="$5"
  shift 5
  local ctx_root
  ctx_root="$(mktemp -d -t skill-engine-eval-runs.XXXXXX)"
  created_dirs+=("$ctx_root")
  mkdir -p "$ctx_root/research" "$ctx_root/references"

  "$builder" "$ctx_root"

  local out rc
  out="$(python3 "$RUNNER" "$ctx_root" --threshold 0.80 "$@" 2>&1)" && rc=0 || rc=$?

  local denied=0 d
  local IFS='|'
  for d in $deny_list; do
    printf '%s' "$out" | grep -qF -- "$d" && denied=1
  done
  unset IFS

  if [ "$rc" -eq "$exp_rc" ] && printf '%s' "$out" | grep -qF -- "$must" && [ "$denied" -eq 0 ]; then
    printf '  PASS  %s\n' "$name"
    pass_count=$((pass_count + 1))
  else
    printf '  FAIL  %s\n        expected rc=%d, containing %q, NOT containing any of %q\n        got rc=%d:\n%s\n' \
      "$name" "$exp_rc" "$must" "$deny_list" "$rc" "$out"
    fail_count=$((fail_count + 1))
  fi
  rm -rf "$ctx_root"
}

# Runs the grader with --results-json and checks one jq boolean program
# against the written file. Isolates the structured-record assertions (as
# opposed to the stdout-substring assertions run_case/run_case2 make) so a
# --results-json regression is distinguishable from a stdout-formatting one.
# Args: 1=case-name, 2=expected-rc, 3=mock-file, 4=jq-program, 5=fixture-builder-fn
run_json_case() {
  local name="$1" exp_rc="$2" mock_file="$3" jq_program="$4" builder="$5"
  local ctx_root results_path
  ctx_root="$(mktemp -d -t skill-engine-eval-runs.XXXXXX)"
  created_dirs+=("$ctx_root")
  mkdir -p "$ctx_root/research" "$ctx_root/references"
  results_path="$(mktemp -t skill-engine-eval-runs-results.XXXXXX)"
  created_dirs+=("$results_path")

  "$builder" "$ctx_root"

  local out rc
  out="$(python3 "$RUNNER" "$ctx_root" --threshold 0.80 --mock-responses "$mock_file" \
        --results-json "$results_path" 2>&1)" && rc=0 || rc=$?

  if [ "$rc" -eq "$exp_rc" ] && jq -e "$jq_program" "$results_path" >/dev/null 2>&1; then
    printf '  PASS  %s\n' "$name"
    pass_count=$((pass_count + 1))
  else
    printf '  FAIL  %s\n        expected rc=%d and jq program %q to hold over --results-json\n        got rc=%d\n        --results-json contents:\n%s\n        stdout:\n%s\n' \
      "$name" "$exp_rc" "$jq_program" "$rc" "$(cat "$results_path" 2>/dev/null)" "$out"
    fail_count=$((fail_count + 1))
  fi
  rm -rf "$ctx_root"
}

# ----- three-runs-per-prompt shape enforcement -----------------------------

# A mock (and by the same per-prompt loop, a live invocation) that only
# supplies two runs for a prompt is rejected outright rather than graded
# on incomplete evidence -- three runs per prompt is the contract, not a
# ceiling.
run_case "mock supplying fewer than three runs per prompt is rejected" 1 \
  "exactly 3 runs per prompt" fx_3prompts \
  --mock-responses "$FIXTURES/bad-run-count-mocks.json"

# ----- unanimous agreement: no flicker either way --------------------------

run_case2 "three prompts unanimously grounded (3/3 each) PASS and carry no flicker marker" 0 \
  "100.0% (3/3 prompts grounded)" "flicker" fx_3prompts \
  --mock-responses "$FIXTURES/pass-unanimous-mocks.json"

run_case "unanimous-PASS run still names the corpus on the verdict line" 0 \
  "[corpus: eval-prompts.json]" fx_3prompts \
  --mock-responses "$FIXTURES/pass-unanimous-mocks.json"

# The cost figure is folded into the deny list (must NOT read as the
# zero-evidence default) alongside "flicker": a run that failed to read any
# of the three per-prompt runs at all would also show 0/3 grounded and no
# flicker marker, so "0/3, no flicker" alone doesn't yet prove the three
# runs were actually consulted. A nonzero cost does, because it can only
# come from summing real per-run token counts.
run_case2 "three prompts unanimously NOT grounded (0/3 each) FAIL and carry no flicker marker" 1 \
  "0.0% (0/3 prompts grounded)" "flicker|(cost: \$0.00)" fx_3prompts \
  --mock-responses "$FIXTURES/fail-unanimous-mocks.json"

run_case2 "unanimous-FAIL prompts keep their ordinary per-prompt failure marker" 1 \
  "[no-reference-opened]" "(cost: \$0.00)" fx_3prompts \
  --mock-responses "$FIXTURES/fail-unanimous-mocks.json"

# ----- unanimous FAIL, disagreeing reasons ---------------------------------

# `flicker` is computed from the boolean votes alone, so three runs that all
# fail count as unanimous even when they failed for different reasons. The
# marker was then read off run 1 and reported as "the shared failure marker
# when unanimous" — a claim nothing enforced.
#
# The cost is a misdiagnosis in the direction that wastes the most work. A
# prompt whose run 1 opened no reference and whose runs 2 and 3 died on a
# rate limit reports `n03 [no-reference-opened]`, and the maintainer reads
# the SELF-AUDIT findings table, concludes the navigator failed to route,
# and retunes SKILL.md against a signal that was two-thirds outage. The
# all-errored exit-2 gate cannot catch it: that requires an error on every
# run of every prompt, and here six of nine runs are clean.
#
# When the reasons disagree, the report has to say so — and has to keep
# naming the infrastructure failure, because that is the part that changes
# what the maintainer does next.

run_case "a unanimous FAIL whose runs failed for different reasons does not report run 1's marker as the shared one" 1 \
  "  n03 [mixed:" fx_3prompts \
  --mock-responses "$FIXTURES/fail-mixed-markers-mocks.json"

run_case "the mixed marker names every distinct reason, so a two-thirds outage cannot read as a routing failure" 1 \
  "  n03 [mixed:api-error+no-reference-opened]" fx_3prompts \
  --mock-responses "$FIXTURES/fail-mixed-markers-mocks.json"

run_case2 "a mixed-reason unanimous FAIL is not relabelled as flicker — the vote really was unanimous" 1 \
  "66.7% (2/3 prompts grounded)" "n03 [flicker]|(cost: \$0.00)" fx_3prompts \
  --mock-responses "$FIXTURES/fail-mixed-markers-mocks.json"

run_json_case "--results-json records the mixed marker too, not just stdout" 1 \
  "$FIXTURES/fail-mixed-markers-mocks.json" \
  '[.records[] | select(.prompt_id == "n03")] | length == 1 and (.[0].marker == "mixed:api-error+no-reference-opened") and (.[0].flicker == false)' \
  fx_3prompts

# The converse: when the three runs DO fail for one reason, the marker stays
# that one reason. Already asserted above against fail-unanimous-mocks.json
# ("unanimous-FAIL prompts keep their ordinary per-prompt failure marker"),
# and re-asserted here as the negative — a mixed: prefix must never appear
# on a genuinely uniform failure.
run_case2 "a genuinely uniform unanimous FAIL carries its plain marker, never a mixed: one" 1 \
  "  n02 [no-reference-opened]" "mixed:|(cost: \$0.00)" fx_3prompts \
  --mock-responses "$FIXTURES/fail-unanimous-mocks.json"

# ----- flickering entry: named distinctly from a stable entry --------------

run_case "a prompt split 2-1 across its three runs is reported as flickering, and the majority vote drives the aggregate rate" 1 \
  "66.7% (2/3 prompts grounded)" fx_3prompts \
  --mock-responses "$FIXTURES/flicker-mixed-mocks.json"

run_case "the flickering prompt's own line names it flicker, not a grading marker" 1 \
  "  n03 [flicker]" fx_3prompts \
  --mock-responses "$FIXTURES/flicker-mixed-mocks.json"

run_case2 "a stably-failing prompt alongside a flickering one keeps its own marker, not flicker's" 1 \
  "  n02 [no-reference-opened]" "n02 [flicker]|(cost: \$0.00)" fx_3prompts \
  --mock-responses "$FIXTURES/flicker-mixed-mocks.json"

# ----- flicker survives an overall PASS -------------------------------------

run_case "flicker on one prompt is surfaced even when the aggregate PASSes" 0 \
  "100.0% (4/4 prompts grounded)" fx_4prompts \
  --mock-responses "$FIXTURES/flicker-inside-pass-mocks.json"

run_case "the flickering prompt's marker still prints on an overall-PASS run" 0 \
  "  n04 [flicker]" fx_4prompts \
  --mock-responses "$FIXTURES/flicker-inside-pass-mocks.json"

# ----- majority-vote aggregation vs. a naive raw-run average ----------------

# A single prompt split 2-1 grounded: majority vote reads it as one grounded
# prompt out of one (100%, PASS). A raw run-level average would instead read
# 2 grounded runs out of 3 (66.7%, FAIL). The two arithmetics disagree on
# which side of the 80% threshold this lands, so PASS vs. FAIL alone proves
# which one is implemented.
run_case "a single 2-1-split prompt PASSes under per-prompt majority vote, not raw run averaging" 0 \
  "100.0% (1/1 prompts grounded)" fx_1prompt \
  --mock-responses "$FIXTURES/majority-vs-raw-single-mocks.json"

run_case "flicker prints even for the sole prompt in a one-prompt corpus" 0 \
  "  n01 [flicker]" fx_1prompt \
  --mock-responses "$FIXTURES/majority-vs-raw-single-mocks.json"

# Three prompts (two unanimous fails, one 2-1-split grounded): per-prompt
# majority vote reads 1/3 prompts grounded (33.3%). A raw run-level average
# over all nine runs would instead read 2/9 (22.2%). Asserting the literal
# percentage string pins down which arithmetic produced the published rate.
run_case2 "aggregate rate is the per-prompt majority-vote percentage, not the raw per-run percentage" 1 \
  "33.3% (1/3 prompts grounded)" "22.2%" fx_3prompts \
  --mock-responses "$FIXTURES/majority-vs-raw-percent-mocks.json"

# ----- --dry-run stays keyless and schema-only ------------------------------

# --dry-run validates schema and calls no model either way; it must behave
# identically whether or not a --mock-responses file is also passed, and
# regardless of that file's per-prompt run count. This is a non-regression
# guard on the one part of the contract this change must NOT touch.
run_case "--dry-run ignores --mock-responses entirely and stays a pure schema gate" 0 \
  "3 prompt(s) parsed" fx_3prompts \
  --dry-run --mock-responses "$FIXTURES/bad-run-count-mocks.json"

# ----- --results-json carries the same distinction structurally ------------

run_json_case "flickering prompt's --results-json record is marked flicker: true" 1 \
  "$FIXTURES/flicker-mixed-mocks.json" \
  '.records[] | select(.prompt_id=="n03") | .flicker == true' \
  fx_3prompts

run_json_case "unanimous prompt's --results-json record is marked flicker: false" 1 \
  "$FIXTURES/flicker-mixed-mocks.json" \
  '.records[] | select(.prompt_id=="n01") | .flicker == false' \
  fx_3prompts

run_json_case "flickering prompt's --results-json record retains all three individual runs" 1 \
  "$FIXTURES/flicker-mixed-mocks.json" \
  '(.records[] | select(.prompt_id=="n03") | .runs | length) == 3' \
  fx_3prompts

run_json_case "--results-json summary.grounded_count is the per-prompt majority tally, not the raw grounded-run count" 1 \
  "$FIXTURES/flicker-mixed-mocks.json" \
  '.summary.grounded_count == 2' \
  fx_3prompts

# ----- a live-shaped invocation issues three model calls per prompt --------

# No --dry-run, no --mock-responses: this exercises the actual per-prompt
# call loop. A local, in-process fake Anthropic SDK (fixtures/fake_sdk/)
# stands in for the network so the assertion stays offline and keyless in
# spirit -- the fake key is never sent anywhere, there is no fake server,
# and every call is answered in-process. Each call appends one line to
# $FAKE_SDK_CALL_LOG; the line count is this suite's only way to observe
# how many model calls one grading invocation actually issued.
live_call_count_case() {
  local name="a live-shaped invocation issues three model calls per prompt (3N total for N prompts)"
  local ctx_root call_log out rc calls
  ctx_root="$(mktemp -d -t skill-engine-eval-runs.XXXXXX)"
  created_dirs+=("$ctx_root")
  mkdir -p "$ctx_root/research" "$ctx_root/references"
  fx_3prompts "$ctx_root"

  call_log="$(mktemp -t skill-engine-eval-runs-calls.XXXXXX)"
  created_dirs+=("$call_log")

  out="$(PYTHONPATH="$FIXTURES/fake_sdk" \
         ANTHROPIC_API_KEY="fake-test-key-never-sent-anywhere" \
         FAKE_SDK_CALL_LOG="$call_log" \
         python3 "$RUNNER" "$ctx_root" --threshold 0.80 --api-key-source env 2>&1)" && rc=0 || rc=$?

  calls="0"
  [ -f "$call_log" ] && calls="$(tr -d ' ' < "$call_log" | grep -c '^call$' || true)"

  # rc 2 (runner failure) or 3 (ImportError) would mean the fake SDK never
  # got exercised as a normal grading run; every other exit code means the
  # per-prompt loop ran to completion and the call count is meaningful.
  if [ "$calls" = "9" ] && [ "$rc" -ne 2 ] && [ "$rc" -ne 3 ]; then
    printf '  PASS  %s\n' "$name"
    pass_count=$((pass_count + 1))
  else
    printf '  FAIL  %s\n        expected 9 calls (3 prompts x 3 runs each), rc not in {2,3}\n        got calls=%s rc=%d:\n%s\n' \
      "$name" "$calls" "$rc" "$out"
    fail_count=$((fail_count + 1))
  fi
  rm -rf "$ctx_root"
}
live_call_count_case

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
