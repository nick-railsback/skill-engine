#!/usr/bin/env bash
# Black-box test runner for the decay-visibility column in STATUS's web-doc
# Cache listing table: whether a cached web-doc snapshot is still within its
# declared decay budget, past it, or non-expiring — computed from crawl_date
# (read from a source's _crawl-manifest.json) and decay (read from a crawled
# snapshot page's own frontmatter — the manifest itself carries no decay
# field), and surfaced without any network fetch or write.
#
# Nothing here assumes the computation lives in a standalone script versus
# inline shell inside status/SKILL.md itself — either is a legitimate place
# for it to land, and this suite must pass either way. So instead of
# invoking a named script, this suite pulls every executable ```bash fence
# out of status/SKILL.md (skipping only the section whose heading mentions
# "probe" — that one reaches the network on purpose, via a live
# `git ls-remote`, and running it here would violate this suite's own
# offline guarantee), concatenates the fences in document order, and runs
# the result as one script against a fixture contextualizer root. That
# fixture root supplies research/source-paths.json plus a
# ~/.cache/skill-engine/web-doc/<id>-<crawl_id>/ cache directory per case,
# holding a _crawl-manifest.json (crawl_date, plus a pages[] entry naming a
# real snapshot file on disk) and that snapshot .md file itself (frontmatter
# carrying the decay value under test), with $CTX_ROOT and $XDG_CACHE_HOME
# pointed at it so the extracted code reads fixture state instead of a real
# machine's cache.
#
# No decay computation exists anywhere in status/SKILL.md yet — the
# extracted bash is empty today, so every check below that requires a real
# verdict to appear in the output fails for that reason. Checks that assert
# an absence (nothing written, nothing claimed, an excluded source stays
# silent) are folded together with a same-run positive-verdict check so
# they cannot pass merely because nothing runs yet.
#
# Elapsed time between a fixture's crawl_date and the real "now" is always
# computed relative to the moment this suite runs (via `date -v`, this
# machine's BSD date, with a `date -d` fallback) rather than a fixed
# calendar date, so the pass/fail boundary a case depends on doesn't drift
# as real time passes.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATUS_SKILL="$PLUGIN_ROOT/skills/status/SKILL.md"

pass_count=0
fail_count=0

TMPDIR_CASE="$(mktemp -d -t skill-engine-status-decay.XXXXXX)"
cleanup() { rm -rf "$TMPDIR_CASE"; }
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

sha256_of_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# ---------------------------------------------------------------------------
# Date helpers: every offset is computed relative to the real current time
# at the moment this suite runs, never a fixed calendar date, so cases stay
# meaningful no matter when the suite is invoked. BSD `date -v` is tried
# first (this is a macOS/BSD-date machine); `date -d` is the portability
# fallback for a GNU environment.
# ---------------------------------------------------------------------------

today_iso() { date -u +%Y-%m-%d; }

days_ago() {
  local n="$1"
  date -v-"${n}"d -u +%Y-%m-%d 2>/dev/null || date -u -d "-${n} days" +%Y-%m-%d
}

years_ago() {
  local n="$1"
  date -v-"${n}"y -u +%Y-%m-%d 2>/dev/null || date -u -d "-${n} years" +%Y-%m-%d
}

# ---------------------------------------------------------------------------
# Extract every ```bash fence from status/SKILL.md, in document order,
# except the fence inside whichever "## " section's heading mentions
# "probe" (that section reaches the live network on purpose and has no
# business running inside an offline fixture suite).
# ---------------------------------------------------------------------------

extract_bash_except_probe_section() {
  local file="$1"
  awk '
    /^## / { skip = (tolower($0) ~ /probe/) ? 1 : 0; capturing = 0; next }
    /^```bash[[:space:]]*$/ { if (!skip) { capturing = 1 }; next }
    /^```[[:space:]]*$/ { capturing = 0; next }
    capturing { print }
  ' "$file"
}

DECAY_CODE="$(extract_bash_except_probe_section "$STATUS_SKILL")"

# run_decay <case-root> <cache-home> — executes the extracted bash with the
# fixture root as $CTX_ROOT (and current directory) and the fixture cache
# tree as $XDG_CACHE_HOME, the same way status/SKILL.md's existing cache
# block already resolves its own cache root. Sets DECAY_OUT and DECAY_RC.
run_decay() {
  local case_root="$1" cache_home="$2"
  DECAY_OUT="$(cd "$case_root" && CTX_ROOT="$case_root" XDG_CACHE_HOME="$cache_home" \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash -c "$DECAY_CODE" 2>&1)"
  DECAY_RC=$?
}

