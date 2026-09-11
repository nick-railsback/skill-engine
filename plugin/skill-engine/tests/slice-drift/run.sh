#!/usr/bin/env bash
# Black-box oracle for the script that decides per-slice drift between two
# cached commits and reports it via JSON — given a cache directory holding
# a previous and a current SHA of a git-managed monorepo, plus that
# monorepo's slice declarations, it says for each declared slice whether
# any file under that slice's own path patterns differs between the two
# trees, so REFRESH's Phase 1 can promote only the slices that actually
# moved instead of re-reading everything on every run.
#
# Written from the chunk's frozen contract alone, black-box throughout:
# CLI invocation and stdout JSON shape, never internal function names the
# eventual implementation might choose. It is written before the script
# exists, so every assertion that invokes it is expected to FAIL right
# now — there is no file to run, so `python3 <path-to-script>` exits
# non-zero with Python's own "can't open file" before a single line of the
# feature ever executes. Also expected to FAIL right now: the three
# documentation assertions against drift-detection-and-phases.md (the
# current file predates this script and names it nowhere).
#
# Expected to PASS right now: the six preservation assertions (pre-existing
# prose this chunk must not delete while it edits these same two files —
# already true today, confirmed by a sibling chunk's own frozen oracle
# asserting the same properties), the fixture self-checks (this file's own
# git plumbing, not the feature), and two of the script-contract checks
# that are vacuously true when the script is simply absent — read-only
# (nothing to write when there is nothing to run) and the git-verb scan
# (no candidate git invocations when there is no source file to scan).
# Those two are NOT proof the finished script satisfies its contract; they
# prove only that its current absence doesn't violate it either. The
# remaining script-contract checks (stdlib-only, unresolvable-SHA named
# error) exercise the script directly and are expected to FAIL right now
# like everything else that invokes it.
#
# Design decisions pinned where the frozen contract is silent on an
# operational detail (asserted, and re-explained, at each site below):
#   1. Array order is not asserted. Objects are looked up by slice_id and
#      checked against the expected id SET plus an exact length — a
#      correct implementation may emit slices in declaration order, sorted
#      order, or any other order without failing this oracle.
#   2. `<cache-dir>` is the clone's own working directory (the one holding
#      `.git`), not a cache root that contains multiple such clones —
#      matching the shallow-clone calibration fixture below, which is
#      exactly the shape this repo's own in-place-advance recipe produces:
#      one directory, two disconnected shallow commits.
#   3. Each fixture's monorepo-config.json carries exactly one entry under
#      `monorepos`. Multi-monorepo behavior for a single cache directory is
#      unspecified by the contract and is not asserted here.
#   4. Exit code 0 is expected on every happy-path invocation (valid SHAs,
#      valid config); a non-zero exit is asserted ONLY for the named
#      must-reject case (an unresolvable SHA).
#   5. stdout is a single JSON document (a bare array), read whole — not a
#      JSON-lines stream.
#   6. `changed_paths` entries are POSIX, repo-root-relative paths (forward
#      slashes, no leading `./`), matching what `git`'s own path-reporting
#      plumbing already emits on every platform this repo runs on.
#   7. A `notice` field is asserted present, non-empty, and naming its own
#      slice_id for the slice whose patterns match nothing in either tree;
#      its exact wording is not pinned, and no other slice is asserted to
#      lack a `notice` key (over-constraining a field the contract never
#      says is exclusive to the empty-match case).
#   8. "Named error" for an unresolvable SHA means stderr contains the
#      literal offending SHA string; both `--old` and `--new` are checked
#      independently since either could be the unresolvable one.
#   9. The contract's git-verb clause is exercised directly against
#      slice_drift.py's own source with a small bespoke AST/regex scan
#      below, NOT via tests/lib/git_verb_scan.sh: that scanner's file
#      collection (doctrine.sh Check 4) never walks tests/*.py, and its
#      literal-stripping pass blanks double-quoted string arguments with
#      no command substitution — exactly the shape of a Python argv list
#      like ["git", "diff", ...], which would scan clean regardless of
#      what verb it names. The bespoke scan below also checks against
#      only the ten unconditionally-read-only verbs (diff, status, log,
#      show, clone, ls-remote, ls-tree, ls-files, rev-parse, cat-file) —
#      NOT doctrine's three cache-scoped exceptions (fetch,
#      sparse-checkout, checkout), which are a conditional allowance for
#      recipes that populate a clone, not something a read-only drift
#      comparison has any legitimate reason to invoke. A checkout/fetch
#      slice_drift.py did issue would independently trip the read-only
#      fingerprint check below anyway.
#
# -uo pipefail, not -e: every assertion runs and reports, not abort at the
# first red one. Every tmpdir this file creates is removed on exit.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_ROOT="$(cd "$TESTS_ROOT/.." && pwd)"

