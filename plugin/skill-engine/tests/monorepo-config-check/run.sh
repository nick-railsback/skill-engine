#!/usr/bin/env bash
# Black-box oracle for verify.sh's monorepo-config.json validation, the
# slice-carrying additions to source-paths.json / Check 2, Check 6's
# uncited-slice warning, the doctrine text those checks are documented by,
# and Check 3's admission of an optional `paths:` third frontmatter key
# alongside continued rejection of any other third key.
#
# Everything here is exercised by stamping the real template verify.sh (and
# reading the real source-paths.schema.json / doctrine docs) against
# synthetic fixtures under `mktemp -d`, via CTX_ROOT / SKILL_ENGINE_CACHE_ROOT
# env-var overrides -- never the real ~/.cache/skill-engine, never a write
# anywhere under the repo. The four real in-repo navigators are read
# directly (CTX_ROOT pointed at their real paths) as a regression check;
# that run is read-only, like every other invocation here.
#
# Proving the five stamped verify.sh copies stay byte-identical to the
# template after `make sync`, and that `ci-local doctrine` passes, is left
# to doctrine.sh -- duplicating that here would just be a slower copy of a
# check that already exists and already runs on every change.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_ROOT="$(cd "$TESTS_ROOT/.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

TEMPLATE="$PLUGIN_ROOT/engine-bootstrap-templates/verify.sh"
SCHEMA="$PLUGIN_ROOT/engine-bootstrap-templates/source-paths.schema.json"
MONOREPO_DOC="$PLUGIN_ROOT/docs/07-monorepo-adapter.md"
CONTRACT_DOC="$PLUGIN_ROOT/docs/02-artifact-contract.md"

pass_count=0
fail_count=0

WORK="$(mktemp -d -t skill-engine-monorepo-config-check.XXXXXX)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

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

section() {
  printf '\n── %s ──\n' "$1"
}

# Collapse every run of whitespace -- newlines included -- to one space, so a
# phrase assertion against hard-wrapped doctrine prose does not depend on
# where the phrase happened to break across lines.
join_lines() {
  tr -s '[:space:]' ' '
}

# extract_heading_section <heading-text-prefix> <file> -- the "##"/"###"
# heading whose text (after the leading hashes) starts with the given
# prefix, through (not including) the next such heading, or EOF.
extract_heading_section() {
  awk -v want="$1" '
    /^###? / {
      if (found) exit
      title = $0
      sub(/^###?[ \t]*/, "", title)
      if (index(title, want) == 1) { found = 1; print; next }
      next
    }
    found { print }
  ' "$2"
}

# windows_around <joined-text> <term> <before> <after> -- the <before>/<after>
# character window around every case-insensitive occurrence of <term>,
# concatenated. Empty when <term> never appears.
windows_around() {
  local hay="$1" term="$2" before="$3" after="$4"
  local rest lower_term prefix idx start span
  lower_term="$(printf '%s' "$term" | tr '[:upper:]' '[:lower:]')"
  rest="$(printf '%s' "$hay" | tr '[:upper:]' '[:lower:]')"
  span=$(( before + after + ${#term} ))
  while :; do
    prefix="${rest%%"$lower_term"*}"
    [ "$prefix" = "$rest" ] && break
    idx="${#prefix}"
    start=$(( idx > before ? idx - before : 0 ))
    printf '%s ' "${rest:$start:$span}"
    rest="${rest:$(( idx + ${#lower_term} ))}"
  done
}

# check_section <combined-output> <needle> -- the lines of one `=== ... ===`
# run_check block whose header contains <needle>, up to (excluding) the
# next `=== ` header.
check_section() {
  CHECK_NEEDLE="$2" awk '
    $0 ~ ENVIRON["CHECK_NEEDLE"] && !found { found=1; print; next }
    found && /^=== / { exit }
    found { print }
  ' <<<"$1"
}

# remove_section <combined-output> <needle> -- the same combined output with
# one `=== ... ===` block (the one whose header contains <needle>, header
# line included) removed entirely, including the blank line that block's own
# run_check call printed ahead of it. Every other block, including the blank
# line ahead of it, survives untouched -- so removing exactly one block
# reconstructs precisely what the stream would look like had that check
# never been called at all, regardless of where in run order it sat.
remove_section() {
  REMOVE_NEEDLE="$2" awk '
    BEGIN { skip = 0; pend_blank = 0 }
    /^=== / {
      if (index($0, ENVIRON["REMOVE_NEEDLE"]) > 0) { skip = 1; pend_blank = 0; next }
      skip = 0
      if (pend_blank) { print ""; pend_blank = 0 }
      print
      next
    }
    $0 == "" { pend_blank = 1; next }
    {
      if (skip) { next }
      if (pend_blank) { print ""; pend_blank = 0 }
      print
    }
  ' <<<"$1"
}

NAV_DESC="Use when answering questions about the acme corpus."

build_nav() {
  local root="$1"
  mkdir -p "$root"
  {
    printf -- '---\n'
    printf 'name: acme-context\n'
    printf 'description: %s\n' "$NAV_DESC"
    printf -- '---\n\n# Acme\n'
  } > "$root/SKILL.md"
}

# write_navigator_fm <root> <frontmatter-body> -- a navigator whose
# frontmatter is exactly the given lines (no name/description assumed),
# for exercising Check 3's key-shape validation directly.
write_navigator_fm() {
  local root="$1" fm="$2"
  mkdir -p "$root"
  {
    printf -- '---\n'
    printf '%s\n' "$fm"
    printf -- '---\n\n# Acme\n'
  } > "$root/SKILL.md"
}

git_managed_source() {
  local id="$1" url="$2" extra="${3:-null}"
  jq -n --arg id "$id" --arg url "$url" --argjson extra "$extra" '
    {
      id: $id,
      kind: "git-managed",
      url: $url,
      status: "confirmed",
      archived: false,
      lifecycle: {state: "reachable", last_checked: "2026-09-06", last_checked_sha: "abc1234", proposed_url: null},
      discovered_via: null
    } + (if $extra == null then {} else $extra end)
  '
}

write_sources() {
  local root="$1" sources_array="$2"
  mkdir -p "$root/research"
  jq -n --argjson sources "$sources_array" '{schema_version: 1, sources: $sources}' > "$root/research/source-paths.json"
}

# write_monorepo_config <root> <root|research> <json-content>
write_monorepo_config() {
  local root="$1" location="$2" content="$3" dest
  case "$location" in
    root) dest="$root/monorepo-config.json" ;;
    research) mkdir -p "$root/research"; dest="$root/research/monorepo-config.json" ;;
    *) printf 'write_monorepo_config: unknown location %s\n' "$location" >&2; return 1 ;;
  esac
  printf '%s' "$content" > "$dest"
}

