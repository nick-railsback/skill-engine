#!/usr/bin/env bash
# Feature-scoped test runner for navigator_budget.py (chunk
# 14-navigator-budget-lint) — the navigator standing-instructions byte-count
# lint: the UTF-8 byte length of a navigator SKILL.md's body, minus
# frontmatter, the Catalog-as-TOC carve-out, and the provisional-preamble
# carve-out, checked against the 5,120-byte budget.
#
# Two kinds of cases:
#   - Criterion 1 (the byte-counting algorithm itself: frontmatter stripped,
#     contiguous `## Catalog*` carve-out, provisional-preamble carve-out):
#     small synthetic SKILL.md fixtures with hand-countable byte lengths,
#     invoked directly as
#     `python3 plugin/skill-engine/tests/navigator_budget.py <fixture-path>`.
#     Each fixture's expected byte count is the sum of the byte lengths of
#     the literal building blocks used to assemble it (arithmetic on known
#     constants via `wc -c`) minus the excluded blocks — never a
#     re-implementation of the carve-out logic under test.
#   - Criteria 2-5 (the 5,120-byte threshold; `bash scripts/ci-local.sh
#     examples` reporting all four real navigators; that command's exit
#     code; examples/README.md's documentation): live-corpus assertions
#     against the real repo. No byte count for any of the four real
#     navigators is ever hardcoded here — only shape (name present, some
#     byte-count-shaped number present, an over-budget verdict, the 5,120
#     threshold, and "not modified by this chunk" language).
#
# navigator_budget.py does not exist yet (that is what makes this oracle
# red today), nor does the ci-local.sh / examples/README.md wiring — this
# suite is what turns green once that implementation lands.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
NAV_SCRIPT="$PLUGIN_ROOT/tests/navigator_budget.py"

pass_count=0
fail_count=0

TMPDIR_CASE="$(mktemp -d -t skill-engine-navigator-budget.XXXXXX)"
cleanup() { rm -rf "$TMPDIR_CASE"; }
trap cleanup EXIT

