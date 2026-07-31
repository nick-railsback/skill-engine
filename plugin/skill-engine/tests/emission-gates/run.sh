#!/usr/bin/env bash
# Feature-scoped test runner for DISCOVER's pre-manifest emission gates —
# the merged-tree verification step (`references/proposal-and-post-run.md`
# § "Post-run summary") that runs `verify.sh` against an ephemeral
# live+proposed overlay before `REVIEW.md` is ever written.
#
# Two kinds of cases:
#   - verify.sh cases build a minimal contextualizer fixture under a tmpdir
#     and invoke the real template script against it with CTX_ROOT set —
#     same pattern as tests/permalink-density/run.sh.
#   - document-text cases assert structural facts about the prose+bash the
#     gate step and `review`'s second pass are made of, by extracting the
#     relevant section/fence from the real file and grepping it — the
#     convention this repo uses for behavior an LLM agent executes at
#     runtime rather than a standalone script.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TEMPLATE="$PLUGIN_ROOT/engine-bootstrap-templates/verify.sh"
PROPOSAL_DOC="$PLUGIN_ROOT/skills/discover/references/proposal-and-post-run.md"
REVIEW_SKILL="$PLUGIN_ROOT/skills/review/SKILL.md"

pass_count=0
fail_count=0
created_dirs=()

cleanup_tmp() {
  local d
  for d in "${created_dirs[@]:-}"; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
}
trap cleanup_tmp EXIT

report() {
  local ok="$1" name="$2"
  if [ "$ok" -eq 1 ]; then
    printf '  PASS  %s\n' "$name"
    pass_count=$((pass_count + 1))
  else
    printf '  FAIL  %s\n' "$name"
    fail_count=$((fail_count + 1))
  fi
}

# ────────────────────────────────────────────────────────────────────────
# Fixture helpers
# ────────────────────────────────────────────────────────────────────────

# bytes_of <literal-byte-sequence> <repeat-count> — repeats a literal byte
# sequence N times via printf's format-reapplication behavior (the format
# string itself carries the literal; %.0s consumes one arg per cycle and
# prints none of it). Used to build description values of an exact byte
# length, including multi-byte UTF-8 sequences passed as raw bytes.
bytes_of() {
  local lit="$1" n="$2"
  printf -- "${lit}%.0s" $(seq 1 "$n")
}

# byte_len <string> — portable byte count (wc -c is always byte-count,
# independent of locale, unlike wc -m).
byte_len() {
  printf '%s' "$1" | wc -c | tr -d ' '
}

# build_min_ctx <root> <description-value> — a minimal contextualizer tree
# that satisfies every verify.sh check except the one under test: empty
# sources[] (Check 2 skips), no references/ (Checks 4/5 skip), no
# SKILL.json (Check 9 skips). Only Check 3 (navigator frontmatter) is live,
# so the script's exit code is driven solely by the description value.
build_min_ctx() {
  local root="$1" desc="$2"
  mkdir -p "$root/research"
  printf '{"schema_version":1,"sources":[]}\n' > "$root/research/source-paths.json"
  {
    printf -- '---\n'
    printf 'name: acme-context\n'
    printf 'description: %s\n' "$desc"
    printf -- '---\n\n# Acme\n'
  } > "$root/SKILL.md"
}

run_verify() {
  local root="$1"
  CTX_ROOT="$root" "$TEMPLATE" 2>&1
}

# ────────────────────────────────────────────────────────────────────────
# description-length gate: a navigator description over a fixed byte cap
# fails the gate; at/under the cap it is unaffected.
# ────────────────────────────────────────────────────────────────────────

desc_at_cap=$(bytes_of 'a' 1024)
desc_over_cap=$(bytes_of 'a' 1025)

# Fixture self-check: guards the case below against a generator bug
# silently producing the wrong byte count (which would make the case
# meaningless rather than red for the right reason).
if [ "$(byte_len "$desc_at_cap")" -ne 1024 ] || [ "$(byte_len "$desc_over_cap")" -ne 1025 ]; then
  printf '  FAIL  fixture error: byte-length generator did not produce the expected byte counts\n'
  fail_count=$((fail_count + 1))
else
  root_at="$(mktemp -d -t skill-engine-emission-gates.XXXXXX)"
  created_dirs+=("$root_at")
  build_min_ctx "$root_at" "$desc_at_cap"
  run_verify "$root_at" >/dev/null; rc_at=$?

  root_over="$(mktemp -d -t skill-engine-emission-gates.XXXXXX)"
  created_dirs+=("$root_over")
  build_min_ctx "$root_over" "$desc_over_cap"
  out_over="$(run_verify "$root_over")"; rc_over=$?

  ok=1
  [ "$rc_at" -eq 0 ] || ok=0
  [ "$rc_over" -ne 0 ] || ok=0
  printf '%s' "$out_over" | grep -qi 'description' || ok=0
  printf '%s' "$out_over" | grep -q '1024' || ok=0
  report "$ok" "description-length gate: exactly-1024-byte description passes, 1025-byte description fails naming the byte cap"
fi

# byte length, not character count, is what is measured — a description
# with fewer than 1024 characters but more than 1024 UTF-8 bytes (a
# 2-byte character repeated 600 times: 600 chars, 1200 bytes) must still
# fail. An implementation that measured characters instead of bytes would
# wrongly let this through.
desc_multibyte=$(bytes_of $'\xC3\xA9' 600)
if [ "$(byte_len "$desc_multibyte")" -ne 1200 ]; then
  printf '  FAIL  fixture error: multi-byte generator did not produce 1200 bytes\n'
  fail_count=$((fail_count + 1))
