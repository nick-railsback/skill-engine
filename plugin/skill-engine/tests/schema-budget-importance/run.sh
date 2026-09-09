#!/usr/bin/env bash
# Black-box oracle for two additive source-paths.json fields: a root-level
# `probe_budget` (JSON integer >= 1) and a per-source `importance` (JSON
# integer 1-5, absent meaning neutral/default 3).
#
# THE INVARIANTS.
#   - probe_budget accepts any JSON integer >= 1 and rejects 0, a negative
#     integer, a non-integer number (1.5 specifically -- JSON Schema's
#     `integer` type accepts a float with no fractional part like 1.0 but
#     must reject one with a fractional part like 1.5), and a string.
#   - importance accepts an integer from 1 to 5 and rejects 0, 6, and a
#     string.
#   - Every existing examples/*/research/source-paths.json, the dogfood
#     source-paths.json, and source-paths.json.template still validate
#     unchanged, and the existing negative fixtures under
#     tests/web-doc/fixtures/schema/invalid/ are still rejected, once the
#     schema gains these two optional fields.
#   - 02-artifact-contract.md's source-paths.json entry shape documents
#     both fields, their ranges, and their absent-value meaning; 03-engine.md's
#     "Source-paths additive fields" section points at the schema as the
#     enforcement mechanism for probe_budget.
#
# THIS RUNS check-jsonschema DIRECTLY AGAINST FIXTURES when it is on PATH:
# every fixture under fixtures/valid/ must validate, every fixture under
# fixtures/invalid/ must fail validation naming the field under test (not
# fail for some unrelated reason), and the preservation set (existing
# examples, the dogfood file, the template, and the existing web-doc
# negative fixtures) must validate exactly as it does today. Right now
# neither field is declared in the schema at all -- additionalProperties
# is open at both the document root and the per-source level -- so every
# "must reject" fixture below currently validates successfully and every
# assertion that depends on the field being constrained fails for that
# reason: the constraint is absent, not the harness broken.
#
# WHEN check-jsonschema IS NOT ON PATH, this degrades the same way
# `scripts/ci-local.sh json` does: it skips every check that requires
# running the validator (the fixture pass/fail set and the preservation
# set) rather than failing the suite merely because the binary is
# missing, and instead asserts what it can without it -- the schema's own
# JSON text (does `properties.probe_budget` declare `type: integer,
# minimum: 1`; does `$defs.source.properties.importance` declare
# `type: integer, minimum: 1, maximum: 5`) and the two docs' prose.
#
# -e is intentionally omitted (see set -uo pipefail below): every
# assertion runs and reports, not abort at the first failing one.

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

SCHEMA="$PLUGIN_ROOT/engine-bootstrap-templates/source-paths.schema.json"
TEMPLATE="$PLUGIN_ROOT/engine-bootstrap-templates/source-paths.json.template"
CONTRACT_MD="$PLUGIN_ROOT/docs/02-artifact-contract.md"
ENGINE_MD="$PLUGIN_ROOT/docs/03-engine.md"
DOGFOOD_SOURCE_PATHS="$REPO_ROOT/.claude/skills/skill-engine-context/research/source-paths.json"
WEBDOC_INVALID_DIR="$PLUGIN_ROOT/tests/web-doc/fixtures/schema/invalid"
FIXTURES="$SCRIPT_DIR/fixtures"

for f in "$SCHEMA" "$TEMPLATE" "$CONTRACT_MD" "$ENGINE_MD" "$DOGFOOD_SOURCE_PATHS"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: expected surface is missing entirely: $f" >&2
    exit 69
  fi
done
if [ ! -d "$WEBDOC_INVALID_DIR" ]; then
  echo "ERROR: expected fixture directory is missing entirely: $WEBDOC_INVALID_DIR" >&2
  exit 69
fi

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

# near <text> <anchor-ere> <needle-ere> <window> — true when <needle>
# occurs within <window> characters of some occurrence of <anchor> in
# <text>. 200, not more: some grep implementations reject an interval
# bound above 255, and the window applies on both sides of the anchor.
near() {
  local text="$1" anchor="$2" needle="$3" window="$4"
  # `grep -c ... > /dev/null`, not `grep -q`: -q exits at its first match,
  # SIGPIPE-ing the upstream -o while that is still writing its remaining
  # windows. Under `set -o pipefail` the pipeline then reports 141 and a
  # needle that WAS found reads as a miss -- the more occurrences of the
  # anchor, the likelier it fires. -c carries the same 0/1 match semantics
  # but drains its input to EOF, so the verdict no longer depends on the
  # anchor's frequency or on the pipe buffer size.
  printf '%s' "$text" \
    | grep -oiE ".{0,${window}}${anchor}.{0,${window}}" \
    | grep -ciE -- "$needle" > /dev/null
}

