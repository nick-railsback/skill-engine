#!/usr/bin/env bash
# Black-box test oracle for the stamped verify.sh's batch/per-item forking
# cost and a handful of related correctness gaps in Checks 4, 5, 5.5, 6, 7,
# 8. Seven named invariants:
#
#   - check5-timing: Check 5 (reference-frontmatter)'s own wall-clock
#     contribution at N=2,000 references is under 2s.
#   - check5.5-root-hoist: Check 5.5 (external-doc-frontmatter)
#     canonicalizes its walk root once per root, not once per provenance
#     file under that root.
#   - check6-7-timing: Checks 6+7 (monorepo-coverage, companions-coverage)
#     combined are under 2s at 150 workspace members / 150 companions
#     over 2,000 references.
#   - git-managed-path-fallback: a git-managed source carrying a non-null
#     `path` is resolved from that path by Checks 6 and 8 when no
#     clone-cache tree exists.
#   - local-path-git-exclusion: a local-path source's own `.git/` no
#     longer inflates Check 8's file count past the density floor.
#   - check4-idiom-consolidation: Check 4's four-line sorted-array-read
#     idiom collapses to one implementation; accept/reject decisions are
#     unchanged.
#   - check8-workspace-roots-reuse: Check 8 reuses Check 6's
#     workspace_roots projection instead of its own per-source jq query;
#     the default nine-item root list is spelled once, not twice.
#
# Every assertion is against verify.sh's OBSERVABLE contract: its PASS/
# WARN/FAIL/[N/A] output lines, wall-clock bounds, and (for the two
# invariants that are explicitly about subprocess counts rather than
# input/output shape -- check5.5-root-hoist's cd+pwd -P calls,
# check8-workspace-roots-reuse's per-source jq call) actual subprocess
# invocation counts captured by instrumenting the real builtins/binary,
# never a proxy. Nothing here asserts which lines of verify.sh's source
# implement a check -- a full rewrite of any check's internals leaves this
# oracle meaningful, with two narrow, source-anchored exceptions:
# check4-idiom-consolidation's "13 occurrences" and
# check8-workspace-roots-reuse's "spelled twice" claims are themselves
# about verify.sh's *source text*, so grepping that text (whitespace-
# normalized against comment line-wrapping) is testing the shipped
# artifact's own stated property, not an implementation-shape assumption.
#
# Expected RED right now, and why:
#   - check5-timing: Check 5 forks one `awk` per reference file; at
#     N=2,000 that's ~7s, not under 2s.
#   - check5.5-root-hoist: Check 5.5 recomputes root_canon via a
#     `cd`+`pwd -P` subshell once per provenance file, not once per root.
#   - check6-7-timing: Checks 6 and 7 each fork one `grep -r` per member/
#     companion, scanning the full references/ corpus every time; at
#     150+150 items over 2,000 references that's several seconds, not
#     under 2s.
#   - git-managed-path-fallback: a git-managed source's `path` field is
#     never read by Check 6 or Check 8 -- only the clone-cache lookup is
#     tried, so a path-only source with no cache tree yet reports [N/A].
#   - local-path-git-exclusion: Check 8's file count excludes `.git/` only
#     on the git-managed branch; a local-path source's own `.git/`
#     inflates the count and can spuriously clear the density floor.
#   - check4-idiom-consolidation: the four-line array-read idiom appears
#     13 times, not collapsed to one implementation.
#   - check8-workspace-roots-reuse: Check 8 issues its own per-source
#     `jq --arg id` workspace_roots query (present, not zero), and the
#     default nine-item root list is spelled twice (Check 6's header
#     comment and its `roots=(...)` literal), not once.
#
# Expected GREEN right now (preservation baselines, captured against
# today's actual verify.sh so a regression during the refactor is
# caught, not just the seven items above landing as designed): every
# "unchanged"/"preservation"/"discrimination" assertion under each named
# invariant above -- Check 5's no-frontmatter/frontmatter/BOM/thematic-
# break fixtures; Check 5.5's valid/missing/malformed-field fixtures;
# Check 6 and 7's cited-vs-uncited and prefix-overlap discrimination
# fixtures; Check 4's phantom/orphan/duplicate-form/mismatch/malformed-
# target/sorted-order fixtures; Check 6/8's workspace_roots-override and
# files_of_interest-scoping fixtures. These hold today by construction
# (nothing under test has moved yet) and must keep holding after the fix.
#
# Out of scope: this file does not test Check 4's own asymptotic
# complexity at scale (that already has its own frozen timing oracle at
# tests/verify-bijection-linear/run.sh) or cited_paths.py's candidate-set
# performance (a separate script, untouched by anything asserted here).
# It also does not re-litigate the full behavioral surface of Check 4,
# Check 6, or Check 8 -- tests/verify-bijection/run.sh,
# tests/verify-bijection-linear/run.sh, and tests/verify-heuristics/run.sh
# already carry a much larger fixture set for those checks; this file
# adds a smaller, independently-run sample so a regression during the
# refactor this file exists to gate is caught here too, not only assumed
# to be caught elsewhere -- an assumption that has been wrong before on
# this repo.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_ROOT="$(cd "$TESTS_ROOT/.." && pwd)"
VERIFY_SH="$PLUGIN_ROOT/engine-bootstrap-templates/verify.sh"
SCHEMA="$PLUGIN_ROOT/engine-bootstrap-templates/source-paths.schema.json"

pass_count=0
fail_count=0

WORK="$(mktemp -d -t skill-engine-verify-batch-forks.XXXXXX)"
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

info() {
  printf '  --    %s\n' "$1"
}

section() {
  printf '\n══ %s ══\n' "$1"
}

# Collapse runs of whitespace (newlines included) to one space, so a
# phrase assertion against a hard-wrapped source-text region does not
# depend on where the phrase happened to break across lines.
normalize() {
  printf '%s' "$1" | tr -s '[:space:]' ' '
}

# check_section <combined-output> <needle> -- the lines of one
# `=== ... ===` run_check block whose header contains <needle>, up to
# (excluding) the next `=== ` header. Isolates one check's own output so
# a phrase legitimately appearing in a NEIGHBORING check can never be
# mistaken for this one's.
check_section() {
  CHECK_NEEDLE="$2" awk '
    $0 ~ ENVIRON["CHECK_NEEDLE"] && !found { found=1; print; next }
    found && /^=== / { exit }
    found { print }
  ' <<<"$1"
}

# ---------------------------------------------------------------------------
# Shared fixture builders
# ---------------------------------------------------------------------------

build_nav() {
  local root="$1"
  mkdir -p "$root"
  {
    printf -- '---\n'
    printf 'name: acme-context\n'
    printf 'description: Use when answering questions about the acme corpus.\n'
    printf -- '---\n\n# Acme\n'
  } > "$root/SKILL.md"
}

git_managed_source() {
  local id="$1" url="$2" extra="${3:-null}"
  jq -n --arg id "$id" --arg url "$url" --argjson extra "$extra" '
    {
      id: $id, kind: "git-managed", url: $url, path: null,
      status: "confirmed", archived: false,
      lifecycle: {state: "reachable", last_checked: "2026-09-06", last_checked_sha: "abc1234", proposed_url: null},
      discovered_via: null
    } + (if $extra == null then {} else $extra end)
  '
}

# git-managed source that ALSO carries a non-null local path -- schema-
# tolerated (the git-managed conditional in source-paths.schema.json
# requires only url, never constrains path) but never shipped in this
# repo's own registries. Used below by the git-managed-path-fallback
# fixtures.
git_managed_with_path_source() {
  local id="$1" url="$2" fs_path="$3"
  jq -n --arg id "$id" --arg url "$url" --arg p "$fs_path" '
    {
      id: $id, kind: "git-managed", url: $url, path: $p,
      status: "confirmed", archived: false,
      lifecycle: {state: "reachable", last_checked: "2026-09-06", last_checked_sha: "abc1234", proposed_url: null},
      discovered_via: null
    }
  '
}

local_path_source() {
  local id="$1" fs_path="$2"
  jq -n --arg id "$id" --arg fs_path "$fs_path" '
    {
      id: $id, kind: "local-path", url: null, path: $fs_path,
      status: "confirmed", archived: false,
      lifecycle: {state: "reachable"}, discovered_via: null
    }
  '
}

external_doc_source() {
  local id="$1" rel_path="$2"
  jq -n --arg id "$id" --arg p "$rel_path" '
    {
      id: $id, kind: "external-doc", url: null, path: $p,
      status: "confirmed", archived: false,
      lifecycle: {state: "reachable"}, discovered_via: null
    }
  '
}

# A DISCOVER-proposed companion: status proposed, discovered_via non-null.
# kind local-path with a path that does not exist on disk -- Check 7 does
# not care about kind, and a nonexistent local-path avoids Check 8 wasting
# a resolve_git_managed_tree() fork per companion (kind git-managed would
# make Check 8 try, and fail, to resolve each one from the clone cache).
companion_source() {
  local id="$1"
  jq -n --arg id "$id" --arg p "/nonexistent/$id" '
    {
      id: $id, kind: "local-path", url: null, path: $p,
      status: "proposed", archived: false,
      lifecycle: {state: "reachable"},
      discovered_via: [{parent_source_id: "parent-src", depth: 1, discover_run: "run-1", signal: "test-signal"}]
    }
  '
}

write_sources() {
  local root="$1" sources_array="$2"
  mkdir -p "$root/research"
  jq -n --argjson sources "$sources_array" '{schema_version: 1, sources: $sources}' > "$root/research/source-paths.json"
}