SLICE_DRIFT_PY="$TESTS_ROOT/slice_drift.py"
DRIFT_PHASES="$PLUGIN_ROOT/skills/refresh/references/drift-detection-and-phases.md"
CACHE_AND_CLONE="$PLUGIN_ROOT/skills/discover/references/cache-and-clone.md"

for f in "$DRIFT_PHASES" "$CACHE_AND_CLONE"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: expected surface is missing entirely: $f" >&2
    exit 69
  fi
done

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
# Text-matching helpers (wrap-normalized prose assertions) — reused
# near-verbatim from tests/slice-units/run.sh's helper shape.
# ---------------------------------------------------------------------------

norm() { printf '%s' "$1" | tr -s '[:space:]' ' '; }
norm_file() { norm "$(cat "$1")"; }

near() {
  local text="$1" anchor="$2" needle="$3" window="$4"
  # `grep -c ... > /dev/null`, not `grep -q`: -q exits at its first match,
  # SIGPIPE-ing the upstream -o while it is still writing remaining
  # windows; under `set -o pipefail` that reads as a miss even when the
  # needle WAS found. -c drains to EOF so the verdict never depends on the
  # anchor's frequency.
  printf '%s' "$text" \
    | grep -oiE ".{0,${window}}${anchor}.{0,${window}}" \
    | grep -ciE -- "$needle" > /dev/null
}

near_all() {
  local text="$1" anchor="$2" window="$3"
  shift 3
  local needle
  for needle in "$@"; do
    near "$text" "$anchor" "$needle" "$window" || return 1
  done
  return 0
}

# jq_check <json> <jq-boolean-program> — true (rc 0) only when the input is
# valid JSON AND the boolean program evaluates true.
jq_check() {
  local json="$1" program="$2"
  printf '%s' "$json" | jq -e "$program" > /dev/null 2>&1
}

sha256_of_file() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# dir_fingerprint <dir> — content fingerprint (path + sha256) of every
# regular file under <dir>, INCLUDING .git internals. Used to prove a
# read-only claim: nothing on disk moved between two snapshots. Content,
# not mtime, so a stat-only refresh can't accidentally read as a change.
dir_fingerprint() {
  local dir="$1"
  if [ ! -d "$dir" ]; then
    echo "MISSING"
    return
  fi
  ( cd "$dir" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s ' "$f"
      sha256_of_file "$f"
    done ) | { command -v sha256sum > /dev/null 2>&1 && sha256sum || shasum -a 256; } | awk '{print $1}'
}

# repeat_hex <2-hex-char pair> <count> — a syntactically valid, obviously
# fake 40-char commit SHA (never a real object anywhere), built by literal
# repetition so its length is correct by construction.
repeat_hex() {
  local pair="$1" count="$2" result="" i
  for ((i = 0; i < count; i++)); do
    result="${result}${pair}"
  done
  printf '%s' "$result"
}

# sd_out <args...> — slice_drift.py's stdout only, stderr discarded, rc
# propagated via $?.
sd_out() {
  python3 "$SLICE_DRIFT_PY" "$@" 2>/dev/null
}

# sd_err <args...> — slice_drift.py's stderr only, stdout discarded, routed
# through a throwaway file. Same rc-capture contract as sd_out above.
sd_err() {
  local errfile rc
  errfile="$(mktemp)"
  python3 "$SLICE_DRIFT_PY" "$@" > /dev/null 2> "$errfile"
  rc=$?
  cat "$errfile"
  rm -f "$errfile"
  return "$rc"
}

# ---------------------------------------------------------------------------
# Shallow-clone calibration fixtures. Per this project's own testing
# doctrine: a real git repo, a --depth=1 shallow clone seeded at commit A,
# then advanced IN PLACE to commit B by fetching the new commit into the
# SAME directory (never a fresh clone), so both A and B are reachable
# there — the "two disconnected shallow commits in one directory" state
# this repo's own production in-place-advance recipe actually produces.
# Verified interactively before writing this file: a plain
# `git fetch --depth=1 <upstream> <sha>` into an existing --depth=1 clone
# followed by `checkout --detach <sha>` leaves BOTH the original and the
# newly-fetched commit resolvable via `git cat-file -e` in that one
# directory, with no fresh clone issued.
# ---------------------------------------------------------------------------

init_upstream() {
  local dir="$1"
  git init -q "$dir"
  git -C "$dir" checkout -q -b main
}

# commit_all <repo-dir> <message> — stages everything and commits, echoing
# the new HEAD SHA. Fully offline; nothing here is ever pushed anywhere.
commit_all() {
  local repo="$1" msg="$2"
  git -C "$repo" add -A
  git -C "$repo" -c user.email=oracle@example.invalid -c user.name=oracle \
    commit -q -m "$msg"
  git -C "$repo" rev-parse HEAD
}

# seed_shallow_cache <upstream-dir> <cache-dir> — a --depth=1 clone from a
# file:// URL, left in a detached HEAD (the state a CI checkout runs in,
# not the branch a fresh `git clone` leaves you on).
seed_shallow_cache() {
  local upstream="$1" cache_dir="$2"
  git clone -q --depth=1 "file://$upstream" "$cache_dir"
  git -C "$cache_dir" checkout -q --detach HEAD
}

