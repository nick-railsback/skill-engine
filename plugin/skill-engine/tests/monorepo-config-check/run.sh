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

run_cfg_case "rule E (underscore) -- a slice id carrying _ cannot survive cache-git.sh and must be rejected here" \
  '{"version":"1.0","monorepos":[{"url":"https://example.com/acme/mono-e3","type":"internal-repo","slices":[{"id":"web_app","paths":["apps/web/**"]}]}]}' \
  fail "web_app"

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
# Malformed shapes: the pass condition must not be "jq printed nothing"
# ============================================================================
# Each rule filter used to be a `done < <(jq ... 2>/dev/null)` process
# substitution. jq's stderr was discarded, its exit status is unobservable
# through a process substitution (pipefail cannot see it), and empty output
# WAS the pass condition -- so every config shape that made jq throw rather
# than return was reported valid. Two shapes below additionally need no jq
# error at all: `paths` as a string took `length` as a CHARACTER count, so
# the zero-length arm never fired; and a slice with no `id` passed all five
# rules, because the duplicate-id filter applied `select(. != "")` to the
# whole id ARRAY (never equal to "") and the id-regex rule explicitly
# exempted the empty string. Every one of these reached slice_drift.py as a
# blessed config and raised there instead. (PR #16 review, finding 3.)
section "monorepo-config.json -- shapes that make jq throw, or that slip past a rule, are rejected not blessed"

run_cfg_case "slices as an array of strings is rejected (the id/paths filters throw on it)" \
  '{"version":"1.0","monorepos":[{"url":"https://example.com/acme/mono-g1","type":"internal-repo","slices":["billing","web"]}]}' \
  fail ""

run_cfg_case "slices as a bare string is rejected" \
  '{"version":"1.0","monorepos":[{"url":"https://example.com/acme/mono-g2","type":"internal-repo","slices":"oops"}]}' \
  fail ""

run_cfg_case "paths as a bare string is rejected (length on a string is a character count, not 0)" \
  '{"version":"1.0","monorepos":[{"url":"https://example.com/acme/mono-g3","type":"internal-repo","slices":[{"id":"billing","paths":"packages/billing/**"}]}]}' \
  fail "billing"

run_cfg_case "a slice with no id at all is rejected" \
  '{"version":"1.0","monorepos":[{"url":"https://example.com/acme/mono-g4","type":"internal-repo","slices":[{"paths":["x"]},{"paths":["y"]}]}]}' \
  fail ""

run_cfg_case "a slice whose id is null is rejected" \
  '{"version":"1.0","monorepos":[{"url":"https://example.com/acme/mono-g5","type":"internal-repo","slices":[{"id":null,"paths":["x"]}]}]}' \
  fail ""

run_cfg_case "a slice whose id is a number is rejected" \
  '{"version":"1.0","monorepos":[{"url":"https://example.com/acme/mono-g6","type":"internal-repo","slices":[{"id":7,"paths":["x"]}]}]}' \
  fail ""

run_cfg_case "a monorepos[] element that is not an object is rejected" \
  '{"version":"1.0","monorepos":["https://example.com/acme/mono-g7"]}' \
  fail ""

run_cfg_case "monorepos: null is rejected" \
  '{"version":"1.0","monorepos":null}' fail ""

run_cfg_case "paths as an object is rejected" \
  '{"version":"1.0","monorepos":[{"url":"https://example.com/acme/mono-g8","type":"internal-repo","slices":[{"id":"billing","paths":{"a":"b"}}]}]}' \
  fail "billing"

# The battery as one invariant: NONE of these may reach the [PASS] line. A
# per-case `fail` expectation already asserts a [FAIL] appears, but a check
# that emitted both would still be broken -- the PASS line is what a reader
# and REVIEW.md act on.
malformed_blessed=()
mal_i=0
while IFS= read -r mal_cfg; do
  [ -n "$mal_cfg" ] || continue
  mal_i=$((mal_i + 1))
  root_mal="$WORK/cfg-malformed-$mal_i"
  build_nav "$root_mal"
  write_sources "$root_mal" '[]'
  write_monorepo_config "$root_mal" research "$mal_cfg"
  cache_mal="$root_mal-cache"
  mkdir -p "$cache_mal"
  mc_mal="$(check_section "$(run_verify "$root_mal" "$cache_mal")" '(monorepo-config)')"
  if printf '%s' "$mc_mal" | grep -qF '[PASS] monorepo-config.json valid'; then
    malformed_blessed+=("$mal_cfg -> $(printf '%s' "$mc_mal" | grep -F '[PASS]')")
  fi