run_verify() {
  local root="$1" cache="$2"
  CTX_ROOT="$root" SKILL_ENGINE_CACHE_ROOT="$cache" bash "$VERIFY_SH" 2>&1
}

real_file_count() {
  find "$1" -path "$1/.git" -prune -o -type f -print | wc -l | tr -d ' '
}

naive_file_count() {
  find "$1" -maxdepth 6 -type f | wc -l | tr -d ' '
}

# build_stubbed_verify <src> <dst> <start-label> [end-label]
#
# Writes a copy of <src> with the block from the run_check call whose
# literal argument is <start-label> up to (not including) the run_check
# call whose literal argument is <end-label> -- or, when omitted, the
# very next run_check call -- replaced by a single immediate skip.
# Substring match (not regex), the technique tests/verify-bijection-
# linear/run.sh already established for Check 4's own timing oracle,
# generalized with an explicit end label so an adjacent PAIR of checks
# (check6-7-timing's Check 6 + Check 7 pair) can be isolated together in
# one stub.
build_stubbed_verify() {
  local src="$1" dst="$2" start="$3" end="${4:-}"
  awk -v start="$start" -v end="$end" '
    BEGIN {
      start_marker = "run_check \"" start "\""
      end_marker = (end == "") ? "" : "run_check \"" end "\""
    }
    index($0, start_marker) == 1 {
      print
      print "skip \"" start " stubbed out for timing isolation\""
      skipping = 1
      next
    }
    skipping && end_marker != "" && index($0, end_marker) == 1 { skipping = 0 }
    skipping && end_marker == "" && index($0, "run_check \"") == 1 { skipping = 0 }
    skipping { next }
    { print }
  ' "$src" > "$dst"
}

# build_large_ref_tree <ctx> <n> -- N one-paragraph file-form references
# with N matching catalog rows (so Check 4 stays clean and its own,
# already-linear cost is identical between a full run and any stub of a
# LATER check, canceling out of the diff).
build_large_ref_tree() {
  local ctx="$1" n="$2" i slug
  mkdir -p "$ctx/references"
  {
    printf -- '---\n'
    printf 'name: perf-fixture-context\n'
    printf 'description: Synthetic large corpus for batch-forks timing isolation.\n'
    printf -- '---\n\n# Perf fixture navigator\n\n## Catalog\n\n'
    printf '| Reference | Description |\n|---|---|\n'
    for ((i = 1; i <= n; i++)); do
      printf -v slug 'ref%05d' "$i"
      printf '| [%s](references/%s.md) | Synthetic reference %s. |\n' "$slug" "$slug" "$slug"
    done
  } > "$ctx/SKILL.md"
  for ((i = 1; i <= n; i++)); do
    printf -v slug 'ref%05d' "$i"
    printf '# %s\n\nSynthetic one-paragraph reference body for %s.\n' "$slug" "$slug" > "$ctx/references/$slug.md"
  done
}

# ===========================================================================
# check5-timing -- Check 5 (reference-frontmatter): under 2s at N=2,000
# ===========================================================================
section "check5-timing -- Check 5's own wall-clock contribution at N=2,000"

c1_ctx="$WORK/c1-perf"
build_large_ref_tree "$c1_ctx" 2000
write_sources "$c1_ctx" "[]"

c1_stub="$WORK/c1-stub-verify.sh"
build_stubbed_verify "$VERIFY_SH" "$c1_stub" "Reference frontmatter (reference-frontmatter)"
chmod +x "$c1_stub"

t0=$(date +%s)
c1_full_out="$(run_verify "$c1_ctx" "$WORK/c1-empty-cache")"
c1_full_rc=$?
t1=$(date +%s)
t_full=$((t1 - t0))

t2=$(date +%s)
c1_stub_out="$(CTX_ROOT="$c1_ctx" SKILL_ENGINE_CACHE_ROOT="$WORK/c1-empty-cache" bash "$c1_stub" 2>&1)"
t3=$(date +%s)
t_stub=$((t3 - t2))

c1_diff=$((t_full - t_stub))
info "N=2000: full=${t_full}s stubbed=${t_stub}s Check-5-contribution=${c1_diff}s"

if printf '%s' "$c1_stub_out" | grep -qF 'Reference frontmatter (reference-frontmatter) stubbed out for timing isolation'; then
  pass "check5-timing: stubbed copy runs to completion and skips Check 5 as intended"
else
  fail "check5-timing: stubbed copy runs to completion and skips Check 5 as intended" "$c1_stub_out"
fi

if [ "$c1_full_rc" -eq 0 ] && printf '%s' "$c1_full_out" | grep -qF 'Failed: 0'; then
  pass "check5-timing: 2,000-reference contextualizer passes all checks"
else
  fail "check5-timing: 2,000-reference contextualizer passes all checks" "$c1_full_out"
fi

section "check5-awk-failure -- a batched awk that cannot run must not report a clean corpus"

# The batch passes every reference file as an argv entry, and the code's own
# comment names the condition under which that stops working: a corpus large
# enough to approach ARG_MAX. With stderr discarded and the exit status
# never read, that failure produced an empty result set, left fm_ok at 1,
# and printed "N references start with a Markdown body" -- asserting a
# property nothing had evaluated. The pre-batch per-file loop degraded one
# file at a time and could not produce a whole-corpus false green (PR #15
# review, finding 12).
#
# ARG_MAX itself is not reproducible in a test at any sane fixture size, so
# the failure is injected where its effect is identical: a stubbed `awk`
# earlier on PATH that refuses this one invocation. It is selected by the
# arguments Check 5 uses -- reference .md paths as positional args -- not by
# the awk program's internals, and everything else is handed to the real awk
# untouched, so the rest of the run is unaffected.

c5f_ctx="$WORK/c5-awk-failure"
build_nav "$c5f_ctx"
mkdir -p "$c5f_ctx/references"
printf '# ref\n\nBody text, no frontmatter.\n' > "$c5f_ctx/references/ref.md"
write_sources "$c5f_ctx" "[]"

