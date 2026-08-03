#!/usr/bin/env bash
# Feature-scoped test runner for the eval corpus train / held-out split
# (grounded_rate.py corpus discovery and selection).
#
# Every assertion asserts observable runner behavior, never an internal. The
# invariant each one encodes is stated in the comment above it.
#
# The two invocation modes are DIFFERENT and are not in tension:
#   --dry-run     a keyless schema gate over EVERY corpus present.
#   a grading run scores EXACTLY ONE corpus, the train set by default.
#
# Two things are deliberately NOT asserted here:
#   * That eval-results.md's prose labels the recorded 90% as a pre-split
#     figure. The only mechanical form is a text match on prose -- green until
#     someone rewords, red for a reason nobody wants. Read the diff instead.
#   * That scripts/ci-local.sh names no corpus filename. Once its filename
#     guard is deleted the name appears nowhere, so a lint asserting an absence
#     would guard against an edit nobody has reason to make.
#
# The `[N/A]` and schema-invalid lines for an UNSPLIT root are already held by
# tests/grounded-rate/run.sh cases (a), (c), (d), (e) and (m), which run in the
# same suite. They are not restated here: they pass against today's tree, and an
# assertion that is green before the change exists demonstrates nothing. What IS
# restated is the part of the unsplit guarantee that can only hold once corpus
# selection exists -- see the "unsplit compat" block.
#
# Hermetic: builds its own context roots under mktemp -d, needs no API key,
# calls no model, and never invokes scripts/ci-local.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
RUNNER="$PLUGIN_ROOT/tests/grounded_rate.py"
FACTS="$SCRIPT_DIR/corpus_facts.py"
FIXTURES="$SCRIPT_DIR/fixtures"
EXAMPLE_RESEARCH="$REPO_ROOT/examples/modelcontextprotocol-python-sdk-context/research"

# ---------------------------------------------------------------------------
# Naming assumptions, all in one place.
#
# The train / held-out FILE NAMING and the corpus SELECTOR SPELLING are design
# choices, not part of the behavioral contract -- but a test has to type
# something. These six constants are every naming assumption this file makes;
# nothing else in it hardcodes a corpus name, a flag, or a label. If the names
# ever change, change them here and nowhere else. The "corpus split" assertions
# about the real example corpus use none of them -- corpus_facts.py discovers
# those files structurally.
# ---------------------------------------------------------------------------
TRAIN_CORPUS="eval-prompts-train.json"
HELDOUT_CORPUS="eval-prompts-test.json"
UNSPLIT_CORPUS="eval-prompts.json"
CORPUS_SELECTOR="--corpus"
# The token the verdict line must carry to identify each corpus. A runner that
# prints the corpus filename satisfies these; so does one that prints a role
# label. Matched case-insensitively, against the verdict line only, with the
# tempdir path masked out first.
TRAIN_LABEL="train"
HELDOUT_LABEL="test"

pass_count=0
fail_count=0
created_dirs=()
CTX=""
OUT=""
RC=0

cleanup_tmp() {
  [ "${#created_dirs[@]}" -eq 0 ] && return 0
  local d
  for d in "${created_dirs[@]}"; do
    [ -d "$d" ] && rm -rf "$d"
  done
  return 0
}
trap cleanup_tmp EXIT

ok() {
  printf '  PASS  %s\n' "$1"
  pass_count=$((pass_count + 1))
}

bad() {
  printf '  FAIL  %s\n        because:%s\n' "$1" "$2"
  fail_count=$((fail_count + 1))
}

# Empty reason string means the assertion held.
verdict() {
  if [ -z "$2" ]; then ok "$1"; else bad "$1" "$2"; fi
}

contains() { printf '%s' "$1" | grep -qF -- "$2"; }

# ----- fixture construction ------------------------------------------------

write_skill_md() {
  cat > "$1/SKILL.md" <<'EOF'
---
name: example-context
description: Test contextualizer.
---

# Context navigator

Body content here.
EOF
}

write_references() {
  local ref
  for ref in alpha beta gamma; do
    printf '# %s\n\nReference body.\n' "$ref" > "$1/references/${ref}.md"
  done
}