run_verify() {
  local root="$1" cache="$2"
  CTX_ROOT="$root" SKILL_ENGINE_CACHE_ROOT="$cache" "$TEMPLATE" 2>&1
}

HAVE_CJS=0
if command -v check-jsonschema >/dev/null 2>&1; then
  HAVE_CJS=1
else
  echo "NOTE: check-jsonschema not on PATH -- skipping schema validation locally." >&2
  echo "      CI runs it (pip install check-jsonschema==0.37.2); install it to match CI exactly." >&2
fi

write_schema_doc() {
  local out="$1" extra="${2:-null}"
  jq -n --argjson extra "$extra" '
    {
      schema_version: 1,
      sources: [
        ({
          id: "widget-src",
          kind: "git-managed",
          url: "https://example.com/acme/widgets",
          status: "confirmed",
          archived: false,
          lifecycle: {state: "reachable", last_checked: "2026-09-06", last_checked_sha: "abc1234", proposed_url: null},
          discovered_via: null
        } + (if $extra == null then {} else $extra end))
      ]
    }
  ' > "$out"
}

schema_accepts() {
  local label="$1" f="$2" out
  if out="$(check-jsonschema --schemafile "$SCHEMA" "$f" 2>&1)"; then
    pass "$label"
  else
    fail "$label" "$out"
  fi
}

schema_rejects() {
  local label="$1" f="$2"
  if check-jsonschema --schemafile "$SCHEMA" "$f" >/dev/null 2>&1; then
    fail "$label" "expected schema validation to reject $f, but it passed"
  else
    pass "$label"
  fi
}

# ============================================================================
# monorepo-config.json -- both documented locations accept a valid config
# ============================================================================
section "monorepo-config.json -- both documented locations accept a valid three-slice config"

valid_cfg='{
  "version": "1.0",
  "monorepos": [
    {
      "url": "https://example.com/acme/big-monorepo",
      "type": "internal-repo",
      "slices": [
        {"id": "billing", "paths": ["packages/billing/**", "shared/billing-types/**"]},
        {"id": "auth",    "paths": ["packages/auth/**", "services/auth-api/**"]},
        {"id": "reports", "paths": ["apps/reports-dashboard/**"]}
      ]
    }
  ]
}'

root_loc1="$WORK/cfg-loc-root"
build_nav "$root_loc1"
write_sources "$root_loc1" '[]'
write_monorepo_config "$root_loc1" root "$valid_cfg"
cache_loc1="$WORK/cache-loc-root"
mkdir -p "$cache_loc1"
out_loc1="$(run_verify "$root_loc1" "$cache_loc1")"
mc_loc1="$(check_section "$out_loc1" '(monorepo-config)')"
if printf '%s' "$mc_loc1" | grep -q '\[FAIL\]'; then
  fail "a valid config at <root>/monorepo-config.json is accepted" "monorepo-config section: ${mc_loc1:-<empty>}"