c5f_stubdir="$WORK/c5-awk-stub"
mkdir -p "$c5f_stubdir"
c5f_real_awk="$(command -v awk)"
cat > "$c5f_stubdir/awk" <<STUB
#!/usr/bin/env bash
case "\$*" in
  */references/*.md*)
    echo "awk: stubbed exec failure (stands in for ARG_MAX)" >&2
    exit 2
    ;;
esac
exec "$c5f_real_awk" "\$@"
STUB
chmod +x "$c5f_stubdir/awk"

c5f_out="$(PATH="$c5f_stubdir:$PATH" CTX_ROOT="$c5f_ctx" \
  SKILL_ENGINE_CACHE_ROOT="$WORK/c5f-empty-cache" bash "$VERIFY_SH" 2>&1)"
c5f_c5="$(check_section "$c5f_out" 'Reference frontmatter')"

if printf '%s' "$c5f_c5" | grep -qE '\[PASS\].*start(s)? with a Markdown body'; then
  fail "check5-awk-failure: a failed batch must not report the corpus clean" \
    "the check reported every reference as frontmatter-free without having evaluated any of them" \
    "${c5f_c5:-<empty>}"
else
  pass "check5-awk-failure: a failed batch does not report the corpus clean"
fi

if printf '%s' "$c5f_c5" | grep -qE '\[FAIL\].*(awk|could not)'; then
  pass "check5-awk-failure: the run says the frontmatter check could not be evaluated"
else
  fail "check5-awk-failure: the run says the frontmatter check could not be evaluated" \
    "a check that did not run has to say so; silence here is indistinguishable from a clean corpus" \
    "${c5f_c5:-<empty>}"
fi

# No assertion on verify.sh's own exit status here: this minimal fixture
# already exits non-zero for unrelated checks, so "exits non-zero" would
# pass whether or not Check 5 noticed anything. The two assertions above are
# the ones that discriminate.

# Calibration: the same fixture with no stub on PATH must pass Check 5
# cleanly, so the three assertions above are reacting to the injected
# failure and not to something wrong with the fixture itself.
c5f_ctrl_out="$(CTX_ROOT="$c5f_ctx" SKILL_ENGINE_CACHE_ROOT="$WORK/c5f-ctrl-cache" bash "$VERIFY_SH" 2>&1)"
c5f_ctrl_c5="$(check_section "$c5f_ctrl_out" 'Reference frontmatter')"
if printf '%s' "$c5f_ctrl_c5" | grep -qE '\[PASS\].*start(s)? with a Markdown body'; then
  pass "check5-awk-failure calibration: the same fixture passes Check 5 with the real awk"
else
  fail "check5-awk-failure calibration: the same fixture passes Check 5 with the real awk" \
    "${c5f_ctrl_c5:-<empty>}"
fi

if [ "$c1_diff" -lt 2 ]; then
  pass "check5-timing: Check 5's own wall-clock contribution at N=2,000 is under 2s (got ${c1_diff}s)"
else
  fail "check5-timing: Check 5's own wall-clock contribution at N=2,000 is under 2s (got ${c1_diff}s)" \
    "full=${t_full}s stubbed=${t_stub}s"
fi

# ---- Check 5 preservation: today's exact PASS/FAIL text, unchanged ----

c1p_ctx="$WORK/c1-pass"
build_nav "$c1p_ctx"
mkdir -p "$c1p_ctx/references" "$c1p_ctx/research"
write_sources "$c1p_ctx" "[]"
printf '# a\n\nBody a.\n' > "$c1p_ctx/references/a.md"
printf '# b\n\nBody b.\n' > "$c1p_ctx/references/b.md"
printf '# c\n\nBody c.\n' > "$c1p_ctx/references/c.md"
c1p_out="$(run_verify "$c1p_ctx" "$WORK/c1p-cache")"
c1p_c5="$(check_section "$c1p_out" 'Reference frontmatter')"
if printf '%s' "$c1p_c5" | grep -qF '[PASS] 3 references start with a Markdown body (no YAML frontmatter)'; then
  pass "check5-preservation: 3 clean references print today's exact PASS text"
else
  fail "check5-preservation: 3 clean references print today's exact PASS text" "${c1p_c5:-<empty>}"
fi

c1f_ctx="$WORK/c1-fail"
build_nav "$c1f_ctx"
mkdir -p "$c1f_ctx/references" "$c1f_ctx/research"
write_sources "$c1f_ctx" "[]"
{ printf -- '---\n'; printf 'name: x\n'; printf -- '---\n\nBody.\n'; } > "$c1f_ctx/references/badref.md"
c1f_out="$(run_verify "$c1f_ctx" "$WORK/c1f-cache")"
c1f_c5="$(check_section "$c1f_out" 'Reference frontmatter')"
if printf '%s' "$c1f_c5" | grep -qF 'references/badref.md starts with YAML frontmatter — references carry no frontmatter (02-artifact-contract.md § No YAML frontmatter on references)'; then
  pass "check5-preservation: a frontmatter-opening reference prints today's exact FAIL text"
else
  fail "check5-preservation: a frontmatter-opening reference prints today's exact FAIL text" "${c1f_c5:-<empty>}"
fi

c1b_ctx="$WORK/c1-bom"
build_nav "$c1b_ctx"
mkdir -p "$c1b_ctx/references" "$c1b_ctx/research"
write_sources "$c1b_ctx" "[]"
printf '\xef\xbb\xbf# BOM heading\n\nBody.\n' > "$c1b_ctx/references/bomref.md"
c1b_out="$(run_verify "$c1b_ctx" "$WORK/c1b-cache")"
c1b_c5="$(check_section "$c1b_out" 'Reference frontmatter')"
if printf '%s' "$c1b_c5" | grep -qF '[PASS]' && ! printf '%s' "$c1b_c5" | grep -qF 'bomref.md starts with YAML frontmatter'; then
  pass "check5-preservation: a BOM-prefixed, non-frontmatter reference still PASSes"
else
  fail "check5-preservation: a BOM-prefixed, non-frontmatter reference still PASSes" "${c1b_c5:-<empty>}"
fi

c1t_ctx="$WORK/c1-thematic"
build_nav "$c1t_ctx"
mkdir -p "$c1t_ctx/references" "$c1t_ctx/research"
write_sources "$c1t_ctx" "[]"
printf -- '----\n\nBody.\n' > "$c1t_ctx/references/thematic.md"
c1t_out="$(run_verify "$c1t_ctx" "$WORK/c1t-cache")"
c1t_c5="$(check_section "$c1t_out" 'Reference frontmatter')"
if printf '%s' "$c1t_c5" | grep -qF '[PASS]' && ! printf '%s' "$c1t_c5" | grep -qF 'thematic.md starts with YAML frontmatter'; then
  pass "check5-preservation: a four-dash thematic break is not mistaken for a frontmatter opener"
else
  fail "check5-preservation: a four-dash thematic break is not mistaken for a frontmatter opener" "${c1t_c5:-<empty>}"
fi

# ===========================================================================
# check5.5-root-hoist -- Check 5.5 (external-doc-frontmatter): root_canon hoisted
# ===========================================================================
section "check5.5-root-hoist -- Check 5.5 canonicalizes its walk root once per root, not once per file"

C2_N=30
c2_ctx="$WORK/c2-root-hoist"
build_nav "$c2_ctx"
docs_abs="$c2_ctx/docs"
pages_abs="$c2_ctx/docs/pages"
mkdir -p "$pages_abs"
for ((i = 1; i <= C2_N; i++)); do
  {
    printf -- '---\n'
    printf 'source_url: https://example.com/policy/%d\n' "$i"
    printf 'crawl_date: 2026-01-01\n'
    printf 'decay: 30d\n'
    printf -- '---\n\n# Doc %d\n\nBody.\n' "$i"
  } > "$pages_abs/doc$(printf '%04d' "$i").md"
done
write_sources "$c2_ctx" "[$(external_doc_source policy-docs docs)]"

c2_log="$WORK/c2-cdpwd.log"
: > "$c2_log"
c2_out="$(
  (
    LOGFILE="$c2_log"
    export LOGFILE
    cd() { printf 'CD\t%s\n' "$*" >> "$LOGFILE"; builtin cd "$@" || return; }
    # shellcheck disable=SC2120 # called with args (pwd -P) by the exported
    # child process (verify.sh), never by this file itself
    pwd() { printf 'PWD\t%s\n' "$*" >> "$LOGFILE"; builtin pwd "$@"; }
    export -f cd
    export -f pwd
    CTX_ROOT="$c2_ctx" SKILL_ENGINE_CACHE_ROOT="$WORK/c2-empty-cache" bash "$VERIFY_SH"
  ) 2>&1
)"

root_cd_count=$(grep -cxF "$(printf 'CD\t%s' "$docs_abs")" "$c2_log" || true)
canon_cd_count=$(grep -cxF "$(printf 'CD\t%s' "$pages_abs")" "$c2_log" || true)
info "N=$C2_N provenance files sharing one root: cd-to-root count=$root_cd_count, cd-to-file-dirname count=$canon_cd_count (informational only, not itself asserted)"

if [ "$root_cd_count" -le 1 ]; then
  pass "check5.5-root-hoist: root_canon's cd+pwd -P runs at most once for the shared root (got ${root_cd_count}, N=${C2_N})"
else
  fail "check5.5-root-hoist: root_canon's cd+pwd -P runs at most once for the shared root (got ${root_cd_count}, N=${C2_N})" \
    "expected <= 1 invocation of cd '$docs_abs'; got $root_cd_count (one per provenance file, today's per-file recomputation)"
fi

c2_c55="$(check_section "$c2_out" 'provenance frontmatter')"
if printf '%s' "$c2_c55" | grep -qF "[PASS] $C2_N provenance file(s) with valid frontmatter"; then
  pass "check5.5-root-hoist: the hoisting fixture's $C2_N valid provenance files still PASS after the fix path"
else
  fail "check5.5-root-hoist: the hoisting fixture's $C2_N valid provenance files still PASS after the fix path" "${c2_c55:-<empty>}"
fi

# ---- Check 5.5 preservation: today's exact PASS/FAIL text per field ----

build_missing_fm_fixture() {
  local ctx="$1"
  build_nav "$ctx"
  mkdir -p "$ctx/docs"
  printf '# no frontmatter here\n' > "$ctx/docs/broken.md"
  write_sources "$ctx" "[$(external_doc_source broken-docs docs)]"
}
c2m_ctx="$WORK/c2-missing-fm"
build_missing_fm_fixture "$c2m_ctx"
c2m_out="$(run_verify "$c2m_ctx" "$WORK/c2m-cache")"
c2m_c55="$(check_section "$c2m_out" 'provenance frontmatter')"
if printf '%s' "$c2m_c55" | grep -qF 'docs/broken.md missing or malformed frontmatter'; then
  pass "check5.5-preservation: missing frontmatter prints today's exact FAIL text"
else
  fail "check5.5-preservation: missing frontmatter prints today's exact FAIL text" "${c2m_c55:-<empty>}"
fi

build_bad_field_fixture() {
  # $1=ctx $2=source_url $3=crawl_date $4=decay
  local ctx="$1" url="$2" date="$3" decay="$4"
  build_nav "$ctx"
  mkdir -p "$ctx/docs"
  {
    printf -- '---\n'
    printf 'source_url: %s\n' "$url"
    printf 'crawl_date: %s\n' "$date"
    printf 'decay: %s\n' "$decay"
    printf -- '---\n\nBody.\n'
  } > "$ctx/docs/field.md"
  write_sources "$ctx" "[$(external_doc_source field-docs docs)]"
}

c2u_ctx="$WORK/c2-bad-url"
build_bad_field_fixture "$c2u_ctx" "not-a-url" "2026-01-01" "30d"
c2u_out="$(run_verify "$c2u_ctx" "$WORK/c2u-cache")"
c2u_c55="$(check_section "$c2u_out" 'provenance frontmatter')"
if printf '%s' "$c2u_c55" | grep -qF 'docs/field.md frontmatter source_url missing or fails regex ^https?://[^[:space:]]+$'; then
  pass "check5.5-preservation: a malformed source_url prints today's exact FAIL text"
else
  fail "check5.5-preservation: a malformed source_url prints today's exact FAIL text" "${c2u_c55:-<empty>}"
fi

c2d_ctx="$WORK/c2-bad-date"
build_bad_field_fixture "$c2d_ctx" "https://example.com/x" "not-a-date" "30d"
c2d_out="$(run_verify "$c2d_ctx" "$WORK/c2d-cache")"
c2d_c55="$(check_section "$c2d_out" 'provenance frontmatter')"
if printf '%s' "$c2d_c55" | grep -qF 'docs/field.md frontmatter crawl_date missing or not ISO-8601 UTC'; then
  pass "check5.5-preservation: a malformed crawl_date prints today's exact FAIL text"
else
  fail "check5.5-preservation: a malformed crawl_date prints today's exact FAIL text" "${c2d_c55:-<empty>}"
fi

c2y_ctx="$WORK/c2-bad-decay"
build_bad_field_fixture "$c2y_ctx" "https://example.com/x" "2026-01-01" "forever"
c2y_out="$(run_verify "$c2y_ctx" "$WORK/c2y-cache")"
c2y_c55="$(check_section "$c2y_out" 'provenance frontmatter')"
if printf '%s' "$c2y_c55" | grep -qF 'docs/field.md frontmatter decay missing or not in {none, Nd, Nw, Nm, Ny}'; then
  pass "check5.5-preservation: a malformed decay prints today's exact FAIL text"
else
  fail "check5.5-preservation: a malformed decay prints today's exact FAIL text" "${c2y_c55:-<empty>}"
fi

# ===========================================================================
# check6-7-timing -- Checks 6+7 combined: under 2s at 150 members / 150
# companions over 2,000 references
# ===========================================================================
section "check6-7-timing -- Checks 6+7 combined wall-clock contribution at 150 members / 150 companions over 2,000 references"

MEMBER_COUNT=150
COMPANION_COUNT=150
# 150 companions is this oracle's own choice, not an independently
# documented count; chosen to genuinely stress Check 7's per-companion
# grep -r loop at the same order of magnitude as Check 6's 150 members,
# so "combined" measures real, not vacuous, cost from both checks.

c3_ctx="$WORK/c3-perf"
build_large_ref_tree "$c3_ctx" 2000

c3_cache="$WORK/c3-cache"
c3_tree="$c3_cache/git-managed/parent-src-abc12345"
mkdir -p "$c3_tree/packages"
for ((i = 1; i <= MEMBER_COUNT; i++)); do
  member_dir="$c3_tree/packages/member$(printf '%05d' "$i")"
  mkdir -p "$member_dir"
  printf 'x\n' > "$member_dir/x.txt"
done

c3_sources="[$(git_managed_source parent-src https://example.com/acme/parent-src)"
for ((i = 1; i <= COMPANION_COUNT; i++)); do
  comp_id=$(printf 'companion%05d' "$i")
  c3_sources="$c3_sources,$(companion_source "$comp_id")"
done
c3_sources="$c3_sources]"
write_sources "$c3_ctx" "$c3_sources"

c3_stub="$WORK/c3-stub-verify.sh"
build_stubbed_verify "$VERIFY_SH" "$c3_stub" \
  "Monorepo-coverage heuristic (monorepo-coverage)" \
  "Catalog-density floor (catalog-density)"
chmod +x "$c3_stub"

t0=$(date +%s)
c3_full_out="$(run_verify "$c3_ctx" "$c3_cache")"
c3_full_rc=$?
t1=$(date +%s)
t_full3=$((t1 - t0))

t2=$(date +%s)
c3_stub_out="$(CTX_ROOT="$c3_ctx" SKILL_ENGINE_CACHE_ROOT="$c3_cache" bash "$c3_stub" 2>&1)"
t3=$(date +%s)
t_stub3=$((t3 - t2))

c3_diff=$((t_full3 - t_stub3))
info "150 members / 150 companions over 2000 references: full=${t_full3}s stubbed=${t_stub3}s Checks-6+7-contribution=${c3_diff}s"

if printf '%s' "$c3_stub_out" | grep -qF 'Monorepo-coverage heuristic (monorepo-coverage) stubbed out for timing isolation'; then
  pass "check6-7-timing: stubbed copy runs to completion and skips Checks 6+7 as intended"
else
  fail "check6-7-timing: stubbed copy runs to completion and skips Checks 6+7 as intended" "$c3_stub_out"
fi

if [ "$c3_full_rc" -eq 0 ] && printf '%s' "$c3_full_out" | grep -qF 'Failed: 0'; then
  pass "check6-7-timing: the 150-member/150-companion/2000-reference contextualizer has no [FAIL]"
else
  fail "check6-7-timing: the 150-member/150-companion/2000-reference contextualizer has no [FAIL]" "$c3_full_out"
fi

c3_warn_count=$(printf '%s' "$c3_full_out" | grep -c '\[WARN\]')
if [ "$c3_warn_count" -ge $((MEMBER_COUNT + COMPANION_COUNT)) ]; then
  pass "check6-7-timing: fixture self-check -- at least $((MEMBER_COUNT + COMPANION_COUNT)) WARN lines fired (got $c3_warn_count), confirming every member/companion was genuinely inspected, not short-circuited"
else
  fail "check6-7-timing: fixture self-check -- at least $((MEMBER_COUNT + COMPANION_COUNT)) WARN lines fired (got $c3_warn_count)"
fi

if [ "$c3_diff" -lt 2 ]; then
  pass "check6-7-timing: Checks 6+7's combined wall-clock contribution is under 2s (got ${c3_diff}s)"
else
  fail "check6-7-timing: Checks 6+7's combined wall-clock contribution is under 2s (got ${c3_diff}s)" \
    "full=${t_full3}s stubbed=${t_stub3}s"
fi

# ---- Check 6 discrimination: cited vs. uncited, and prefix overlap ----
# A rewrite from per-member `grep -r` to a single ERE alternation must not
# just run faster -- it must still distinguish "foo" (uncited) from
# "foobar" (cited) rather than treating the alternation as an unanchored
# substring match, and must still escape a literal '.' in a member name
# (ere_escape, shared with Check 7's own grep -rqE construction) so
# "my.pkg" is not silently satisfied by an unrelated "myXpkg" citation.
#
# The predicate being replaced was `grep -rqE "<root>/<member>\b"` -- LEFT
# anchored on the root prefix, not just word-bounded. The two shapes only
# diverge when one member's name is a boundary-suffix of another member
# that IS cited, because the batched form tests the root-stripped blob:
# "api" against a blob holding "web-api" finds it preceded by '-'. A
# collision pair with no separator between the names ("foo"/"foobar")
# cannot tell the two predicates apart -- the boundary test rejects it
# either way -- so the separator pair below is what actually pins the
# anchor. Check 7's own block immediately after this one reasons about
# exactly this '-'-is-a-word-boundary property; Check 6 needs the stronger
# claim because its anchor is a path prefix, not a word boundary.
#
# This is a preservation assertion, and no red->green step calibrates one
# (the property is present in both states by construction). It is
# calibrated by mutation instead: strip the leading anchor back out of the
# check and this assertion fires. See PR #15 review, finding 1.

c6d_ctx="$WORK/c6-discriminate"
build_nav "$c6d_ctx"
mkdir -p "$c6d_ctx/references"
printf '# ref\n\nSee packages/foobar for details.\nAlso see packages/myXpkg.\nThe HTTP layer lives in packages/web-api.\n' > "$c6d_ctx/references/ref.md"
c6d_cache="$WORK/c6-discriminate-cache"
c6d_tree="$c6d_cache/git-managed/discsrc-11112222"
mkdir -p "$c6d_tree/packages/foo" "$c6d_tree/packages/foobar" "$c6d_tree/packages/my.pkg" \
  "$c6d_tree/packages/api" "$c6d_tree/packages/web-api"
write_sources "$c6d_ctx" "[$(git_managed_source discsrc https://example.com/acme/discsrc)]"
c6d_out="$(run_verify "$c6d_ctx" "$c6d_cache")"
c6d_c6="$(check_section "$c6d_out" 'Monorepo-coverage')"

if printf '%s' "$c6d_c6" | grep -qF '[WARN] workspace member foo under discsrc is not cited in any reference (verify post-run summary for an explicit skip-reason)'; then
  pass "check6-discrimination: uncited member 'foo' warns with today's exact text"
else
  fail "check6-discrimination: uncited member 'foo' warns with today's exact text" "${c6d_c6:-<empty>}"
fi
if printf '%s' "$c6d_c6" | grep -qF 'member foobar'; then
  fail "check6-discrimination: cited member 'foobar' (via packages/foobar) must not warn" "${c6d_c6:-<empty>}"
else
  pass "check6-discrimination: cited member 'foobar' does not warn"
fi
if printf '%s' "$c6d_c6" | grep -qF '[WARN] workspace member my.pkg under discsrc is not cited in any reference (verify post-run summary for an explicit skip-reason)'; then
  pass "check6-discrimination: 'my.pkg' still warns -- ere_escape's literal-dot escaping survives (an unescaped '.' would wrongly match the decoy 'myXpkg' citation)"
else
  fail "check6-discrimination: 'my.pkg' still warns -- ere_escape's literal-dot escaping survives" "${c6d_c6:-<empty>}"
fi
if printf '%s' "$c6d_c6" | grep -qF '[WARN] workspace member api under discsrc is not cited in any reference (verify post-run summary for an explicit skip-reason)'; then
  pass "check6-discrimination: uncited member 'api' warns even though the cited sibling 'web-api' ends in it -- the <root>/ prefix anchor is intact"
else
  fail "check6-discrimination: uncited member 'api' warns even though the cited sibling 'web-api' ends in it -- the <root>/ prefix anchor is intact" \
    "a citation of packages/web-api must not score packages/api as cited" "${c6d_c6:-<empty>}"
fi
if printf '%s' "$c6d_c6" | grep -qF 'member web-api'; then
  fail "check6-discrimination: cited member 'web-api' (via packages/web-api) must not warn" "${c6d_c6:-<empty>}"
else
  pass "check6-discrimination: cited member 'web-api' does not warn"
fi

# ===========================================================================
# additive-field-parity -- importance and probe_budget are enforced by
# verify.sh, not by the schema alone
# ===========================================================================
section "additive-field-parity -- verify.sh bounds importance and probe_budget like the schema does"

# The schema advertises the parity explicitly on the analogous field:
# crawl_budget's description says "verify.sh enforces the same rule, keeping
# the two enforcers equivalent". The two fields this PR added inherited the
# claim without the enforcement, and the gap is not theoretical: CI runs
# check-jsonschema against the template and the bundled examples only
# (scripts/ci-local.sh), never against a live registry, so a hand-edited
# `"importance": 9` reaches the ordering sort unchallenged and pins that
# source to the head of every budgeted session for good (PR #15 review,
# finding 13).

c9_ctx="$WORK/c9-additive-fields"
build_nav "$c9_ctx"
mkdir -p "$c9_ctx/references"
write_sources "$c9_ctx" "[$(git_managed_source hot-src https://example.com/acme/hot | jq '.importance = 9')]"
c9_out="$(run_verify "$c9_ctx" "$WORK/c9-empty-cache")"
c9_c2="$(check_section "$c9_out" 'Source entries')"
if printf '%s' "$c9_c2" | grep -qE '\[FAIL\].*importance'; then
  pass "additive-field-parity: an out-of-range importance (9, schema bounds it to [1,5]) fails verify.sh"
else
  fail "additive-field-parity: an out-of-range importance (9, schema bounds it to [1,5]) fails verify.sh" \
    "${c9_c2:-<empty>}"
fi

c9b_ctx="$WORK/c9-bad-probe-budget"
build_nav "$c9b_ctx"
mkdir -p "$c9b_ctx/references"
mkdir -p "$c9b_ctx/research"
jq -n --argjson s "[$(git_managed_source ok-src https://example.com/acme/ok)]" \
  '{schema_version: 1, probe_budget: 0, sources: $s}' > "$c9b_ctx/research/source-paths.json"
c9b_out="$(run_verify "$c9b_ctx" "$WORK/c9b-empty-cache")"
c9b_c2="$(check_section "$c9b_out" 'Source entries')"
if printf '%s' "$c9b_c2" | grep -qE '\[FAIL\].*probe_budget'; then
  pass "additive-field-parity: probe_budget 0 (schema requires >= 1) fails verify.sh"
else
  fail "additive-field-parity: probe_budget 0 (schema requires >= 1) fails verify.sh" "${c9b_c2:-<empty>}"
fi

# Preservation: the valid values, and absence, stay clean -- a bound that
# rejects everything would satisfy both assertions above.
c9c_ctx="$WORK/c9-valid-additive"
build_nav "$c9c_ctx"
mkdir -p "$c9c_ctx/references" "$c9c_ctx/research"
jq -n --argjson s "[$(git_managed_source edge-lo https://example.com/acme/lo | jq '.importance = 1'),$(git_managed_source edge-hi https://example.com/acme/hi | jq '.importance = 5'),$(git_managed_source no-imp https://example.com/acme/none)]" \
  '{schema_version: 1, probe_budget: 1, sources: $s}' > "$c9c_ctx/research/source-paths.json"
c9c_out="$(run_verify "$c9c_ctx" "$WORK/c9c-empty-cache")"
c9c_c2="$(check_section "$c9c_out" 'Source entries')"
if printf '%s' "$c9c_c2" | grep -qE '\[FAIL\].*(importance|probe_budget)'; then
  fail "additive-field-parity preservation: importance 1 and 5, an absent importance, and probe_budget 1 are all accepted" \
    "${c9c_c2:-<empty>}"
else
  pass "additive-field-parity preservation: importance 1 and 5, an absent importance, and probe_budget 1 are all accepted"
fi

# ---- Check 6: a member name carrying a newline keeps its own pattern ----
# `members` is filled from `find -print0` and is newline-safe; the escaped
# copy it is indexed against was filled from a newline-delimited producer,
# which cannot represent a member whose name contains one. The two are read
# in lockstep, so any disagreement silently tests one member against another
# member's pattern (PR #15 review, finding 11).
#
# The fixture makes that observable without depending on `find`'s ordering:
# a member named "\nfoo" alongside a genuinely cited member "foo". Under the
# newline-delimited producer, "\nfoo" escapes to an empty line plus "foo",
# the empty line is dropped as blank, and the uncited member ends up carrying
# the cited one's pattern -- so it is scored as cited and never warns. Either
# find order gives the same result, because the collision is between the two
# names rather than between two positions.

c6nl_ctx="$WORK/c6-newline-member"
build_nav "$c6nl_ctx"
mkdir -p "$c6nl_ctx/references"
printf '# ref\n\nOnly packages/foo is cited here.\n' > "$c6nl_ctx/references/ref.md"
c6nl_cache="$WORK/c6-newline-cache"
c6nl_tree="$c6nl_cache/git-managed/nlsrc-33334444"
mkdir -p "$c6nl_tree/packages/foo" "$c6nl_tree/packages/$(printf '\nfoo')"
write_sources "$c6nl_ctx" "[$(git_managed_source nlsrc https://example.com/acme/nlsrc)]"
c6nl_out="$(run_verify "$c6nl_ctx" "$c6nl_cache")"
c6nl_c6="$(check_section "$c6nl_out" 'Monorepo-coverage')"

# Such a name cannot be turned into a citation pattern at all -- grep -E
# reads a newline inside its pattern as a separator between alternatives,
# so the name does not merely test loosely, it splits the whole root's
# alternation into two broken ones. The requirement is therefore that the
# member is reported as unassessed, by name of the condition, rather than
# scored either way.
if printf '%s' "$c6nl_c6" | grep -qF 'whose directory name contains a newline'; then
  pass "check6-newline-member: a member name carrying a newline is reported as unassessed, naming the reason"
else
  fail "check6-newline-member: a member name carrying a newline is reported as unassessed, naming the reason" \
    "the member was silently scored instead -- either as cited (tested against a sibling's escaped pattern) or not at all" \
    "${c6nl_c6:-<empty>}"
fi
# The other half, and the one that matters more: whatever happens to the
# pathological name must not change the verdict for its siblings. 'foo' is
# genuinely cited and must stay unwarned.
c6nl_warns="$(printf '%s' "$c6nl_c6" | grep -c 'is not cited in any reference' || true)"
if [ "$c6nl_warns" -eq 0 ]; then
  pass "check6-newline-member: the genuinely cited sibling 'foo' is unaffected by it"
else
  fail "check6-newline-member: the genuinely cited sibling 'foo' is unaffected by it" \
    "expected no uncited warnings, got $c6nl_warns" "${c6nl_c6:-<empty>}"
fi

# ---- Check 7 discrimination: cited vs. uncited, and prefix overlap ----
# Check 7 wraps BOTH sides in \b (\b$id\b), and '-' is a non-word
# character, so today a reference citing "acme-core-utils" already
# satisfies companion "acme-core"'s own \bacme-core\b pattern (there is a
# word boundary right after "...core" and before "-utils"). That is
# today's actual behavior (verified empirically against this repo's grep),
# not a new expectation being introduced here -- an alternation rewrite
# must preserve it, not "fix" it.

c7d_ctx="$WORK/c7-discriminate"
build_nav "$c7d_ctx"
mkdir -p "$c7d_ctx/references"
printf '# ref\n\nCited: alpha.\nAlso see acme-core-utils for details.\n' > "$c7d_ctx/references/ref.md"
write_sources "$c7d_ctx" "[$(companion_source alpha | jq '.status="proposed"'),$(companion_source beta),$(companion_source acme-core),$(companion_source acme-core-utils)]"
c7d_out="$(run_verify "$c7d_ctx" "$WORK/c7-discriminate-cache")"
c7d_c7="$(check_section "$c7d_out" 'Companions-coverage')"

if printf '%s' "$c7d_c7" | grep -qF 'proposed companion alpha'; then
  fail "check7-discrimination: cited companion 'alpha' must not warn" "${c7d_c7:-<empty>}"
else
  pass "check7-discrimination: cited companion 'alpha' does not warn"
fi
if printf '%s' "$c7d_c7" | grep -qF '[WARN] proposed companion beta has no reference citing it (verify post-run summary for an explicit skip-reason)'; then
  pass "check7-discrimination: uncited companion 'beta' warns with today's exact text"
else
  fail "check7-discrimination: uncited companion 'beta' warns with today's exact text" "${c7d_c7:-<empty>}"
fi
if printf '%s' "$c7d_c7" | grep -qF 'proposed companion acme-core '; then
  fail "check7-discrimination: today's \\b...\\b boundary treats '-' as a boundary, so 'acme-core' is (incidentally) satisfied by the 'acme-core-utils' citation -- this must not regress to a spurious warn" \
    "${c7d_c7:-<empty>}"
else
  pass "check7-discrimination: 'acme-core' is not warned (today's \\b/'-' boundary interaction preserved, not tightened)"
fi
if printf '%s' "$c7d_c7" | grep -qF 'proposed companion acme-core-utils'; then
  fail "check7-discrimination: cited companion 'acme-core-utils' must not warn" "${c7d_c7:-<empty>}"
else
  pass "check7-discrimination: 'acme-core-utils' is not warned"
fi

# ===========================================================================
# git-managed-path-fallback -- git-managed source with `path` set: Check 6 and Check 8
# resolve from it when no clone-cache tree exists
# ===========================================================================
section "git-managed-path-fallback -- git-managed + path, no clone-cache tree: Checks 6 and 8 must not report [N/A]"

c4_ctx="$WORK/c4-path-fallback"
build_nav "$c4_ctx"
mkdir -p "$c4_ctx/references"
c4_vendor="$WORK/c4-vendor-tree"
mkdir -p "$c4_vendor/packages/widgets"
printf 'x\n' > "$c4_vendor/packages/widgets/x.txt"
for ((i = 1; i <= 25; i++)); do
  printf 'x' > "$c4_vendor/file$(printf '%02d' "$i").txt"
done
write_sources "$c4_ctx" "[$(git_managed_with_path_source vendored-git-src https://example.com/acme/vendored-git-src "$c4_vendor")]"
c4_empty_cache="$WORK/c4-empty-cache"
mkdir -p "$c4_empty_cache"

c4_out="$(run_verify "$c4_ctx" "$c4_empty_cache")"
c4_c6="$(check_section "$c4_out" 'Monorepo-coverage')"
c4_c8="$(check_section "$c4_out" 'Catalog-density')"

if printf '%s' "$c4_c6" | grep -qF 'vendored-git-src has no local cache tree'; then
  fail "git-managed-path-fallback (Check 6): a git-managed source with path set and no cache tree must not report [N/A]/no-local-cache-tree" "${c4_c6:-<empty>}"
else
  pass "git-managed-path-fallback (Check 6): no [N/A]/no-local-cache-tree line for vendored-git-src"
fi
if printf '%s' "$c4_c6" | grep -qF '[WARN] workspace member widgets under vendored-git-src is not cited in any reference (verify post-run summary for an explicit skip-reason)'; then
  pass "git-managed-path-fallback (Check 6): the source's path-resolved tree is genuinely opened -- the uncited 'widgets' member warns"
else
  fail "git-managed-path-fallback (Check 6): the source's path-resolved tree is genuinely opened -- the uncited 'widgets' member warns" "${c4_c6:-<empty>}"
fi

if printf '%s' "$c4_c8" | grep -qF 'vendored-git-src has no local cache tree'; then
  fail "git-managed-path-fallback (Check 8): a git-managed source with path set and no cache tree must not report [N/A]/no-local-cache-tree" "${c4_c8:-<empty>}"
else
  pass "git-managed-path-fallback (Check 8): no [N/A]/no-local-cache-tree line for vendored-git-src"
fi
if printf '%s' "$c4_c8" | grep -qE '\[WARN\] source vendored-git-src has 26 files but the catalog carries only 0 row\(s\)'; then
  pass "git-managed-path-fallback (Check 8): the path-resolved tree's real file count (26) drives the density floor -- 0 catalog rows for this source warns"
else
  fail "git-managed-path-fallback (Check 8): the path-resolved tree's real file count (26) drives the density floor -- 0 catalog rows for this source warns" "${c4_c8:-<empty>}"
fi

# ---- Preservation: path set but the directory does not exist -- still
# falls through to the (unaffected) no-cache-tree N/A, exactly as today ----

c4n_ctx="$WORK/c4-path-nonexistent"
build_nav "$c4n_ctx"
mkdir -p "$c4n_ctx/references"
write_sources "$c4n_ctx" "[$(git_managed_with_path_source ghost-src https://example.com/acme/ghost-src /nonexistent/ghost-src-checkout)]"
c4n_out="$(run_verify "$c4n_ctx" "$WORK/c4n-empty-cache")"
c4n_c6="$(check_section "$c4n_out" 'Monorepo-coverage')"
c4n_c8="$(check_section "$c4n_out" 'Catalog-density')"
if printf '%s' "$c4n_c6" | grep -qF 'ghost-src has no local cache tree' \
  && printf '%s' "$c4n_c8" | grep -qF 'ghost-src has no local cache tree'; then
  pass "git-managed-path-fallback preservation: path set to a nonexistent directory still falls through to [N/A]/no-cache-tree on both checks (path fallback requires the directory to exist)"
else
  fail "git-managed-path-fallback preservation: path set to a nonexistent directory still falls through to [N/A]/no-cache-tree on both checks" \
    "Check 6: ${c4n_c6:-<empty>}" "Check 8: ${c4n_c8:-<empty>}"
fi

# ---- Must-reject: a RELATIVE path resolves against whatever directory
# verify.sh happens to be run from, so it must not be followed at all ----
#
# verify.sh never cd's, so `[ -d "$src_path" ]` on a relative path is a
# question about the caller's working directory, not about the source. The
# schema constrains `path` on a web-doc entry (null or empty) and constrains
# `url` on external-doc and local-path, but the git-managed branch requires
# only a non-empty url -- so `"path": "docs"` on a git-managed source is
# schema-valid, and was simply ignored before the fallback existed. Run from
# a project root that has a ./docs/, the fallback made both checks enumerate
# the maintainer's OWN tree as if it were the upstream one: bogus uncited-
# member warnings, and a density floor computed against an unrelated file
# count (PR #15 review, finding 5).

c4rel_ctx="$WORK/c4-path-relative"
build_nav "$c4rel_ctx"
mkdir -p "$c4rel_ctx/references"
write_sources "$c4rel_ctx" "[$(git_managed_with_path_source relpath-src https://example.com/acme/relpath-src docs)]"
# The caller's own working directory, carrying a ./docs/ of its own -- the
# ordinary shape of a repository root, and what a relative `path` would
# resolve against.
c4rel_cwd="$WORK/c4-relative-cwd"
mkdir -p "$c4rel_cwd/docs/packages/impostor"
printf 'x\n' > "$c4rel_cwd/docs/packages/impostor/x.txt"
c4rel_out="$(cd "$c4rel_cwd" && CTX_ROOT="$c4rel_ctx" SKILL_ENGINE_CACHE_ROOT="$WORK/c4rel-empty-cache" bash "$VERIFY_SH" 2>&1)"
c4rel_c6="$(check_section "$c4rel_out" 'Monorepo-coverage')"
c4rel_c8="$(check_section "$c4rel_out" 'Catalog-density')"

if printf '%s' "$c4rel_c6" | grep -qF 'relpath-src has no local cache tree' \
  && printf '%s' "$c4rel_c8" | grep -qF 'relpath-src has no local cache tree'; then
  pass "git-managed-path-fallback must-reject: a relative path is not followed -- both checks report the documented no-cache-tree [N/A]"
else
  fail "git-managed-path-fallback must-reject: a relative path is not followed -- both checks report the documented no-cache-tree [N/A]" \
    "Check 6: ${c4rel_c6:-<empty>}" "Check 8: ${c4rel_c8:-<empty>}"
fi
if printf '%s' "$c4rel_c6" | grep -qF 'workspace member impostor'; then
  fail "git-managed-path-fallback must-reject: the caller's own ./docs/ is never enumerated as the source's tree" \
    "a directory belonging to whoever ran verify.sh was reported as an uncited workspace member of relpath-src" \
    "${c4rel_c6:-<empty>}"
else
  pass "git-managed-path-fallback must-reject: the caller's own ./docs/ is never enumerated as the source's tree"
fi

# ---- Preservation: path null (today's shape), no cache tree -- unaffected ----

c4z_ctx="$WORK/c4-path-null"
build_nav "$c4z_ctx"
mkdir -p "$c4z_ctx/references"
write_sources "$c4z_ctx" "[$(git_managed_source plain-src https://example.com/acme/plain-src)]"
c4z_out="$(run_verify "$c4z_ctx" "$WORK/c4z-empty-cache")"
c4z_c6="$(check_section "$c4z_out" 'Monorepo-coverage')"
if printf '%s' "$c4z_c6" | grep -qF 'plain-src has no local cache tree'; then
  pass "git-managed-path-fallback preservation: a source with path null and no cache tree is unaffected ([N/A] as today)"
else
  fail "git-managed-path-fallback preservation: a source with path null and no cache tree is unaffected ([N/A] as today)" "${c4z_c6:-<empty>}"
fi

# ---- Schema tolerance sanity: git-managed + non-null path validates ----

if command -v check-jsonschema >/dev/null 2>&1; then
  c4_schema_doc="$WORK/c4-schema-fixture.json"
  jq -n --argjson s "[$(git_managed_with_path_source schema-check https://example.com/acme/schema-check /some/local/checkout)]" \
    '{schema_version: 1, sources: $s}' > "$c4_schema_doc"
  if check-jsonschema --schemafile "$SCHEMA" "$c4_schema_doc" >/dev/null 2>&1; then
    pass "git-managed-path-fallback: schema tolerates a non-null path on a git-managed source (its conditional constrains only url)"
  else
    fail "git-managed-path-fallback: schema tolerates a non-null path on a git-managed source"
  fi
else
  info "check-jsonschema not on PATH -- skipping the schema-tolerance sanity check locally (CI runs it)"
fi

# ===========================================================================
# local-path-git-exclusion -- local-path source's own .git/ must not inflate Check 8's
# file count
# ===========================================================================
section "local-path-git-exclusion -- Check 8 excludes a local-path source's own .git/ from its file count"

c5_repo="$WORK/c5-local-clone"
mkdir -p "$c5_repo"
git init -q -b main "$c5_repo" >/dev/null 2>&1
for ((i = 1; i <= 12; i++)); do
  printf 'x' > "$c5_repo/f$(printf '%02d' "$i").txt"
done
git -C "$c5_repo" add -A >/dev/null 2>&1
git -C "$c5_repo" -c user.email=test@example.com -c user.name=Test -c commit.gpgsign=false \
  commit -q -m seed >/dev/null 2>&1

c5_outside=$(real_file_count "$c5_repo")
c5_total=$(naive_file_count "$c5_repo")
if [ "$c5_outside" -lt 20 ] && [ "$c5_total" -ge 20 ]; then
  pass "local-path-git-exclusion: fixture self-check -- real corpus ($c5_outside files, excl. .git/) stays under the floor while the unfiltered count ($c5_total) clears it"
else
  fail "local-path-git-exclusion: fixture self-check -- real corpus ($c5_outside files, excl. .git/) stays under the floor while the unfiltered count ($c5_total) clears it" \
    "outside=$c5_outside total=$c5_total"
fi

c5_ctx="$WORK/c5-ctx"
build_nav "$c5_ctx"
mkdir -p "$c5_ctx/references"
write_sources "$c5_ctx" "[$(local_path_source local-clone-src "$c5_repo")]"
c5_out="$(run_verify "$c5_ctx" "$WORK/c5-unrelated-cache")"
c5_c8="$(check_section "$c5_out" 'Catalog-density')"

if printf '%s' "$c5_c8" | grep -qF 'local-clone-src'; then
  fail "local-path-git-exclusion: a local-path source whose own .git/ inflates the unfiltered count past 20 must not warn once .git/ is excluded (real corpus is only $c5_outside files)" \
    "${c5_c8:-<empty>}"
else
  pass "local-path-git-exclusion: no WARN for local-clone-src once .git/ is excluded from its file count"
fi

# ---- Discrimination: a genuinely large local-path corpus (no .git/
# involved) must still warn -- the exclusion must not over-suppress ----

c5b_dir="$WORK/c5-real-large"
mkdir -p "$c5b_dir"
for ((i = 1; i <= 25; i++)); do
  printf 'x' > "$c5b_dir/doc$(printf '%02d' "$i").txt"
done
c5b_ctx="$WORK/c5b-ctx"
build_nav "$c5b_ctx"
mkdir -p "$c5b_ctx/references"
write_sources "$c5b_ctx" "[$(local_path_source local-large-src "$c5b_dir")]"
c5b_out="$(run_verify "$c5b_ctx" "$WORK/c5b-unrelated-cache")"
c5b_c8="$(check_section "$c5b_out" 'Catalog-density')"
if printf '%s' "$c5b_c8" | grep -qE '\[WARN\] source local-large-src has 25 files but the catalog carries only 0 row\(s\)'; then
  pass "local-path-git-exclusion discrimination: a genuine 25-file local-path corpus (no .git/ involved) still warns with today's exact text"
else
  fail "local-path-git-exclusion discrimination: a genuine 25-file local-path corpus (no .git/ involved) still warns with today's exact text" "${c5b_c8:-<empty>}"
fi

# ===========================================================================
# check4-idiom-consolidation -- Check 4's four-line array-read idiom collapses to one
# implementation; accept/reject decisions unchanged
# ===========================================================================
section "check4-idiom-consolidation -- Check 4's array-read idiom consolidates; behavior unchanged"

idiom_count=$(awk '
  /while IFS= read -r s; do/ {
    getline nextline
    if (nextline ~ /\[ -n "\$s" \] \|\| continue/) count++
  }
  END { print count + 0 }
' "$VERIFY_SH")
info "today's four-line \"while IFS= read -r s; do / [ -n \\\"\\\$s\\\" ] || continue\" idiom occurs $idiom_count time(s) in verify.sh"
if [ "$idiom_count" -le 1 ]; then
  pass "check4-idiom-consolidation: the array-read idiom is implemented once, not repeated per call site (got $idiom_count occurrence(s))"
else
  fail "check4-idiom-consolidation: the array-read idiom is implemented once, not repeated per call site (got $idiom_count occurrence(s))" \
    "expected <= 1 (one possible occurrence being the shared helper's own body); found $idiom_count separate inline copies"
fi

# ---- Behavior preservation: representative Check 4 decisions, today's
# exact text (the full behavioral surface is already pinned by
# tests/verify-bijection*/run.sh -- this is a smaller, independently run
# sample so this file's own assertions also catch a regression directly,
# rather than relying on the assumption that a sibling suite already
# covers it -- an assumption that has been wrong before on this repo) ----