# near_all <text> <anchor-ere> <window> <needle-ere>... — true when EVERY
# given needle occurs somewhere within <window> characters of some
# occurrence of <anchor> (not necessarily the same occurrence, and not
# necessarily all in one needle's own window — tolerant on purpose, since
# the exact phrasing a future edit lands on isn't known yet).
near_all() {
  local text="$1" anchor="$2" window="$3"
  shift 3
  local needle
  for needle in "$@"; do
    near "$text" "$anchor" "$needle" "$window" || return 1
  done
  return 0
}

# ---------------------------------------------------------------------------
# Doc prose: 02-artifact-contract.md's "source-paths.json entry shape"
# section, and 03-engine.md's "Source-paths additive fields" paragraph.
# Extracted by heading/anchor, not a hardcoded line number, since the
# exact line either sits on can shift as prose is edited around it.
# ---------------------------------------------------------------------------

banner "locating the two doc sections under test"

CONTRACT_SECTION_START="$(line_of "$CONTRACT_MD" '^### source-paths\.json entry shape')"
CONTRACT_SECTION_END="$(line_of "$CONTRACT_MD" '^### Body - the core sections, in order')"
if [ -z "$CONTRACT_SECTION_START" ] || [ -z "$CONTRACT_SECTION_END" ]; then
  echo "ERROR: cannot locate the 'source-paths.json entry shape' / 'Body - the core sections' headings in $CONTRACT_MD" >&2
  exit 69
fi
RAW_CONTRACT_SECTION="$(sed -n "${CONTRACT_SECTION_START},$((CONTRACT_SECTION_END - 1))p" "$CONTRACT_MD")"
NORM_CONTRACT_SECTION="$(norm_str "$RAW_CONTRACT_SECTION")"

ENGINE_SECTION_START="$(line_of "$ENGINE_MD" '^\*\*Source-paths additive fields\.\*\*')"
ENGINE_SECTION_END="$(line_of "$ENGINE_MD" '^\*\*REFRESH temporal-delta verbiage\.\*\*')"
if [ -z "$ENGINE_SECTION_START" ] || [ -z "$ENGINE_SECTION_END" ]; then
  echo "ERROR: cannot locate the 'Source-paths additive fields' / 'REFRESH temporal-delta verbiage' paragraph markers in $ENGINE_MD" >&2
  exit 69
fi
RAW_ENGINE_SECTION="$(sed -n "${ENGINE_SECTION_START},$((ENGINE_SECTION_END - 1))p" "$ENGINE_MD")"
NORM_ENGINE_SECTION="$(norm_str "$RAW_ENGINE_SECTION")"
pass "doc_sections_located"

# ---------------------------------------------------------------------------
# 02-artifact-contract.md documents both fields: name, range, and the
# absent-value meaning.
# ---------------------------------------------------------------------------

banner "02-artifact-contract.md documents probe_budget"

assert_str "contract_probe_budget_named" "$NORM_CONTRACT_SECTION" 'probe_budget'

if near_all "$NORM_CONTRACT_SECTION" 'probe_budget' 200 'integer' '(≥ ?1|>= ?1|at least 1|minimum of 1|1 or (greater|more|higher))'; then
  pass "contract_probe_budget_range_documented"
else
  fail "contract_probe_budget_range_documented" \
    "expected probe_budget documented near both 'integer' and a >=1 lower-bound phrase"
fi

if near_all "$NORM_CONTRACT_SECTION" 'probe_budget' 200 'absent' '(probes? (all|every))'; then
  pass "contract_probe_budget_absent_meaning_documented"
else
  fail "contract_probe_budget_absent_meaning_documented" \
    "expected probe_budget documented near both 'absent' and a 'probe all/every' phrase (absent budget => probe all sources)"
fi

banner "02-artifact-contract.md documents importance"

assert_str "contract_importance_named" "$NORM_CONTRACT_SECTION" 'importance'

if near_all "$NORM_CONTRACT_SECTION" 'importance' 200 'integer' '(1.{0,10}(to|-|–|through|and|,).{0,10}5|1 to 5|1-5|1–5)'; then
  pass "contract_importance_range_documented"
else
  fail "contract_importance_range_documented" \
    "expected importance documented near both 'integer' and a 1-to-5 range phrase"
fi

if near_all "$NORM_CONTRACT_SECTION" 'importance' 200 'absent' '((default|⇒|=>).{0,15}3|3.{0,15}default)'; then
  pass "contract_importance_absent_meaning_documented"