done <<'MALFORMED'
{"version":"1.0","monorepos":[{"url":"https://example.com/acme/m1","slices":["billing","web"]}]}
{"version":"1.0","monorepos":[{"url":"https://example.com/acme/m2","slices":"oops"}]}
{"version":"1.0","monorepos":[{"url":"https://example.com/acme/m3","slices":[{"id":"billing","paths":"packages/billing/**"}]}]}
{"version":"1.0","monorepos":[{"url":"https://example.com/acme/m4","slices":[{"paths":["x"]},{"paths":["y"]}]}]}
{"version":"1.0","monorepos":[{"url":"https://example.com/acme/m5","slices":[{"id":null,"paths":["x"]}]}]}
{"version":"1.0","monorepos":[{"url":"https://example.com/acme/m6","slices":[{"id":7,"paths":["x"]}]}]}
{"version":"1.0","monorepos":[{"url":"https://example.com/acme/m7","slices":[{"id":"billing","paths":{"a":"b"}}]}]}
{"version":"1.0","monorepos":[{"url":"https://example.com/acme/m8","slices":[{"id":"billing","paths":["ok"],"extra":[1,2]}]}, "not-an-object"]}
{"version":"1.0","monorepos":null}
MALFORMED

if [ "${#malformed_blessed[@]}" -eq 0 ]; then
  pass "no malformed config in the battery reaches the [PASS] monorepo-config.json valid line"
else
  fail "no malformed config in the battery reaches the [PASS] monorepo-config.json valid line" "${malformed_blessed[@]}"
fi

# Control: the battery is discriminating, not blanket-rejecting.
root_mal_ok="$WORK/cfg-malformed-control"
build_nav "$root_mal_ok"
write_sources "$root_mal_ok" '[]'
write_monorepo_config "$root_mal_ok" research "$valid_cfg"
cache_mal_ok="$WORK/cfg-malformed-control-cache"
mkdir -p "$cache_mal_ok"
if check_section "$(run_verify "$root_mal_ok" "$cache_mal_ok")" '(monorepo-config)' \
   | grep -qF '[PASS] monorepo-config.json valid'; then
  pass "control: the valid three-slice config still reaches the [PASS] line"
else
  fail "control: the valid three-slice config still reaches the [PASS] line" \
    "$(check_section "$(run_verify "$root_mal_ok" "$cache_mal_ok")" '(monorepo-config)')"
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
write_schema_doc "$WORK/slice-id-underscore.json" '{"slice_of":"https://example.com/acme/parent","slice_id":"web_app","slice_paths":["apps/web/**"]}'

fixture_ok=true
for f in slice-absent slice-all-present slice-bad-id slice-paths-string slice-paths-empty slice-paths-blank-entry slice-id-underscore; do
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
  schema_rejects "slice_id carrying _ is rejected — the derived source id is a cache path segment" "$WORK/slice-id-underscore.json"
fi

# ============================================================================
# The slice-id pattern vs. the guard that actually consumes the derived id
# ============================================================================
# Every derived source id is "<parent id>-<slice_id>" (cache-and-clone.md
# step 1.7) and is interpolated straight into a cache directory name by
# bin/cache-git.sh, whose own guard is narrower than the slice-id pattern
# was. An id the config check blesses but cache-git.sh refuses validates,
# stages and applies, and is then never cached, never crawled, and
# [N/A]-skipped by Checks 6 and 8 forever -- the failure has no line of its
# own anywhere. This asserts the containment directly rather than trusting
# two regexes written 1,100 lines apart to agree. (PR #16 review, finding 2.)
section "slice-id pattern ⊆ cache-git.sh's source_id guard"

CACHE_GIT_SH="$PLUGIN_ROOT/bin/cache-git.sh"

# cfg_admits_slice_id <slice-id> -- true when the SHIPPED monorepo-config
# check accepts a one-slice config carrying that id. Reads the real
# verify.sh rather than re-spelling its regex here, so this stays an
# assertion about what ships and not about a copy of it.
cfg_admits_slice_id() {
  local sid="$1" root cache out mc
  root="$WORK/guard-cfg-$(printf '%s' "$sid" | tr -c 'a-zA-Z0-9' '-')"
  build_nav "$root"
  write_sources "$root" '[]'
  write_monorepo_config "$root" research \
    "$(jq -n --arg id "$sid" '{version:"1.0",monorepos:[{url:"https://example.com/acme/guard",type:"internal-repo",slices:[{id:$id,paths:["packages/x/**"]}]}]}')"
  cache="$root-cache"
  mkdir -p "$cache"
  out="$(run_verify "$root" "$cache")"
  mc="$(check_section "$out" '(monorepo-config)')"
  ! printf '%s' "$mc" | grep -q '\[FAIL\]'
}

# cache_git_admits <source_id> -- true when cmd_sparse_clone's guard lets
# the id through. The clone that follows is expected to fail (the url is
# unroutable by construction); only the guard's own refusal line is read.
cache_git_admits() {
  local sid="$1" out
  out="$(SKILL_ENGINE_CACHE_ROOT="$WORK/guard-cache" \
    bash "$CACHE_GIT_SH" sparse-clone "$sid" "file://$WORK/no-such-repo" HEAD -- 'packages/x/**' 2>&1)"
  ! printf '%s' "$out" | grep -qF 'refusing unsafe source_id'
}

