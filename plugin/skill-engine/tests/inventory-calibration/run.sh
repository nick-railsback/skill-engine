#!/usr/bin/env bash
# Feature-scoped test runner calibrating discover_inventory.py's corpus-shape
# inventory (and the pre-flight step in cache-and-clone.md that drives its
# no-local-cache path) to sources whose scale breaks today's fixed
# assumptions: a directory-rollup depth hard-capped at 3 segments that
# collapses a multi-module tree into a handful of buckets, a --tree-json
# input mode that discards the upstream tree API's truncation flag, and a
# since-last-check computation that walks a connected commit range and
# cannot succeed against two commits with no shared history (the shape a
# shallow, advance-in-place cache holds).
#
# This suite locks down, in fully black-box terms — CLI invocation, stdout
# JSON, and cache-and-clone.md's prose/jq, never internal function names or
# data structures a correct implementation is free to choose:
#
#   - the directory rollup adapts to the tree instead of staying flat at a
#     fixed depth, on a synthetic multi-module Java-shaped corpus;
#   - existing callers see no behavior change: the already-shipped
#     discover-preflight-inventory suite stays green, unmodified, and a
#     shallow (no directory deeper than two segments) tree's
#     file_counts_by_dir is unaffected;
#   - a --tree-json input can now carry a top-level truncation flag, which
#     surfaces as partial:true plus a human-readable notice, while the old
#     bare-JSON-array input shape (and the "no truncation information
#     available" case) keeps working exactly as before;
#   - the output names which computation path produced it — a local
#     directory walk vs. a --tree-json listing — and cache-and-clone.md's
#     jq for the no-local-cache path is updated to match;
#   - the since-last-check computation succeeds against two commits with no
#     connecting history (what an in-place-advanced shallow clone holds),
#     not only against a normal connected git-log range;
#   - a separate, unrelated input path (--since-json, a verbatim
#     passthrough already relied on elsewhere) is untouched by any of the
#     above;
#   - the script stays stdlib-only, shells out to git alone (never to a
#     network-capable git verb), writes nothing outside its own stdout, and
#     its CLI keeps every argument a pinned prior version of the script
#     declared.
#
# Fixture style matches the sibling suites this reuses idioms from: small
# synthetic trees and real throwaway local git repositories built under
# mktemp, with expected values computed by direct arithmetic on the
# fixture as built, never by re-deriving what the script itself computes.
#
# The pinned SHA below names a real commit in this repository's history,
# not a build artifact of this suite, so `git show <sha>:<path>` resolves
# in any clone with full history. It is a literal, not a value read from
# any untracked planning file, so this suite carries no dangling reference
# in a fresh clone.
#
# Every section below that depends on resolving that pinned baseline gates
# on one up-front extraction and fails loudly — never silently skips —
# when it can't be resolved locally.
#
# Most sections here are expected to fail against the current, unmodified
# script and prose: the rollup is still flat, --tree-json still only
# accepts a bare array, there is no inventory_source field, and
# since-last-check is still a connected git-log walk. The
# already-shipped-behavior sections — the frozen sibling suite, the
# flat-tree comparison, --since-json passthrough, stdlib/no-network/
# no-writes, and the current CLI surface — are expected to pass; that is
# the correct, unchanged behavior this suite also has to protect.
#
# -e is intentionally omitted: every assertion runs and reports, not abort
# at the first red one. Every tmpdir this file creates is removed on exit.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
INV_SCRIPT="$PLUGIN_ROOT/tests/discover_inventory.py"
CACHE_AND_CLONE="$PLUGIN_ROOT/skills/discover/references/cache-and-clone.md"
FROZEN_PREFLIGHT_ORACLE="$PLUGIN_ROOT/tests/discover-preflight-inventory/run.sh"

# A real, already-merged commit in this repository's own history — not a
# pointer into any untracked planning tree. See the header comment above.
BASELINE_SHA="04d15201d5d44da79b19644619cc8842b85b0a91"

pass_count=0
fail_count=0

TMPROOT="$(mktemp -d -t skill-engine-inventory-calibration.XXXXXX)"
cleanup() { rm -rf "$TMPROOT"; }
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

# run_inventory [args...] — invokes the script under test and echoes its
# stdout; stderr is discarded. Every check below independently requires
# valid, specific JSON content, so a crash or bad-arg exit always reads as
# a failure for the right reason rather than a vacuous pass.
run_inventory() {
  python3 "$INV_SCRIPT" "$@" 2>/dev/null
}