else
  pass "a valid config at <root>/monorepo-config.json is accepted"
fi

root_loc2="$WORK/cfg-loc-research"
build_nav "$root_loc2"
write_sources "$root_loc2" '[]'
write_monorepo_config "$root_loc2" research "$valid_cfg"
cache_loc2="$WORK/cache-loc-research"
mkdir -p "$cache_loc2"
out_loc2="$(run_verify "$root_loc2" "$cache_loc2")"
mc_loc2="$(check_section "$out_loc2" '(monorepo-config)')"
if printf '%s' "$mc_loc2" | grep -q '\[FAIL\]'; then
  fail "a valid config at <root>/research/monorepo-config.json is accepted" "monorepo-config section: ${mc_loc2:-<empty>}"
else
  pass "a valid config at <root>/research/monorepo-config.json is accepted"
fi

# ============================================================================
# monorepo-config.json -- five rules, one violation each, named with the
# offending value; plus a few bonus instances of the same classes
# ============================================================================
section "monorepo-config.json -- each of the five validation rules rejects by name and offending value"

run_cfg_case() {
  # run_cfg_case <label> <content> <expect: fail|pass> <grep-target(s)...>
  local label="$1" content="$2" expect="$3" root cache out mc
  shift 3
  root="$WORK/cfg-$(printf '%s' "$label" | tr -c 'a-z0-9' '-' | cut -c1-40)-$RANDOM"
  build_nav "$root"
  write_sources "$root" '[]'
  write_monorepo_config "$root" research "$content"
  cache="$root-cache"
  mkdir -p "$cache"
  out="$(run_verify "$root" "$cache")"
  mc="$(check_section "$out" '(monorepo-config)')"
  if [ "$expect" = "fail" ]; then
    if printf '%s' "$mc" | grep -q '\[FAIL\]'; then
      local all_found=1 needle
      for needle in "$@"; do
        printf '%s' "$mc" | grep -qF "$needle" || all_found=0
      done
      if [ "$all_found" -eq 1 ]; then
        pass "$label"
      else
        fail "$label" "expected FAIL line naming: $* -- got: ${mc:-<empty>}"
      fi
    else
      fail "$label" "expected a [FAIL] line, got: ${mc:-<empty>}"
    fi
  else
    if printf '%s' "$mc" | grep -q '\[FAIL\]'; then
      fail "$label" "expected acceptance, got: ${mc:-<empty>}"
    else
      pass "$label"
    fi
  fi
}

run_cfg_case "rule A -- monorepos[] must be an array" \
  '{"version":"1.0","monorepos":"oops"}' fail "monorepos"

run_cfg_case "rule B -- monorepos[].url must be unique" \
  '{"version":"1.0","monorepos":[
     {"url":"https://example.com/acme/mono-dup","type":"internal-repo","slices":[{"id":"billing","paths":["packages/billing/**"]}]},
     {"url":"https://example.com/acme/mono-dup","type":"internal-repo","slices":[{"id":"auth","paths":["packages/auth/**"]}]}
   ]}' fail "https://example.com/acme/mono-dup"

run_cfg_case "rule C -- slice id must be unique within its monorepo" \
  '{"version":"1.0","monorepos":[
     {"url":"https://example.com/acme/mono-c","type":"internal-repo","slices":[
       {"id":"billing","paths":["packages/billing/**"]},
       {"id":"billing","paths":["packages/billing-legacy/**"]}
     ]}
   ]}' fail "billing"

run_cfg_case "rule D (empty paths array) -- every slice needs at least one path" \
  '{"version":"1.0","monorepos":[{"url":"https://example.com/acme/mono-d1","type":"internal-repo","slices":[{"id":"empty-paths","paths":[]}]}]}' \
  fail "empty-paths"

run_cfg_case "rule D (blank path string) -- every path must be non-empty" \
  '{"version":"1.0","monorepos":[{"url":"https://example.com/acme/mono-d2","type":"internal-repo","slices":[{"id":"blank-path","paths":["packages/billing/**",""]}]}]}' \
  fail "blank-path"

run_cfg_case "rule E (uppercase id) -- slice id must match ^[a-z][a-z0-9_-]{0,30}\$" \
  '{"version":"1.0","monorepos":[{"url":"https://example.com/acme/mono-e1","type":"internal-repo","slices":[{"id":"Billing","paths":["packages/billing/**"]}]}]}' \
  fail "Billing"

run_cfg_case "rule E (leading digit) -- slice id must start with a lowercase letter" \
  '{"version":"1.0","monorepos":[{"url":"https://example.com/acme/mono-e2","type":"internal-repo","slices":[{"id":"1team","paths":["packages/team/**"]}]}]}' \
  fail "1team"