if [ ! -f "$CACHE_GIT_SH" ]; then
  fail "bin/cache-git.sh is present to check the derived id against" "not found at $CACHE_GIT_SH"
else
  guard_ok=1
  guard_detail=()
  for slice_id in billing web_app under_score plain-dash x2; do
    derived="acme-monorepo-$slice_id"
    if cfg_admits_slice_id "$slice_id" && ! cache_git_admits "$derived"; then
      guard_ok=0
      guard_detail+=("slice id '$slice_id' passes the monorepo-config check but cache-git.sh refuses '$derived'")
    fi
  done
  if [ "$guard_ok" -eq 1 ]; then
    pass "every slice id the monorepo-config check accepts yields a derived source id cache-git.sh accepts"
  else
    fail "every slice id the monorepo-config check accepts yields a derived source id cache-git.sh accepts" \
      "${guard_detail[@]}"
  fi

  # The containment must not be vacuous: at least one id in the probe set
  # has to be accepted on both sides, or the loop above proves nothing.
  if cfg_admits_slice_id billing && cache_git_admits "acme-monorepo-billing"; then
    pass "the containment check is non-vacuous — an ordinary slice id is admitted by both surfaces"
  else
    fail "the containment check is non-vacuous — an ordinary slice id is admitted by both surfaces" \
      "'billing' must pass the config check and yield a cache-git.sh-admissible derived id"
  fi
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