# ---------------------------------------------------------------------------
# Fixture builders.
# ---------------------------------------------------------------------------

new_case_root() {
  local name="$1"
  local root="$TMPDIR_CASE/$name"
  mkdir -p "$root/research"
  printf '%s' "$root"
}

web_doc_entry() {
  # web_doc_entry <id> <curation-state> <archived: true|false>
  local id="$1" curation_state="$2" archived="$3" url="https://example.invalid/${1}/"
  jq -n --arg id "$id" --arg st "$curation_state" --argjson archived "$archived" --arg url "$url" \
    '{id: $id, kind: "web-doc", url: $url, crawl_mode: "list", page_list: [$url + "index"],
      status: $st, archived: $archived,
      lifecycle: {state: "reachable", last_checked: null, last_checked_sha: null, proposed_url: null},
      discovered_via: null}'
}

git_managed_entry() {
  # git_managed_entry <id> — a confirmed git-managed source, used only to
  # prove a corpus with registered sources but zero web-doc ones among them
  # still renders cleanly.
  local id="$1"
  jq -n --arg id "$id" \
    '{id: $id, kind: "git-managed", url: ("https://example.invalid/" + $id + ".git"),
      status: "confirmed", archived: false,
      lifecycle: {state: "reachable", last_checked: null, last_checked_sha: "deadbeef", proposed_url: null},
      discovered_via: null}'
}

write_sources_file() {
  local out="$1"
  shift
  if [ "$#" -eq 0 ]; then
    printf '{"schema_version":1,"sources":[]}\n' > "$out"
  else
    printf '%s\n' "$@" | jq -s '{schema_version: 1, sources: .}' > "$out"
  fi
}

write_manifest() {
  # write_manifest <cache-home> <id> <crawl_date> <decay> — writes a
  # _crawl-manifest.json carrying crawl_date (the manifest never carries a
  # decay field on disk) plus one real snapshot page named in its pages[]
  # array, whose own frontmatter carries the decay value under test — this
  # is where decay actually lives for a web-doc source, not the manifest.
  local cache_home="$1" id="$2" crawl_date="$3" decay="$4"
  local dir="$cache_home/skill-engine/web-doc/${id}-crawl001"
  mkdir -p "$dir"
  local page_url="https://example.invalid/${id}/page"
  printf -- '---\nsource_url: %s\ncrawl_date: %s\ndecay: %s\n---\n\n# %s snapshot\n\nFixture body content.\n' \
    "$page_url" "$crawl_date" "$decay" "$id" > "$dir/page1.md"
  jq -n --arg id "$id" --arg cd "$crawl_date" --arg url "$page_url" \
    '{source_id: $id, crawl_id: "crawl001", crawl_date: $cd, fetcher: "WebFetch",
      sitemap_source: ($url + "-sitemap.xml"),
      pages: [{url: $url, file: "page1.md",
               content_hash: "0000000000000000000000000000000000000000000000000000000000000000",
               bytes: 42}],
      failures: [], robots_disallows: [], budget_truncated: 0}' \
    > "$dir/_crawl-manifest.json"
}

# ---------------------------------------------------------------------------
# Reading the rendered output: shape-tolerant pattern classes for the three
# outcomes a web-doc snapshot can report, plus helpers to pull just the line
# naming one fixture's id out of a larger capture and classify it.
# ---------------------------------------------------------------------------

PAST_RE='past[- ]?(its[- ])?(decay[- ])?budget|over[- ]?budget|expired|overdue'
WITHIN_RE='within[- ]?(its[- ])?(decay[- ])?budget|not[- ]?(yet[- ])?expired|fresh|[0-9]+[a-z]*[ -]?(day|days|week|weeks|month|months|year|years)[ -]?(remaining|left|to go)'
NONE_RE='non-?expir|no expiry|never expir|does not expire|crawl-once|n/a.{0,20}expiry'

row_line() {
  printf '%s\n' "$1" | grep -m1 -F -- "$2"
}