# advance_cache_inplace <cache-dir> <upstream-dir> <sha> — fetches exactly
# one commit by SHA into the SAME directory and checks it out, without
# issuing a fresh clone. The original shallow commit and this new one are
# both left resolvable, disconnected from each other's history.
advance_cache_inplace() {
  local cache_dir="$1" upstream="$2" sha="$3"
  git -C "$cache_dir" fetch -q --depth=1 "file://$upstream" "$sha"
  git -C "$cache_dir" checkout -q --detach "$sha"
}

both_resolvable() {
  local cache_dir="$1" sha_a="$2" sha_b="$3"
  git -C "$cache_dir" cat-file -e "$sha_a" 2>/dev/null \
    && git -C "$cache_dir" cat-file -e "$sha_b" 2>/dev/null
}

WORK="$(mktemp -d -t skill-engine-slice-drift.XXXXXX)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ===========================================================================
# Fixture 1 — must-accept: three slices declared, one commit touching files
# under exactly one slice's two path patterns, one untouched file left in
# that same slice to prove changed_paths lists only what actually changed.
# ===========================================================================
UP1="$WORK/upstream1"
init_upstream "$UP1"
mkdir -p "$UP1/packages/billing" "$UP1/shared/billing-types" \
  "$UP1/packages/auth" "$UP1/apps/reports-dashboard"
printf 'keep\n' > "$UP1/packages/billing/keep.py"
printf 'one\n' > "$UP1/packages/billing/a.py"
printf 'orig\n' > "$UP1/shared/billing-types/t.py"
printf 'auth1\n' > "$UP1/packages/auth/b.py"
printf 'report1\n' > "$UP1/apps/reports-dashboard/index.js"
SHA_A1="$(commit_all "$UP1" "commit A")"

# Seed the shallow cache at commit A BEFORE commit B exists upstream — a
# --depth=1 clone always takes the upstream's CURRENT HEAD, so cloning
# after both commits exist would seed at B and never fetch A at all.
CACHE1="$WORK/cache1"
seed_shallow_cache "$UP1" "$CACHE1"

printf 'one\nchanged\n' > "$UP1/packages/billing/a.py"
printf 'orig\nchanged\n' > "$UP1/shared/billing-types/t.py"
SHA_B1="$(commit_all "$UP1" "commit B")"

advance_cache_inplace "$CACHE1" "$UP1" "$SHA_B1"

CONFIG_3SLICE="$WORK/monorepo-config-3slice.json"
cat > "$CONFIG_3SLICE" <<'EOF'
{
  "version": "1.0",
  "monorepos": [
    {
      "url": "https://example.com/acme/big-monorepo",
      "type": "internal-repo",
      "slices": [
        {"id": "billing", "paths": ["packages/billing/**", "shared/billing-types/**"]},
        {"id": "auth",    "paths": ["packages/auth/**"]},
        {"id": "reports", "paths": ["apps/reports-dashboard/**"]}
      ]
    }
  ]
}
EOF

CONFIG_3SLICE_PLUS_GHOST="$WORK/monorepo-config-3slice-plus-ghost.json"
cat > "$CONFIG_3SLICE_PLUS_GHOST" <<'EOF'
{
  "version": "1.0",
  "monorepos": [
    {
      "url": "https://example.com/acme/big-monorepo",
      "type": "internal-repo",
      "slices": [
        {"id": "billing", "paths": ["packages/billing/**", "shared/billing-types/**"]},
        {"id": "auth",    "paths": ["packages/auth/**"]},
        {"id": "reports", "paths": ["apps/reports-dashboard/**"]},
        {"id": "ghost",   "paths": ["packages/nowhere/**"]}
      ]
    }
  ]
}
EOF

# ===========================================================================
# Fixture 2 — must-reject: a fully independent repository/commit (not the
# same commit read two ways), where the only changed files sit outside
# every declared slice's patterns. A script that answers "changed" too
# eagerly — e.g. by actually comparing whole-repo state rather than
# per-slice paths — must fail this fixture's assertions.
# ===========================================================================
UP2="$WORK/upstream2"
init_upstream "$UP2"
mkdir -p "$UP2/packages/billing" "$UP2/shared/billing-types" \
  "$UP2/packages/auth" "$UP2/apps/reports-dashboard" "$UP2/tools"
printf '1\n' > "$UP2/packages/billing/x.py"
printf '1\n' > "$UP2/shared/billing-types/y.py"
printf '1\n' > "$UP2/packages/auth/z.py"
printf '1\n' > "$UP2/apps/reports-dashboard/w.js"
printf '1\n' > "$UP2/tools/misc.py"
printf '1\n' > "$UP2/README.md"
SHA_A2="$(commit_all "$UP2" "commit A")"

CACHE2="$WORK/cache2"
seed_shallow_cache "$UP2" "$CACHE2"