else
  root_mb="$(mktemp -d -t skill-engine-emission-gates.XXXXXX)"
  created_dirs+=("$root_mb")
  build_min_ctx "$root_mb" "$desc_multibyte"
  run_verify "$root_mb" >/dev/null; rc_mb=$?
  ok=0
  [ "$rc_mb" -ne 0 ] && ok=1
  report "$ok" "description-length gate: cap is measured in UTF-8 bytes, not characters (600 two-byte chars = 1200 bytes exceeds the cap despite being under 1024 characters)"
fi

# ────────────────────────────────────────────────────────────────────────
# Document-text cases: the merged-tree gate procedure and review's second
# pass are prose+bash an agent executes at runtime, not a standalone
# script. Extract the relevant section/fence and assert structural facts
# about it.
# ────────────────────────────────────────────────────────────────────────

# The gate section runs from "## Post-run summary" to end of file (the
# last section in this document today).
gate_section="$(awk '/^## Post-run summary/{p=1} p' "$PROPOSAL_DOC")"

# The merged-tree bash fence inside the gate section (the block that
# builds the ephemeral tree and runs verify.sh against it).
mt_block="$(printf '%s\n' "$gate_section" | awk '
  /^```bash$/ && !found { found=1; next }
  found && /^```$/ { exit }
  found { print }
')"

if [ -z "$mt_block" ]; then
  printf '  FAIL  fixture error: could not locate the merged-tree bash fence in %s\n' "$PROPOSAL_DOC"
  fail_count=$((fail_count + 1))
fi

# cross-root collision gate: a proposed <name>-context directory that
# collides with an existing one under a DIFFERENT install root than the
# one this run targets is flagged before REVIEW.md is written; the check
# reuses the shared locator's glob (no second definition of the
# three-root list) and does not flag the ordinary same-root
# update-in-place case.
ok=1
printf '%s' "$gate_section" | grep -qiE 'collis' || ok=0
printf '%s' "$gate_section" | grep -qi 'locator-block' || ok=0
printf '%s' "$gate_section" | grep -qiE 'different[^.]{0,40}root|other[^.]{0,40}root' || ok=0
printf '%s' "$gate_section" | grep -qiE 'same[^.]{0,20}root|update-in-place' || ok=0
# A hardcoded copy of the locator's three-root list (rather than reusing
# it) would defeat the reuse requirement even if the collision keywords
# above happen to be present.
if printf '%s' "$gate_section" | grep -qF '$HOME/.claude/skills' \
    && printf '%s' "$gate_section" | grep -qF '$HOME/.claude/local/skills' \
    && printf '%s' "$gate_section" | grep -qF '$PWD/.claude/skills'; then
  ok=0
fi
report "$ok" "cross-root collision gate: a colliding navigator name under a different install root is flagged before REVIEW.md is written, reusing the shared locator's glob instead of a second root list, and a same-root update is not flagged"

# density report-only gate: permalink_density.py runs against the merged
# tree's references/ directory inside the same gate step that runs
# verify.sh — not a separately invoked script — and its result never
# changes verify.sh's own exit code (report-only).
ok=1
printf '%s' "$mt_block" | grep -q 'verify.sh' || ok=0
printf '%s' "$mt_block" | grep -q 'permalink_density.py' || ok=0
# Exactly one exit-code capture in the block, and it belongs to the
# verify.sh invocation — the density command's own exit status must not
# be folded into the variable that decides whether the gate aborts.
rc_capture_count="$(printf '%s' "$mt_block" | grep -c 'rc=\$?' || true)"
[ "$rc_capture_count" -eq 1 ] || ok=0
rc_capture_line="$(printf '%s' "$mt_block" | grep -n 'rc=\$?' | tail -1)"
printf '%s' "$rc_capture_line" | grep -q 'verify.sh' || ok=0
report "$ok" "density report-only gate: permalink_density.py runs inside the same gate step as verify.sh, and verify.sh's own exit code is unaffected by the density result"

# post-run Coverage report: the density percentage this run computed
# appears in the post-run summary's Coverage report component.
coverage_bullet="$(printf '%s\n' "$gate_section" | awk '
  /^1\. \*\*Coverage report\.\*\*/ {p=1}
  /^2\. \*\*Skip-reasoning\.\*\*/ {p=0}
  p {print}
')"
ok=0
printf '%s' "$coverage_bullet" | grep -qi 'density' && ok=1
report "$ok" "post-run Coverage report: surfaces the paragraph-to-permalink density percentage computed this run"

# review Step 2 positioning: the density figure appears somewhere in
# review's output but is not one of the 5-9 ranked disagreement
# categories Step 2 computes (scope-mismatch, content-style,
# reference-count) — it must not consume one of those slots.
review_all="$(cat "$REVIEW_SKILL")"
step2_categories="$(awk '
  /^2\. \*\*Compute 5–9 disagreements\*\*/ {p=1}
  /^3\. \*\*Write 5–9 disagreements\*\*/ {p=0}
  p {print}
' "$REVIEW_SKILL")"
ok=1
printf '%s' "$review_all" | grep -qi 'density' || ok=0
printf '%s' "$step2_categories" | grep -qi 'density' && ok=0
report "$ok" "review Step 2 positioning: the density figure surfaces in review's output without being ranked as a fourth disagreement category"

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