# state_is <output> <source_id> <past|within|none> — true only when the
# line naming source_id matches exactly the one expected outcome class and
# none of the other two, so a case that (wrongly) claims two states at once
# doesn't count as a pass.
state_is() {
  local output="$1" id="$2" expect="$3" line
  line="$(row_line "$output" "$id")"
  [ -n "$line" ] || return 1
  local is_past=0 is_within=0 is_none=0
  printf '%s' "$line" | grep -qiE "$PAST_RE" && is_past=1
  printf '%s' "$line" | grep -qiE "$WITHIN_RE" && is_within=1
  printf '%s' "$line" | grep -qiE "$NONE_RE" && is_none=1
  case "$expect" in
    past)   [ "$is_past" -eq 1 ] && [ "$is_within" -eq 0 ] && [ "$is_none" -eq 0 ] ;;
    within) [ "$is_within" -eq 1 ] && [ "$is_past" -eq 0 ] && [ "$is_none" -eq 0 ] ;;
    none)   [ "$is_none" -eq 1 ] && [ "$is_past" -eq 0 ] && [ "$is_within" -eq 0 ] ;;
    *) return 1 ;;
  esac
}

assert_state() {
  local output="$1" id="$2" expect="$3" label="$4"
  if state_is "$output" "$id" "$expect"; then
    pass "$label"
  else
    fail "$label" "row for '$id': $(row_line "$output" "$id")"
  fi
}

echo
echo "── expiry: a snapshot past its declared budget reads differently from one within it ──"

case_a="$(new_case_root case-a)"
write_sources_file "$case_a/research/source-paths.json" \
  "$(web_doc_entry "past-budget-src" "confirmed" "false")" \
  "$(web_doc_entry "within-budget-src" "confirmed" "false")"
write_manifest "$case_a/cache-home" "past-budget-src" "$(years_ago 3)" "1y"
write_manifest "$case_a/cache-home" "within-budget-src" "$(today_iso)" "7d"
run_decay "$case_a" "$case_a/cache-home"
decay_out_a="$DECAY_OUT"

assert_state "$decay_out_a" "past-budget-src" "past" \
  "a snapshot crawled years ago against a one-year budget is reported as past its budget"
assert_state "$decay_out_a" "within-budget-src" "within" \
  "a snapshot crawled just now against a one-week budget is reported as within its budget"

if state_is "$decay_out_a" "past-budget-src" "past" && state_is "$decay_out_a" "within-budget-src" "within"; then
  pass "the past-budget and within-budget snapshots read as two distinguishable states, not the same ambiguous output"
else
  fail "the past-budget and within-budget snapshots read as two distinguishable states, not the same ambiguous output" \
    "past row: $(row_line "$decay_out_a" "past-budget-src") | within row: $(row_line "$decay_out_a" "within-budget-src")"
fi

groupA_positive_signal=0
if state_is "$decay_out_a" "past-budget-src" "past" && state_is "$decay_out_a" "within-budget-src" "within"; then
  groupA_positive_signal=1
fi

# The web-doc Cache listing table's data row is documented today as a
# literal 5-cell placeholder — a real run against in-scope sources must
# replace it, not merely coexist with it. Folded with the same-run positive
# signal above so a currently-empty capture (nothing implemented yet, so
# the placeholder trivially never appears either) can't pass this by
# accident.
if printf '%s' "$decay_out_a" | grep -qF '| ... | ... | ... | ... | ... |' ; then
  fail "the placeholder cache-listing row is gone once real in-scope sources are reported" \
    "literal placeholder row still present in output"
elif [ "$groupA_positive_signal" -eq 1 ]; then
  pass "the placeholder cache-listing row is gone once real in-scope sources are reported"
else
  fail "the placeholder cache-listing row is gone once real in-scope sources are reported" \
    "no real verdict was detected for either fixture source in this run"
fi

echo
echo "── in-scope filtering: only a confirmed source with a cached snapshot gets a verdict ──"

case_b="$(new_case_root case-b)"
write_sources_file "$case_b/research/source-paths.json" \
  "$(web_doc_entry "in-scope-confirmed-src" "confirmed" "false")" \
  "$(web_doc_entry "excluded-proposed-src" "proposed" "false")" \
  "$(web_doc_entry "excluded-rejected-src" "rejected" "false")" \
  "$(web_doc_entry "excluded-nocache-src" "confirmed" "false")"