printf '2\n' > "$UP2/tools/misc.py"
printf '2\n' > "$UP2/README.md"
SHA_B2="$(commit_all "$UP2" "commit B")"

advance_cache_inplace "$CACHE2" "$UP2" "$SHA_B2"

# ===========================================================================
# Fixture 3 — pathspec semantics: a slice pattern `packages/billing` (bare,
# no /** suffix) plus a sibling `packages/billing-legacy/`. The one commit
# changes a file under BOTH the slice's own subtree and the sibling. This
# single fixture rejects two wrong implementations at once:
#   - naive fnmatch (no subtree semantics for a bare directory pattern)
#     would miss packages/billing/sub/x.py entirely -> changed_paths == []
#   - naive string-prefix matching would ALSO catch
#     packages/billing-legacy/b.py (it does start with "packages/billing")
#     -> changed_paths would carry two entries instead of one
# Correct gitignore/sparse-checkout pathspec semantics reports exactly the
# one file under the slice's own subtree.
# ===========================================================================
UP3="$WORK/upstream3"
init_upstream "$UP3"
mkdir -p "$UP3/packages/billing/sub" "$UP3/packages/billing-legacy"
printf '1\n' > "$UP3/packages/billing/a.py"
printf '1\n' > "$UP3/packages/billing/sub/x.py"
printf '1\n' > "$UP3/packages/billing-legacy/b.py"
SHA_A3="$(commit_all "$UP3" "commit A")"

CACHE3="$WORK/cache3"
seed_shallow_cache "$UP3" "$CACHE3"

printf '2\n' > "$UP3/packages/billing/sub/x.py"
printf '2\n' > "$UP3/packages/billing-legacy/b.py"
SHA_B3="$(commit_all "$UP3" "commit B")"

advance_cache_inplace "$CACHE3" "$UP3" "$SHA_B3"

CONFIG_PATHSPEC="$WORK/monorepo-config-pathspec.json"
cat > "$CONFIG_PATHSPEC" <<'EOF'
{
  "version": "1.0",
  "monorepos": [
    {
      "url": "https://example.com/acme/mono-pathspec",
      "type": "internal-repo",
      "slices": [
        {"id": "billing", "paths": ["packages/billing"]}
      ]
    }
  ]
}
EOF

# ===========================================================================
# Fixture 4 — pathspec semantics: a slice pattern `packages/widgets/*` (bare
# single star, one path segment) where the changed-file set includes one
# file directly under that directory AND one file nested one level deeper
# under a subdirectory of it. Per the frozen contract, a bare `*` matches
# within a single path segment and does NOT cross a path separator the way
# `**` does — only the direct child is a match.
#   - an implementation that treats a single `*` the same as `**` (lets `*`
#     cross directory separators, e.g. by translating the pattern to a
#     regex that maps `*` to `.*` instead of `[^/]*`) would incorrectly
#     ALSO match packages/widgets/inner/deep.py, growing changed_paths to
#     two entries instead of one
# Correct sparse-checkout pathspec semantics reports only the direct child.
# ===========================================================================
UP4="$WORK/upstream4"
init_upstream "$UP4"
mkdir -p "$UP4/packages/widgets/inner"
printf '1\n' > "$UP4/packages/widgets/top.py"
printf '1\n' > "$UP4/packages/widgets/inner/deep.py"
SHA_A4="$(commit_all "$UP4" "commit A")"

CACHE4="$WORK/cache4"
seed_shallow_cache "$UP4" "$CACHE4"

printf '2\n' > "$UP4/packages/widgets/top.py"
printf '2\n' > "$UP4/packages/widgets/inner/deep.py"
SHA_B4="$(commit_all "$UP4" "commit B")"

advance_cache_inplace "$CACHE4" "$UP4" "$SHA_B4"

CONFIG_STAR="$WORK/monorepo-config-star.json"
cat > "$CONFIG_STAR" <<'EOF'
{
  "version": "1.0",
  "monorepos": [
    {
      "url": "https://example.com/acme/mono-star",
      "type": "internal-repo",
      "slices": [
        {"id": "widgets", "paths": ["packages/widgets/*"]}
      ]
    }
  ]
}
EOF

# ===========================================================================
# Fixture self-checks — this file's own git plumbing, not the feature.
# Expected to PASS today; a failure here is a bug in this oracle's fixture
# construction, not evidence about slice_drift.py.
# ===========================================================================
section "fixture self-checks (this oracle's own plumbing, not the feature)"

if both_resolvable "$CACHE1" "$SHA_A1" "$SHA_B1" \
  && both_resolvable "$CACHE2" "$SHA_A2" "$SHA_B2" \
  && both_resolvable "$CACHE3" "$SHA_A3" "$SHA_B3"; then
  pass "fixture_both_shas_resolvable_in_each_shallow_cache"
else
  fail "fixture_both_shas_resolvable_in_each_shallow_cache" \
    "one or more cache directories do not resolve both their old and new SHA"