else
  fail "contract_importance_absent_meaning_documented" \
    "expected importance documented near both 'absent' and a 'default(s) to 3' phrase"
fi

banner "03-engine.md points at the schema as probe_budget's enforcement"

if near "$NORM_ENGINE_SECTION" 'probe_budget' 'schema' 200; then
  pass "engine_probe_budget_points_at_schema"
else
  fail "engine_probe_budget_points_at_schema" \
    "expected the 'Source-paths additive fields' paragraph to name the schema as what enforces probe_budget's bounds"
fi

# ---------------------------------------------------------------------------
# Static schema-text checks: independent of check-jsonschema, these parse
# the schema's own JSON structure with jq. They double as the required
# degraded-mode assertions when check-jsonschema is not on PATH.
# ---------------------------------------------------------------------------

banner "schema JSON declares the two fields with the doctrine's bounds"

# A floor of "1" is equally well expressed as minimum:1 or
# exclusiveMinimum:0 (and a ceiling of "5" as maximum:5 or
# exclusiveMaximum:6) — either spelling satisfies the doctrine, so both
# are accepted rather than pinning to the one crawl_budget happens to use.
if jq -e '
    (.properties.probe_budget.type == "integer") and
    ((.properties.probe_budget.minimum == 1) or (.properties.probe_budget.exclusiveMinimum == 0))
  ' "$SCHEMA" >/dev/null 2>&1; then
  pass "schema_declares_probe_budget_as_root_level_bounded_integer"
else
  fail "schema_declares_probe_budget_as_root_level_bounded_integer" \
    "expected .properties.probe_budget in $SCHEMA with type \"integer\" and a lower bound of 1 (minimum:1 or exclusiveMinimum:0)"
fi

if jq -e '
    (.["$defs"].source.properties.importance.type == "integer") and
    ((.["$defs"].source.properties.importance.minimum == 1) or (.["$defs"].source.properties.importance.exclusiveMinimum == 0)) and
    ((.["$defs"].source.properties.importance.maximum == 5) or (.["$defs"].source.properties.importance.exclusiveMaximum == 6))
  ' "$SCHEMA" >/dev/null 2>&1; then
  pass "schema_declares_importance_as_per_source_bounded_integer"
else
  fail "schema_declares_importance_as_per_source_bounded_integer" \
    "expected .\$defs.source.properties.importance in $SCHEMA with type \"integer\", a lower bound of 1, and an upper bound of 5"
fi

# ---------------------------------------------------------------------------
# check-jsonschema-backed behavior: accept/reject fixtures and the
# preservation set. Skipped (not failed) when the binary is absent —
# matching scripts/ci-local.sh's own local-degradation behavior exactly,
# so this oracle never fails merely because a tool isn't installed.
# ---------------------------------------------------------------------------

banner "check-jsonschema availability"

# validate_ok <file> — true (rc 0) iff check-jsonschema accepts <file>
# against $SCHEMA. Sets LAST_VALIDATE_OUT to the combined output.
LAST_VALIDATE_OUT=""
validate_ok() {
  local f="$1"
  LAST_VALIDATE_OUT="$(check-jsonschema --schemafile "$SCHEMA" "$f" 2>&1)"
}

assert_schema_accepts() {
  local label="$1" file="$2"
  if [ ! -f "$file" ]; then
    fail "$label" "fixture file missing: $file"
    return
  fi
  if validate_ok "$file"; then
    pass "$label"
  else
    fail "$label" "expected $file to validate; check-jsonschema said:" "$LAST_VALIDATE_OUT"
  fi
}

# assert_schema_rejects <label> <file> <field-name> — must fail validation,
# and the reported error must name <field-name> as the JSON-path segment
# check-jsonschema blames (".<field>:" — e.g. "$.probe_budget:" or
# "$.sources[0].importance:"), so a fixture that happens to be invalid for
# some unrelated reason cannot pass this check. Anchored on the ".<field>:"
# shape rather than a bare substring match: the fixture's own file path is
# echoed ahead of "::" in check-jsonschema's output, and a hyphenated
# filename like "importance-zero.json" must not be mistaken for the
# schema blaming the "importance" property.
assert_schema_rejects() {
  local label="$1" file="$2" field="$3"
  if [ ! -f "$file" ]; then
    fail "$label" "fixture file missing: $file"
    return
  fi
  if validate_ok "$file"; then
    fail "$label" "expected $file to be rejected (it validated successfully)"
  elif printf '%s' "$LAST_VALIDATE_OUT" | grep -qiE -- "\\.${field}:"; then
    pass "$label"
  else
    fail "$label" "rejected, but not naming '$field' — may be failing for an unrelated reason:" "$LAST_VALIDATE_OUT"
  fi
}