seed_bij_ctx() {
  local ctx="$1"
  mkdir -p "$ctx/research" "$ctx/references"
  printf '{"schema_version": 1, "sources": []}\n' > "$ctx/research/source-paths.json"
}
write_bij_nav() {
  local ctx="$1"; shift
  {
    printf -- '---\n'
    printf 'name: test-context\n'
    printf 'description: Fixture navigator for batch-forks Check 4 preservation.\n'
    printf -- '---\n\n# Context navigator\n\n## Catalog\n\n'
    printf '| Reference | Description |\n|---|---|\n'
    local line
    for line in "$@"; do printf '%s\n' "$line"; done
  } > "$ctx/SKILL.md"
}
write_bij_ref() {
  printf '# %s\n\nReference body for %s.\n' "$2" "$2" > "$1/references/$2.md"
}
write_bij_dir_ref() {
  mkdir -p "$1/references/$2"
  printf '# %s\n\nDirectory-form primary for %s.\n' "$2" "$2" > "$1/references/$2/$2.md"
}

# clean pass
{
  ctx="$WORK/c6-clean"; seed_bij_ctx "$ctx"
  write_bij_ref "$ctx" onlyref
  write_bij_nav "$ctx" '| [onlyref](references/onlyref.md) | One reference. |'
  out="$(run_verify "$ctx" "$WORK/c6-clean-cache")"
  bij="$(check_section "$out" 'bijection')"
  if printf '%s' "$bij" | grep -qF '[PASS] Catalog ↔ references bijection valid (1 reference, all linked from catalog)'; then
    pass "check4-preservation: a clean 1-reference bijection prints today's exact PASS text"
  else
    fail "check4-preservation: a clean 1-reference bijection prints today's exact PASS text" "${bij:-<empty>}"
  fi
}