fi

fx1_diff="$(git -C "$CACHE1" diff --name-only "$SHA_A1" "$SHA_B1" | LC_ALL=C sort | tr '\n' ',')"
if [ "$fx1_diff" = "packages/billing/a.py,shared/billing-types/t.py," ]; then
  pass "fixture_one_slice_repo_diff_matches_intended_change_set"
else
  fail "fixture_one_slice_repo_diff_matches_intended_change_set" "got: $fx1_diff"
fi

fx2_diff="$(git -C "$CACHE2" diff --name-only "$SHA_A2" "$SHA_B2" | LC_ALL=C sort | tr '\n' ',')"
if [ "$fx2_diff" = "README.md,tools/misc.py," ]; then
  pass "fixture_unrelated_commit_repo_diff_matches_intended_change_set"
else
  fail "fixture_unrelated_commit_repo_diff_matches_intended_change_set" "got: $fx2_diff"
fi

fx3_diff="$(git -C "$CACHE3" diff --name-only "$SHA_A3" "$SHA_B3" | LC_ALL=C sort | tr '\n' ',')"
if [ "$fx3_diff" = "packages/billing-legacy/b.py,packages/billing/sub/x.py," ]; then
  pass "fixture_pathspec_repo_diff_matches_intended_change_set"
else
  fail "fixture_pathspec_repo_diff_matches_intended_change_set" "got: $fx3_diff"
fi

if jq_check "$(cat "$CONFIG_3SLICE")" '(.monorepos[0].slices | length) == 3' \
  && jq_check "$(cat "$CONFIG_PATHSPEC")" '(.monorepos[0].slices | length) == 1'; then
  pass "fixture_monorepo_config_files_are_valid_json_with_expected_slice_counts"
else
  fail "fixture_monorepo_config_files_are_valid_json_with_expected_slice_counts"
fi

# ===========================================================================
# Feature assertions — expected to FAIL right now (slice_drift.py absent).
# ===========================================================================
section "one object per declared slice, looked up by slice_id, not by array order"

OUT1="$(sd_out "$CACHE1" --old "$SHA_A1" --new "$SHA_B1" --config "$CONFIG_3SLICE")"
RC1=$?

if [ "$RC1" -eq 0 ] && jq_check "$OUT1" \
  '(type=="array") and (length==3) and ((map(.slice_id)|sort)==["auth","billing","reports"])'; then
  pass "every_declared_slice_gets_exactly_one_object_ids_and_count_match"
else
  fail "every_declared_slice_gets_exactly_one_object_ids_and_count_match" \
    "rc=$RC1" "stdout: $OUT1"
fi

section "must-accept: the one slice whose paths were touched reports changed:true with the exact changed file set"

if [ "$RC1" -eq 0 ] && jq_check "$OUT1" '
    (map(select(.slice_id=="billing"))[0]) as $b
    | ($b.changed == true)
    and (($b.changed|type) == "boolean")
    and ($b.changed_paths == ["packages/billing/a.py","shared/billing-types/t.py"])
  '; then
  pass "changed_slice_reports_true_with_exact_sorted_changed_paths_across_both_its_patterns"
else
  fail "changed_slice_reports_true_with_exact_sorted_changed_paths_across_both_its_patterns" \
    "rc=$RC1" "stdout: $OUT1"
fi

if [ "$RC1" -eq 0 ] && jq_check "$OUT1" '
    (map(select(.slice_id=="auth"))[0]) as $a
    | ($a.changed == false) and (($a.changed|type) == "boolean") and ($a.changed_paths == [])
  ' && jq_check "$OUT1" '
    (map(select(.slice_id=="reports"))[0]) as $r
    | ($r.changed == false) and ($r.changed_paths == [])
  '; then
  pass "untouched_sibling_slices_report_false_with_empty_changed_paths"
else
  fail "untouched_sibling_slices_report_false_with_empty_changed_paths" "rc=$RC1" "stdout: $OUT1"
fi

section "must-reject: a commit touching only out-of-scope files reports every slice unchanged"

OUT2="$(sd_out "$CACHE2" --old "$SHA_A2" --new "$SHA_B2" --config "$CONFIG_3SLICE")"
RC2=$?

# This is the must-reject input named in the frozen contract: a script that
# answers "changed" too eagerly — e.g. because it actually compares
# whole-repo state rather than per-slice paths — must fail this assertion.
if [ "$RC2" -eq 0 ] && jq_check "$OUT2" '
    (type=="array") and (length==3)
    and (all(.[]; .changed == false))
    and (all(.[]; .changed_paths == []))
  '; then
  pass "must_reject_unrelated_commit_reports_every_slice_unchanged"
else
  fail "must_reject_unrelated_commit_reports_every_slice_unchanged" "rc=$RC2" "stdout: $OUT2"
fi

section "pathspec semantics: gitignore/sparse-checkout matching, not fnmatch or string-prefix matching"