# assert_schema_rejects_unscoped <label> <file> — like assert_schema_rejects
# but without pinning the error to one field; used for the preservation
# sweep over the existing web-doc negative fixtures, whose violations are
# unrelated to probe_budget/importance.
assert_schema_rejects_unscoped() {
  local label="$1" file="$2"
  if [ ! -f "$file" ]; then
    fail "$label" "fixture file missing: $file"
    return
  fi
  if validate_ok "$file"; then
    fail "$label" "expected $file to still be rejected; it validated successfully"
  else
    pass "$label"
  fi
}

if command -v check-jsonschema >/dev/null 2>&1; then
  pass "check_jsonschema_on_path"

  banner "probe_budget: accepted values"
  assert_schema_accepts "probe_budget_accepts_minimum_1" "$FIXTURES/valid/probe-budget-min.json"
  assert_schema_accepts "probe_budget_accepts_representative_value" "$FIXTURES/valid/probe-budget-representative.json"

  banner "probe_budget: the four must-reject inputs"
  assert_schema_rejects "probe_budget_rejects_zero" "$FIXTURES/invalid/probe-budget-zero.json" "probe_budget"
  assert_schema_rejects "probe_budget_rejects_negative_integer" "$FIXTURES/invalid/probe-budget-negative.json" "probe_budget"
  assert_schema_rejects "probe_budget_rejects_non_integer_1_5" "$FIXTURES/invalid/probe-budget-non-integer.json" "probe_budget"
  assert_schema_rejects "probe_budget_rejects_string" "$FIXTURES/invalid/probe-budget-string.json" "probe_budget"

  banner "importance: accepted values"
  assert_schema_accepts "importance_accepts_minimum_1" "$FIXTURES/valid/importance-min.json"
  assert_schema_accepts "importance_accepts_maximum_5" "$FIXTURES/valid/importance-max.json"

  banner "importance: the three must-reject inputs"
  assert_schema_rejects "importance_rejects_zero" "$FIXTURES/invalid/importance-zero.json" "importance"
  assert_schema_rejects "importance_rejects_six" "$FIXTURES/invalid/importance-six.json" "importance"
  assert_schema_rejects "importance_rejects_string" "$FIXTURES/invalid/importance-string.json" "importance"

  banner "preservation: existing valid documents still validate unchanged"

  example_count=0
  for f in "$REPO_ROOT"/examples/*/research/source-paths.json; do
    [ -f "$f" ] || continue
    example_count=$((example_count + 1))
    example_name="$(basename "$(dirname "$(dirname "$f")")")"
    assert_schema_accepts "preserved_example_${example_name}" "$f"
  done
  if [ "$example_count" -eq 0 ]; then
    fail "preserved_examples_present" "no examples/*/research/source-paths.json files found — cannot exercise the preservation set"
  fi

  assert_schema_accepts "preserved_dogfood_source_paths" "$DOGFOOD_SOURCE_PATHS"
  assert_schema_accepts "preserved_template" "$TEMPLATE"

  banner "preservation: existing negative fixtures are still rejected"

  invalid_count=0
  for f in "$WEBDOC_INVALID_DIR"/*.json; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    # Declared schema gap, unrelated to this chunk: page_list same-origin
    # is enforced only by verify.sh, not expressible in JSON Schema. This
    # is the same fixture scripts/ci-local.sh's run_json skips for the
    # same reason.
    case "$base" in
      invalid--page-list-cross-origin.json) continue ;;
    esac
    invalid_count=$((invalid_count + 1))
    assert_schema_rejects_unscoped "preserved_invalid_${base%.json}" "$f"
  done
  if [ "$invalid_count" -eq 0 ]; then
    fail "preserved_invalid_fixtures_present" "no fixtures found under $WEBDOC_INVALID_DIR to exercise the preservation set"
  fi
else
  # Same degradation scripts/ci-local.sh's run_json applies locally: not an
  # error, just a skip of everything that requires running the validator.
  # This oracle must not fail merely because check-jsonschema isn't
  # installed — the schema-text and doc-text assertions above already ran
  # and still gate the suite.
  echo "NOTE: check-jsonschema not on PATH — skipping schema validation locally." >&2
  echo "      CI runs it (pip install check-jsonschema==0.37.2); install it to match CI exactly." >&2
  printf '  SKIP  %s\n' "probe_budget/importance fixture accept-reject checks (check-jsonschema unavailable)"
  printf '  SKIP  %s\n' "preservation checks against examples/dogfood/template/web-doc-invalid fixtures (check-jsonschema unavailable)"
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