run_cfg_case "bonus -- malformed JSON fails instead of crashing the run" \
  '{"version": "1.0", "monorepos": [' fail ""

run_cfg_case "bonus -- the same slice id in two DIFFERENT monorepos is not a violation" \
  '{"version":"1.0","monorepos":[
     {"url":"https://example.com/acme/mono-f1","type":"internal-repo","slices":[{"id":"shared-name","paths":["packages/a/**"]}]},
     {"url":"https://example.com/acme/mono-f2","type":"internal-repo","slices":[{"id":"shared-name","paths":["packages/b/**"]}]}
   ]}' pass

# Multi-violation: two rules broken in one file must surface two [FAIL] lines,
# not just the first one found.
root_multi="$WORK/cfg-multi-violation"
build_nav "$root_multi"
write_sources "$root_multi" '[]'
write_monorepo_config "$root_multi" research '{"version":"1.0","monorepos":[
  {"url":"https://example.com/acme/mono-multi","type":"internal-repo","slices":[{"id":"Weird","paths":["packages/w/**"]}]},
  {"url":"https://example.com/acme/mono-multi","type":"internal-repo","slices":[{"id":"other","paths":["packages/o/**"]}]}
]}'
cache_multi="$root_multi-cache"
mkdir -p "$cache_multi"
out_multi="$(run_verify "$root_multi" "$cache_multi")"
mc_multi="$(check_section "$out_multi" '(monorepo-config)')"
mc_multi_fail_count="$(printf '%s\n' "$mc_multi" | grep -c '\[FAIL\]')"
if [ "$mc_multi_fail_count" -ge 2 ]; then
  pass "a config violating two rules at once reports two (or more) distinct [FAIL] lines, not just the first"
else
  fail "a config violating two rules at once reports two (or more) distinct [FAIL] lines, not just the first" \
    "saw $mc_multi_fail_count [FAIL] line(s): ${mc_multi:-<empty>}"
fi

# ============================================================================
# No config file at either location -- one [N/A] line, everything else
# preserved exactly (computed by hand from the unmodified checks, not from a
# second live run of an old binary)
# ============================================================================
section "no monorepo-config.json anywhere -- one [N/A] line, every other check's output unchanged"

root_noconfig="$WORK/no-config"
build_nav "$root_noconfig"
write_sources "$root_noconfig" '[]'
cache_noconfig="$WORK/no-config-cache"
mkdir -p "$cache_noconfig"

out_noconfig="$(run_verify "$root_noconfig" "$cache_noconfig")"

mc_noconfig="$(check_section "$out_noconfig" '(monorepo-config)')"
mc_noconfig_body="$(printf '%s\n' "$mc_noconfig" | tail -n +2)"
mc_noconfig_nonblank="$(printf '%s\n' "$mc_noconfig_body" | grep -cve '^[[:space:]]*$' || true)"
mc_noconfig_is_na="$(printf '%s\n' "$mc_noconfig_body" | grep -c '\[N/A\]' || true)"
if [ "$mc_noconfig_nonblank" -eq 1 ] && [ "$mc_noconfig_is_na" -eq 1 ]; then
  pass "with no config file anywhere, the monorepo-config check prints exactly one [N/A] line and nothing else"
else
  fail "with no config file anywhere, the monorepo-config check prints exactly one [N/A] line and nothing else" \
    "monorepo-config section: ${mc_noconfig:-<empty>}"
fi

desc_bytes="$(printf '%s' "$NAV_DESC" | wc -c | tr -d ' ')"

# This is the current, unmodified verify.sh's own output for this exact
# fixture (2-key navigator, sources: [], no references/, no SKILL.json),
# hand-derived from its source by inspection -- not produced by running a
# second copy of the script. See the Open Questions note in the sketch this
# script is embedded in for what that trade-off costs.
expected_rest="$(cat <<EOF

=== source-paths.json shape (source-paths-shape) ===
  [PASS] research/source-paths.json parses with schema_version: 1 and sources[] array

=== Source entries: thin per-source schema (source-entries) ===
  [N/A]  sources[] is empty — no sources registered yet (re-run /skill-engine:engine-bootstrap with at least one source)

=== Navigator SKILL.md exists with frontmatter (navigator-skill) ===
  [PASS] SKILL.md exists with valid frontmatter (name + description, ${desc_bytes}/1024 bytes)

=== Catalog ↔ references bijection (catalog-bijection) ===
  [N/A]  references/ directory absent — no references emitted yet (run /skill-engine:discover to populate the catalog)

=== Reference frontmatter (reference-frontmatter) ===
  [N/A]  references/ directory absent — no references to validate (see Check 4)