OUT3="$(sd_out "$CACHE3" --old "$SHA_A3" --new "$SHA_B3" --config "$CONFIG_PATHSPEC")"
RC3=$?

if [ "$RC3" -eq 0 ] && jq_check "$OUT3" '
    (type=="array") and (length==1)
    and (.[0].slice_id == "billing")
    and (.[0].changed == true)
    and (.[0].changed_paths == ["packages/billing/sub/x.py"])
  '; then
  pass "pathspec_bare_directory_matches_own_subtree_but_not_a_prefix_sharing_sibling"
else
  fail "pathspec_bare_directory_matches_own_subtree_but_not_a_prefix_sharing_sibling" \
    "rc=$RC3" "stdout: $OUT3" \
    "a naive fnmatch would report changed_paths==[] here (bare pattern, no subtree rule);" \
    "a naive string-prefix match would additionally include packages/billing-legacy/b.py"
fi

section "pathspec semantics: a bare single * matches one path segment and does not cross a path separator the way ** does"

OUT4="$(sd_out "$CACHE4" --old "$SHA_A4" --new "$SHA_B4" --config "$CONFIG_STAR")"
RC4=$?

if [ "$RC4" -eq 0 ] && jq_check "$OUT4" '
    (type=="array") and (length==1)
    and (.[0].slice_id == "widgets")
    and (.[0].changed == true)
    and (.[0].changed_paths == ["packages/widgets/top.py"])
  '; then
  pass "pathspec_single_star_does_not_cross_a_path_separator"
else
  fail "pathspec_single_star_does_not_cross_a_path_separator" \
    "rc=$RC4" "stdout: $OUT4" \
    "an implementation that treats a single * the same as ** (letting * cross" \
    "a path separator) would additionally include packages/widgets/inner/deep.py" \
    "in changed_paths alongside packages/widgets/top.py"
fi

section "a slice whose patterns match nothing in either tree"

OUT1G="$(sd_out "$CACHE1" --old "$SHA_A1" --new "$SHA_B1" --config "$CONFIG_3SLICE_PLUS_GHOST")"
RC1G=$?

if [ "$RC1G" -eq 0 ] && jq_check "$OUT1G" \
  '(length==4) and ((map(.slice_id)|sort)==["auth","billing","ghost","reports"])'; then
  pass "empty_match_slice_still_gets_its_own_object_alongside_the_others"
else
  fail "empty_match_slice_still_gets_its_own_object_alongside_the_others" "rc=$RC1G" "stdout: $OUT1G"
fi

if [ "$RC1G" -eq 0 ] && jq_check "$OUT1G" '
    (map(select(.slice_id=="ghost"))[0]) as $g
    | ($g.changed == false)
    and ($g.changed_paths == [])
    and (($g.notice|type) == "string")
    and (($g.notice|length) > 0)
    and ($g.notice | test("ghost"; "i"))
  '; then
  pass "empty_match_slice_reports_unchanged_empty_changed_paths_and_a_notice_naming_itself"
else
  fail "empty_match_slice_reports_unchanged_empty_changed_paths_and_a_notice_naming_itself" \
    "rc=$RC1G" "stdout: $OUT1G"
fi

section "stdlib-only imports"

if [ -f "$SLICE_DRIFT_PY" ]; then
  non_stdlib="$(python3 - "$SLICE_DRIFT_PY" <<'PYEOF'
import ast, sys
path = sys.argv[1]
tree = ast.parse(open(path, encoding="utf-8").read(), filename=path)
stdlib = getattr(sys, "stdlib_module_names", None)
if stdlib is None:
    stdlib = {"argparse", "json", "os", "re", "subprocess", "sys", "pathlib",
               "fnmatch", "itertools", "functools", "collections", "dataclasses"}
mods = set()
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        for alias in node.names:
            mods.add(alias.name.split(".")[0])
    elif isinstance(node, ast.ImportFrom):
        if node.module is not None and node.level == 0:
            mods.add(node.module.split(".")[0])
mods.discard("__future__")
print("\n".join(sorted(m for m in mods if m not in stdlib)))
PYEOF
)"
  if [ -z "$non_stdlib" ]; then
    pass "stdlib_only_imports"
  else
    fail "stdlib_only_imports" "non-stdlib imports: $non_stdlib"
  fi
else
  fail "stdlib_only_imports" "slice_drift.py does not exist yet"
fi

section "git verbs limited to the read-only allow-list"

# See design decision 9 in the header for why this is a bespoke scan
# rather than tests/lib/git_verb_scan.sh.
if [ -f "$SLICE_DRIFT_PY" ]; then
  verb_result="$(python3 - "$SLICE_DRIFT_PY" <<'PYEOF'
import ast, re, sys
path = sys.argv[1]
src = open(path, encoding="utf-8").read()
tree = ast.parse(src, filename=path)

READONLY = {"diff", "status", "log", "show", "clone", "ls-remote",
            "ls-tree", "ls-files", "rev-parse", "cat-file"}
