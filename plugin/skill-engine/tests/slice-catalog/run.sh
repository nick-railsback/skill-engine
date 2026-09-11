#!/usr/bin/env bash
# Black-box oracle for a sliced contextualizer's navigator catalog shape.
#
# THE INVARIANTS.
#   - The multi-domain navigator template documents a per-slice catalog
#     heading shape, `## Catalog: <slug>/<slice-id>`, nested inside the same
#     `## Catalog` container the existing per-source `## Catalog: <source-
#     slug>` sections already use, with a worked example naming at least two
#     concrete slices.
#   - The pre-existing per-source catalog form is preserved, unrestructured,
#     alongside the new slice form -- documenting slices never means
#     deleting or rewriting the source form.
#   - The navigator standing-instructions budget script already excludes any
#     heading shaped `## Catalog: ...` from its byte count, slice
#     subsections included, with no change to the script itself: a fixture
#     navigator reports identical standing bytes whether or not it carries
#     slice subsections.
#   - The stamped verify.sh's catalog-bijection check already reads catalog
#     rows nested under a `## Catalog: <slug>/<slice-id>` heading into the
#     bijection, with no change to the script itself: a fixture whose only
#     catalog rows sit under slice subsections still passes the bijection
#     check, every reference matched, none orphaned or phantom.
#   - 07-monorepo-adapter.md's introduction and its forward-pointers section
#     keep describing the adapter as a shipped, composed layer -- unchanged
#     by this feature's edits to the chapter, if any.
#   - The three bundled examples are untouched, and each still carries the
#     load-bearing Claims-policy sentences the doctrine example-sync check
#     depends on.
#
# THIS ORACLE HAS TWO HALVES: prose assertions against the template and the
# doctrine chapter (wrap-normalized -- see norm() below; hand-wrapped
# Markdown can carry a multi-word phrase across a line break that a naive
# line-oriented grep would miss), and an executed half that runs the real
# navigator_budget.py and the real stamped verify.sh against fixture
# navigators built fresh in a tmpdir.
#
# -e is intentionally omitted: every assertion runs and reports, not abort
# at the first failing one. Every tmpdir this file creates is removed on
# exit.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_ROOT="$(cd "$TESTS_ROOT/.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

TEMPLATE="$PLUGIN_ROOT/engine-bootstrap-templates/navigator-multi-domain.md.template"
MONOREPO_DOC="$PLUGIN_ROOT/docs/07-monorepo-adapter.md"
VERIFY_SH="$PLUGIN_ROOT/engine-bootstrap-templates/verify.sh"
BUDGET_PY="$PLUGIN_ROOT/tests/navigator_budget.py"
EXAMPLES_DIR="$REPO_ROOT/examples"

for f in "$TEMPLATE" "$MONOREPO_DOC" "$VERIFY_SH" "$BUDGET_PY"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: expected surface is missing entirely: $f" >&2
    exit 69
  fi
done
if [ ! -d "$EXAMPLES_DIR" ]; then
  echo "ERROR: expected surface is missing entirely: $EXAMPLES_DIR" >&2
  exit 69
fi

WORK="$(mktemp -d -t skill-engine-slice-catalog.XXXXXX)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

pass_count=0
fail_count=0

section() { printf '\n── %s ──\n' "$1"; }

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

# ---------------------------------------------------------------------------
# Text-matching helpers (wrap-normalized prose assertions).
# ---------------------------------------------------------------------------

norm() { tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'; }

assert_contains() {
  local label="$1" text="$2" lit="$3"
  if printf '%s' "$text" | grep -qF -- "$lit"; then
    pass "$label"
  else
    fail "$label" "string not found: $lit"
  fi
}

assert_contains_norm() {
  local label="$1" text="$2" lit="$3"
  local norm_text norm_lit
  norm_text="$(printf '%s' "$text" | norm)"
  norm_lit="$(printf '%s' "$lit" | norm)"
  if printf '%s' "$norm_text" | grep -qF -- "$norm_lit"; then
    pass "$label"
  else
    fail "$label" "wrap-normalized string not found: $norm_lit"
  fi
}

# extract_catalog_container <file> — every line from the first heading
# shaped `## Catalog` (bare, or followed by `:` or a space -- the same
# word-boundary the shipped navigator_budget.py's CATALOG_HEADING_RE
# matches) through the last line before the next `## ` heading that is NOT
# itself shaped `## Catalog...`. Mirrors navigator_budget.py's own
# skip_catalog state machine, so this test's notion of "the Catalog
# container" is the contract's own, not a reinvented one.
extract_catalog_container() {
  local file="$1"
  local in_block=0
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "## Catalog"|"## Catalog:"*|"## Catalog "*)
        in_block=1
        printf '%s\n' "$line"
        continue
        ;;
    esac
    if [ "$in_block" -eq 1 ]; then
      case "$line" in
        "## "*)
          in_block=0
          ;;
        *)
          printf '%s\n' "$line"
          ;;
      esac
    fi
  done < "$file"
}