# phantom row (file-form)
{
  ctx="$WORK/c6-phantom"; seed_bij_ctx "$ctx"
  write_bij_nav "$ctx" '| [ghost](references/ghost.md) | Phantom. |'
  out="$(run_verify "$ctx" "$WORK/c6-phantom-cache")"
  bij="$(check_section "$out" 'bijection')"
  if printf '%s' "$bij" | grep -qF 'Catalog row points at references/ghost.md but no matching reference exists (file or directory)'; then
    pass "check4-preservation: phantom file-form row fails with today's exact text"
  else
    fail "check4-preservation: phantom file-form row fails with today's exact text" "${bij:-<empty>}"
  fi
}

# orphan reference (directory-form)
{
  ctx="$WORK/c6-orphan"; seed_bij_ctx "$ctx"
  write_bij_dir_ref "$ctx" orph
  write_bij_nav "$ctx"
  out="$(run_verify "$ctx" "$WORK/c6-orphan-cache")"
  bij="$(check_section "$out" 'bijection')"
  if printf '%s' "$bij" | grep -qF 'references/orph/ exists with canonical primary but no catalog row points at it (run /skill-engine:self-audit to repair)'; then
    pass "check4-preservation: orphan directory-form reference fails with today's exact text"
  else
    fail "check4-preservation: orphan directory-form reference fails with today's exact text" "${bij:-<empty>}"
  fi
}

