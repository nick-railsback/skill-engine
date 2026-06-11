#!/usr/bin/env bash
# Feature-scoped test runner for grounded_rate.py (SELF-AUDIT Check 8).
# Each case builds a synthetic contextualizer tree in a tempdir, invokes the
# runner, and asserts exit code + a substring in stdout. No live API calls.

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
    [ -d "$d" ] && rm -rf "$d"
  done
}
trap cleanup_tmp EXIT

# Args: 1=case-name, 2=expected-rc, 3=expected-substring, 4=fixture-builder-fn, 5..=extra runner args
run_case() {
  local name="$1" exp_rc="$2" exp_substr="$3" builder="$4"
  shift 4
  local ctx_root
  ctx_root="$(mktemp -d -t skill-engine-grounded-rate.XXXXXX)"
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

write_valid_prompts() {
  local dir="$1"
  cat > "$dir/research/eval-prompts.json" <<'EOF'
{
  "schema_version": 1,
  "prompts": [
    {"id": "n01", "category": "needs_reference", "text": "Q1: what is Alpha's import path?"},
    {"id": "n02", "category": "needs_reference", "text": "Q2: list the v1→v2 migration steps."},
    {"id": "n03", "category": "needs_reference", "text": "Q3: signature of Gamma's interface."}
  ]
}
EOF
}

# (a) missing eval-prompts.json → N/A exit 0.
fx_no_prompts_file() {
  local dir="$1"
  write_skill_md "$dir"
  write_references "$dir"
}
run_case "missing eval-prompts.json is N/A" 0 \
  "no eval prompts defined" fx_no_prompts_file

# (b) eval-prompts.json with empty prompts list → N/A exit 0.
fx_empty_prompts() {
  local dir="$1"
  write_skill_md "$dir"
  write_references "$dir"
  cat > "$dir/research/eval-prompts.json" <<'EOF'
{"schema_version": 1, "prompts": []}
EOF
}
run_case "empty prompts list is N/A" 0 \
  "eval-prompts.json has 0 prompts" fx_empty_prompts

# (c) eval-prompts.json missing 'prompts' key → FAIL exit 1.
fx_schema_invalid_missing_key() {
  local dir="$1"
  write_skill_md "$dir"
  write_references "$dir"
  cat > "$dir/research/eval-prompts.json" <<'EOF'
{"schema_version": 1}
EOF
}
run_case "schema invalid (no 'prompts' key)" 1 \
  "schema invalid" fx_schema_invalid_missing_key

# (d) eval-prompts.json with bad schema_version → FAIL exit 1.
fx_schema_invalid_version() {
  local dir="$1"
  write_skill_md "$dir"
  write_references "$dir"
  cat > "$dir/research/eval-prompts.json" <<'EOF'
{"schema_version": 2, "prompts": []}
EOF
}
run_case "schema invalid (bad schema_version)" 1 \
  "unsupported schema_version" fx_schema_invalid_version

# (e) eval-prompts.json prompt missing required field → FAIL exit 1.
fx_schema_invalid_prompt_field() {
  local dir="$1"
  write_skill_md "$dir"
  write_references "$dir"
  cat > "$dir/research/eval-prompts.json" <<'EOF'
{
  "schema_version": 1,
  "prompts": [{"id": "n01", "category": "needs_reference"}]
}
EOF
}
run_case "schema invalid (missing 'text' field)" 1 \
  "missing or whitespace-only field 'text'" fx_schema_invalid_prompt_field

# (f) --dry-run on valid prompts → exit 0, prompts echoed.
fx_dry_run_valid() {
  local dir="$1"
  write_skill_md "$dir"
  write_references "$dir"
  write_valid_prompts "$dir"
}
run_case "dry-run valid file echoes prompts" 0 \
  "3 prompt(s) parsed" fx_dry_run_valid --dry-run

# (g) --dry-run on schema-invalid file → exit 1, no API touched.
fx_dry_run_invalid() {
  local dir="$1"
  write_skill_md "$dir"
  write_references "$dir"
  cat > "$dir/research/eval-prompts.json" <<'EOF'
{"schema_version": 1, "prompts": "not-a-list"}
EOF
}
run_case "dry-run schema-invalid is FAIL" 1 \
  "schema invalid" fx_dry_run_invalid --dry-run

# (h) Mocked grounded-PASS: 3/3 grounded, ≥80% threshold → PASS exit 0.
# (i,j) Mocked FAIL fixtures share the same builder — same SKILL.md, refs,
# and prompts; the differentiator is the --mock-responses payload.
fx_mock_run() {
  local dir="$1"
  write_skill_md "$dir"
  write_references "$dir"
  write_valid_prompts "$dir"
}
run_case "mock grounded PASS (3/3)" 0 \
  "[PASS] grounded-rate" fx_mock_run \
  --mock-responses "$FIXTURES/grounded-pass-mocks.json"

run_case "mock grounded FAIL (1/3)" 1 \
  "[FAIL] grounded-rate" fx_mock_run \
  --mock-responses "$FIXTURES/grounded-fail-mocks.json"

# (j) Mocked grounded-FAIL surfaces per-prompt failure markers.
run_case "mock FAIL shows no-reference-opened marker" 1 \
  "[no-reference-opened]" fx_mock_run \
  --mock-responses "$FIXTURES/grounded-fail-mocks.json"
run_case "mock FAIL shows no-permalink-in-response marker" 1 \
  "[no-permalink-in-response]" fx_mock_run \
  --mock-responses "$FIXTURES/grounded-fail-mocks.json"

# (k) Error-marker fixture: all three error paths surface their markers
# AND the all-errored gate emits exit 2 (runner failure).
run_case "all-errored runner failure → exit 2" 2 \
  "all prompts errored" fx_mock_run \
  --mock-responses "$FIXTURES/grounded-error-markers-mocks.json"
run_case "error fixture surfaces tool-turn-cap-exceeded marker" 2 \
  "[tool-turn-cap-exceeded]" fx_mock_run \
  --mock-responses "$FIXTURES/grounded-error-markers-mocks.json"
run_case "error fixture surfaces per-prompt-timeout marker" 2 \
  "[per-prompt-timeout]" fx_mock_run \
  --mock-responses "$FIXTURES/grounded-error-markers-mocks.json"
run_case "error fixture surfaces api-error marker" 2 \
  "[api-error]" fx_mock_run \
  --mock-responses "$FIXTURES/grounded-error-markers-mocks.json"

# (k2) Finding 5 regression: every prompt opened a reference and THEN errored.
# The all-errored gate must still return exit 2 (runner failure); the pre-fix
# `not references_opened` conjunct demoted this outage to a content FAIL (1).
run_case "all-errored WITH refs opened → exit 2" 2 \
  "all prompts errored" fx_mock_run \
  --mock-responses "$FIXTURES/grounded-error-refs-opened-mocks.json"

# (l) References dir present but empty → N/A (matches Check 7 convention).
fx_empty_refs() {
  local dir="$1"
  write_skill_md "$dir"
  # references/ exists (mkdir -p in run_case) but contains no .md files
  write_valid_prompts "$dir"
}
run_case "empty references dir is N/A" 0 \
  "no .md files under references/" fx_empty_refs

# (m) Whitespace-only prompt text → schema invalid FAIL.
fx_whitespace_prompt() {
  local dir="$1"
  write_skill_md "$dir"
  write_references "$dir"
  cat > "$dir/research/eval-prompts.json" <<'EOF'
{
  "schema_version": 1,
  "prompts": [{"id": "n01", "category": "needs_reference", "text": "   "}]
}
EOF
}
run_case "whitespace-only prompt text is schema invalid" 1 \
  "whitespace-only" fx_whitespace_prompt

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