# ===========================================================================
# Section A — prose: the template documents the slice catalog heading shape,
# a worked two-slice example, and keeps the per-source form intact, all
# under the same Catalog container.
# ===========================================================================
section "navigator-multi-domain.md.template — slice catalog heading shape"

TEMPLATE_TEXT="$(cat "$TEMPLATE")"
CONTAINER_TEXT="$(extract_catalog_container "$TEMPLATE")"

assert_contains "slice_catalog_heading_shape_documented" "$TEMPLATE_TEXT" \
  '## Catalog: <slug>/<slice-id>'

# Concrete worked-example headings only: any `## Catalog: <a>/<b>` line
# inside the Catalog container whose two tokens contain neither `/` nor
# whitespace (so it matches indented placeholder-style slugs like
# `<source-slug-1>/billing` just as readily as bare ones like
# `bigmono/reports`), excluding the literal abstract shape line itself.
slice_example_headings="$(printf '%s\n' "$CONTAINER_TEXT" \
  | grep -E '^[[:space:]]*## Catalog: [^/[:space:]]+/[^/[:space:]]+[[:space:]]*$' \
  | grep -vF -- '<slug>/<slice-id>' \
  | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
  | sort -u)"
slice_example_count="$(printf '%s\n' "$slice_example_headings" | grep -c .)"
if [ "$slice_example_count" -ge 2 ]; then
  pass "slice_catalog_worked_two_slice_example"
else
  fail "slice_catalog_worked_two_slice_example" \
    "expected >=2 distinct concrete '## Catalog: <slug>/<slice-id>'-shaped headings inside the Catalog container; found $slice_example_count" \
    "headings seen:" "$slice_example_headings"
fi

assert_contains "per_source_catalog_heading_prefix_preserved" "$TEMPLATE_TEXT" \
  '## Catalog: <source-slug>'

if printf '%s' "$CONTAINER_TEXT" | grep -qF -- '<source-slug-1>' \
   && printf '%s' "$CONTAINER_TEXT" | grep -qF -- '<source-slug-2>'; then
  pass "per_source_catalog_worked_example_preserved_in_same_container"
else
  fail "per_source_catalog_worked_example_preserved_in_same_container" \
    "expected both <source-slug-1> and <source-slug-2> still documented inside the same Catalog container the slice form now shares"
fi

# ===========================================================================
# Section B — executed: navigator_budget.py excludes slice subsections from
# the standing-instructions byte count exactly as it excludes per-source
# sections, with no change to the script itself.
# ===========================================================================
section "navigator_budget.py — slice subsections excluded from standing bytes"

STANDING_HEAD='---
name: fixture-context
description: fixture navigator for the budget oracle
---

# Context navigator (fixture)

## Overview

Some standing instructions that must always count toward the byte budget,
no matter how the Catalog section below is shaped.

## Claims policy

Cite everything, always, in every answer this fixture navigator gives.

## Catalog

## Catalog: acme

| Reference | Description |
|---|---|
| [acme-foo](references/acme-foo.md) | foo reference |
'

STANDING_TAIL='
## Progressive disclosure

Closing standing instructions that must also always count toward the byte
budget, after the Catalog section has ended.
'

FIXTURE_NO_SLICES="$WORK/no-slices.md"
printf '%s%s' "$STANDING_HEAD" "$STANDING_TAIL" > "$FIXTURE_NO_SLICES"