INVOKERS = {"run", "call", "check_output", "check_call", "Popen", "system", "popen"}

bad = []
seen = [False]

def verb_from_tokens(toks):
    i = 0
    while i < len(toks):
        t = toks[i]
        if t in ("-C", "-c"):
            i += 2
            continue
        if t.startswith("-"):
            i += 1
            continue
        return t
    return None

def note(verb, where):
    if verb is None:
        return
    seen[0] = True
    if verb not in READONLY:
        bad.append(verb + " (" + where + ")")

class V(ast.NodeVisitor):
    def _seq(self, node):
        elts = node.elts
        if elts and isinstance(elts[0], ast.Constant) and elts[0].value == "git":
            # Keep every element's POSITION even when its value isn't a
            # string literal (an f-string, a variable, a subscript...) —
            # collapsing to only the string constants first would let a
            # non-literal argument silently absorb the slot before it
            # (e.g. `["git", "-C", cache_dir, "diff", ...]` would drop to
            # `["-C", "diff"]`, and "-C" would then wrongly consume "diff"
            # as ITS value, hiding the real verb entirely). A placeholder
            # landing in the verb slot itself is statically unknowable and
            # is treated as a violation below, not given a free pass.
            toks = [e.value if (isinstance(e, ast.Constant) and isinstance(e.value, str))
                    else "<expr>"
                    for e in elts[1:]]
            note(verb_from_tokens(toks), "argv")

    def visit_List(self, node):
        self._seq(node)
        self.generic_visit(node)

    def visit_Tuple(self, node):
        self._seq(node)
        self.generic_visit(node)

    def visit_Call(self, node):
        fname = None
        if isinstance(node.func, ast.Attribute):
            fname = node.func.attr
        elif isinstance(node.func, ast.Name):
            fname = node.func.id
        if fname in INVOKERS:
            for arg in list(node.args) + [kw.value for kw in node.keywords]:
                if isinstance(arg, ast.Constant) and isinstance(arg.value, str):
                    m = re.search(
                        r'git\s+((?:-C\s+\S+\s+|-c\s+\S+\s+|--\S+(?:=\S+)?\s+)*)([a-zA-Z][a-zA-Z-]*)',
                        arg.value)
                    if m:
                        note(m.group(2), "shell-string")
        self.generic_visit(node)

V().visit(tree)

if bad:
    print("BAD:" + ",".join(sorted(set(bad))))
elif seen[0]:
    print("OK")
else:
    print("NONE")
PYEOF
)"
  case "$verb_result" in
    BAD:*)
      fail "git_verbs_limited_to_read_only_allow_list" \
        "non-read-only git verb(s) detected: ${verb_result#BAD:}" ;;
    OK | NONE)
      pass "git_verbs_limited_to_read_only_allow_list" ;;
    *)
      fail "git_verbs_limited_to_read_only_allow_list" "scanner produced unexpected output: $verb_result" ;;
  esac
else
  pass "git_verbs_limited_to_read_only_allow_list (vacuous: slice_drift.py does not exist yet, so it invokes no git verb)"
fi

section "read-only against the cache"

# Vacuously true today, same convention as tests/cited-paths/run.sh's own
# read-only check: a script that does not exist writes nothing either. This does not prove the finished script is read-only; it proves
# only that its current absence isn't a counterexample.
fp_before="$(dir_fingerprint "$CACHE1")"
sd_out "$CACHE1" --old "$SHA_A1" --new "$SHA_B1" --config "$CONFIG_3SLICE" > /dev/null 2>&1
fp_after="$(dir_fingerprint "$CACHE1")"
if [ "$fp_before" = "$fp_after" ]; then
  pass "read_only_against_cache_fingerprint_unchanged"
else
  fail "read_only_against_cache_fingerprint_unchanged" "cache directory content changed after invocation"
fi

section "an unresolvable SHA exits non-zero with a named error"

OLD_BOGUS="$(repeat_hex "de" 20)"
NEW_BOGUS="$(repeat_hex "be" 20)"

err_old="$(sd_err "$CACHE1" --old "$OLD_BOGUS" --new "$SHA_B1" --config "$CONFIG_3SLICE")"
rc_old=$?
if [ "$rc_old" -ne 0 ] && printf '%s' "$err_old" | grep -qF "$OLD_BOGUS"; then
  pass "unresolvable_old_sha_named_error"
else
  fail "unresolvable_old_sha_named_error" "rc=$rc_old" "stderr: $err_old"
fi

err_new="$(sd_err "$CACHE1" --old "$SHA_A1" --new "$NEW_BOGUS" --config "$CONFIG_3SLICE")"
rc_new=$?
if [ "$rc_new" -ne 0 ] && printf '%s' "$err_new" | grep -qF "$NEW_BOGUS"; then
  pass "unresolvable_new_sha_named_error"
else
  fail "unresolvable_new_sha_named_error" "rc=$rc_new" "stderr: $err_new"
fi