# write_corpus <dest> <id-prefix> <count>
write_corpus() {
  local dest="$1" prefix="$2" count="$3"
  local i entries=""
  for i in $(seq 1 "$count"); do
    [ -n "$entries" ] && entries="${entries},"
    entries="${entries}
    {\"id\": \"${prefix}$(printf '%02d' "$i")\", \"category\": \"needs_reference\", \"text\": \"${prefix} question ${i}: which pinned source answers this?\"}"
  done
  printf '{\n  "schema_version": 1,\n  "prompts": [%s\n  ]\n}\n' "$entries" > "$dest"
}

# A corpus any discovery scheme can see (`prompts` IS a list) that nonetheless
# fails the runner's schema_version: 1 contract on a prompt field.
write_invalid_corpus() {
  cat > "$1" <<'EOF'
{
  "schema_version": 1,
  "prompts": [{"id": "hld01", "category": "needs_reference"}]
}
EOF
}

# Non-corpus sidecars that really do live in research/ alongside the corpus and
# really do carry `schema_version: 1`. A naive "*.json is a corpus" discovery
# would try to validate them.
write_sidecars() {
  printf '{"schema_version": 1, "sources": []}\n' > "$1/research/source-paths.json"
  printf '{"schema_version": 1, "review_state": "clean"}\n' > "$1/research/review-state.json"
  printf '{"schema_version": 1}\n' > "$1/research/.research-state.json"
}

new_ctx() {
  CTX="$(mktemp -d -t skill-engine-eval-corpus-split.XXXXXX)"
  created_dirs+=("$CTX")
  mkdir -p "$CTX/research" "$CTX/references"
  write_skill_md "$CTX"
  write_references "$CTX"
}

# A context root carrying a train corpus (3 prompts, ids trn01-trn03) and a
# held-out corpus (2 prompts, ids hld01-hld02). The sizes are load-bearing:
# 3 != 2 != 5, so the count in the verdict line identifies which corpus was
# graded without this file having to trust any filename.
new_split_ctx() {
  new_ctx
  write_corpus "$CTX/research/$TRAIN_CORPUS" "trn" 3
  write_corpus "$CTX/research/$HELDOUT_CORPUS" "hld" 2
}

new_unsplit_ctx() {
  new_ctx
  write_corpus "$CTX/research/$UNSPLIT_CORPUS" "n" 3
}

# ----- runner invocation ---------------------------------------------------

run_runner() {
  local ctx="$1"
  shift
  OUT="$(python3 "$RUNNER" "$ctx" --threshold 0.80 "$@" 2>&1)" && RC=0 || RC=$?
}

# The verdict line only, with the tempdir path masked so a random mktemp suffix
# can never satisfy a corpus-identity match.
verdict_line() {
  local found
  found="$(printf '%s\n' "$OUT" | grep -E '^\[(PASS|FAIL)\] grounded-rate' | head -n 1)"
  printf '%s' "${found//$1/CTXROOT}"
}

echo "== eval corpus split =="
echo

# ===========================================================================
# corpus split -- the MCP example's research/ carries two corpus files rather
# than one. Each parses under the runner's existing schema_version: 1 contract,
# their prompt-id sets are disjoint, and their union is exactly the ten ids
# n01-n10 the single corpus carried.
#
# Disjointness is the one that regresses through an ordinary edit: adding a
# prompt to both files, or reusing an id, silently inflates the graded rate.
#
# This is a fact about the example corpus in THIS repo, so it is asserted
# against the real path rather than a fixture. corpus_facts.py discovers corpus
# files structurally (schema_version: 1 + a `prompts` list), so no filename is
# assumed.
# ===========================================================================
facts=""
facts_rc=0
facts="$(python3 "$FACTS" "$EXAMPLE_RESEARCH" 2>&1)" || facts_rc=$?

fact() { printf '%s\n' "$facts" | grep -E "^$1=" | head -n 1 | cut -d= -f2- ; }

if [ "$facts_rc" -ne 0 ]; then
  bad "corpus split: example corpus facts are readable" " corpus_facts.py exited ${facts_rc}: ${facts}"
  bad "corpus split: example research/ carries exactly two corpus files" " facts unavailable"
  bad "corpus split: both example corpus files parse under schema_version: 1" " facts unavailable"
  bad "corpus split: example corpus prompt-id sets are disjoint" " facts unavailable"
  bad "corpus split: example corpus prompt ids union to exactly n01-n10" " facts unavailable"
else
  why=""
  [ "$(fact COUNT)" = "2" ] || why=" found $(fact COUNT) corpus file(s) under research/: $(fact NAMES)"
  verdict "corpus split: example research/ carries exactly two corpus files" "$why"

  why=""
  [ "$(fact VALID)" = "1" ] || why=" $(fact VALID_DETAIL)"
  verdict "corpus split: both example corpus files parse under schema_version: 1" "$why"

  why=""
  [ "$(fact DISJOINT)" = "1" ] || why=" $(fact DISJOINT_DETAIL)"
  verdict "corpus split: example corpus prompt-id sets are disjoint" "$why"

  why=""
  [ "$(fact UNION)" = "1" ] || why=" $(fact UNION_DETAIL)"
  verdict "corpus split: example corpus prompt ids union to exactly n01-n10" "$why"
fi

# ===========================================================================
# dry-run gate -- grounded_rate.py --dry-run validates every corpus file under
# <ctx>/research/, not one hardcoded name. A context root carrying both a train
# and a held-out corpus reports both; a schema-invalid file among them exits
# non-zero.
#
# This is the keyless gate that costs nothing to run, so there is no reason for
# it to look at less than all of them: a corpus it skips is a corpus gated by
# nothing until a paid live run trips over it.
# ===========================================================================
new_split_ctx
split_ctx="$CTX"
run_runner "$split_ctx" --dry-run

why=""
[ "$RC" -eq 0 ] || why="$why rc=$RC (want 0);"
contains "$OUT" "$TRAIN_CORPUS" || why="$why train corpus $TRAIN_CORPUS not reported;"
contains "$OUT" "$HELDOUT_CORPUS" || why="$why held-out corpus $HELDOUT_CORPUS not reported;"
verdict "dry-run gate: --dry-run reports every corpus file under research/" "$why"

why=""
[ "$RC" -eq 0 ] || why="$why rc=$RC (want 0);"
for pid in trn01 trn02 trn03 hld01 hld02; do
  contains "$OUT" "$pid" || why="$why prompt id $pid not parsed;"
done
verdict "dry-run gate: --dry-run parses the prompts of every corpus (all 5 ids)" "$why"

# A schema-invalid corpus among them must sink the keyless gate -- otherwise a
# split silently narrows what CI validates and the held-out file is gated by
# nothing until a paid live run trips over it.
new_split_ctx
write_invalid_corpus "$CTX/research/$HELDOUT_CORPUS"
run_runner "$CTX" --dry-run

why=""
[ "$RC" -ne 0 ] || why="$why rc=0 (want non-zero) -- an invalid corpus passed the keyless gate;"
verdict "dry-run gate: --dry-run exits non-zero when any corpus is schema-invalid" "$why"

why=""
contains "$OUT" "$HELDOUT_CORPUS" || why="$why output does not name the invalid corpus $HELDOUT_CORPUS;"
verdict "dry-run gate: --dry-run names the schema-invalid corpus" "$why"

# research/ also holds non-corpus schema_version: 1 sidecars. Discovery must
# tell a corpus from them: the sidecars neither break the gate nor get
# validated as corpora.
new_split_ctx
write_sidecars "$CTX"
run_runner "$CTX" --dry-run

why=""
[ "$RC" -eq 0 ] || why="$why rc=$RC (want 0) -- non-corpus sidecars broke the gate;"
contains "$OUT" "$TRAIN_CORPUS" || why="$why train corpus $TRAIN_CORPUS not reported;"
contains "$OUT" "$HELDOUT_CORPUS" || why="$why held-out corpus $HELDOUT_CORPUS not reported;"
verdict "dry-run gate: --dry-run ignores non-corpus JSON sidecars in research/" "$why"

# ===========================================================================
# grading run -- grounded_rate.py grades exactly one corpus per invocation, and
# which one is observable from its output. With no corpus selector it grades the
# train corpus; the held-out corpus is reachable only by naming it explicitly.
# No invocation grades the union of both, and the verdict line identifies the
# corpus graded.
#
# Why it matters: a rate averaged across a tuned set and a held-out set means
# nothing, and an unlabeled rate can be misattributed to the other set later.
# Reaching the held-out corpus must cost a deliberate act, not a default.
#
# The graded-prompt count in the verdict line is the name-free evidence of
# WHICH corpus ran: train=3, held-out=2, union=5.
# ===========================================================================
new_split_ctx
split_ctx="$CTX"
run_runner "$split_ctx" --mock-responses "$FIXTURES/mocks-grounded-3.json"

why=""
[ "$RC" -eq 0 ] || why="$why rc=$RC (want 0);"
contains "$OUT" "[PASS] grounded-rate" || why="$why no [PASS] verdict;"
contains "$OUT" "3/3 prompts grounded" || why="$why verdict does not report 3/3 (the train corpus size);"
verdict "grading run: with no selector the train corpus alone is graded (3/3)" "$why"

why=""
vline="$(verdict_line "$split_ctx")"
if [ -z "$vline" ]; then
  why="$why no verdict line emitted;"
else
  printf '%s' "$vline" | grep -qi -- "$TRAIN_LABEL" ||
    why="$why verdict line does not identify the train corpus: ${vline};"
fi
verdict "grading run: the verdict line identifies the train corpus as graded" "$why"

# The held-out set is reachable only by naming it. Note the mock record count:
# --mock-responses requires one record per prompt, so a run that graded the
# train corpus or the union could not have consumed a 2-record file.
run_runner "$split_ctx" "$CORPUS_SELECTOR" "$HELDOUT_CORPUS" \
  --mock-responses "$FIXTURES/mocks-grounded-2.json"

why=""
[ "$RC" -eq 0 ] || why="$why rc=$RC (want 0);"
contains "$OUT" "[PASS] grounded-rate" || why="$why no [PASS] verdict;"
contains "$OUT" "2/2 prompts grounded" || why="$why verdict does not report 2/2 (the held-out corpus size);"
verdict "grading run: the held-out corpus is graded when named explicitly (2/2)" "$why"

why=""
vline="$(verdict_line "$split_ctx")"
if [ -z "$vline" ]; then
  why="$why no verdict line emitted;"
else
  printf '%s' "$vline" | grep -qi -- "$HELDOUT_LABEL" ||
    why="$why verdict line does not identify the held-out corpus: ${vline};"
  if printf '%s' "$vline" | grep -qi -- "$TRAIN_LABEL"; then
    why="$why verdict line misattributes the run to the train corpus: ${vline};"
  fi
fi
verdict "grading run: the held-out verdict names the held-out set, not train" "$why"

# No invocation grades the union. Probe: hand the default invocation a mock file
# sized to the union (5). A runner grading exactly one corpus cannot consume it,
# so no graded verdict may come back.
run_runner "$split_ctx" --mock-responses "$FIXTURES/mocks-grounded-5.json"

why=""
[ "$RC" -ne 0 ] || why="$why rc=0 (want non-zero) -- a union-sized run was accepted;"
if contains "$OUT" "prompts grounded"; then
  why="$why a graded verdict was produced for the union;"
fi
verdict "grading run: no invocation grades the union of both corpora" "$why"

# ===========================================================================
# unsplit compat -- a contextualizer whose research/ carries only the unsplit
# eval-prompts.json, with no train/held-out pair, is graded exactly as it is
# today: same exit codes, same [N/A], [PASS] and [FAIL] lines. Splitting is a
# per-contextualizer choice, not a precondition for running Check 8.
#
# This is the downstream contract. 13-coverage-testing.md publishes "place the
# file at <CTX_ROOT>/research/eval-prompts.json", so every forker who followed
# that instruction has an unsplit root; splitting must not break them.
#
# Written so it can only hold once corpus selection exists: the unsplit corpus
# must still be what the DEFAULT path resolves to, must still produce today's
# exit codes and [PASS] / [FAIL] markers with today's counts, must be named by
# the verdict line's corpus identification, and must itself be selectable by
# name.
# ===========================================================================
new_unsplit_ctx
unsplit_ctx="$CTX"
run_runner "$unsplit_ctx" --mock-responses "$FIXTURES/mocks-grounded-3.json"

why=""
[ "$RC" -eq 0 ] || why="$why rc=$RC (want 0);"
contains "$OUT" "[PASS] grounded-rate" || why="$why no [PASS] verdict;"
contains "$OUT" "3/3 prompts grounded" || why="$why verdict does not report 3/3;"
vline="$(verdict_line "$unsplit_ctx")"
if [ -n "$vline" ]; then
  contains "$vline" "$UNSPLIT_CORPUS" ||
    why="$why verdict line does not identify $UNSPLIT_CORPUS as the corpus graded: ${vline};"
fi
verdict "unsplit compat: unsplit root still grades $UNSPLIT_CORPUS by default ([PASS], 3/3)" "$why"

run_runner "$unsplit_ctx" --mock-responses "$FIXTURES/mocks-partial-3.json"

why=""
[ "$RC" -eq 1 ] || why="$why rc=$RC (want 1);"
contains "$OUT" "[FAIL] grounded-rate" || why="$why no [FAIL] verdict;"
contains "$OUT" "1/3 prompts grounded" || why="$why verdict does not report 1/3;"
vline="$(verdict_line "$unsplit_ctx")"
if [ -n "$vline" ]; then
  contains "$vline" "$UNSPLIT_CORPUS" ||
    why="$why verdict line does not identify $UNSPLIT_CORPUS as the corpus graded: ${vline};"
fi
verdict "unsplit compat: unsplit root below threshold still yields [FAIL] exit 1 (1/3)" "$why"

run_runner "$unsplit_ctx" "$CORPUS_SELECTOR" "$UNSPLIT_CORPUS" \
  --mock-responses "$FIXTURES/mocks-grounded-3.json"

why=""
[ "$RC" -eq 0 ] || why="$why rc=$RC (want 0);"
contains "$OUT" "[PASS] grounded-rate" || why="$why no [PASS] verdict;"
contains "$OUT" "3/3 prompts grounded" || why="$why verdict does not report 3/3;"
verdict "unsplit compat: the unsplit corpus is itself selectable by name" "$why"

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