FIXTURE_WITH_SLICES="$WORK/with-slices.md"
{
  printf '%s' "$STANDING_HEAD"
  cat <<'EOF'

## Catalog: acme/billing

| Reference | Description |
|---|---|
| [acme-billing](references/acme-billing.md) | billing reference, padded with extra descriptive prose so this subsection is clearly larger than the per-source one above it |

## Catalog: acme/reports

| Reference | Description |
|---|---|
| [acme-reports](references/acme-reports.md) | reports reference, also padded with extra descriptive prose to make a byte-count difference unmistakable if it were ever counted |
EOF
  printf '%s' "$STANDING_TAIL"
} > "$FIXTURE_WITH_SLICES"

budget_bytes() {
  local file="$1" out
  out="$(python3 "$BUDGET_PY" "$file")"
  printf '%s\n' "$out" | sed -nE 's/.*navigator-budget: ([0-9,]+) bytes,.*/\1/p' | tr -d ','
}

bytes_no_slices="$(budget_bytes "$FIXTURE_NO_SLICES")"
bytes_with_slices="$(budget_bytes "$FIXTURE_WITH_SLICES")"

if [ -n "$bytes_no_slices" ] && [ -n "$bytes_with_slices" ] && [ "$bytes_no_slices" = "$bytes_with_slices" ]; then
  pass "budget_excludes_slice_subsections"
else
  fail "budget_excludes_slice_subsections" \
    "expected equal standing-instruction byte counts with and without slice subsections" \
    "without slice subsections: ${bytes_no_slices:-<unparsed>} bytes" \
    "with slice subsections:    ${bytes_with_slices:-<unparsed>} bytes"
fi

# ===========================================================================
# Section C — executed: the stamped verify.sh's catalog-bijection check
# (Check 4) reads catalog rows nested under slice subsections into the
# bijection, with no change to the script itself.
# ===========================================================================
section "verify.sh Check 4 — catalog rows under slice subsections resolve the bijection"

FIXTURE_CTX="$WORK/ctx"
mkdir -p "$FIXTURE_CTX/research" "$FIXTURE_CTX/references"

cat > "$FIXTURE_CTX/research/source-paths.json" <<'EOF'
{
  "schema_version": 1,
  "sources": []
}
EOF

cat > "$FIXTURE_CTX/SKILL.md" <<'EOF'
---
name: fixture-context
description: fixture navigator for the bijection oracle
---

# Context navigator (fixture)

## Catalog

## Catalog: acme/billing

| Reference | Description |
|---|---|
| [acme-billing](references/acme-billing.md) | billing reference |

## Catalog: acme/reports

| Reference | Description |
|---|---|
| [acme-reports](references/acme-reports.md) | reports reference |
EOF

cat > "$FIXTURE_CTX/references/acme-billing.md" <<'EOF'
# Acme Billing

Fixture reference content for the billing slice.
EOF

cat > "$FIXTURE_CTX/references/acme-reports.md" <<'EOF'
# Acme Reports

Fixture reference content for the reports slice.
EOF

verify_out="$(CTX_ROOT="$FIXTURE_CTX" bash "$VERIFY_SH" 2>&1)"
verify_rc=$?

check4_section="$(printf '%s\n' "$verify_out" | awk -v start='=== Catalog ↔ references bijection (catalog-bijection) ===' '
  $0 == start { grab = 1; next }
  grab && index($0, "=== ") == 1 { grab = 0 }
  grab { print }
')"

if [ "$verify_rc" -eq 0 ]; then
  pass "verify_sh_fixture_runs_clean"
else
  fail "verify_sh_fixture_runs_clean" \
    "expected the fixture contextualizer to pass verify.sh outright (rc=$verify_rc)" "$verify_out"
fi

if printf '%s' "$check4_section" | grep -q '\[FAIL\]'; then
  fail "bijection_no_failures_for_slice_subsection_rows" "$check4_section"
else
  pass "bijection_no_failures_for_slice_subsection_rows"
fi

assert_contains "bijection_counts_both_slice_subsection_rows" "$check4_section" \
  'Catalog ↔ references bijection valid (2 references, all linked from catalog)'

# ===========================================================================
# Section D — prose + preservation: 07-monorepo-adapter.md's introduction and
# its forward-pointers section (§7.11) still describe the adapter as a
# shipped, composed layer. This section is allowed to already be green --
# nothing in this feature needs to touch these sentences.
# ===========================================================================
section "07-monorepo-adapter.md — the adapter still reads as a shipped, composed layer"