# ===========================================================================
# Documentation assertions — expected to FAIL right now: the current file
# predates this script and names it nowhere.
# ===========================================================================
section "drift-detection-and-phases.md documents this script's role (expected RED today)"

DRIFT_TEXT="$(norm_file "$DRIFT_PHASES")"

if near_all "$DRIFT_TEXT" 'slice_drift(\.py)?' 250 '(decid|determin|report|says|answer)' 'parent'; then
  pass "drift_doc_names_slice_drift_as_the_per_slice_decider"
else
  fail "drift_doc_names_slice_drift_as_the_per_slice_decider" \
    "expected slice_drift(.py) (or an equivalent unambiguous reference) documented near 'drift' and 'parent'"
fi

if near_all "$DRIFT_TEXT" 'slice_drift(\.py)?' 250 \
  '(unchanged|changed.{0,10}false|reports?.{0,20}(no|un)changed)' \
  '(skip|omit|not.{0,20}(re-?read|crawl))' \
  'Phase 2'; then
  pass "drift_doc_states_unchanged_slice_skips_phase_2_this_run"
else
  fail "drift_doc_states_unchanged_slice_skips_phase_2_this_run" \
    "expected slice_drift(.py) documented near an unchanged/skip/Phase 2 phrase"
fi

if near "$DRIFT_TEXT" 'gh api commits\?path=' 'optional|fast.path' 200 \
  && ! near "$DRIFT_TEXT" 'gh api commits\?path=' 'must|required|mandatory|only way' 200; then
  pass "drift_doc_gh_api_commits_path_named_optional_never_mandatory"
else
  fail "drift_doc_gh_api_commits_path_named_optional_never_mandatory" \
    "expected 'gh api commits?path=' documented as an optional/fast-path form, never as mandatory/required/the only way"
fi

# ===========================================================================
# Preservation assertions — REQUIRED. Expected to PASS right now: these
# properties already hold in the current, shipped files; this chunk must
# not delete them while adding the documentation above. Named for the
# behavior each protects, never by an ordinal.
# ===========================================================================
section "preservation: pre-existing prose this chunk must not disturb"

if printf '%s' "$DRIFT_TEXT" | grep -qiE 'candidate set.{0,200}before.{0,200}re-(read|emit)|before.{0,200}re-(read|emit).{0,200}candidate set'; then
  pass "preservation_candidate_set_precedes_reread_language_intact"
else
  fail "preservation_candidate_set_precedes_reread_language_intact" \
    "expected pre-existing 'candidate set ... before re-read/re-emit' language in drift-detection-and-phases.md"
fi

if printf '%s' "$DRIFT_TEXT" | grep -qiE 'candidate.{0,250}uncited|uncited.{0,250}candidate'; then
  pass "preservation_candidate_uncited_language_intact"
else
  fail "preservation_candidate_uncited_language_intact" \
    "expected pre-existing candidate/uncited language in drift-detection-and-phases.md"
fi

if printf '%s' "$DRIFT_TEXT" | grep -qiE 'non-candidate.{0,250}reason|reason.{0,250}non-candidate'; then
  pass "preservation_non_candidate_reason_language_intact"
else
  fail "preservation_non_candidate_reason_language_intact" \
    "expected pre-existing non-candidate/reason language in drift-detection-and-phases.md"
fi

EXCLUDE_RE='(exclud|skip|omit|not.{0,20}(re-?read|crawl)|removed from|no whole.tree)'
COUNT_RE='(<N>|<[a-z]*count[a-z]*>|[0-9]+ slices?|slice count|count of slices)'

if near_all "$DRIFT_TEXT" '(parent|slice_of)' 250 "$EXCLUDE_RE" 'slice'; then
  pass "preservation_parent_exclusion_near_slice_language_intact_in_drift_phases"
else
  fail "preservation_parent_exclusion_near_slice_language_intact_in_drift_phases" \
    "expected exclusion language near 'parent'/'slice_of' and 'slice' in drift-detection-and-phases.md"
fi

if near_all "$DRIFT_TEXT" 'slice' 250 '(parent|slice_of)' '(one.line|summary)' "$COUNT_RE"; then
  pass "preservation_parent_slice_summary_count_language_intact_in_drift_phases"
else
  fail "preservation_parent_slice_summary_count_language_intact_in_drift_phases" \
    "expected a one-line/summary phrase with a count placeholder, documented near 'slice' and 'parent'/'slice_of'"
fi

CACHE_TEXT="$(norm_file "$CACHE_AND_CLONE")"

if near_all "$CACHE_TEXT" '(parent|slice_of)' 250 "$EXCLUDE_RE" 'slice'; then
  pass "preservation_parent_exclusion_near_slice_language_intact_in_cache_and_clone"
else
  fail "preservation_parent_exclusion_near_slice_language_intact_in_cache_and_clone" \
    "expected exclusion language near 'parent'/'slice_of' and 'slice' in cache-and-clone.md"
fi

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"

[ "$fail_count" -eq 0 ]