write_manifest "$case_b/cache-home" "in-scope-confirmed-src" "$(years_ago 3)" "30d"
write_manifest "$case_b/cache-home" "excluded-proposed-src" "$(years_ago 3)" "30d"
write_manifest "$case_b/cache-home" "excluded-rejected-src" "$(years_ago 3)" "30d"
# excluded-nocache-src deliberately gets no cache directory at all.
run_decay "$case_b" "$case_b/cache-home"
decay_out_b="$DECAY_OUT"

groupB_inscope_ok=0
state_is "$decay_out_b" "in-scope-confirmed-src" "past" && groupB_inscope_ok=1

fold_exclusion() {
  # Passes only when the excluded id is absent from the output AND the
  # same run correctly reported the in-scope sibling — so a run that
  # excludes everything (including the source that should be included)
  # can't pass this check by accident.
  local id="$1" label="$2"
  local present=0
  printf '%s' "$decay_out_b" | grep -qF -- "$id" && present=1
  if [ "$present" -eq 0 ] && [ "$groupB_inscope_ok" -eq 1 ]; then
    pass "$label"
  else
    fail "$label" "excluded-id-present=$present in-scope-sibling-correct=$groupB_inscope_ok"
  fi
}

fold_exclusion "excluded-proposed-src" \
  "a cached web-doc source that hasn't been confirmed yet produces no past/within/non-expiring claim"
fold_exclusion "excluded-rejected-src" \
  "a cached web-doc source that was rejected produces no past/within/non-expiring claim"
fold_exclusion "excluded-nocache-src" \
  "a confirmed web-doc source with no cached snapshot on disk produces no past/within/non-expiring claim"

echo
echo "── decay: \"none\" reads as non-expiring, never as a past- or within-budget claim ──"

case_c="$(new_case_root case-c)"
write_sources_file "$case_c/research/source-paths.json" \
  "$(web_doc_entry "none-decay-src" "confirmed" "false")"
# Old enough that misreading "none" as a numeric budget would clearly show
# up as an expired verdict instead of a non-expiring one.
write_manifest "$case_c/cache-home" "none-decay-src" "$(years_ago 3)" "none"
run_decay "$case_c" "$case_c/cache-home"
decay_out_c="$DECAY_OUT"

assert_state "$decay_out_c" "none-decay-src" "none" \
  "a source whose decay is \"none\" is reported as non-expiring rather than past- or within-budget"

echo
echo "── decay unit suffixes (d/w/m/y) change the expiry threshold, not just the display ──"

case_d="$(new_case_root case-d)"
write_sources_file "$case_d/research/source-paths.json" \
  "$(web_doc_entry "unit-d-vs-w-day-src" "confirmed" "false")" \
  "$(web_doc_entry "unit-d-vs-w-week-src" "confirmed" "false")" \
  "$(web_doc_entry "unit-w-vs-m-week-src" "confirmed" "false")" \
  "$(web_doc_entry "unit-w-vs-m-month-src" "confirmed" "false")" \
  "$(web_doc_entry "unit-m-vs-y-month-src" "confirmed" "false")" \
  "$(web_doc_entry "unit-m-vs-y-year-src" "confirmed" "false")"
d3="$(days_ago 3)"
d10="$(days_ago 10)"
d45="$(days_ago 45)"
write_manifest "$case_d/cache-home" "unit-d-vs-w-day-src" "$d3" "1d"
write_manifest "$case_d/cache-home" "unit-d-vs-w-week-src" "$d3" "1w"
write_manifest "$case_d/cache-home" "unit-w-vs-m-week-src" "$d10" "1w"
write_manifest "$case_d/cache-home" "unit-w-vs-m-month-src" "$d10" "1m"
write_manifest "$case_d/cache-home" "unit-m-vs-y-month-src" "$d45" "1m"
write_manifest "$case_d/cache-home" "unit-m-vs-y-year-src" "$d45" "1y"
run_decay "$case_d" "$case_d/cache-home"
decay_out_d="$DECAY_OUT"

assert_state "$decay_out_d" "unit-d-vs-w-day-src" "past" \
  "3 days after crawl, a 1-day decay budget is already past"
assert_state "$decay_out_d" "unit-d-vs-w-week-src" "within" \
  "3 days after crawl, a 1-week decay budget is not yet past (the unit suffix, not just the number, changed the threshold)"