MONOREPO_TEXT="$(cat "$MONOREPO_DOC")"

assert_contains_norm "monorepo_adapter_intro_describes_shipped_layer" "$MONOREPO_TEXT" \
  "This chapter covers the **monorepo adapter**: a lightweight layer the engine uses to treat one giant repository as N freshness units instead of one."

assert_contains_norm "monorepo_adapter_intro_describes_recipe_grade_composition" "$MONOREPO_TEXT" \
  "None of these are new engine machinery; they are recipe-grade additions that compose with the existing pipeline."

assert_contains_norm "monorepo_adapter_forward_pointers_describe_read_by_maintenance_agent" "$MONOREPO_TEXT" \
  "The adapter is **read** by the \`maintenance-agent.md.template\`"

assert_contains_norm "monorepo_adapter_forward_pointers_describe_config_machine_validated" "$MONOREPO_TEXT" \
  "The adapter's config schema is machine-validated by the consumer-stamped \`verify.sh\`'s \`monorepo-config\` check"

assert_contains_norm "monorepo_adapter_forward_pointers_describe_bootstrapped" "$MONOREPO_TEXT" \
  "The adapter is **bootstrapped** by \`bootstrap-monorepo-config.sh.template\`."

assert_contains_norm "monorepo_adapter_forward_pointers_describe_shaped_by_claude_md" "$MONOREPO_TEXT" \
  "The adapter is **shaped** by per-slice \`CLAUDE.md\` files the maintainer authors in their monorepo."

# ===========================================================================
# Section E — preservation: the three bundled examples are untouched, and
# each still carries the load-bearing Claims-policy sentences the doctrine
# example-sync check depends on.
# ===========================================================================
section "bundled examples — untouched, and still doctrine-sync-clean"

KNOWN_EXAMPLE_SLUGS=(inspect-ai-context langchain-context modelcontextprotocol-python-sdk-context)

actual_example_dirs=""
while IFS= read -r -d '' d; do
  actual_example_dirs="$actual_example_dirs${d##*/}"$'\n'
done < <(find "$EXAMPLES_DIR" -mindepth 1 -maxdepth 1 -type d -not -name '.*' -print0 2>/dev/null)
actual_example_dirs="$(printf '%s' "$actual_example_dirs" | sort)"
expected_example_dirs="$(printf '%s\n' "${KNOWN_EXAMPLE_SLUGS[@]}" | sort)"

if [ "$actual_example_dirs" = "$expected_example_dirs" ]; then
  pass "bundled_examples_set_unchanged"
else
  fail "bundled_examples_set_unchanged" \
    "expected exactly:" "$expected_example_dirs" "found:" "$actual_example_dirs"
fi

claims_sentence_1="This inline permalink is what the grounded-citation eval (SELF-AUDIT Check 8) grades."
claims_sentence_2="summary of what you read — not a substitute"

for slug in "${KNOWN_EXAMPLE_SLUGS[@]}"; do
  example_skill="$EXAMPLES_DIR/$slug/SKILL.md"
  if [ ! -f "$example_skill" ]; then
    fail "bundled_example_claims_policy_intact_$slug" "SKILL.md not found: $example_skill"
    continue
  fi
  example_text="$(cat "$example_skill")"
  if printf '%s' "$example_text" | grep -qF -- "$claims_sentence_1" \
     && printf '%s' "$example_text" | grep -qF -- "$claims_sentence_2"; then
    pass "bundled_example_claims_policy_intact_$slug"
  else
    fail "bundled_example_claims_policy_intact_$slug" \
      "missing one of the two load-bearing Claims-policy sentences the doctrine example-sync check requires"
  fi

  # Regenerating a bundled example as a sliced contextualizer is explicitly
  # out of scope for this feature -- none of the three should have grown a
  # slice-shaped catalog heading of their own.
  if printf '%s' "$example_text" | grep -qE '^## Catalog: [^/[:space:]]+/[^/[:space:]]+[[:space:]]*$'; then
    fail "bundled_example_not_regenerated_as_sliced_$slug" \
      "found a '## Catalog: <slug>/<slice-id>'-shaped heading in a bundled example; regenerating an example as sliced is out of scope"
  else
    pass "bundled_example_not_regenerated_as_sliced_$slug"
  fi
done

# ----- summary -------------------------------------------------------------

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