# jq_check <json> <jq-boolean-program> [--arg name value ...] — true (rc 0)
# only when the input is valid JSON AND the boolean program evaluates true.
jq_check() {
  local json="$1" program="$2"
  shift 2
  printf '%s' "$json" | jq -e "$@" "$program" >/dev/null 2>&1
}

sha256_of_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# dir_fingerprint <dir> — content fingerprint (path + sha256) of every
# regular file under <dir>, .git/ internals included. Used to prove a
# computation touched nothing on disk: the tempting-but-wrong fix for
# disconnected shallow history is reaching for `git fetch --unshallow` or
# `--deepen` to make a log-range walk work again, and that would leave a
# trace here even though it might still produce a plausible-looking answer.
dir_fingerprint() {
  local dir="$1"
  if [ ! -d "$dir" ]; then
    echo "MISSING"
    return
  fi
  ( cd "$dir" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s ' "$f"
      sha256_of_file "$f"
    done ) | { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } | awk '{print $1}'
}

# ---- pinned-baseline extraction, up front, shared by every section below
# that needs "what did this script look like before" -----------------------

BASELINE_OK=false
baseline_script="$TMPROOT/baseline_discover_inventory.py"
baseline_err="$TMPROOT/baseline-git-err.txt"
if git -C "$REPO_ROOT" show "$BASELINE_SHA:plugin/skill-engine/tests/discover_inventory.py" \
     > "$baseline_script" 2>"$baseline_err"; then
  BASELINE_OK=true
fi
BASELINE_UNAVAILABLE_REASON="cannot evaluate — pinned baseline $BASELINE_SHA did not resolve locally: $(cat "$baseline_err" 2>/dev/null)"

section "pinned baseline resolves locally"
if $BASELINE_OK; then
  pass "git show $BASELINE_SHA:plugin/skill-engine/tests/discover_inventory.py resolves in this checkout"
else
  fail "git show $BASELINE_SHA:plugin/skill-engine/tests/discover_inventory.py resolves in this checkout" \
    "$(cat "$baseline_err" 2>/dev/null)"
fi

# ============================================================================
# Adaptive rollup depth on a five-module x four-layer Java layout
# ============================================================================
section "adaptive rollup depth on a five-module x four-layer Java layout"

# 5 modules x 4 layers x 6 classes under src/main/java/com/acme, mirrored
# 1:1 under src/test/java/com/acme, 40 migrations under
# src/main/resources/db/migration, plus pom.xml and README.md at the root:
# 282 files total. Today's fixed depth-3 rollup collapses every one of the
# 20 module/layer directories under src/main/java into the single bucket
# "src/main/java" (count 120) — the fixture is built independently of the
# script under test so this is provable by direct construction, not by
# trusting the script's own arithmetic.
build_java_fixture() {
  local root="$1"
  local modules=(billing ledger auth catalog shipping)
  local layers=(controller service repository model)
  local m l c
  for m in "${modules[@]}"; do
    for l in "${layers[@]}"; do
      mkdir -p "$root/src/main/java/com/acme/$m/$l"
      mkdir -p "$root/src/test/java/com/acme/$m/$l"
      for c in 1 2 3 4 5 6; do
        printf 'package com.acme.%s.%s;\npublic class Entity%d {}\n' "$m" "$l" "$c" \
          > "$root/src/main/java/com/acme/$m/$l/Entity${c}.java"
        printf 'package com.acme.%s.%s;\npublic class Entity%dTest {}\n' "$m" "$l" "$c" \
          > "$root/src/test/java/com/acme/$m/$l/Entity${c}Test.java"
      done
    done
  done
  mkdir -p "$root/src/main/resources/db/migration"
  local i
  for i in $(seq -w 1 40); do
    printf -- '-- migration %s\n' "$i" > "$root/src/main/resources/db/migration/V${i}__change.sql"
  done
  printf '<project/>\n' > "$root/pom.xml"
  printf '# acme\n' > "$root/README.md"
}

java_root="$TMPROOT/java-fixture"
mkdir -p "$java_root"
build_java_fixture "$java_root"

java_fixture_count="$(find "$java_root" -type f | wc -l | tr -d ' ')"
if [ "$java_fixture_count" -eq 282 ]; then
  pass "fixture self-check: the built tree has exactly 282 files"