assert_state "$decay_out_d" "unit-w-vs-m-week-src" "past" \
  "10 days after crawl, a 1-week decay budget is already past"
assert_state "$decay_out_d" "unit-w-vs-m-month-src" "within" \
  "10 days after crawl, a 1-month decay budget is not yet past"
assert_state "$decay_out_d" "unit-m-vs-y-month-src" "past" \
  "45 days after crawl, a 1-month decay budget is already past"
assert_state "$decay_out_d" "unit-m-vs-y-year-src" "within" \
  "45 days after crawl, a 1-year decay budget is not yet past"

echo
echo "── zero in-scope web-doc sources: no crash, no fabricated claim ──"

case_e1="$(new_case_root case-e1)"
write_sources_file "$case_e1/research/source-paths.json"
run_decay "$case_e1" "$case_e1/cache-home"
decay_out_e1="$DECAY_OUT"
rc_e1="$DECAY_RC"

case_e2="$(new_case_root case-e2)"
write_sources_file "$case_e2/research/source-paths.json" \
  "$(git_managed_entry "only-git-managed-src")"
run_decay "$case_e2" "$case_e2/cache-home"
decay_out_e2="$DECAY_OUT"
rc_e2="$DECAY_RC"

assert_zero_scope_clean() {
  # Folded with the case-A positive signal so this can't pass merely
  # because nothing is implemented yet and therefore nothing runs.
  local output="$1" rc="$2" label="$3"
  local no_claims=1
  printf '%s' "$output" | grep -qiE "$PAST_RE|$WITHIN_RE|$NONE_RE" && no_claims=0
  if [ "$rc" -eq 0 ] && [ "$no_claims" -eq 1 ] && [ "$groupA_positive_signal" -eq 1 ]; then
    pass "$label"
  else
    fail "$label" "rc=$rc no_claims=$no_claims same-run-positive-verdicts-elsewhere-confirmed=$groupA_positive_signal"
  fi
}

assert_zero_scope_clean "$decay_out_e1" "$rc_e1" \
  "an empty source corpus produces no error and no past/within/non-expiring claim for anything"
assert_zero_scope_clean "$decay_out_e2" "$rc_e2" \
  "a corpus with sources registered but none of kind web-doc produces no error and no past/within/non-expiring claim for anything"

echo
echo "── read-only: no writes, and nothing in the code path reaches the network ──"

state_file="$case_a/research/.research-state.json"
printf '{"placeholder": true}\n' > "$state_file"
sp_before="$(sha256_of_file "$case_a/research/source-paths.json")"
manifest_before="$(sha256_of_file "$case_a/cache-home/skill-engine/web-doc/past-budget-src-crawl001/_crawl-manifest.json")"
state_before="$(sha256_of_file "$state_file")"

run_decay "$case_a" "$case_a/cache-home"
decay_out_a2="$DECAY_OUT"

sp_after="$(sha256_of_file "$case_a/research/source-paths.json")"
manifest_after="$(sha256_of_file "$case_a/cache-home/skill-engine/web-doc/past-budget-src-crawl001/_crawl-manifest.json")"
state_after="$(sha256_of_file "$state_file")"

writes_clean=0
[ "$sp_before" = "$sp_after" ] && [ "$manifest_before" = "$manifest_after" ] && [ "$state_before" = "$state_after" ] && writes_clean=1

no_network_cmds=1
printf '%s' "$DECAY_CODE" | grep -qiE 'curl |wget |git ls-remote|git clone|git[[:space:]]+fetch|WebFetch' && no_network_cmds=0

groupA2_positive=0
state_is "$decay_out_a2" "past-budget-src" "past" && state_is "$decay_out_a2" "within-budget-src" "within" && groupA2_positive=1

if [ "$writes_clean" -eq 1 ] && [ "$no_network_cmds" -eq 1 ] && [ "$groupA2_positive" -eq 1 ]; then
  pass "computing decay state touches no outbound network call and writes nothing to source-paths.json, the crawl manifest, or .research-state.json"
else
  fail "computing decay state touches no outbound network call and writes nothing to source-paths.json, the crawl manifest, or .research-state.json" \
    "writes_clean=$writes_clean no_network_cmds=$no_network_cmds positive_signal=$groupA2_positive"
fi

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