# ----------------------------------------------------------------------------
# Check 2's parent-existence gate must require a NON-SLICE match
# ----------------------------------------------------------------------------
# A derived slice carries `url: $m.url` -- the parent's own url -- so url is
# not a unique key into .sources[]. The gate excluded only the entry being
# checked (`select(.key != $idx)`) and never required the match to be a
# non-slice entry, so two sibling slices satisfied it for each other and a
# registry with slices but NO PARENT AT ALL passed. The gate only bound for
# a lone slice, i.e. never in the case slicing exists for.
# (PR #16 review, finding 7.)
root_orphan_slices="$WORK/check2-orphan-slices"
build_nav "$root_orphan_slices"
orphan_parent_url="https://example.com/acme/orphan-monorepo"
orphan_billing_extra="$(jq -n --arg of "$orphan_parent_url" \
  '{slice_of: $of, slice_id: "billing", slice_paths: ["packages/billing/**"]}')"
orphan_reports_extra="$(jq -n --arg of "$orphan_parent_url" \
  '{slice_of: $of, slice_id: "reports", slice_paths: ["apps/reports/**"]}')"
orphan_sources="$( {
  git_managed_source acme-orphan-billing "$orphan_parent_url" "$orphan_billing_extra"
  git_managed_source acme-orphan-reports "$orphan_parent_url" "$orphan_reports_extra"
} | jq -s '.' )"
write_sources "$root_orphan_slices" "$orphan_sources"
cache_orphan="$WORK/check2-orphan-cache"
mkdir -p "$cache_orphan"
c2_orphan="$(check_section "$(run_verify "$root_orphan_slices" "$cache_orphan")" 'Source entries')"
if printf '%s' "$c2_orphan" | grep -q '\[FAIL\]'; then
  pass "source-entries: two sibling slices with no parent entry fail — a sibling does not satisfy the parent gate"
else
  fail "source-entries: two sibling slices with no parent entry fail — a sibling does not satisfy the parent gate" \
    "source-entries section: ${c2_orphan:-<empty>}"
fi

# Control: with the parent present, the identical pair passes. Without
# this the gate could satisfy the case above by rejecting every slice.
root_sibling_ok="$WORK/check2-siblings-with-parent"
build_nav "$root_sibling_ok"
sibling_ok_sources="$( {
  git_managed_source acme-orphan "$orphan_parent_url"
  git_managed_source acme-orphan-billing "$orphan_parent_url" "$orphan_billing_extra"
  git_managed_source acme-orphan-reports "$orphan_parent_url" "$orphan_reports_extra"
} | jq -s '.' )"
write_sources "$root_sibling_ok" "$sibling_ok_sources"
cache_sibling_ok="$WORK/check2-siblings-with-parent-cache"
mkdir -p "$cache_sibling_ok"
c2_sibling_ok="$(check_section "$(run_verify "$root_sibling_ok" "$cache_sibling_ok")" 'Source entries')"
if printf '%s' "$c2_sibling_ok" | grep -q '\[FAIL\]'; then
  fail "source-entries: control — the same two slices WITH their parent registered pass" \
    "source-entries section: ${c2_sibling_ok:-<empty>}"
else
  pass "source-entries: control — the same two slices WITH their parent registered pass"
fi

# ----------------------------------------------------------------------------
# Check 2 must validate the REGISTRY side of the slice contract too
# ----------------------------------------------------------------------------
# The slice gate validated exactly two things: that slice_of/slice_id/
# slice_paths are present together, and that slice_of matches a registered
# source. It never checked slice_id against the documented pattern, and
# never checked slice_paths's type or non-emptiness.
# source-paths.schema.json DOES constrain both, and its preamble calls
# itself "the machine-readable transcription of the contract that verify.sh
# Check 1 ... and Check 2 ... enforce at audit time" -- but ci-local points
# check-jsonschema only at the template and the examples, never at a live
# contextualizer's own registry, so neither gate ran on the file every
# consumer reads. The asymmetry is the tell: the same two constraints ARE
# enforced on the config side by the monorepo-config check. The engine
# validated the file it derives FROM and not the registry it derives TO.
# (PR #16 review, finding 11.)
section "Check 2 -- slice_id pattern and slice_paths shape are enforced on the registry, not only on the config"

registry_slice_case() {
  # registry_slice_case <label> <extra-json-for-the-slice-entry> <expect: fail|pass>
  local label="$1" extra="$2" expect="$3" root cache c2 sources
  root="$WORK/check2-registry-$(printf '%s' "$label" | tr -c 'a-z0-9' '-' | cut -c1-36)-$RANDOM"
  build_nav "$root"
  sources="$( {
    git_managed_source acme-reg "$parent_url"
    git_managed_source acme-reg-slice "$parent_url" "$extra"
  } | jq -s '.' )"
  write_sources "$root" "$sources"
  cache="$root-cache"
  mkdir -p "$cache"
  c2="$(check_section "$(run_verify "$root" "$cache")" 'Source entries')"
  if [ "$expect" = "fail" ]; then
    if printf '%s' "$c2" | grep -q '\[FAIL\]'; then
      pass "$label"
    else
      fail "$label" "source-entries section: ${c2:-<empty>}"
    fi
  else
    if printf '%s' "$c2" | grep -q '\[FAIL\]'; then
      fail "$label" "source-entries section: ${c2:-<empty>}"
    else
      pass "$label"
    fi
  fi
}

registry_slice_case "slice_id failing the id pattern is rejected on the registry side" \
  "$(jq -n --arg of "$parent_url" '{slice_of:$of, slice_id:"Bad Slice/../../etc", slice_paths:["packages/billing/**"]}')" fail

registry_slice_case "slice_id carrying _ is rejected on the registry side" \
  "$(jq -n --arg of "$parent_url" '{slice_of:$of, slice_id:"web_app", slice_paths:["apps/web/**"]}')" fail

registry_slice_case "slice_paths as a bare string is rejected on the registry side" \
  "$(jq -n --arg of "$parent_url" '{slice_of:$of, slice_id:"billing", slice_paths:"packages/billing/**"}')" fail

registry_slice_case "slice_paths as an empty array is rejected on the registry side" \
  "$(jq -n --arg of "$parent_url" '{slice_of:$of, slice_id:"billing", slice_paths:[]}')" fail

registry_slice_case "slice_paths containing an empty string is rejected on the registry side" \
  "$(jq -n --arg of "$parent_url" '{slice_of:$of, slice_id:"billing", slice_paths:["packages/billing/**",""]}')" fail

registry_slice_case "slice_paths containing a non-string is rejected on the registry side" \
  "$(jq -n --arg of "$parent_url" '{slice_of:$of, slice_id:"billing", slice_paths:[123]}')" fail

registry_slice_case "control: a well-formed slice entry still passes" \
  "$(jq -n --arg of "$parent_url" '{slice_of:$of, slice_id:"billing", slice_paths:["packages/billing/**"]}')" pass

# The combination the report reproduced as `Passed: 16, Failed: 0`: a bad
# slice_id AND a string slice_paths in one entry, alongside a second slice
# whose slice_paths is []. Both must surface.
root_reg_multi="$WORK/check2-registry-multi"
build_nav "$root_reg_multi"
reg_multi_sources="$( {
  git_managed_source acme-reg "$parent_url"
  git_managed_source acme-reg-a "$parent_url" \
    "$(jq -n --arg of "$parent_url" '{slice_of:$of, slice_id:"Bad Slice/../../etc", slice_paths:"packages/billing/**"}')"
  git_managed_source acme-reg-b "$parent_url" \
    "$(jq -n --arg of "$parent_url" '{slice_of:$of, slice_id:"reports", slice_paths:[]}')"
} | jq -s '.' )"
write_sources "$root_reg_multi" "$reg_multi_sources"
cache_reg_multi="$WORK/check2-registry-multi-cache"
mkdir -p "$cache_reg_multi"
c2_reg_multi="$(check_section "$(run_verify "$root_reg_multi" "$cache_reg_multi")" 'Source entries')"
reg_multi_fails="$(printf '%s' "$c2_reg_multi" | grep -c '\[FAIL\]' || true)"
if [ "$reg_multi_fails" -ge 2 ]; then
  pass "source-entries: two independently malformed slice entries surface at least two failures, not one or none"
else
  fail "source-entries: two independently malformed slice entries surface at least two failures, not one or none" \
    "saw $reg_multi_fails [FAIL] line(s) -- section: ${c2_reg_multi:-<empty>}"
fi

# The schema is the second gate, and it has to actually run on real
# registries. ci-local pointed check-jsonschema at the template and
# examples/ only, so this repo's own dogfood contextualizer's registry --
# tracked in git, read by every /skill-engine:* invocation here -- was
# validated by nothing. (PR #16 review, finding 11.)
if [ "$HAVE_CJS" -eq 1 ]; then
  cjs_expected=$(( 1 + $(git -C "$REPO_ROOT" ls-files -- '*/research/source-paths.json' | grep -c . || true) ))
  cjs_line="$(cd "$REPO_ROOT" && bash scripts/ci-local.sh json 2>&1 | grep -E 'Validating [0-9]+ file' | head -1)"
  cjs_count="$(printf '%s' "$cjs_line" | sed -E 's/[^0-9]*([0-9]+).*/\1/')"
  if [ -n "$cjs_count" ] && [ "$cjs_count" -ge "$cjs_expected" ]; then
    pass "ci-local validates every tracked research/source-paths.json against the schema, not only the examples"
  else
    fail "ci-local validates every tracked research/source-paths.json against the schema, not only the examples" \
      "expected at least $cjs_expected target(s) (1 template + every tracked registry), saw: ${cjs_line:-<no line>}"
  fi

  # Non-vacuity: there IS a tracked registry outside examples/, so the
  # count above is not satisfied by the examples alone.
  if git -C "$REPO_ROOT" ls-files -- '*/research/source-paths.json' | grep -qv '^examples/'; then
    pass "the schema-target inventory is non-vacuous — a tracked registry exists outside examples/"
  else
    fail "the schema-target inventory is non-vacuous — a tracked registry exists outside examples/" \
      "every tracked registry is under examples/, so this assertion proves nothing"
  fi
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
# Each slice also has its own sparse tree, installed under its own derived
# source id -- what `cache-git.sh sparse-clone "$source_id"` actually
# creates (chunk 04, "slice-sparse-crawl"). The parent's own clone stays
# alongside them: chunk 02 excludes it from crawling but never deletes it.
mkdir -p "$cache_slices/git-managed/acme-monorepo-slices-billing-a1b2c3d4/domains/billing" \
         "$cache_slices/git-managed/acme-monorepo-slices-auth-a1b2c3d4/domains/auth"