else
  fail "fixture self-check: the built tree has exactly 282 files" "found: $java_fixture_count"
fi

java_out="$(run_inventory "$java_root")"

# At least 20 distinct directories reported under src/main/java (never
# collapsed to the single bucket "src/main/java"), each with its own
# positive count. Deliberately agnostic about WHERE exactly the rollup
# lands (module/layer vs. some other adaptive boundary) — only the count
# and non-degeneracy are pinned, matching the "at least twenty" wording
# this fixture is built to satisfy.
if jq_check "$java_out" '
    ([.file_counts_by_dir | to_entries[] | select(.key | startswith("src/main/java"))] | length) >= 20
    and ([.file_counts_by_dir | to_entries[] | select(.key | startswith("src/main/java")) | .value] | all(. > 0))
'; then
  pass "at least 20 distinct directories are reported under src/main/java, each with a positive count"
else
  fail "at least 20 distinct directories are reported under src/main/java, each with a positive count" "$java_out"
fi

# Conservation, not shape: the src/main/java subtree's counts sum to 120
# (5*4*6) and the whole tree's counts sum to 282 — catches double-counting
# or silently dropped files that a bare key-count assertion would miss.
if jq_check "$java_out" '
    ([.file_counts_by_dir | to_entries[] | select(.key | startswith("src/main/java")) | .value] | add) == 120
    and ([.file_counts_by_dir | to_entries[] | .value] | add) == 282
'; then
  pass "file counts conserve: the src/main/java subtree sums to 120, the whole tree sums to 282"
else
  fail "file counts conserve: the src/main/java subtree sums to 120, the whole tree sums to 282" "$java_out"
fi

# ============================================================================
# Preserved output: the already-shipped suite, and a flat tree unaffected
# ============================================================================
section "preserved output on a flat tree, and the already-shipped suite stays green"

# "Byte-identical" is checked as key-order-normalized JSON equality (jq -S
# -c on both sides) rather than a literal diff of raw stdout. Nothing in
# this script or its frozen sibling oracle commits to a key-insertion-order
# guarantee for file_counts_by_dir (it is built by iterating os.walk
# results, whose directory-entry order is not itself pinned), so a literal
# byte comparison would incidentally freeze an ordering guarantee nobody
# asked for. Key-order-normalized equality is the strictest check that
# doesn't do that.
flat_root="$TMPROOT/flat-fixture"
mkdir -p "$flat_root/a/b"
printf 'x' > "$flat_root/top.txt"
printf 'y' > "$flat_root/a/one.txt"
printf 'z' > "$flat_root/a/b/two.txt"

if ! $BASELINE_OK; then
  fail "a flat tree (no directory deeper than two segments) produces file_counts_by_dir matching the pinned baseline" \
    "$BASELINE_UNAVAILABLE_REASON"
else
  new_out="$(run_inventory "$flat_root")"
  old_out="$(python3 "$baseline_script" "$flat_root" 2>/dev/null)"
  new_counts="$(printf '%s' "$new_out" | jq -S -c '.file_counts_by_dir' 2>/dev/null)"
  old_counts="$(printf '%s' "$old_out" | jq -S -c '.file_counts_by_dir' 2>/dev/null)"

  if [ -n "$new_counts" ] && [ "$new_counts" = "$old_counts" ]; then
    pass "a flat tree (no directory deeper than two segments) produces file_counts_by_dir matching the pinned baseline"
  else
    fail "a flat tree (no directory deeper than two segments) produces file_counts_by_dir matching the pinned baseline" \
      "baseline: ${old_counts:-<empty>}" "current: ${new_counts:-<empty>}"
  fi
fi

if bash "$FROZEN_PREFLIGHT_ORACLE" >/dev/null 2>&1; then
  pass "the already-shipped preflight-inventory suite stays green, unmodified"
else
  fail "the already-shipped preflight-inventory suite stays green, unmodified"
fi

# ============================================================================
# Truncation signal on --tree-json input, old bare-array shape still works
# ============================================================================
section "truncation signal on --tree-json input, old bare-array shape still works"