=== External-doc / web-doc provenance frontmatter (external-doc-frontmatter) ===
  [N/A]  No external-doc paths or web-doc cache directories present to validate

=== Web-doc snapshot present (web-doc-snapshot-present) ===
  [N/A]  No confirmed web-doc sources to check

=== Monorepo-coverage heuristic (monorepo-coverage) ===
  [N/A]  monorepo-coverage heuristic — no sources to inspect

=== Companions-coverage heuristic (companions-coverage) ===
  [N/A]  companions-coverage heuristic — no sources to inspect

=== Catalog-density floor (catalog-density) ===
  [N/A]  catalog-density heuristic — no sources to inspect

=== Optional SKILL.json trijection (skill-json-trijection) ===
  [N/A]  SKILL.json absent — skipping (opt-in machine-readable sibling not present)
EOF
)"

live_rest="$(remove_section "$out_noconfig" '(monorepo-config)')"
live_rest_no_summary="$(remove_section "$live_rest" 'Summary')"

if [ "$live_rest_no_summary" = "$expected_rest" ]; then
  pass "every OTHER check's section is byte-identical to the unmodified script's output for this tree"
else
  fail "every OTHER check's section is byte-identical to the unmodified script's output for this tree" \
    "diff:" "$(diff <(printf '%s\n' "$expected_rest") <(printf '%s\n' "$live_rest_no_summary") 2>&1 | head -20)"
fi

summary_block="$(check_section "$out_noconfig" 'Summary')"
live_passed="$(printf '%s\n' "$summary_block" | grep -oE 'Passed: [0-9]+' | grep -oE '[0-9]+')"
live_failed="$(printf '%s\n' "$summary_block" | grep -oE 'Failed: [0-9]+' | grep -oE '[0-9]+')"
if [ "${live_passed:-}" = "12" ] && [ "${live_failed:-}" = "0" ]; then
  pass "Summary counts shift by exactly the one added [N/A] pass (11 baseline checks -> 12) and Failed stays 0"
else
  fail "Summary counts shift by exactly the one added [N/A] pass (11 baseline checks -> 12) and Failed stays 0" \
    "Passed=${live_passed:-<none>} Failed=${live_failed:-<none>}"
fi

# ============================================================================
# source-paths.schema.json -- slice_of / slice_id / slice_paths
# ============================================================================
section "source-paths.schema.json -- slice_of/slice_id/slice_paths accepted together, constrained individually"

write_schema_doc "$WORK/slice-absent.json" 'null'
write_schema_doc "$WORK/slice-all-present.json" '{"slice_of":"https://example.com/acme/parent","slice_id":"billing","slice_paths":["packages/billing/**"]}'
write_schema_doc "$WORK/slice-bad-id.json" '{"slice_of":"https://example.com/acme/parent","slice_id":"Billing","slice_paths":["packages/billing/**"]}'
write_schema_doc "$WORK/slice-paths-string.json" '{"slice_of":"https://example.com/acme/parent","slice_id":"billing","slice_paths":"packages/billing/**"}'
write_schema_doc "$WORK/slice-paths-empty.json" '{"slice_of":"https://example.com/acme/parent","slice_id":"billing","slice_paths":[]}'
write_schema_doc "$WORK/slice-paths-blank-entry.json" '{"slice_of":"https://example.com/acme/parent","slice_id":"billing","slice_paths":["packages/billing/**",""]}'

fixture_ok=true
for f in slice-absent slice-all-present slice-bad-id slice-paths-string slice-paths-empty slice-paths-blank-entry; do
  if ! jq empty "$WORK/$f.json" 2>/dev/null; then
    fixture_ok=false
    fail "fixture $f.json is well-formed JSON"
  fi
done
$fixture_ok && pass "every slice-field schema fixture is well-formed JSON"

if [ "$HAVE_CJS" -eq 1 ]; then
  schema_accepts "slice_of/slice_id/slice_paths absent still validates" "$WORK/slice-absent.json"
  schema_accepts "slice_of/slice_id/slice_paths all present and well-formed validates" "$WORK/slice-all-present.json"
  schema_rejects "slice_id failing the id regex is rejected" "$WORK/slice-bad-id.json"
  schema_rejects "slice_paths as a bare string (non-array) is rejected" "$WORK/slice-paths-string.json"
  schema_rejects "slice_paths as an empty array is rejected" "$WORK/slice-paths-empty.json"
  schema_rejects "slice_paths containing an empty string is rejected" "$WORK/slice-paths-blank-entry.json"
fi

# ============================================================================
# Check 2 -- dangling slice_of, and partial slice fields
# ============================================================================
section "Check 2 -- a slice_of naming no registered source fails; a partial subset of the three fields fails"

parent_url="https://example.com/acme/monorepo"

