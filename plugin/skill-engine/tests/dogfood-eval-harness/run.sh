#!/usr/bin/env bash
# Feature-scoped test runner for the dogfood eval corpus's schema, split-
# arithmetic, referential-integrity, persona-balance, template-staging, and
# results-artifact validator (validate_eval_corpus.py).
#
# Most cases build a synthetic <navigator>/references/ + <navigator>/evals/
# tree under a mktemp -d scratch root to isolate one invariant at a time --
# the same way eval-corpus-split/run.sh builds synthetic contextualizer
# trees for its dry-run and grading sections. A final, read-only section
# points the same validator at the real .claude/skills/skill-engine-context/
# tree -- the same way eval-corpus-split/run.sh's own opening section reads
# real facts about the live MCP example's research/ directory -- so the
# suite's overall exit code reflects whether the dogfood navigator actually
# carries a compliant corpus, not just whether the validator's own logic is
# self-consistent against fixtures it also authored.
#
# Hermetic: no network, no API key, no `claude` CLI invocation anywhere in
# this file, and the validator itself never shells out to a model or
# re-runs the harness. The real-tree section only ever reads; it never
# writes into .claude/skills/skill-engine-context/.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
VALIDATOR="$SCRIPT_DIR/validate_eval_corpus.py"

pass_count=0
fail_count=0
created_dirs=()
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

new_root() {
  local d
  d="$(mktemp -d -t skill-engine-dogfood-eval.XXXXXX)"
  created_dirs+=("$d")
  mkdir -p "$d/evals"
  printf '%s' "$d"
}

run_validator() {
  OUT="$(python3 "$VALIDATOR" "$@" 2>&1)" && RC=0 || RC=$?
}

# ----- reference fixtures ---------------------------------------------------

write_references() {
  local dir="$1"
  mkdir -p "$dir"
  local name
  for name in alpha beta gamma delta; do
    printf '# %s\n\nReference body for %s.\n' "$name" "$name" > "$dir/${name}.md"
  done
}

# ----- a schema-valid, disjoint, referentially-sound, persona-balanced pair
# ----- of train/test files: 10 train + 4 test = 14 combined (over the
# ----- ten-entry threshold), test count = round(30% of 14) = 4, every
# ----- "expected" resolves under references/{alpha,beta,gamma,delta}.md, and
# ----- persona counts are domain-expert=5, domain-naive-technical=4,
# ----- non-technical=5 (balanced, none over half of 14, all >= 2).

write_valid_train() {
  cat > "$1" <<'EOF'
{
  "schema_version": 1,
  "entries": [
    {"query": "How do we roll back a bad alpha deploy?", "expected": "alpha", "notes": "Rollback path lives in the alpha reference.", "persona": "domain-expert"},
    {"query": "What happens when alpha times out mid-request?", "expected": "alpha", "notes": "Timeout handling is documented under alpha.", "persona": "domain-expert"},
    {"query": "Can beta run without an alpha token?", "expected": "beta", "notes": "Cross-reference between alpha and beta auth.", "persona": "domain-expert"},
    {"query": "Where do I look when beta silently drops events?", "expected": "beta", "notes": "Silent-drop debugging is a beta topic.", "persona": "domain-naive-technical"},
    {"query": "Is there a way to see why gamma jobs stall?", "expected": "gamma", "notes": "Stall diagnostics live in gamma.", "persona": "domain-naive-technical"},
    {"query": "Who do I ask when gamma looks broken?", "expected": "gamma", "notes": "Escalation path is documented under gamma.", "persona": "domain-naive-technical"},
    {"query": "Why did my delta report come back empty?", "expected": "delta", "notes": "Empty-report causes are covered in delta.", "persona": "non-technical"},
    {"query": "My delta export never finished, what do I do?", "expected": "delta", "notes": "Export troubleshooting lives in delta.", "persona": "non-technical"},
    {"query": "The app said alpha failed, is that bad?", "expected": "alpha", "notes": "Plain-language alpha failure explainer.", "persona": "non-technical"},
    {"query": "Something about beta broke and I don't know why", "expected": "beta", "notes": "Non-technical beta failure phrasing.", "persona": "non-technical"}
  ]
}
EOF
}