# duplicate-form
{
  ctx="$WORK/c6-dupform"; seed_bij_ctx "$ctx"
  write_bij_ref "$ctx" dupform
  write_bij_dir_ref "$ctx" dupform
  write_bij_nav "$ctx" '| [dupform](references/dupform.md) | file-form row. |'
  out="$(run_verify "$ctx" "$WORK/c6-dupform-cache")"
  bij="$(check_section "$out" 'bijection')"
  if printf '%s' "$bij" | grep -qF 'duplicate primary for reference dupform: file form references/dupform.md AND directory form references/dupform/ both present'; then
    pass "check4-preservation: duplicate-form slug fails with today's exact text"
  else
    fail "check4-preservation: duplicate-form slug fails with today's exact text" "${bij:-<empty>}"
  fi
}

# form mismatch, both directions (the mirrored file-half/dir-half case
# blocks flagged for consolidation into one shared implementation)
{
  ctx="$WORK/c6-mismatch-file"; seed_bij_ctx "$ctx"
  write_bij_dir_ref "$ctx" mm1
  write_bij_nav "$ctx" '| [mm1](references/mm1.md) | declared file form. |'
  out="$(run_verify "$ctx" "$WORK/c6-mismatch-file-cache")"
  bij="$(check_section "$out" 'bijection')"
  if printf '%s' "$bij" | grep -qF 'Catalog row references/mm1.md declares file form but the on-disk reference is directory form references/mm1/ — link will render broken'; then
    pass "check4-preservation: file-declared/dir-actual mismatch fails with today's exact text"
  else
    fail "check4-preservation: file-declared/dir-actual mismatch fails with today's exact text" "${bij:-<empty>}"
  fi
}
{
  ctx="$WORK/c6-mismatch-dir"; seed_bij_ctx "$ctx"
  write_bij_ref "$ctx" mm2
  write_bij_nav "$ctx" '| [mm2](references/mm2/) | declared directory form. |'
  out="$(run_verify "$ctx" "$WORK/c6-mismatch-dir-cache")"
  bij="$(check_section "$out" 'bijection')"
  if printf '%s' "$bij" | grep -qF 'Catalog row references/mm2/ declares directory form but the on-disk reference is file form references/mm2.md — link will render broken'; then
    pass "check4-preservation: dir-declared/file-actual mismatch fails with today's exact text (the mirrored case block's own message)"
  else
    fail "check4-preservation: dir-declared/file-actual mismatch fails with today's exact text" "${bij:-<empty>}"
  fi
}