byte_len() {
  printf '%s' "$1" | wc -c | tr -d ' '
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

# ────────────────────────────────────────────────────────────────────────
# Criterion 1: the standing-instructions byte-counting algorithm, against
# synthetic fixtures with hand-countable byte lengths.
# ────────────────────────────────────────────────────────────────────────

# Frontmatter is identical across every criterion-1 fixture and is entirely
# excluded from the count by contract, so its own byte length never enters
# any "expected" arithmetic below — only that a real closing `---`
# delimiter is present for the body to start after.
FRONTMATTER=$'---\nname: fixture-nav\ndescription: synthetic fixture for the navigator budget algorithm\n---\n'

# run_algo_case <slug> <label> <full-body-content> <expected-bytes>
# Writes FRONTMATTER + body to a fixture file, invokes navigator_budget.py
# against it, and compares its printed byte count to <expected-bytes>.
# Extraction (strip commas, take the first digit run) tolerates either a
# bare number or a comma-grouped / labeled one — the exact output format is
# an implementation decision this oracle does not prescribe; only the
# numeric value is asserted.
run_algo_case() {
  local slug="$1" label="$2" body="$3" expected="$4"
  local fixture_path="$TMPDIR_CASE/${slug}.md"
  printf '%s' "$FRONTMATTER$body" > "$fixture_path"

  local out extracted
  out="$(python3 "$NAV_SCRIPT" "$fixture_path" 2>/dev/null)"
  extracted="$(printf '%s' "$out" | tr -d ',' | grep -oE '[0-9]+' | head -1)"

  if [ -n "$extracted" ] && [ "$extracted" = "$expected" ]; then
    pass "$label (expected $expected bytes)"
  else
    fail "$label" "expected byte count $expected, got stdout: ${out:-<empty>}"
  fi
}

# --- baseline: no Catalog section, no provisional preamble — the whole
# body counts toward the budget.
h1=$'# Fixture Baseline Navigator\n'
instr_h=$'## Instructions to Claude\n'
instr_b=$'Always confirm the requested domain before answering.\n'
body="$h1$instr_h$instr_b"
expected=$(byte_len "$body")
run_algo_case "baseline" \
  "algorithm: no Catalog section and no provisional preamble -> full body counts" \
  "$body" "$expected"

# --- single-domain Catalog section, carved out contiguously through to
# the next heading that is NOT a Catalog heading.
h1=$'# Fixture Single Catalog Navigator\n'
instr_h=$'## Instructions to Claude\n'
instr_b=$'Dispatch every request through the rules below.\n'
cat_h=$'## Catalog\n'
cat_b=$'| Path | Note |\n| --- | --- |\n| a.md | primary reference |\n| b.md | secondary reference |\n'
next_h=$'## Cross-reference map\n'
next_b=$'See references/ for the full cross-reference map.\n'
body="$h1$instr_h$instr_b$cat_h$cat_b$next_h$next_b"
carve="$cat_h$cat_b"
expected=$(( $(byte_len "$body") - $(byte_len "$carve") ))
run_algo_case "single-domain-catalog" \
  "algorithm: single-domain Catalog section carved out through the next non-Catalog heading" \
  "$body" "$expected"

# --- multi-domain sectioned Catalog: a `## Catalog` container immediately
# followed by one or more `## Catalog: <source>` subsections — the whole
# contiguous run is carved out as one unit (the shape of
# examples/inspect-ai-context/SKILL.md's catalog; spec.md's resolved fork
# on the multi-domain case).
h1=$'# Fixture Multi-Domain Navigator\n'
instr_h=$'## Instructions to Claude\n'
instr_b=$'Route each query to the matching source below.\n'
cat_container=$'## Catalog\n'
cat_sub1_h=$'## Catalog: source-one\n'
cat_sub1_b=$'| Path | Note |\n| --- | --- |\n| a.md | source one primary |\n'
cat_sub2_h=$'## Catalog: source-two\n'
cat_sub2_b=$'| Path | Note |\n| --- | --- |\n| c.md | source two primary |\n'
next_h=$'## Markdown style for generated references\n'
next_b=$'Use standard GitHub-flavored markdown throughout.\n'
body="$h1$instr_h$instr_b$cat_container$cat_sub1_h$cat_sub1_b$cat_sub2_h$cat_sub2_b$next_h$next_b"
carve="$cat_container$cat_sub1_h$cat_sub1_b$cat_sub2_h$cat_sub2_b"
expected=$(( $(byte_len "$body") - $(byte_len "$carve") ))
run_algo_case "multi-domain-catalog" \
  "algorithm: sectioned multi-domain Catalog (container + per-source subsections) carved out as one contiguous run" \
  "$body" "$expected"

# --- Catalog section runs to end of file (no trailing heading) — the
# carve-out must not assume a heading always follows the Catalog section.
h1=$'# Fixture Catalog At EOF Navigator\n'
instr_h=$'## Instructions to Claude\n'
instr_b=$'Confirm scope before responding.\n'
cat_h=$'## Catalog\n'
cat_b=$'| Path | Note |\n| --- | --- |\n| a.md | only reference |\n'
body="$h1$instr_h$instr_b$cat_h$cat_b"
carve="$cat_h$cat_b"
expected=$(( $(byte_len "$body") - $(byte_len "$carve") ))
run_algo_case "catalog-at-eof" \
  "algorithm: Catalog section running to end of file is carved out in full" \
  "$body" "$expected"

# --- engine-managed provisional-preamble block, no Catalog section.
preamble=$'<!-- BEGIN provisional-preamble (managed by skill-engine; do not hand-edit) -->\n> This navigator has not yet been reviewed against its upstream sources.\n<!-- END provisional-preamble -->\n'
h1=$'# Fixture Provisional Navigator\n'
instr_h=$'## Instructions to Claude\n'
instr_b=$'Treat unreviewed claims with caution.\n'
body="$preamble$h1$instr_h$instr_b"
carve="$preamble"
expected=$(( $(byte_len "$body") - $(byte_len "$carve") ))
run_algo_case "provisional-preamble" \
  "algorithm: provisional-preamble block carved out (BEGIN..END inclusive)" \
  "$body" "$expected"

# --- provisional preamble AND a Catalog section together — both
# exclusions apply independently within the same file.
preamble=$'<!-- BEGIN provisional-preamble (managed by skill-engine; do not hand-edit) -->\n> This navigator has not yet been reviewed against its upstream sources.\n<!-- END provisional-preamble -->\n'
h1=$'# Fixture Provisional Plus Catalog Navigator\n'
instr_h=$'## Instructions to Claude\n'
instr_b=$'Treat unreviewed claims with caution and confirm domain scope.\n'
cat_h=$'## Catalog\n'
cat_b=$'| Path | Note |\n| --- | --- |\n| a.md | primary |\n'
next_h=$'## Cross-reference map\n'
next_b=$'See references/.\n'
body="$preamble$h1$instr_h$instr_b$cat_h$cat_b$next_h$next_b"
carve="$preamble$cat_h$cat_b"
expected=$(( $(byte_len "$body") - $(byte_len "$carve") ))
run_algo_case "provisional-plus-catalog" \
  "algorithm: provisional preamble and Catalog section both carved out in the same file" \
  "$body" "$expected"

echo

# ────────────────────────────────────────────────────────────────────────
# Criteria 2-4: `bash scripts/ci-local.sh examples` reports all four real
# navigators' byte counts and over/within-budget verdicts against the
# exact 5,120-byte threshold, without affecting the command's exit code.
# Run for real against this repo; no byte value for any of the four real
# navigators is ever hardcoded.
# ────────────────────────────────────────────────────────────────────────

examples_out="$(bash "$REPO_ROOT/scripts/ci-local.sh" examples 2>&1)"
examples_rc=$?

# A byte-count-shaped number: either a plain run of 4+ digits, or a
# comma-grouped number (e.g. "5,120" or "13,126"). Tolerates either
# formatting choice without prescribing one.
NUMBER_RE='[0-9]{4,}|[0-9]{1,3}(,[0-9]{3})+'

# nav_blocks <needle> — every line belonging to any "== ... ==" delimited
# section of the output whose header contains needle. Unioned across every
# matching header (there may be more than one per navigator today: the
# verify.sh header, the permalink-density header, the eval-corpus dry-run
# header, and — once implemented — the navigator-budget report's own
# header), not first-match-only, so a budget section appended after the
# pre-existing loops is not silently skipped.
nav_blocks() {
  local needle="$1"
  printf '%s\n' "$examples_out" | awk -v needle="$needle" '
    /^==/ { capturing = ($0 ~ needle) }
    capturing { print }
  '
}

all_reported=1

check_nav_reported() {
  local needle="$1" label="$2"
  local blocks
  blocks="$(nav_blocks "$needle")"
  local ok=1
  [ -n "$blocks" ] || ok=0
  printf '%s' "$blocks" | grep -qE "$NUMBER_RE" || ok=0
  printf '%s' "$blocks" | grep -q '5,120' || ok=0
  printf '%s' "$blocks" | grep -qi 'budget' || ok=0
  printf '%s' "$blocks" | grep -qi 'over' || ok=0
  if [ "$ok" -eq 1 ]; then
    pass "$label"
  else
    fail "$label" \
      "no section of 'bash scripts/ci-local.sh examples' output for this navigator reports a byte count alongside the 5,120 threshold and an over-budget verdict"
    all_reported=0
  fi
}

check_nav_reported "skill-engine-context" \
  "ci-local examples: dogfood navigator (.claude/skills/skill-engine-context/SKILL.md) reports byte count + over-budget verdict against 5,120"
check_nav_reported "examples/inspect-ai-context" \
  "ci-local examples: inspect-ai-context navigator reports byte count + over-budget verdict against 5,120"
check_nav_reported "examples/langchain-context" \
  "ci-local examples: langchain-context navigator reports byte count + over-budget verdict against 5,120"
check_nav_reported "examples/modelcontextprotocol-python-sdk-context" \
  "ci-local examples: modelcontextprotocol-python-sdk-context navigator reports byte count + over-budget verdict against 5,120"

# Criterion 4: the command's exit code stays 0 even though every navigator
# it reports on is over budget. Folded together with all_reported (rather
# than asserted alone) so this case cannot pass today merely because the
# pre-existing checks already exit 0 before any budget reporting exists —
# an exit-code check with nothing else behind it would be a case testing
# nothing.
if [ "$examples_rc" -eq 0 ] && [ "$all_reported" -eq 1 ]; then
  pass "ci-local examples: exit code 0 despite all four navigators reporting over-budget"
else
  fail "ci-local examples: exit code 0 despite all four navigators reporting over-budget" \
    "rc=$examples_rc all_reported=$all_reported"
fi

echo

# ────────────────────────────────────────────────────────────────────────
# Criterion 5: examples/README.md documents all four navigators by name,
# each with a byte count and the 5,120-byte budget it's compared against,
# and states that none of the four is modified by this chunk. Same
# no-hardcoded-byte-value discipline: shape, not exact figures.
# ────────────────────────────────────────────────────────────────────────

README_PATH="$REPO_ROOT/examples/README.md"
readme_content="$(cat "$README_PATH")"

check_readme_nav_bytecount() {
  local needle="$1" label="$2"
  local line_nums
  line_nums="$(grep -n -F "$needle" "$README_PATH" | cut -d: -f1)"
  local ok=0 n window
  for n in $line_nums; do
    window="$(sed -n "${n},$((n + 8))p" "$README_PATH")"
    if printf '%s' "$window" | grep -qE "$NUMBER_RE"; then
      ok=1
      break
    fi
  done
  if [ "$ok" -eq 1 ]; then
    pass "$label"
  else
    fail "$label" \
      "no mention of this navigator in examples/README.md is followed within a few lines by a byte-count-shaped number"
  fi
}

check_readme_nav_bytecount "skill-engine-context" \
  "examples/README.md: dogfood navigator documented with a byte count"
check_readme_nav_bytecount "inspect-ai-context" \
  "examples/README.md: inspect-ai-context navigator documented with a byte count"
check_readme_nav_bytecount "langchain-context" \
  "examples/README.md: langchain-context navigator documented with a byte count"
check_readme_nav_bytecount "modelcontextprotocol-python-sdk-context" \
  "examples/README.md: modelcontextprotocol-python-sdk-context navigator documented with a byte count"

if printf '%s' "$readme_content" | grep -q '5,120'; then
  pass "examples/README.md: states the 5,120-byte budget threshold"
else
  fail "examples/README.md: states the 5,120-byte budget threshold"
fi

if printf '%s' "$readme_content" | grep -qiE 'not modified|unmodified|not (been )?(changed|edited|shrunk)|does not (change|modify|shrink|edit)'; then
  pass "examples/README.md: states none of the four navigators is modified by this chunk"
else
  fail "examples/README.md: states none of the four navigators is modified by this chunk"
fi

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