# Design decision: the new --tree-json envelope is a top-level JSON object
# {"truncated": bool, "tree": [...entries...]}, mirroring the shape the
# real upstream tree API itself returns (a top-level object carrying
# "tree" and "truncated" alongside it) — the caller's own jq today
# discards exactly that envelope down to a bare `[.tree[] | ...]` array,
# which is the behavior this fixes. The old bare-array shape (no envelope
# at all) must keep parsing exactly as it does today: nothing may break an
# existing --tree-json caller or fixture, and there is no way to detect
# truncation from a bare array, so it reads as partial:false.
tree_entries_min='[
  {"path": "a.txt", "bytes": 10, "type": "blob"},
  {"path": "dir", "bytes": 0, "type": "tree"},
  {"path": "dir/b.txt", "bytes": 20, "type": "blob"}
]'

truncated_true_json="$TMPROOT/tree-truncated-true.json"
printf '{"truncated": true, "tree": %s}\n' "$tree_entries_min" > "$truncated_true_json"

truncated_false_json="$TMPROOT/tree-truncated-false.json"
printf '{"truncated": false, "tree": %s}\n' "$tree_entries_min" > "$truncated_false_json"

truncated_absent_json="$TMPROOT/tree-truncated-absent.json"
printf '{"tree": %s}\n' "$tree_entries_min" > "$truncated_absent_json"

bare_array_json="$TMPROOT/tree-bare-array.json"
printf '%s\n' "$tree_entries_min" > "$bare_array_json"

true_out="$(run_inventory --tree-json "$truncated_true_json")"
if jq_check "$true_out" '
    .partial == true
    and (.notice | type == "string")
    and (.notice | length > 0)
    and (.notice | test("truncat"; "i"))
'; then
  pass "truncated:true yields partial:true and a non-empty notice naming the truncation"
else
  fail "truncated:true yields partial:true and a non-empty notice naming the truncation" "$true_out"
fi

false_out="$(run_inventory --tree-json "$truncated_false_json")"
if jq_check "$false_out" '.partial == false'; then
  pass "truncated:false yields partial:false"
else
  fail "truncated:false yields partial:false" "$false_out"
fi

absent_out="$(run_inventory --tree-json "$truncated_absent_json")"
if jq_check "$absent_out" '.partial == false'; then
  pass "an object with no truncated key yields partial:false"
else
  fail "an object with no truncated key yields partial:false" "$absent_out"
fi

# Backward compatibility: the old bare-JSON-array shape (no enclosing
# object, so there is nothing to read a truncated flag from) is treated
# the same way — partial:false, not an error and not a crash.
bare_out="$(run_inventory --tree-json "$bare_array_json")"
if jq_check "$bare_out" '.partial == false'; then
  pass "the old bare-JSON-array shape (no envelope at all) still parses, and reads as partial:false"
else
  fail "the old bare-JSON-array shape (no envelope at all) still parses, and reads as partial:false" "$bare_out"
fi

# The tree-shape signals themselves must agree across all four
# representations of the identical entry list — the envelope changes,
# the corpus it describes does not.
if jq_check "$bare_out" 'true' \
   && [ "$(printf '%s' "$bare_out" | jq -S -c '{file_counts_by_dir, largest_files, doc_roots}' 2>/dev/null)" \
        = "$(printf '%s' "$false_out" | jq -S -c '{file_counts_by_dir, largest_files, doc_roots}' 2>/dev/null)" ] \
   && [ "$(printf '%s' "$false_out" | jq -S -c '{file_counts_by_dir, largest_files, doc_roots}' 2>/dev/null)" \
        = "$(printf '%s' "$absent_out" | jq -S -c '{file_counts_by_dir, largest_files, doc_roots}' 2>/dev/null)" ]; then
  pass "file_counts_by_dir/largest_files/doc_roots agree across the bare-array, truncated:false, and truncated-absent representations of the same entries"
else
  fail "file_counts_by_dir/largest_files/doc_roots agree across the bare-array, truncated:false, and truncated-absent representations of the same entries" \
    "bare: $bare_out" "false: $false_out" "absent: $absent_out"
fi

# ============================================================================
# Which computation path produced the inventory, and the doc that reads it
# ============================================================================
section "which computation path produced the inventory (directory walk vs. tree-json), and the doc surfacing it"

cache_mode_out="$(run_inventory "$java_root")"
if jq_check "$cache_mode_out" '.inventory_source == "cache"'; then
  pass "a directory-walk invocation reports inventory_source: cache"
else
  fail "a directory-walk invocation reports inventory_source: cache" "$cache_mode_out"