# malformed target
{
  ctx="$WORK/c6-malformed"; seed_bij_ctx "$ctx"
  write_bij_nav "$ctx" '| [bad](references/foo) | Malformed. |'
  out="$(run_verify "$ctx" "$WORK/c6-malformed-cache")"
  bij="$(check_section "$out" 'bijection')"
  if printf '%s' "$bij" | grep -qF 'Catalog row target references/foo has neither a .md suffix nor a trailing / — file form requires .md, directory form requires trailing /'; then
    pass "check4-preservation: a malformed catalog target fails with today's exact text"
  else
    fail "check4-preservation: a malformed catalog target fails with today's exact text" "${bij:-<empty>}"
  fi
}

# duplicate catalog rows
{
  ctx="$WORK/c6-duprows"; seed_bij_ctx "$ctx"
  write_bij_ref "$ctx" dup
  write_bij_nav "$ctx" \
    '| [dup](references/dup.md) | Row one. |' \
    '| [dup](references/dup.md) | Row two. |'
  out="$(run_verify "$ctx" "$WORK/c6-duprows-cache")"
  bij="$(check_section "$out" 'bijection')"
  if printf '%s' "$bij" | grep -qF 'Catalog has duplicate rows pointing at references/dup (strict 1:1 bijection violation)'; then
    pass "check4-preservation: duplicate catalog rows fail with today's exact text"
  else
    fail "check4-preservation: duplicate catalog rows fail with today's exact text" "${bij:-<empty>}"
  fi
}