write_valid_test() {
  cat > "$1" <<'EOF'
{
  "schema_version": 1,
  "entries": [
    {"query": "What's the retry policy for alpha calls?", "expected": "alpha", "notes": "Retry policy detail for alpha.", "persona": "domain-expert"},
    {"query": "Does beta support partial batches?", "expected": "beta", "notes": "Partial-batch support is a beta detail.", "persona": "domain-expert"},
    {"query": "How would a new engineer debug a gamma failure?", "expected": "gamma", "notes": "Sibling-team debugging entry point for gamma.", "persona": "domain-naive-technical"},
    {"query": "I can't tell if delta ran, how do I check?", "expected": "delta", "notes": "Run-confirmation is a non-technical delta question.", "persona": "non-technical"}
  ]
}
EOF
}

# write_n_entries <file> <query-prefix> <count>
# Schema-valid filler entries for split-arithmetic cases, where the split
# check does not look at expected/persona content -- only counts and query
# disjointness matter.
write_n_entries() {
  local file="$1" prefix="$2" count="$3" i entries=""
  for i in $(seq 1 "$count"); do
    [ -n "$entries" ] && entries="${entries},"
    entries="${entries}
    {\"query\": \"${prefix} filler query number ${i}\", \"expected\": \"alpha\", \"notes\": \"filler note ${i}\", \"persona\": \"domain-expert\"}"
  done
  printf '{\n  "schema_version": 1,\n  "entries": [%s\n  ]\n}\n' "$entries" > "$file"
}

echo "== dogfood eval corpus validator =="
echo

# ===========================================================================
# schema well-formedness -- schema_version must be a present JSON integer
# >= 1, entries must be an array, and every entry needs non-empty query,
# expected, and notes strings.
# ===========================================================================

root="$(new_root)"
write_valid_train "$root/evals/evals-train.json"
run_validator schema "$root/evals/evals-train.json"
why=""
[ "$RC" -eq 0 ] || why="$why rc=$RC (want 0): $OUT;"
contains "$OUT" "OK" || why="$why no OK line in output;"
verdict "a well-formed train file with integer schema_version and non-empty query/expected/notes is accepted" "$why"

root="$(new_root)"
write_valid_test "$root/evals/evals-test.json"
run_validator schema "$root/evals/evals-test.json"
why=""
[ "$RC" -eq 0 ] || why="$why rc=$RC (want 0): $OUT;"
verdict "a well-formed test file with integer schema_version and non-empty query/expected/notes is accepted" "$why"

root="$(new_root)"
write_valid_train "$root/evals/evals-train.json"
jq 'del(.schema_version)' "$root/evals/evals-train.json" > "$root/evals/mutated.json"
run_validator schema "$root/evals/mutated.json"
why=""
[ "$RC" -ne 0 ] || why="$why rc=0 (want non-zero) -- a file missing schema_version was accepted;"
contains "$OUT" "schema_version" || why="$why does not name schema_version as the problem: $OUT;"
verdict "a file missing the schema_version field is rejected, naming the missing field" "$why"

root="$(new_root)"
write_valid_train "$root/evals/evals-train.json"
jq '.schema_version = "1"' "$root/evals/evals-train.json" > "$root/evals/mutated.json"
run_validator schema "$root/evals/mutated.json"
why=""
[ "$RC" -ne 0 ] || why="$why rc=0 (want non-zero) -- a string schema_version was accepted;"
contains "$OUT" "schema_version" || why="$why does not name schema_version as the problem: $OUT;"
contains "$OUT" "str" || why="$why does not name the offending type (str): $OUT;"
verdict "a file with schema_version given as a string is rejected, naming the offending type" "$why"

root="$(new_root)"
write_valid_train "$root/evals/evals-train.json"
jq '.schema_version = 1.0' "$root/evals/evals-train.json" > "$root/evals/mutated.json"
run_validator schema "$root/evals/mutated.json"
why=""
[ "$RC" -ne 0 ] || why="$why rc=0 (want non-zero) -- a float schema_version was accepted;"
contains "$OUT" "float" || why="$why does not name the offending type (float): $OUT;"
verdict "a file with schema_version given as a float is rejected, naming the offending type" "$why"

root="$(new_root)"
write_valid_train "$root/evals/evals-train.json"
jq '.schema_version = null' "$root/evals/evals-train.json" > "$root/evals/mutated.json"
run_validator schema "$root/evals/mutated.json"
why=""
[ "$RC" -ne 0 ] || why="$why rc=0 (want non-zero) -- a null schema_version was accepted;"
contains "$OUT" "NoneType" || why="$why does not name the offending type (NoneType): $OUT;"
verdict "a file with schema_version given as null is rejected, naming the offending type" "$why"

root="$(new_root)"
write_valid_train "$root/evals/evals-train.json"
jq 'del(.entries)' "$root/evals/evals-train.json" > "$root/evals/mutated.json"
run_validator schema "$root/evals/mutated.json"
why=""
[ "$RC" -ne 0 ] || why="$why rc=0 (want non-zero) -- a file missing entries was accepted;"
contains "$OUT" "entries" || why="$why does not name entries as the problem: $OUT;"
verdict "a file missing the entries array is rejected" "$why"

root="$(new_root)"
write_valid_train "$root/evals/evals-train.json"
jq '.entries[0] |= del(.query)' "$root/evals/evals-train.json" > "$root/evals/mutated.json"
run_validator schema "$root/evals/mutated.json"
why=""
[ "$RC" -ne 0 ] || why="$why rc=0 (want non-zero) -- an entry missing query was accepted;"
contains "$OUT" "query" || why="$why does not name query as the problem: $OUT;"
verdict "an entry missing the query field is rejected" "$why"

root="$(new_root)"
write_valid_train "$root/evals/evals-train.json"
jq '.entries[0] |= del(.expected)' "$root/evals/evals-train.json" > "$root/evals/mutated.json"
run_validator schema "$root/evals/mutated.json"
why=""
[ "$RC" -ne 0 ] || why="$why rc=0 (want non-zero) -- an entry missing expected was accepted;"
contains "$OUT" "expected" || why="$why does not name expected as the problem: $OUT;"
verdict "an entry missing the expected field is rejected" "$why"

root="$(new_root)"
write_valid_train "$root/evals/evals-train.json"
jq '.entries[0] |= del(.notes)' "$root/evals/evals-train.json" > "$root/evals/mutated.json"
run_validator schema "$root/evals/mutated.json"
why=""
[ "$RC" -ne 0 ] || why="$why rc=0 (want non-zero) -- an entry missing notes was accepted;"
contains "$OUT" "notes" || why="$why does not name notes as the problem: $OUT;"
verdict "an entry missing the notes field is rejected" "$why"

root="$(new_root)"
write_valid_train "$root/evals/evals-train.json"
jq '.entries[0].query = ""' "$root/evals/evals-train.json" > "$root/evals/mutated.json"
run_validator schema "$root/evals/mutated.json"
why=""
[ "$RC" -ne 0 ] || why="$why rc=0 (want non-zero) -- an empty-string query was accepted;"
contains "$OUT" "empty string" || why="$why does not report an empty string: $OUT;"
verdict "an entry with an empty-string query is rejected" "$why"

root="$(new_root)"
write_valid_train "$root/evals/evals-train.json"
jq '.entries[0].expected = ""' "$root/evals/evals-train.json" > "$root/evals/mutated.json"
run_validator schema "$root/evals/mutated.json"
why=""
[ "$RC" -ne 0 ] || why="$why rc=0 (want non-zero) -- an empty-string expected was accepted;"
contains "$OUT" "empty string" || why="$why does not report an empty string: $OUT;"
verdict "an entry with an empty-string expected is rejected" "$why"

root="$(new_root)"
write_valid_train "$root/evals/evals-train.json"
jq '.entries[0].notes = ""' "$root/evals/evals-train.json" > "$root/evals/mutated.json"
run_validator schema "$root/evals/mutated.json"
why=""
[ "$RC" -ne 0 ] || why="$why rc=0 (want non-zero) -- an empty-string notes was accepted;"
contains "$OUT" "empty string" || why="$why does not report an empty string: $OUT;"
verdict "an entry with an empty-string notes is rejected" "$why"

# ===========================================================================
# split arithmetic -- train and test queries must be disjoint, the combined
# count must exceed ten, and the test file's entry count must equal the
# nearest-integer rounding of 30% of the combined count.
# ===========================================================================

root="$(new_root)"
write_valid_train "$root/evals/evals-train.json"
write_valid_test "$root/evals/evals-test.json"
run_validator split "$root/evals/evals-train.json" "$root/evals/evals-test.json"
why=""
[ "$RC" -eq 0 ] || why="$why rc=$RC (want 0): $OUT;"
verdict "disjoint train/test queries with combined count over ten and an exact 30% test split are accepted" "$why"

root="$(new_root)"
write_valid_train "$root/evals/evals-train.json"
write_valid_test "$root/evals/evals-test.json"
dup_query="How do we roll back a bad alpha deploy?"
jq --arg q "$dup_query" '.entries[0].query = $q' "$root/evals/evals-test.json" > "$root/evals/mutated-test.json"
run_validator split "$root/evals/evals-train.json" "$root/evals/mutated-test.json"
why=""
[ "$RC" -ne 0 ] || why="$why rc=0 (want non-zero) -- a duplicate query across train and test was accepted;"
contains "$OUT" "not disjoint" || why="$why does not name the disjointness violation: $OUT;"
verdict "a query duplicated across the train and test files is rejected" "$why"

root="$(new_root)"
write_n_entries "$root/evals/evals-train.json" "trn" 7
write_n_entries "$root/evals/evals-test.json" "tst" 3
run_validator split "$root/evals/evals-train.json" "$root/evals/evals-test.json"
why=""
[ "$RC" -ne 0 ] || why="$why rc=0 (want non-zero) -- a combined count of ten was accepted;"
contains "$OUT" "does not exceed the ten-entry split threshold" || why="$why does not name the threshold violation: $OUT;"
verdict "a combined entry count of exactly ten is rejected as not exceeding the split threshold" "$why"

root="$(new_root)"
write_n_entries "$root/evals/evals-train.json" "trn" 15
write_n_entries "$root/evals/evals-test.json" "tst" 5
run_validator split "$root/evals/evals-train.json" "$root/evals/evals-test.json"
why=""
[ "$RC" -ne 0 ] || why="$why rc=0 (want non-zero) -- a test count of 5 against a combined count of 20 (wants 6) was accepted;"
contains "$OUT" "expected 6" || why="$why does not name the expected 30% count: $OUT;"
verdict "a test-file entry count that does not equal round(0.3 * combined) is rejected" "$why"

# ===========================================================================
# referential integrity -- every entry's expected value, across both files,
# must exactly match the filename (minus .md) of a file that exists under
# references/.
# ===========================================================================

root="$(new_root)"
write_references "$root/references"
write_valid_train "$root/evals/evals-train.json"
write_valid_test "$root/evals/evals-test.json"
run_validator references "$root/evals/evals-train.json" "$root/evals/evals-test.json" "$root/references"
why=""
[ "$RC" -eq 0 ] || why="$why rc=$RC (want 0): $OUT;"
verdict "every expected value resolving to a references/<name>.md file on disk is accepted" "$why"

root="$(new_root)"
write_references "$root/references"
write_valid_train "$root/evals/evals-train.json"
write_valid_test "$root/evals/evals-test.json"
jq '.entries[0].expected = "epsilon"' "$root/evals/evals-test.json" > "$root/evals/mutated-test.json"
run_validator references "$root/evals/evals-train.json" "$root/evals/mutated-test.json" "$root/references"
why=""
[ "$RC" -ne 0 ] || why="$why rc=0 (want non-zero) -- an expected value with no matching reference file was accepted;"
contains "$OUT" "epsilon" || why="$why does not name the unresolved expected value: $OUT;"
verdict "an expected value with no matching references/<name>.md on disk is rejected, naming it" "$why"

# ===========================================================================
# persona balance -- every entry needs a persona in the three-value enum, no
# single value may exceed half the combined corpus, and every value needs
# at least two occurrences.
# ===========================================================================

root="$(new_root)"
write_valid_train "$root/evals/evals-train.json"
write_valid_test "$root/evals/evals-test.json"
run_validator persona "$root/evals/evals-train.json" "$root/evals/evals-test.json"
why=""
[ "$RC" -eq 0 ] || why="$why rc=$RC (want 0): $OUT;"
verdict "a persona distribution with all three enum values represented and none over half is accepted" "$why"

root="$(new_root)"
write_valid_train "$root/evals/evals-train.json"
write_valid_test "$root/evals/evals-test.json"
jq '.entries[0].persona = "expert"' "$root/evals/evals-train.json" > "$root/evals/mutated-train.json"
run_validator persona "$root/evals/mutated-train.json" "$root/evals/evals-test.json"
why=""
[ "$RC" -ne 0 ] || why="$why rc=0 (want non-zero) -- a persona value outside the enum was accepted;"
contains "$OUT" "expert" || why="$why does not name the offending persona value: $OUT;"
verdict "a persona value that is not one of the three enum values is rejected" "$why"

root="$(new_root)"
cat > "$root/evals/skewed-train.json" <<'EOF'
{
  "schema_version": 1,
  "entries": [
    {"query": "q1", "expected": "alpha", "notes": "n1", "persona": "domain-expert"},
    {"query": "q2", "expected": "alpha", "notes": "n2", "persona": "domain-expert"},
    {"query": "q3", "expected": "alpha", "notes": "n3", "persona": "domain-expert"},
    {"query": "q4", "expected": "alpha", "notes": "n4", "persona": "domain-expert"},
    {"query": "q5", "expected": "alpha", "notes": "n5", "persona": "domain-expert"},
    {"query": "q6", "expected": "alpha", "notes": "n6", "persona": "domain-expert"},
    {"query": "q7", "expected": "alpha", "notes": "n7", "persona": "domain-expert"},
    {"query": "q8", "expected": "alpha", "notes": "n8", "persona": "domain-expert"},
    {"query": "q9", "expected": "alpha", "notes": "n9", "persona": "domain-naive-technical"},
    {"query": "q10", "expected": "alpha", "notes": "n10", "persona": "domain-naive-technical"}
  ]
}
EOF
cat > "$root/evals/skewed-test.json" <<'EOF'
{
  "schema_version": 1,
  "entries": [
    {"query": "q11", "expected": "alpha", "notes": "n11", "persona": "domain-naive-technical"},
    {"query": "q12", "expected": "alpha", "notes": "n12", "persona": "non-technical"},
    {"query": "q13", "expected": "alpha", "notes": "n13", "persona": "non-technical"},
    {"query": "q14", "expected": "alpha", "notes": "n14", "persona": "non-technical"}
  ]
}
EOF
run_validator persona "$root/evals/skewed-train.json" "$root/evals/skewed-test.json"
why=""
[ "$RC" -ne 0 ] || why="$why rc=0 (want non-zero) -- a persona value at 8/14 (over half) was accepted;"
contains "$OUT" "more than half" || why="$why does not name the majority-share violation: $OUT;"
verdict "a persona value accounting for more than half the combined entries is rejected" "$why"

root="$(new_root)"
cat > "$root/evals/zero-train.json" <<'EOF'
{
  "schema_version": 1,
  "entries": [
    {"query": "z1", "expected": "alpha", "notes": "n1", "persona": "domain-expert"},
    {"query": "z2", "expected": "alpha", "notes": "n2", "persona": "domain-expert"},
    {"query": "z3", "expected": "alpha", "notes": "n3", "persona": "domain-expert"},
    {"query": "z4", "expected": "alpha", "notes": "n4", "persona": "domain-naive-technical"},
    {"query": "z5", "expected": "alpha", "notes": "n5", "persona": "domain-naive-technical"}
  ]
}
EOF
cat > "$root/evals/zero-test.json" <<'EOF'
{
  "schema_version": 1,
  "entries": [
    {"query": "z6", "expected": "alpha", "notes": "n6", "persona": "domain-expert"},
    {"query": "z7", "expected": "alpha", "notes": "n7", "persona": "domain-expert"},
    {"query": "z8", "expected": "alpha", "notes": "n8", "persona": "domain-naive-technical"},
    {"query": "z9", "expected": "alpha", "notes": "n9", "persona": "domain-naive-technical"},
    {"query": "z10", "expected": "alpha", "notes": "n10", "persona": "domain-naive-technical"}
  ]
}
EOF
run_validator persona "$root/evals/zero-train.json" "$root/evals/zero-test.json"
why=""
[ "$RC" -ne 0 ] || why="$why rc=0 (want non-zero) -- a persona value that never appears was accepted;"
contains "$OUT" "non-technical" || why="$why does not name the missing persona value: $OUT;"
contains "$OUT" "appears only 0 time" || why="$why does not report zero occurrences: $OUT;"
verdict "a persona value that never appears across the combined corpus is rejected" "$why"

root="$(new_root)"
cat > "$root/evals/once-train.json" <<'EOF'
{
  "schema_version": 1,
  "entries": [
    {"query": "o1", "expected": "alpha", "notes": "n1", "persona": "domain-expert"},
    {"query": "o2", "expected": "alpha", "notes": "n2", "persona": "domain-expert"},
    {"query": "o3", "expected": "alpha", "notes": "n3", "persona": "domain-expert"},
    {"query": "o4", "expected": "alpha", "notes": "n4", "persona": "domain-naive-technical"},
    {"query": "o5", "expected": "alpha", "notes": "n5", "persona": "domain-naive-technical"},
    {"query": "o6", "expected": "alpha", "notes": "n6", "persona": "domain-naive-technical"},
    {"query": "o7", "expected": "alpha", "notes": "n7", "persona": "non-technical"}
  ]
}
EOF
cat > "$root/evals/once-test.json" <<'EOF'
{
  "schema_version": 1,
  "entries": [
    {"query": "o8", "expected": "alpha", "notes": "n8", "persona": "domain-expert"},
    {"query": "o9", "expected": "alpha", "notes": "n9", "persona": "domain-expert"},
    {"query": "o10", "expected": "alpha", "notes": "n10", "persona": "domain-expert"},
    {"query": "o11", "expected": "alpha", "notes": "n11", "persona": "domain-naive-technical"},
    {"query": "o12", "expected": "alpha", "notes": "n12", "persona": "domain-naive-technical"},
    {"query": "o13", "expected": "alpha", "notes": "n13", "persona": "domain-naive-technical"},
    {"query": "o14", "expected": "alpha", "notes": "n14", "persona": "domain-naive-technical"}
  ]
}
EOF
run_validator persona "$root/evals/once-train.json" "$root/evals/once-test.json"
why=""
[ "$RC" -ne 0 ] || why="$why rc=0 (want non-zero) -- a persona value appearing only once was accepted;"
contains "$OUT" "appears only 1 time" || why="$why does not report the single occurrence: $OUT;"
verdict "a persona value that appears only once across the combined corpus is rejected" "$why"

# ===========================================================================
# template staging -- the harness, renderer, and viewer must all be present
# under evals/, none may still carry the <area-domain> placeholder, and the
# two shell files must carry the executable bit.
# ===========================================================================

_ph_a="<area"
_ph_b="-domain>"
PLACEHOLDER="${_ph_a}${_ph_b}"

write_staged_templates() {
  local dir="$1"
  printf '#!/usr/bin/env bash\necho "running evals for dogfood-context"\n' > "$dir/run-eval.sh"
  chmod +x "$dir/run-eval.sh"
  printf '#!/usr/bin/env bash\necho "rendering results for dogfood-context"\n' > "$dir/render-eval-results.sh"
  chmod +x "$dir/render-eval-results.sh"
  printf '<!doctype html>\n<html><head><title>dogfood-context eval viewer</title></head><body></body></html>\n' > "$dir/eval-viewer.html"
}

root="$(new_root)"
write_staged_templates "$root/evals"
run_validator templates "$root/evals"
why=""
[ "$RC" -eq 0 ] || why="$why rc=$RC (want 0): $OUT;"
verdict "all three staged templates, placeholder-free, with both shell scripts executable, are accepted" "$why"

root="$(new_root)"
write_staged_templates "$root/evals"
rm "$root/evals/eval-viewer.html"
run_validator templates "$root/evals"
why=""
[ "$RC" -ne 0 ] || why="$why rc=0 (want non-zero) -- a missing template was accepted;"
contains "$OUT" "eval-viewer.html" || why="$why does not name the missing template: $OUT;"
verdict "a missing staged template is rejected, naming which one" "$why"

root="$(new_root)"
write_staged_templates "$root/evals"
printf '#!/usr/bin/env bash\necho "running evals for %s-context"\n' "$PLACEHOLDER" > "$root/evals/run-eval.sh"
chmod +x "$root/evals/run-eval.sh"
run_validator templates "$root/evals"
why=""
[ "$RC" -ne 0 ] || why="$why rc=0 (want non-zero) -- an unsubstituted placeholder was accepted;"
contains "$OUT" "$PLACEHOLDER" || why="$why does not name the unsubstituted placeholder: $OUT;"
verdict "a template still containing the literal unsubstituted domain placeholder is rejected" "$why"

root="$(new_root)"
write_staged_templates "$root/evals"
chmod -x "$root/evals/render-eval-results.sh"
run_validator templates "$root/evals"
why=""
[ "$RC" -ne 0 ] || why="$why rc=0 (want non-zero) -- a non-executable shell template was accepted;"
contains "$OUT" "render-eval-results.sh" || why="$why does not name the non-executable file: $OUT;"
contains "$OUT" "not executable" || why="$why does not report the missing executable bit: $OUT;"
verdict "a staged shell template without the executable bit set is rejected" "$why"

# ===========================================================================
# results artifact -- a results-*.json matching the harness's naming
# convention must exist, parse, and carry a navigator identifier plus
# per-entry run records, and a prose note must exist alongside it. This is
# an artifact-shape check only: nothing here re-invokes the harness or the
# `claude` CLI.
# ===========================================================================

write_results_file() {
  cat > "$1" <<'EOF'
{
  "navigator": "skill-engine-context",
  "schema_version": 1,
  "started_at": "2026-04-15T09:00:00Z",
  "runs_per_query": 3,
  "entries": [
    {"query": "How do we roll back a bad alpha deploy?", "expected": "alpha", "persona": "domain-expert", "runs": ["pass", "pass", "pass"]},
    {"query": "Does beta support partial batches?", "expected": "beta", "persona": "domain-expert", "runs": ["pass", "fail", "pass"]}
  ],
  "ended_at": "2026-04-15T09:04:12Z"
}
EOF
}

write_run_note() {
  cat > "$1" <<'EOF'
2026-04-15: ran evals/run-eval.sh evals/evals-test.json once by hand against
the live claude CLI. 3 pass, 1 fail, 0 error. One flickering entry (the beta
partial-batches query passed twice and failed once); no description changes
made as a result of this run.
EOF
}

root="$(new_root)"
write_results_file "$root/evals/results-20260415T090412Z-4711.json"
write_run_note "$root/evals/run-note.md"
run_validator results "$root/evals" "$root/evals/run-note.md"
why=""
[ "$RC" -eq 0 ] || why="$why rc=$RC (want 0): $OUT;"
verdict "a well-formed results-*.json file plus a parseable prose note are accepted" "$why"

root="$(new_root)"
write_run_note "$root/evals/run-note.md"
run_validator results "$root/evals" "$root/evals/run-note.md"
why=""
[ "$RC" -ne 0 ] || why="$why rc=0 (want non-zero) -- a missing results file was accepted;"
contains "$OUT" "no results-*.json file found" || why="$why does not report the missing results file: $OUT;"
verdict "a missing results-*.json file is rejected" "$why"

root="$(new_root)"
printf '{"navigator": "skill-engine-context", "entries": [' > "$root/evals/results-20260415T090412Z-4711.json"
write_run_note "$root/evals/run-note.md"
run_validator results "$root/evals" "$root/evals/run-note.md"
why=""
[ "$RC" -ne 0 ] || why="$why rc=0 (want non-zero) -- a syntactically invalid results file was accepted;"
contains "$OUT" "invalid JSON" || why="$why does not report invalid JSON: $OUT;"
verdict "a syntactically malformed results-*.json file is rejected" "$why"

root="$(new_root)"
cat > "$root/evals/results-20260415T090412Z-4711.json" <<'EOF'
{
  "schema_version": 1,
  "entries": [
    {"query": "How do we roll back a bad alpha deploy?", "expected": "alpha", "runs": ["pass", "maybe", "pass"]}
  ]
}
EOF
write_run_note "$root/evals/run-note.md"
run_validator results "$root/evals" "$root/evals/run-note.md"
why=""
[ "$RC" -ne 0 ] || why="$why rc=0 (want non-zero) -- a results file missing 'navigator' with an invalid run outcome was accepted;"
contains "$OUT" "navigator" || why="$why does not name the missing navigator identifier: $OUT;"
contains "$OUT" "maybe" || why="$why does not name the invalid run outcome: $OUT;"
verdict "a results-*.json with the wrong record shape is rejected" "$why"

root="$(new_root)"
write_results_file "$root/evals/results-20260415T090412Z-4711.json"
run_validator results "$root/evals" "$root/evals/run-note.md"
why=""
[ "$RC" -ne 0 ] || why="$why rc=0 (want non-zero) -- a missing run note was accepted;"
contains "$OUT" "no run note found" || why="$why does not report the missing run note: $OUT;"
verdict "a missing prose run note is rejected" "$why"

# ===========================================================================
# the real dogfood navigator -- .claude/skills/skill-engine-context/evals/
# is where the corpus, staged templates, and one witnessed live-run artifact
# actually have to live for a maintainer to run this harness against the
# navigator they use daily. Every check below is read-only against the real
# tree and asserts the exact positive requirement a maintainer needs true --
# never an inverted "still missing" check -- so it reports a real, specific
# failure for as long as those files are unauthored, and a real pass once
# they exist and are valid. Nothing here writes into the real tree, shells
# out to a model, or re-invokes the harness.
# ===========================================================================

NAV_DIR="$REPO_ROOT/.claude/skills/skill-engine-context"
NAV_REFS="$NAV_DIR/references"
NAV_EVALS="$NAV_DIR/evals"
NAV_TRAIN="$NAV_EVALS/evals-train.json"
NAV_TEST="$NAV_EVALS/evals-test.json"

run_validator schema "$NAV_TRAIN"
why=""
[ "$RC" -eq 0 ] || why="$why rc=$RC: $OUT;"
verdict "the dogfood navigator's evals-train.json exists and is schema-valid" "$why"

run_validator schema "$NAV_TEST"
why=""
[ "$RC" -eq 0 ] || why="$why rc=$RC: $OUT;"
verdict "the dogfood navigator's evals-test.json exists and is schema-valid" "$why"

run_validator split "$NAV_TRAIN" "$NAV_TEST"
why=""
[ "$RC" -eq 0 ] || why="$why rc=$RC: $OUT;"
verdict "the dogfood navigator's train/test split is disjoint and matches the 30% test-count arithmetic" "$why"

run_validator references "$NAV_TRAIN" "$NAV_TEST" "$NAV_REFS"
why=""
[ "$RC" -eq 0 ] || why="$why rc=$RC: $OUT;"
verdict "every expected value in the dogfood navigator's corpus resolves to a references/*.md file on disk" "$why"

run_validator persona "$NAV_TRAIN" "$NAV_TEST"
why=""
[ "$RC" -eq 0 ] || why="$why rc=$RC: $OUT;"
verdict "the dogfood navigator's corpus carries a balanced three-persona distribution" "$why"

run_validator templates "$NAV_EVALS"
why=""
[ "$RC" -eq 0 ] || why="$why rc=$RC: $OUT;"
verdict "the dogfood navigator's evals/ directory stages all three harness templates, placeholder-free and executable" "$why"

# The run note has no fixed filename convention (unlike results-*.json), so
# this looks for any non-results *.md/*.txt file under evals/ rather than
# guessing one hardcoded name.
note_candidate=""
if [ -d "$NAV_EVALS" ]; then
  for f in "$NAV_EVALS"/*.md "$NAV_EVALS"/*.txt; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in
      results-*) continue ;;
    esac
    note_candidate="$f"
    break
  done
fi
if [ -z "$note_candidate" ]; then
  run_validator results "$NAV_EVALS" "$NAV_EVALS/__no_run_note_found__"
else
  run_validator results "$NAV_EVALS" "$note_candidate"
fi
why=""
[ "$RC" -eq 0 ] || why="$why rc=$RC: $OUT;"
verdict "the dogfood navigator's evals/ directory carries a results-*.json and a run note documenting one live run" "$why"

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