printf 'billing code\n' > "$cache_slices/git-managed/acme-monorepo-slices-billing-a1b2c3d4/domains/billing/main.go"
printf 'auth code\n' > "$cache_slices/git-managed/acme-monorepo-slices-auth-a1b2c3d4/domains/auth/main.go"

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

# ----------------------------------------------------------------------------
# Check 6's slice-tree resolution must not depend on .sources[] order
# ----------------------------------------------------------------------------
# The branch resolved the PARENT's cache tree through
# `[.sources[]? | select((.url // "") == $of) | .id] | first`. Every sibling
# slice carries the parent's url too, so `first` is decided by array order:
# a slice can resolve to a SIBLING's tree, or to itself. And since skip() is
# `passed=$((passed + 1))`, a misresolution does not merely drop coverage --
# the heuristic reports clean. The branch's own comment named the cause ("a
# slice entry has no clone of its own -- chunk 04 is what will ever give it
# one"), and chunk 04 is in this same PR: cache-git.sh sparse-clone installs
# each slice under its OWN derived source id. Resolve that, and the
# order-dependence disappears with the sibling lookup. (PR #16 review,
# finding 7.)
# The fixture above gives each slice its own distinct url, which is not
# what step 1.7 emits: the derivation stamps `url: $m.url`, so every slice
# carries the PARENT's url verbatim. That is precisely what makes url a
# non-unique key, so the order-dependence only reproduces against the real
# shape. Built here rather than by patching the fixture above, which stays
# as the narrower already-frozen case.
real_billing_extra="$(jq -n --arg of "$parent_slices_url" \
  '{slice_of: $of, slice_id: "billing", slice_paths: ["domains/billing/**"]}')"
real_auth_extra="$(jq -n --arg of "$parent_slices_url" \
  '{slice_of: $of, slice_id: "auth", slice_paths: ["domains/auth/**"]}')"
real_slices_sources="$( {
  git_managed_source acme-monorepo-slices "$parent_slices_url"
  git_managed_source acme-monorepo-slices-billing "$parent_slices_url" "$real_billing_extra"
  git_managed_source acme-monorepo-slices-auth "$parent_slices_url" "$real_auth_extra"
} | jq -s '.' )"

run_check6_order() {
  # run_check6_order <label-suffix> <jq-reorder-program>
  local suffix="$1" reorder="$2" root cache
  root="$WORK/check6-order-$suffix"
  build_nav "$root"
  mkdir -p "$root/references"
  printf '# Auth notes\n\nSee domains/auth for the service implementation.\n' \
    > "$root/references/acme-monorepo-auth.md"
  write_sources "$root" "$(printf '%s' "$real_slices_sources" | jq "$reorder")"
  cache="$root-cache"
  # Each slice gets its own sparse tree under its own derived id, which is
  # what bin/cache-git.sh sparse-clone actually installs, plus the parent's
  # own clone (the pre-slicing one, which chunk 02 now excludes from
  # crawling but never deletes).
  mkdir -p "$cache/git-managed/acme-monorepo-slices-a1b2c3d4" \
           "$cache/git-managed/acme-monorepo-slices-billing-a1b2c3d4" \
           "$cache/git-managed/acme-monorepo-slices-auth-a1b2c3d4"
  populate_monorepo_tree "$cache/git-managed/acme-monorepo-slices-a1b2c3d4"
  mkdir -p "$cache/git-managed/acme-monorepo-slices-billing-a1b2c3d4/domains/billing"
  printf 'billing code\n' > "$cache/git-managed/acme-monorepo-slices-billing-a1b2c3d4/domains/billing/main.go"
  mkdir -p "$cache/git-managed/acme-monorepo-slices-auth-a1b2c3d4/domains/auth"
  printf 'auth code\n' > "$cache/git-managed/acme-monorepo-slices-auth-a1b2c3d4/domains/auth/main.go"
  check_section "$(run_verify "$root" "$cache")" 'Monorepo-coverage'
}

# The parent first, then the two slices -- and the exact reverse. The
# verdict must be identical.
c6_order_fwd="$(run_check6_order fwd '.')"
c6_order_rev="$(run_check6_order rev 'reverse')"

c6_warns_fwd="$(printf '%s' "$c6_order_fwd" | grep -c '\[WARN\]' || true)"
c6_warns_rev="$(printf '%s' "$c6_order_rev" | grep -c '\[WARN\]' || true)"
c6_skips_fwd="$(printf '%s' "$c6_order_fwd" | grep -c '\[N/A\]' || true)"
c6_skips_rev="$(printf '%s' "$c6_order_rev" | grep -c '\[N/A\]' || true)"

if [ "$c6_warns_fwd" = "$c6_warns_rev" ] && [ "$c6_skips_fwd" = "$c6_skips_rev" ]; then
  pass "monorepo-coverage: reordering .sources[] does not change the slice verdicts"
else
  fail "monorepo-coverage: reordering .sources[] does not change the slice verdicts" \
    "forward: $c6_warns_fwd WARN / $c6_skips_fwd N-A -- reversed: $c6_warns_rev WARN / $c6_skips_rev N-A" \
    "forward section: ${c6_order_fwd:-<empty>}" \
    "reversed section: ${c6_order_rev:-<empty>}"
fi

# Non-vacuity: in BOTH orders the uncited slice must actually warn and the
# cited one must not. Equal-but-both-silent would satisfy the check above.
c6_order_ok=1
c6_order_detail=()
for c6_ord in "forward:$c6_order_fwd" "reversed:$c6_order_rev"; do
  c6_ord_label="${c6_ord%%:*}"
  c6_ord_text="${c6_ord#*:}"
  printf '%s' "$c6_ord_text" | grep -qE '\[WARN\].*\bbilling\b' \
    || { c6_order_ok=0; c6_order_detail+=("$c6_ord_label: uncited slice 'billing' did not warn"); }
  printf '%s' "$c6_ord_text" | grep -qE '\[WARN\].*\bauth\b' \
    && { c6_order_ok=0; c6_order_detail+=("$c6_ord_label: cited slice 'auth' warned"); }
  printf '%s' "$c6_ord_text" | grep -qE '\[N/A\].*slice' \
    && { c6_order_ok=0; c6_order_detail+=("$c6_ord_label: a slice was [N/A]-skipped though its own tree is cached"); }
done
if [ "$c6_order_ok" -eq 1 ]; then
  pass "monorepo-coverage: in both orders the uncited slice warns, the cited one does not, and neither is skipped"
else
  fail "monorepo-coverage: in both orders the uncited slice warns, the cited one does not, and neither is skipped" \
    "${c6_order_detail[@]}"
fi

# ----------------------------------------------------------------------------
# Check 6's slice branch: anchored citation, every slice_path, no double
# enumeration of the parent
# ----------------------------------------------------------------------------
# The slice branch scored a slice cited with an UNANCHORED `\b<slice_id>\b`
# grep over all of references/ -- exactly the form the member path's own
# comment in the same loop forbids, citing PR #15 review finding 1: "a
# generic [^[:alnum:]_] on the left drops the anchor: `api` would match
# inside a cited sibling's `web-api` at the `-`". Slice ids like api, web,
# core and db are the common case, and the branch even computed $slice_dir
# -- the anchor it needs -- and never used it. It also read only
# slice_paths[0], though 07-monorepo-adapter.md and the schema both say the
# field feeds Check 6 "the same way workspace_roots does", and
# workspace_roots iterates every entry. (PR #16 review, finding 15.)
section "Check 6 -- slice citation is path-anchored, reads every slice_path, and does not double-count the parent"

c6_slice_fixture() {
  # c6_slice_fixture <name> <slice-paths-json> <reference-body>
  # Builds a contextualizer whose slice `api` is genuinely uncited, with
  # one reference carrying the given body. Echoes the coverage section.
  local name="$1" slice_paths="$2" ref_body="$3" root cache purl sources
  root="$WORK/check6-slice-$name"
  build_nav "$root"
  mkdir -p "$root/references"
  printf '%s\n' "$ref_body" > "$root/references/notes.md"
  purl="https://example.com/acme/mono-$name"
  sources="$( {
    git_managed_source acme-mono-"$name" "$purl"
    git_managed_source acme-mono-"$name"-api "$purl" \
      "$(jq -n --arg of "$purl" --argjson sp "$slice_paths" \
         '{slice_of:$of, slice_id:"api", slice_paths:$sp}')"
  } | jq -s '.' )"
  write_sources "$root" "$sources"
  cache="$root-cache"
  mkdir -p "$cache/git-managed/acme-mono-$name-api-a1b2c3d4/packages/api" \
           "$cache/git-managed/acme-mono-$name-api-a1b2c3d4/shared/api-types" \
           "$cache/git-managed/acme-mono-$name-a1b2c3d4/packages/api"
  printf 'x\n' > "$cache/git-managed/acme-mono-$name-api-a1b2c3d4/packages/api/m.go"
  printf 'x\n' > "$cache/git-managed/acme-mono-$name-api-a1b2c3d4/shared/api-types/t.go"
  printf 'x\n' > "$cache/git-managed/acme-mono-$name-a1b2c3d4/packages/api/m.go"
  check_section "$(run_verify "$root" "$cache")" 'Monorepo-coverage'
}

# Each assertion names the branch it is about. The slice branch reports the
# slice's own derived source id; the member branch reports the parent's.
# Conflating them is how the pre-fix behaviour read as "something warned":
# the parent warned about packages/api while the slice branch, in the same
# run, scored that identical directory cited.
slice_warned() { printf '%s' "$1" | grep -qE "\\[WARN\\].*acme-mono-$2-api\\b"; }
parent_warned() { printf '%s' "$1" | grep -qE "\\[WARN\\].*acme-mono-$2([^-]|$)"; }

# (a) The only occurrence of "api" anywhere under references/ is inside an
# unrelated `packages/web-api` path. An unanchored \bapi\b matches at the
# hyphen and scores the slice cited.
c6_hyphen="$(c6_slice_fixture hyphen '["packages/api/**"]' \
  '# Notes

The web front end lives under packages/web-api and is documented there.')"
if slice_warned "$c6_hyphen" hyphen; then
  pass "monorepo-coverage: a slice named 'api' is NOT scored cited by 'packages/web-api' in an unrelated reference"
else
  fail "monorepo-coverage: a slice named 'api' is NOT scored cited by 'packages/web-api' in an unrelated reference" \
    "an unanchored word-boundary grep matches 'api' inside 'web-api' at the hyphen" \
    "coverage section: ${c6_hyphen:-<empty>}"
fi

# (b) The bare word in prose is not a citation either -- the member path
# requires the ROOT-PREFIXED path form, and the slice path must too.
c6_prose="$(c6_slice_fixture prose '["packages/api/**"]' \
  '# Notes

This corpus says a lot about api design in general.')"
if slice_warned "$c6_prose" prose; then
  pass "monorepo-coverage: the bare word 'api' in prose does not score the slice cited"
else
  fail "monorepo-coverage: the bare word 'api' in prose does not score the slice cited" \
    "coverage section: ${c6_prose:-<empty>}"
fi

# (c) Control: the slice's actual path IS a citation.
c6_cited="$(c6_slice_fixture cited '["packages/api/**"]' \
  '# Notes

The handler lives in packages/api/m.go and is described here.')"
if slice_warned "$c6_cited" cited; then
  fail "monorepo-coverage: control — citing the slice's own path scores it cited" \
    "coverage section: ${c6_cited:-<empty>}"
else
  pass "monorepo-coverage: control — citing the slice's own path scores it cited"
fi

# (d) Every slice_paths entry counts, not only the first. The slice
# declares two; only the SECOND is cited.
c6_second="$(c6_slice_fixture second '["packages/api/**", "shared/api-types/**"]' \
  '# Notes

The shared types live in shared/api-types/t.go.')"
if slice_warned "$c6_second" second; then
  fail "monorepo-coverage: a citation of the SECOND slice_paths entry scores the slice cited" \
    "07-monorepo-adapter.md and the schema both say slice_paths feeds Check 6 the same way" \
    "workspace_roots does, and workspace_roots iterates every entry" \
    "coverage section: ${c6_second:-<empty>}"
else
  pass "monorepo-coverage: a citation of the SECOND slice_paths entry scores the slice cited"
fi

# (e) A first entry that is a bare glob or names a file must not
# [N/A]-skip the whole slice when a later entry resolves.
c6_globfirst="$(c6_slice_fixture globfirst '["**/api/**", "packages/api/**"]' \
  '# Notes

The handler lives in packages/api/m.go and is described here.')"
if printf '%s' "$c6_globfirst" | grep -qE '\[N/A\].*acme-mono-globfirst-api'; then
  fail "monorepo-coverage: a leading glob entry does not [N/A]-skip a slice whose later entry resolves" \
    "coverage section: ${c6_globfirst:-<empty>}"
else
  pass "monorepo-coverage: a leading glob entry does not [N/A]-skip a slice whose later entry resolves"
fi

# (f) The parent must not be enumerated as an ordinary source alongside its
# own slices: one run emitted [WARN] workspace member api under <parent>
# from the member branch while the slice branch scored the identical
# directory cited -- two opposite verdicts on one directory, in one run.
if parent_warned "$c6_hyphen" hyphen; then
  fail "monorepo-coverage: an applied parent is not also enumerated as an ordinary source" \
    "the parent branch warned about a directory its own slice branch also judged" \
    "coverage section: ${c6_hyphen:-<empty>}"
else
  pass "monorepo-coverage: an applied parent is not also enumerated as an ordinary source"
fi

# (g) A slice is not a "workspace member ... under" its own source id.
if printf '%s' "$c6_hyphen" | grep -qE '\[WARN\].*workspace member api under acme-mono-hyphen-api'; then
  fail "monorepo-coverage: a slice is reported as a slice, not as a workspace member under itself" \
    "coverage section: ${c6_hyphen:-<empty>}"
else
  pass "monorepo-coverage: a slice is reported as a slice, not as a workspace member under itself"
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

# Claude Code documents `paths` as accepting "a comma-separated string or a
# YAML list", and 02-artifact-contract.md justifies admitting the field by
# pointing at that documentation. Check 3 was a line-oriented grep that fell
# through to a scalar arm for any same-line value other than the literal
# `[]`, so BOTH documented spellings failed -- the flow sequence with the
# diagnostic "must be a YAML list, not a scalar value", which is not merely
# strict but factually false, since yaml.safe_load on that same frontmatter
# returns a list. The item-counting awk below the branch, the only code that
# actually counts entries, was unreachable for anything but block style.
# This expectation is a deliberate flip of the previously frozen one.
# (PR #16 review, finding 8.)
check3_case "paths: as a YAML flow sequence passes -- it IS a list" \
  "name: acme-context
description: ${NAV_DESC}
paths: [packages/billing/**, shared/**]" pass

check3_case "paths: as a single-item flow sequence passes" \
  "name: acme-context
description: ${NAV_DESC}
paths: [packages/billing/**]" pass

check3_case "paths: as a comma-separated string passes -- the other spelling the platform documents" \
  "name: acme-context
description: ${NAV_DESC}
paths: packages/billing/**, shared/**" pass

check3_case "paths: as a single-glob string passes" \
  "name: acme-context
description: ${NAV_DESC}
paths: packages/billing/**" pass

check3_case "paths: as a quoted flow sequence passes" \
  "name: acme-context
description: ${NAV_DESC}
paths: [\"packages/billing/**\", \"shared/**\"]" pass

check3_case "paths: [] (empty list) is rejected -- the admitted shape requires non-empty" \
  "name: acme-context
description: ${NAV_DESC}
paths: []" fail

check3_case "paths: with only separators and no glob is rejected" \
  "name: acme-context
description: ${NAV_DESC}
paths: [ , , ]" fail

check3_case "paths: as a bare comma is rejected" \
  "name: acme-context
description: ${NAV_DESC}
paths: ," fail

check3_case "paths: with an empty key and no block entries is still rejected" \
  "name: acme-context
description: ${NAV_DESC}
paths:" fail

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