root_dangle="$WORK/check2-dangling"
build_nav "$root_dangle"
write_sources "$root_dangle" "[$(git_managed_source acme-monorepo "$parent_url"),\
$(git_managed_source acme-monorepo-billing https://example.com/acme/monorepo/billing-slice \
  '{"slice_of": "https://example.com/NOT-REGISTERED-ANYWHERE", "slice_id": "billing", "slice_paths": ["packages/billing/**"]}')]"
cache_dangle="$WORK/check2-dangling-cache"
mkdir -p "$cache_dangle"
out_dangle="$(run_verify "$root_dangle" "$cache_dangle")"
c2_dangle="$(check_section "$out_dangle" 'Source entries')"
if printf '%s' "$c2_dangle" | grep -q '\[FAIL\]' && printf '%s' "$c2_dangle" | grep -qF 'NOT-REGISTERED-ANYWHERE'; then
  pass "source-entries: slice_of naming no registered source's url fails, naming the dangling url"
else
  fail "source-entries: slice_of naming no registered source's url fails, naming the dangling url" \
    "source-entries section: ${c2_dangle:-<empty>}"
fi

root_valid_slice="$WORK/check2-valid-slice"
build_nav "$root_valid_slice"
# Built via jq -s (slurp) rather than string-concatenating two sibling
# $(...) command substitutions with a comma and backslash-newline: bash 3.2
# mis-tokenizes that shape once one substitution's argument is a
# double-quoted JSON literal with an embedded $variable, re-evaluating it
# and handing git_managed_source a truncated fragment. Building each entry
# as its own jq -n invocation and slurping them sidesteps the parser bug
# entirely -- see root_dangle above for the one shape (single-quoted, no
# interpolation) that was never affected.
valid_slice_extra="$(jq -n --arg of "$parent_url" \
  '{slice_of: $of, slice_id: "billing", slice_paths: ["packages/billing/**"]}')"
valid_slice_sources="$( {
  git_managed_source acme-monorepo "$parent_url"
  git_managed_source acme-monorepo-billing https://example.com/acme/monorepo/billing-slice "$valid_slice_extra"
} | jq -s '.' )"
write_sources "$root_valid_slice" "$valid_slice_sources"
cache_valid_slice="$WORK/check2-valid-slice-cache"
mkdir -p "$cache_valid_slice"
out_valid_slice="$(run_verify "$root_valid_slice" "$cache_valid_slice")"
c2_valid_slice="$(check_section "$out_valid_slice" 'Source entries')"
if printf '%s' "$c2_valid_slice" | grep -q '\[FAIL\]'; then
  fail "source-entries: slice_of matching a registered source's url is accepted" \
    "source-entries section: ${c2_valid_slice:-<empty>}"
else
  pass "source-entries: slice_of matching a registered source's url is accepted"
fi

root_partial1="$WORK/check2-partial-id-only"
build_nav "$root_partial1"
write_sources "$root_partial1" "[$(git_managed_source acme-monorepo "$parent_url"),\
$(git_managed_source acme-monorepo-partial1 https://example.com/acme/monorepo/partial1-slice \
  '{"slice_id": "billing"}')]"
cache_partial1="$WORK/check2-partial1-cache"
mkdir -p "$cache_partial1"
out_partial1="$(run_verify "$root_partial1" "$cache_partial1")"
c2_partial1="$(check_section "$out_partial1" 'Source entries')"
if printf '%s' "$c2_partial1" | grep -q '\[FAIL\]'; then
  pass "source-entries: an entry carrying only slice_id (no slice_of, no slice_paths) fails"
else
  fail "source-entries: an entry carrying only slice_id (no slice_of, no slice_paths) fails" \
    "source-entries section: ${c2_partial1:-<empty>}"
fi

root_partial2="$WORK/check2-partial-no-paths"
build_nav "$root_partial2"
# Same bash-3.2 quote-parsing hazard as root_valid_slice above -- built via
# jq -s (slurp) rather than concatenated sibling $(...) substitutions.
partial2_extra="$(jq -n --arg of "$parent_url" '{slice_of: $of, slice_id: "billing"}')"
partial2_sources="$( {
  git_managed_source acme-monorepo "$parent_url"
  git_managed_source acme-monorepo-partial2 https://example.com/acme/monorepo/partial2-slice "$partial2_extra"
} | jq -s '.' )"
write_sources "$root_partial2" "$partial2_sources"
cache_partial2="$WORK/check2-partial2-cache"
mkdir -p "$cache_partial2"
out_partial2="$(run_verify "$root_partial2" "$cache_partial2")"
c2_partial2="$(check_section "$out_partial2" 'Source entries')"
if printf '%s' "$c2_partial2" | grep -q '\[FAIL\]'; then
  pass "source-entries: an entry carrying slice_of + slice_id but no slice_paths fails"
else
  fail "source-entries: an entry carrying slice_of + slice_id but no slice_paths fails" \
    "source-entries section: ${c2_partial2:-<empty>}"
fi

# ============================================================================
# Check 6 -- an uncited slice warns by slice id and parent; a cited one
# does not
# ============================================================================
section "Check 6 -- slice_paths as workspace roots: uncited slice warns, cited slice stays clean"

populate_monorepo_tree() {
  mkdir -p "$1/domains/billing" "$1/domains/auth"
  printf 'billing code\n' > "$1/domains/billing/main.go"
  printf 'auth code\n' > "$1/domains/auth/main.go"
}

root_slices="$WORK/check6-slices"
build_nav "$root_slices"
mkdir -p "$root_slices/references"
printf '# Auth notes\n\nSee domains/auth for the service implementation.\n' > "$root_slices/references/acme-monorepo-auth.md"

parent_slices_url="https://example.com/acme/monorepo-slices"
# Same bash-3.2 quote-parsing hazard as root_valid_slice above, with three
# concatenated siblings instead of two -- built via jq -s (slurp) instead.
billing_slice_extra="$(jq -n --arg of "$parent_slices_url" \
  '{slice_of: $of, slice_id: "billing", slice_paths: ["domains/billing/**"]}')"
auth_slice_extra="$(jq -n --arg of "$parent_slices_url" \
  '{slice_of: $of, slice_id: "auth", slice_paths: ["domains/auth/**"]}')"
slices_sources="$( {
  git_managed_source acme-monorepo-slices "$parent_slices_url"
  git_managed_source acme-monorepo-slices-billing https://example.com/acme/monorepo-slices/billing-slice "$billing_slice_extra"
  git_managed_source acme-monorepo-slices-auth https://example.com/acme/monorepo-slices/auth-slice "$auth_slice_extra"
} | jq -s '.' )"
write_sources "$root_slices" "$slices_sources"

cache_slices="$WORK/check6-slices-cache"
mkdir -p "$cache_slices/git-managed/acme-monorepo-slices-a1b2c3d4"
populate_monorepo_tree "$cache_slices/git-managed/acme-monorepo-slices-a1b2c3d4"

out_slices="$(run_verify "$root_slices" "$cache_slices")"
c6_slices="$(check_section "$out_slices" 'Monorepo-coverage')"

if printf '%s' "$c6_slices" | grep -qE '\[WARN\].*\bbilling\b' \
    && { printf '%s' "$c6_slices" | grep -qF 'acme-monorepo-slices' || printf '%s' "$c6_slices" | grep -qF "$parent_slices_url"; }; then
  pass "monorepo-coverage: the uncited slice (billing) warns, naming the slice id and the parent"
else
  fail "monorepo-coverage: the uncited slice (billing) warns, naming the slice id and the parent" \
    "monorepo-coverage section: ${c6_slices:-<empty>}"
fi

if printf '%s' "$c6_slices" | grep -qE '\[WARN\].*\bauth\b'; then
  fail "monorepo-coverage: the cited slice (auth) does not also warn" \
    "monorepo-coverage section: ${c6_slices:-<empty>}"
else
  pass "monorepo-coverage: the cited slice (auth) does not also warn"
fi

# ============================================================================
# Doctrine text -- 07-monorepo-adapter.md stops saying "not enforced";
# 02-artifact-contract.md documents the three new fields
# ============================================================================
section "doctrine text -- §7.3 no longer disclaims enforcement; the entry-shape docs gain the three fields"

schema_section="$(extract_heading_section '7.3' "$MONOREPO_DOC")"
schema_joined="$(join_lines <<< "$schema_section")"
# Markdown emphasis sits directly against the word it wraps ("**not**
# currently"), with no whitespace between the word and its `*`/`_`
# markers. A whitespace-anchored regex against the raw joined text would
# never see the wrapped word as adjacent to its neighbor -- so this
# specific check strips emphasis markers first, rather than widening the
# regex to tolerate them (the doctrine wording itself may or may not stay
# emphasized after the rewrite; either way the words are what's asserted).
schema_no_emphasis="$(printf '%s' "$schema_joined" | tr -d '*_')"

if grep -qiE 'not[[:space:]]+currently[[:space:]]+enforced|not[[:space:]]+enforced[[:space:]]+by' <<< "$schema_no_emphasis"; then
  fail "§7.3 no longer states the validation rules are unenforced" \
    "still present: $(windows_around "$schema_no_emphasis" 'enforced' 80 80)"
else
  pass "§7.3 no longer states the validation rules are unenforced"
fi

# The section also names the *file* `monorepo-config.json` (and the
# `.json.template` it's documented in) independently of whether it names
# the *check* -- a bare substring match on "monorepo-config" would be
# satisfied by the filename alone, today, before anything is edited. Strip
# the filename spellings first so what's left can only be a reference to
# the check itself, then require "check" nearby.
schema_no_filename="$(printf '%s' "$schema_joined" | sed -E 's/monorepo-config\.json(\.template)?//g')"
check_name_window="$(windows_around "$schema_no_filename" 'monorepo-config' 60 60)"
if [ -n "$check_name_window" ] && grep -qi 'check' <<< "$check_name_window"; then
  pass "§7.3 names the monorepo-config check itself, not just the config filename"
else
  fail "§7.3 names the monorepo-config check itself, not just the config filename" \
    "window (filename mentions stripped): ${check_name_window:-<empty>}"
fi

contract_joined="$(join_lines < "$CONTRACT_DOC")"
# Wide window: the three new fields could land before OR after the
# workspace_roots row they're anchored on, and a source-field table entry
# (id, kind, description) runs long -- a narrow window risks a true
# positive missing the anchor by table-row distance alone.
entry_shape_window="$(windows_around "$contract_joined" 'workspace_roots' 1200 1200)"

for field in slice_of slice_id slice_paths; do
  if grep -qF "$field" <<< "$entry_shape_window"; then
    pass "02-artifact-contract.md's entry-shape area documents $field"
  else
    fail "02-artifact-contract.md's entry-shape area documents $field" "window: $entry_shape_window"
  fi
done

# ============================================================================
# Check 3 -- paths: admitted as an optional third key; every other third key
# still rejected; the four real in-repo navigators pass unchanged
# ============================================================================
section "Check 3 -- paths: accepted as the third key, any other third key still rejected"

check3_case() {
  # check3_case <label> <frontmatter-body> <expect: fail|pass>
  local label="$1" fm="$2" expect="$3" root cache out c3
  root="$WORK/check3-$(printf '%s' "$label" | tr -c 'a-z0-9' '-' | cut -c1-40)-$RANDOM"
  write_navigator_fm "$root" "$fm"
  write_sources "$root" '[]'
  cache="$root-cache"
  mkdir -p "$cache"
  out="$(run_verify "$root" "$cache")"
  c3="$(check_section "$out" '(navigator-skill)')"
  if [ "$expect" = "fail" ]; then
    if printf '%s' "$c3" | grep -q '\[FAIL\]'; then
      pass "$label"
    else
      fail "$label" "navigator-skill section: ${c3:-<empty>}"
    fi
  else
    if printf '%s' "$c3" | grep -q '\[FAIL\]'; then
      fail "$label" "navigator-skill section: ${c3:-<empty>}"
    else
      pass "$label"
    fi
  fi
}

check3_case "two-key frontmatter (name + description) still passes" \
  "name: acme-context
description: ${NAV_DESC}" pass

check3_case "name + description + paths: (non-empty glob list) passes" \
  "name: acme-context
description: ${NAV_DESC}
paths:
  - \"packages/billing/**\"
  - \"shared/**\"" pass

check3_case "a third key of version: is rejected" \
  "name: acme-context
description: ${NAV_DESC}
version: 1.0" fail

check3_case "a third key of author: is rejected (a second, distinct instance of the same class)" \
  "name: acme-context
description: ${NAV_DESC}
author: someone" fail

check3_case "paths: present but as a scalar string (not a list) is rejected" \
  "name: acme-context
description: ${NAV_DESC}
paths: packages/billing/**" fail

check3_case "paths: [] (empty list) is rejected -- the admitted shape requires non-empty" \
  "name: acme-context
description: ${NAV_DESC}
paths: []" fail

section "Check 3 -- the four real in-repo navigators still pass, unchanged"

real_navigators=(
  ".claude/skills/skill-engine-context"
  "examples/inspect-ai-context"
  "examples/langchain-context"
  "examples/modelcontextprotocol-python-sdk-context"
)
real_cache="$WORK/real-nav-cache"
mkdir -p "$real_cache"
for rel in "${real_navigators[@]}"; do
  real_root="$REPO_ROOT/$rel"
  if [ ! -f "$real_root/SKILL.md" ]; then
    fail "real navigator present: $rel/SKILL.md" "not found -- fixture assumption stale, confirm the path at freeze time"
    continue
  fi
  real_out="$(run_verify "$real_root" "$real_cache")"
  real_c3="$(check_section "$real_out" '(navigator-skill)')"
  if printf '%s' "$real_c3" | grep -q '\[FAIL\]'; then
    fail "real navigator $rel still passes Check 3 unchanged" "navigator-skill section: ${real_c3:-<empty>}"
  else
    pass "real navigator $rel still passes Check 3 unchanged"
  fi
done

# ----- summary -------------------------------------------------------------

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