fi

tree_mode_out="$(run_inventory --tree-json "$truncated_false_json")"
if jq_check "$tree_mode_out" '.inventory_source == "tree-json"'; then
  pass "a --tree-json invocation reports inventory_source: tree-json"
else
  fail "a --tree-json invocation reports inventory_source: tree-json" "$tree_mode_out"
fi

# The no-local-cache step's prose is scanned wrap-tolerant: the numbered
# step is extracted as a whole block first (surviving re-wrapped
# paragraphs within it), and the one fenced bash block that actually
# builds a tree listing (identifiable by its git/trees API path, unique
# among every fenced block in the step) is isolated before grepping —
# a whole-step grep for "truncated" would also pass on a sentence merely
# describing the problem, without the fix itself carrying it.
step7_block=""
if [ -f "$CACHE_AND_CLONE" ]; then
  step7_block="$(awk '
    /^7\. \*\*/ { f = 1 }
    f && /^## / { exit }
    f { print }
  ' "$CACHE_AND_CLONE")"
fi
step7_flat="$(printf '%s' "$step7_block" | tr '\n' ' ' | tr -s '[:space:]' ' ')"

tree_jq_block="$(awk '
  /^[[:space:]]*```/ {
    if (in_block) { in_block = 0; if (buf ~ /git\/trees/) print buf; buf = "" }
    else { in_block = 1 }
    next
  }
  in_block { buf = buf $0 "\n" }
' <<<"$step7_block")"

if [ -n "$tree_jq_block" ] && printf '%s' "$tree_jq_block" | grep -q 'truncated'; then
  pass "the git/trees fenced jq in the no-local-cache step passes truncated through"
else
  fail "the git/trees fenced jq in the no-local-cache step passes truncated through" \
    "${tree_jq_block:-<no git/trees fenced block found in the pre-flight-inventory step>}"
fi

# Best-guess textual anchor for "the summary names which path was used":
# grepping for the literal field name the script actually emits, rather
# than a fuzzy phrase, at least ties this to something checkable. Applied
# to the whole wrap-normalized step (not only the git/trees block) since
# nothing pins this sentence to living inside that one fenced block.
if printf '%s' "$step7_flat" | grep -qF 'inventory_source'; then
  pass "the pre-flight-inventory step names inventory_source as the field distinguishing which path produced the inventory"
else
  fail "the pre-flight-inventory step names inventory_source as the field distinguishing which path produced the inventory" \
    "${step7_block:-<pre-flight-inventory step not found>}"
fi

# ============================================================================
# Since-last-check across two disconnected shallow commits
# ============================================================================
section "since-last-check across two commits with no connecting history"

sll_upstream="$TMPROOT/sll-upstream"
mkdir -p "$sll_upstream"
git init -q "$sll_upstream"
git -C "$sll_upstream" checkout -q -b main
printf 'v1\n' > "$sll_upstream/a.txt"
printf 'v1\n' > "$sll_upstream/b.txt"
git -C "$sll_upstream" add -A
git -C "$sll_upstream" -c user.email=oracle@example.invalid -c user.name=oracle \
  commit -q -m "commit A"
SHA_A="$(git -C "$sll_upstream" rev-parse HEAD)"

# depth=1 clone of A, taken now, before B exists upstream, so the clone's
# tip really is A. file:// (not a bare local path) is load-bearing — a
# bare local path silently ignores --depth.
sll_workdir="$TMPROOT/sll-workdir"
git clone -q --depth=1 "file://$sll_upstream" "$sll_workdir"
git -C "$sll_workdir" checkout -q --detach HEAD

printf 'v2\n' > "$sll_upstream/a.txt"
printf 'new\n' > "$sll_upstream/c.txt"
git -C "$sll_upstream" add -A
git -C "$sll_upstream" -c user.email=oracle@example.invalid -c user.name=oracle \
  commit -q -m "commit B"
SHA_B="$(git -C "$sll_upstream" rev-parse HEAD)"

WANT_PATHS_AB="$(git -C "$sll_upstream" diff --name-only "$SHA_A" "$SHA_B" | LC_ALL=C sort -u)"

# depth=1 fetch of B (a real tip SHA on the remote) then detach onto it —
# the one-step-further move an in-place cache advance performs, leaving
# two commits with no merge-base between them.
git -C "$sll_workdir" fetch -q --depth=1 "file://$sll_upstream" "$SHA_B"
git -C "$sll_workdir" checkout -q --detach FETCH_HEAD

fixture_ok=true
git -C "$sll_workdir" cat-file -e "$SHA_A" 2>/dev/null || fixture_ok=false
git -C "$sll_workdir" cat-file -e "$SHA_B" 2>/dev/null || fixture_ok=false
if git -C "$sll_workdir" merge-base "$SHA_A" "$SHA_B" >/dev/null 2>&1; then
  fixture_ok=false
fi
[ "$(git -C "$sll_workdir" rev-parse HEAD 2>/dev/null)" = "$SHA_B" ] || fixture_ok=false

if $fixture_ok; then
  pass "fixture self-check: A and B are both locally resolvable, HEAD is at B, and no merge-base connects them"
else
  fail "fixture self-check: A and B are both locally resolvable, HEAD is at B, and no merge-base connects them" \
    "cannot evaluate the assertions below without a valid fixture"
fi

git_fp_before="$(dir_fingerprint "$sll_workdir/.git")"
sll_out="$(run_inventory "$sll_workdir" --last-checked-sha "$SHA_A")"
git_fp_after="$(dir_fingerprint "$sll_workdir/.git")"

if $fixture_ok && jq_check "$sll_out" '
    has("since_last_check")
    and .since_last_check.from_sha == $from
    and .since_last_check.to_sha == $to
' --arg from "$SHA_A" --arg to "$SHA_B"; then
  pass "--last-checked-sha A yields a non-null since_last_check naming A and B"
else
  fail "--last-checked-sha A yields a non-null since_last_check naming A and B" "$sll_out"
fi

got_paths_ab="$(printf '%s' "$sll_out" | jq -r '.since_last_check.files[]?.path' 2>/dev/null | LC_ALL=C sort -u)"
if $fixture_ok && [ "$got_paths_ab" = "$WANT_PATHS_AB" ]; then
  pass "since_last_check.files[].path equals the real A-to-B diff (a.txt modified, c.txt added, b.txt untouched excluded)"
else
  fail "since_last_check.files[].path equals the real A-to-B diff" \
    "expected:" "$WANT_PATHS_AB" "got:" "${got_paths_ab:-<none>}"
fi

if [ "$git_fp_before" = "$git_fp_after" ]; then
  pass "computing since_last_check across the disconnected fixture writes nothing to .git/ (no unshallow, no deepen, no incidental fetch)"
else
  fail "computing since_last_check across the disconnected fixture writes nothing to .git/" \
    "fingerprint before: $git_fp_before" "fingerprint after: $git_fp_after"
fi

section "since-last-check when the last-checked SHA is absent from the object store"

# A REAL absent A: a second clone from the same still-reachable upstream,
# seeded at B only — A was never fetched into this repo at all. This
# matters: with the file:// origin still reachable, a fix that
# "helpfully" fetched the missing SHA on demand would both produce a
# since_last_check here (failing this check) and write to .git/ (failing
# the no-writes check below) — neither failure mode is reachable with a
# fabricated SHA no real remote could ever resolve either way.
sll_absent_workdir="$TMPROOT/sll-absent-workdir"
git clone -q --depth=1 "file://$sll_upstream" "$sll_absent_workdir"
git -C "$sll_absent_workdir" checkout -q --detach HEAD

if git -C "$sll_absent_workdir" cat-file -e "$SHA_A" 2>/dev/null; then
  fail "fixture self-check: A is genuinely absent from this clone's object store" \
    "SHA_A ($SHA_A) unexpectedly resolved in a clone seeded at B only"
else
  pass "fixture self-check: A is genuinely absent from this clone's object store (seeded at B only)"
fi

absent_fp_before="$(dir_fingerprint "$sll_absent_workdir/.git")"
sll_absent_out="$(run_inventory "$sll_absent_workdir" --last-checked-sha "$SHA_A")"
absent_fp_after="$(dir_fingerprint "$sll_absent_workdir/.git")"

if jq_check "$sll_absent_out" 'has("since_last_check") | not'; then
  pass "since_last_check is omitted, exactly as today, when the last-checked SHA is absent from the object store"
else
  fail "since_last_check is omitted when the last-checked SHA is absent from the object store" "$sll_absent_out"
fi

if [ "$absent_fp_before" = "$absent_fp_after" ]; then
  pass "the absent-SHA case writes nothing to .git/ either (no on-demand fetch of the missing commit)"
else
  fail "the absent-SHA case writes nothing to .git/ either" \
    "fingerprint before: $absent_fp_before" "fingerprint after: $absent_fp_after"
fi

# ============================================================================
# --since-json passthrough is untouched by any of the above
# ============================================================================
section "since-json passthrough stays untouched"

# --since-json is a separate, already-shipped input path (verbatim
# passthrough, independent of --last-checked-sha / the local-git-log
# computation) that a change to the disconnected-history handling above
# has no business touching. This is the one check in this file that isn't
# derived from anything new above needs to add — it exists purely to
# catch that path being deleted or altered as a side effect.
since_payload="$TMPROOT/since-payload.json"
cat > "$since_payload" <<'EOF'
{"from_sha": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
 "to_sha": "cafef00dcafef00dcafef00dcafef00dcafef00d",
 "files": [{"path": "z.txt", "changes": 3}]}
EOF

since_json_root="$TMPROOT/since-json-root"
mkdir -p "$since_json_root"
printf 'x\n' > "$since_json_root/x.txt"

since_json_out="$(run_inventory "$since_json_root" --since-json "$since_payload")"
if jq_check "$since_json_out" '.since_last_check == $want[0]' --slurpfile want "$since_payload"; then
  pass "--since-json alone is emitted verbatim as since_last_check"
else
  fail "--since-json alone is emitted verbatim as since_last_check" "$since_json_out"
fi

# --since-json must still win over --last-checked-sha when both are given
# — the documented precedence today — even against the real disconnected-
# history fixture built above, where --last-checked-sha alone would
# otherwise compute something itself.
if $fixture_ok; then
  since_json_precedence_out="$(run_inventory "$sll_workdir" --last-checked-sha "$SHA_A" --since-json "$since_payload")"
  if jq_check "$since_json_precedence_out" '.since_last_check == $want[0]' --slurpfile want "$since_payload"; then
    pass "--since-json still takes precedence over --last-checked-sha when both are supplied"
  else
    fail "--since-json still takes precedence over --last-checked-sha when both are supplied" "$since_json_precedence_out"
  fi
else
  fail "--since-json still takes precedence over --last-checked-sha when both are supplied" \
    "cannot evaluate — the disconnected-history fixture above did not build cleanly"
fi

# ============================================================================
# stdlib-only, git-only, no network verbs, no side effects
# ============================================================================
section "stdlib-only, git-only, no network verbs, no side effects"

# stdlib-only, via the AST rather than a hand-maintained allowlist, so a
# genuinely new stdlib import doesn't need this file edited while any
# third-party import fails loudly.
non_stdlib="$(python3 - "$INV_SCRIPT" <<'PYEOF'
import ast, sys
path = sys.argv[1]
tree = ast.parse(open(path, encoding="utf-8").read(), filename=path)
stdlib = getattr(sys, "stdlib_module_names", None)
if stdlib is None:
    stdlib = {"argparse", "json", "os", "re", "subprocess", "sys", "pathlib"}
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
  pass "every top-level import resolves to the standard library"
else
  fail "every top-level import resolves to the standard library" "$non_stdlib"
fi

# Every subprocess call's argv[0] is "git" — AST-based so it survives
# reformatting of the call site, unlike a line-oriented grep.
bad_subprocess="$(python3 - "$INV_SCRIPT" <<'PYEOF'
import ast, sys
path = sys.argv[1]
tree = ast.parse(open(path, encoding="utf-8").read(), filename=path)
bad = []
for node in ast.walk(tree):
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) \
       and isinstance(node.func.value, ast.Name) and node.func.value.id == "subprocess" \
       and node.func.attr in ("run", "call", "Popen", "check_output", "check_call"):
        argv0 = None
        if node.args and isinstance(node.args[0], ast.List) and node.args[0].elts:
            first = node.args[0].elts[0]
            if isinstance(first, ast.Constant) and isinstance(first.value, str):
                argv0 = first.value
        if argv0 != "git":
            bad.append("line %d: subprocess.%s argv[0]=%r" % (node.lineno, node.func.attr, argv0))
print("\n".join(bad))
PYEOF
)"
if [ -z "$bad_subprocess" ]; then
  pass "every subprocess call shells out to git only"
else
  fail "every subprocess call shells out to git only" "$bad_subprocess"
fi

# No git invocation uses a network-capable verb. This is the static
# counterpart to the .git/ fingerprint checks above: it guards the whole
# script, not just the one fixture, against the tempting-but-wrong fix for
# disconnected shallow history ("just fetch --unshallow / --deepen to make
# the range walk work again") rather than switching to a two-tree diff
# that needs no network at all.
network_verbs="$(python3 - "$INV_SCRIPT" <<'PYEOF'
import ast, sys
path = sys.argv[1]
tree = ast.parse(open(path, encoding="utf-8").read(), filename=path)
deny = {"clone", "fetch", "pull", "push", "ls-remote", "remote"}
hits = []
for node in ast.walk(tree):
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) \
       and isinstance(node.func.value, ast.Name) and node.func.value.id == "subprocess" \
       and node.func.attr in ("run", "call", "Popen", "check_output", "check_call"):
        if node.args and isinstance(node.args[0], ast.List):
            argv = [e.value for e in node.args[0].elts
                    if isinstance(e, ast.Constant) and isinstance(e.value, str)]
            bad = [a for a in argv if a in deny]
            if bad:
                hits.append("line %d: argv contains %r" % (node.lineno, bad))
print("\n".join(hits))
PYEOF
)"
if [ -z "$network_verbs" ]; then
  pass "no git invocation uses a network-capable verb (clone/fetch/pull/push/ls-remote/remote)"
else
  fail "no git invocation uses a network-capable verb (clone/fetch/pull/push/ls-remote/remote)" "$network_verbs"
fi

# No writes outside stdout — the caller decides where (and whether) to
# persist the computed inventory; the script itself must not write
# anywhere on its own.
nse_control="$TMPROOT/no-side-effects-control"
nse_source="$TMPROOT/no-side-effects-source"
mkdir -p "$nse_control" "$nse_source"
printf 'a\n' > "$nse_source/a.txt"
nse_before="$(find "$nse_source" -type f | sort)"
nse_run_out="$(cd "$nse_control" && python3 "$INV_SCRIPT" "$nse_source" 2>/dev/null)"
nse_after="$(find "$nse_source" -type f | sort)"
nse_control_listing="$(find "$nse_control" -mindepth 1 | sort)"
if printf '%s' "$nse_run_out" | jq -e . >/dev/null 2>&1 \
    && [ "$nse_before" = "$nse_after" ] && [ -z "$nse_control_listing" ]; then
  pass "invoking the script writes nothing to its cwd or to the source root"
else
  fail "invoking the script writes nothing to its cwd or to the source root"
fi

# ============================================================================
# CLI surface: every argument the pinned baseline exposes is still present
# ============================================================================
section "CLI surface keeps every argument the pinned baseline exposes"

# Enumerated programmatically from the pinned baseline's own argparse
# setup (never a hand-typed list this file's author might have missed a
# flag from), then checked against the CURRENT script's --help text — the
# black-box channel "the CLI" itself is observed through.
if ! $BASELINE_OK; then
  fail "the current script's --help documents every argument the pinned baseline's argparse setup declares" \
    "$BASELINE_UNAVAILABLE_REASON"
else
  baseline_tokens="$(python3 - "$baseline_script" <<'PYEOF'
import importlib.util, sys
path = sys.argv[1]
spec = importlib.util.spec_from_file_location("inventory_baseline_cli", path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
parser = mod.build_parser()
tokens = set()
for action in parser._actions:  # noqa: SLF001 -- introspection, not production use
    if action.option_strings:
        tokens.update(action.option_strings)
    elif action.dest and action.dest != "help":
        tokens.add(action.dest)
for t in sorted(tokens):
    print(t)
PYEOF
)"
  current_help="$(python3 "$INV_SCRIPT" --help 2>&1)"
  missing=""
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    if ! printf '%s' "$current_help" | grep -qF -- "$tok"; then
      missing="${missing}${missing:+, }${tok}"
    fi
  done < <(printf '%s\n' "$baseline_tokens")

  if [ -z "$missing" ]; then
    pass "the current script's --help documents every argument the pinned baseline's argparse setup declares ($baseline_tokens)"
  else
    fail "the current script's --help documents every argument the pinned baseline's argparse setup declares" \
      "missing from --help: $missing" "baseline tokens: $baseline_tokens"
  fi
fi

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