# sorted output order -- directly exercises the "sort -u" idiom's
# ordering guarantee, the property most at risk from consolidating it
{
  ctx="$WORK/c6-sorted"; seed_bij_ctx "$ctx"
  write_bij_nav "$ctx" \
    '| [zzz](references/zzz.md) | Phantom z. |' \
    '| [aaa](references/aaa.md) | Phantom a. |' \
    '| [mmm](references/mmm.md) | Phantom m. |'
  out="$(run_verify "$ctx" "$WORK/c6-sorted-cache")"
  got_order=$(printf '%s\n' "$out" \
    | grep -oE '\[FAIL\] Catalog row points at references/[a-z]+\.md but no matching reference exists' \
    | grep -oE 'references/[a-z]+\.md' \
    | sed -E 's#references/([a-z]+)\.md#\1#' \
    | tr '\n' ' ')
  got_order="${got_order% }"
  if [ "$got_order" = "aaa mmm zzz" ]; then
    pass "check4-preservation: phantom-row failures still emit in sorted slug order after consolidation (got: $got_order)"
  else
    fail "check4-preservation: phantom-row failures still emit in sorted slug order after consolidation" \
      "expected: aaa mmm zzz; got: $got_order"
  fi
}

# ===========================================================================
# check8-workspace-roots-reuse -- Check 8 reuses Check 6's workspace_roots projection; the
# default nine-item root list is spelled once, not twice
# ===========================================================================
section "check8-workspace-roots-reuse -- Check 8 stops issuing its own per-source workspace_roots jq query; default root list spelled once"

# ---- Source-text count: the nine-item default list, comment-marker-
# normalized so line-wrapping across the header comment does not defeat
# the match (verified: today's comment wraps the list across two lines,
# each prefixed with '#') ----
default_list_count=$(sed -E 's/^#[[:space:]]?//' "$VERIFY_SH" | tr -s '[:space:]' ' ' \
  | grep -o 'packages apps libs crates services modules cmd internal pkg' | wc -l | tr -d ' ')
info "the literal nine-item default root list 'packages apps libs crates services modules cmd internal pkg' occurs $default_list_count time(s) in verify.sh's source text (today: Check 6's header comment + its roots=(...) array literal)"
if [ "$default_list_count" -eq 1 ]; then
  pass "check8-workspace-roots-reuse: the default root list is spelled in exactly one place in verify.sh"
else
  fail "check8-workspace-roots-reuse: the default root list is spelled in exactly one place in verify.sh (got $default_list_count)"
fi

# ---- Subprocess count: Check 8 must stop issuing its own per-source
# `jq --arg id ... workspace_roots` query. Instrumented via a PATH-
# shimmed jq that logs every invocation's argv, then filtered for the
# distinctive shape (--arg id paired with a workspace_roots-querying
# filter) that today's line 1409 alone produces (confirmed unique via
# grep over verify.sh before writing this fixture). ----

real_jq="$(command -v jq)"
jq_shim_dir="$WORK/jq-shim"
mkdir -p "$jq_shim_dir"
jq_log="$WORK/jq-invocations.log"
: > "$jq_log"
cat > "$jq_shim_dir/jq" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$jq_log"
exec "$real_jq" "\$@"
EOF
chmod +x "$jq_shim_dir/jq"

C7_SCOPED_COUNT=5
c7q_ctx="$WORK/c7-jq-count"
build_nav "$c7q_ctx"
mkdir -p "$c7q_ctx/references"
c7q_cache="$WORK/c7-jq-count-cache"
c7q_sources="[]"
for ((i = 1; i <= C7_SCOPED_COUNT; i++)); do
  sid=$(printf 'scoped-src%02d' "$i")
  tree="$c7q_cache/git-managed/${sid}-aaaa$(printf '%04d' "$i")"
  mkdir -p "$tree/packages/onlymember"
  printf 'x\n' > "$tree/packages/onlymember/x.txt"
  entry=$(git_managed_source "$sid" "https://example.com/acme/$sid" \
    '{"files_of_interest": ["packages/**"], "workspace_roots": ["packages"]}')
  if [ "$c7q_sources" = "[]" ]; then
    c7q_sources="[$entry"
  else
    c7q_sources="$c7q_sources,$entry"
  fi
done
c7q_sources="$c7q_sources]"
write_sources "$c7q_ctx" "$c7q_sources"

PATH="$jq_shim_dir:$PATH" CTX_ROOT="$c7q_ctx" SKILL_ENGINE_CACHE_ROOT="$c7q_cache" bash "$VERIFY_SH" >/dev/null 2>&1

per_source_ws_jq_calls=$(grep -F -- '--arg id' "$jq_log" | grep -cF 'workspace_roots' || true)
info "$C7_SCOPED_COUNT files_of_interest-scoped git-managed sources with a resolvable tree: Check 8's own per-source '--arg id ... workspace_roots' jq calls = $per_source_ws_jq_calls (today: one per source)"
if [ "$per_source_ws_jq_calls" -eq 0 ]; then
  pass "check8-workspace-roots-reuse: Check 8 issues zero of its own per-source workspace_roots jq queries (reuses Check 6's projection)"
else
  fail "check8-workspace-roots-reuse: Check 8 issues zero of its own per-source workspace_roots jq queries (reuses Check 6's projection)" \
    "expected 0; got $per_source_ws_jq_calls across $C7_SCOPED_COUNT scoped sources"
fi

# ---- Behavior preservation: Check 6 AND Check 8 must agree, exactly as
# today, on a workspace_roots override and on files_of_interest scoping
# with no override ----

c7o_ctx="$WORK/c7-override"
build_nav "$c7o_ctx"
mkdir -p "$c7o_ctx/references"
c7o_cache="$WORK/c7-override-cache"
c7o_tree="$c7o_cache/git-managed/override-src-33334444"
mkdir -p "$c7o_tree/custom_root/thing1" "$c7o_tree/packages/ignored"
printf 'x\n' > "$c7o_tree/custom_root/thing1/a.txt"
printf 'x\n' > "$c7o_tree/packages/ignored/b.txt"
write_sources "$c7o_ctx" "[$(git_managed_source override-src https://example.com/acme/override-src '{"workspace_roots": ["custom_root"]}')]"
c7o_out="$(run_verify "$c7o_ctx" "$c7o_cache")"
c7o_c6="$(check_section "$c7o_out" 'Monorepo-coverage')"
if printf '%s' "$c7o_c6" | grep -qE 'workspace member thing1([[:space:]]|$)' && ! printf '%s' "$c7o_out" | grep -qF 'ignored'; then
  pass "check8-preservation: a workspace_roots override still replaces (not augments) the default list in Check 6"
else
  fail "check8-preservation: a workspace_roots override still replaces (not augments) the default list in Check 6" "${c7o_c6:-<empty>}"
fi

c7s_ctx="$WORK/c7-scoped-no-override"
build_nav "$c7s_ctx"
mkdir -p "$c7s_ctx/references"
c7s_cache="$WORK/c7-scoped-no-override-cache"
c7s_tree="$c7s_cache/git-managed/scoped-src-55556666"
mkdir -p "$c7s_tree/docs"
for ((i = 1; i <= 25; i++)); do
  printf 'x' > "$c7s_tree/docs/page$(printf '%02d' "$i").md"
done
write_sources "$c7s_ctx" "[$(git_managed_source scoped-src https://example.com/acme/scoped-src '{"files_of_interest": ["docs/**"]}')]"
c7s_out="$(run_verify "$c7s_ctx" "$c7s_cache")"
c7s_c8="$(check_section "$c7s_out" 'Catalog-density')"
if printf '%s' "$c7s_c8" | grep -qF 'scoped-src' && printf '%s' "$c7s_c8" | grep -q '\[WARN\]'; then
  pass "check8-preservation: a files_of_interest source with no workspace_roots override still keeps the density floor live in Check 8"
else
  fail "check8-preservation: a files_of_interest source with no workspace_roots override still keeps the density floor live in Check 8" "${c7s_c8:-<empty>}"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
