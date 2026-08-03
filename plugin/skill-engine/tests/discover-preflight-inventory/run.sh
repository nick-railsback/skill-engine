#!/usr/bin/env bash
# Feature-scoped test runner for discover_inventory.py — a deterministic,
# non-model pre-flight step that computes a per-source corpus-shape
# inventory (file counts by directory, largest files, doc-root presence,
# and — when possible — a since-last-check change summary) and hands it
# to the caller as JSON, so a discovery pass can start from a precomputed
# frame of the corpus's shape instead of re-deriving it in-window.
#
# Nothing upstream pins discover_inventory.py's CLI or output shape, so
# this suite designs and freezes both here:
#
#   python3 discover_inventory.py <source-root> [--last-checked-sha <sha>]
#
#   Exits 0 and writes exactly one JSON object to stdout, nothing else on
#   stdout, and touches no file anywhere (the script's only output channel
#   is stdout — whether and where to persist it is entirely the caller's
#   decision, not this script's). Exits non-zero with a stderr diagnostic
#   if <source-root> does not exist.
#
#   {
#     "file_counts_by_dir": {
#       "<dir-path-relative-to-source-root>": <int>, ...
#       // "" is the source root itself. A directory more than 3 path
#       // segments deep is not its own key — its files are counted
#       // against the key formed by its first 3 segments.
#     },
#     "largest_files": [
#       {"path": "<rel-path>", "bytes": <int>}, ...
#       // up to 20 entries, descending by bytes; fewer than 20 when the
#       // source has fewer than 20 files (never padded).
#     ],
#     "doc_roots": ["<top-level entry name>", ...]
#       // the actual on-disk names (case preserved) of top-level-only
#       // entries matching README*, CHANGELOG*, docs/, or doc/,
#       // case-insensitively; never recurses into subdirectories.
#     ,
#     "since_last_check": {
#       "from_sha": "<sha>", "to_sha": "<sha>",
#       "files": [{"path": "<rel-path>", "changes": <int>}, ...]
#     }
#     // present ONLY when --last-checked-sha was supplied AND
#     // <source-root> is itself a real local git working tree (has a
#     // .git/ directory). Otherwise the key is absent from the object
#     // entirely — never null, never a zero-valued placeholder.
#   }
#
#   .git/ internals never contribute to file_counts_by_dir, largest_files,
#   or doc_roots — a plain directory and the identical tree checked out as
#   a git working copy must report byte-identical values for those three
#   fields. That equivalence is also this script's answer to "does this
#   still work with no local clone under
#   ~/.cache/skill-engine/git-managed/": every fixture below hands the
#   script an arbitrary tmpdir it never inspects the location of, so
#   nothing here (or in a real caller) can make these signals depend on
#   that specific cache path existing.
#
# Fixture style: small synthetic directory trees built under a tmpdir,
# with expected values computed by direct arithmetic/enumeration on the
# fixture as built (never by re-deriving what the script itself computes)
# — same discipline as tests/navigator-budget/run.sh.
#
# The since-last-check fixtures use a real local git repository built
# with `git init` plus local commits inside a tmpdir — fully offline, no
# network, no clone of anything real.
#
# The two document-content sections near the bottom assert structural
# facts about prose+bash an agent reads and executes at runtime (the new
# pre-flight step in cache-and-clone.md, and the reasoning-aids list in
# discover/SKILL.md's "Discovering essence" section) by extracting the
# relevant block and grepping it — the convention this repo uses for
# behavior that isn't a standalone script. Neither the step nor the SKILL.md
# line exists yet, so both sections fail today.
#
# The behavior for web-doc/external-doc/local-path sources is untouched by
# any of this — that's chiefly evidenced by the rest of `ci-local` staying
# green (nothing here or in cache-and-clone.md's existing steps changes
# for those source kinds), not by a standalone assertion that would test
# nothing on its own.
#
# discover_inventory.py does not exist yet (that's what makes this oracle
# red today), and neither does the cache-and-clone.md / SKILL.md prose —
# this suite is what turns green once that implementation lands.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INV_SCRIPT="$PLUGIN_ROOT/tests/discover_inventory.py"
CACHE_AND_CLONE="$PLUGIN_ROOT/skills/discover/references/cache-and-clone.md"
DISCOVER_SKILL_MD="$PLUGIN_ROOT/skills/discover/SKILL.md"

pass_count=0
fail_count=0

TMPDIR_CASE="$(mktemp -d -t skill-engine-discover-inventory.XXXXXX)"
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

# run_inventory <source-root> [extra args...] — invokes the script under
# test and echoes its stdout. Errors (script missing, bad args, etc.) are
# swallowed into an empty stdout capture; every check below independently
# requires valid, specific JSON content, so an empty/invalid capture always
# reads as a failure for the right reason rather than a vacuous pass.
run_inventory() {
  python3 "$INV_SCRIPT" "$@" 2>/dev/null
}

# jq_check <json> <jq-boolean-program> [--arg name value ...] — true (rc 0)
# only when the input is valid JSON AND the boolean program evaluates true.
# A parse error, a missing key, or a false result are all rc != 0 — jq -e's
# own semantics, not a custom parser this suite would need to trust.
jq_check() {
  local json="$1" program="$2"
  shift 2
  printf '%s' "$json" | jq -e "$@" "$program" >/dev/null 2>&1
}

echo
echo "── directory file counts, depth-3 rollup ──"

# depth rollup: root-level files, one/two/three-segment directories, and
# two files nested 4 and 5 segments deep that must roll up into their
# depth-3 ancestor rather than being dropped or kept at their own depth.
build_depth_fixture() {
  local root="$1"
  mkdir -p "$root/src/lib/utils/helpers/more"
  printf 'a' > "$root/a.txt"
  printf 'bb' > "$root/b.txt"
  printf 'x' > "$root/src/x.txt"
  printf 'y' > "$root/src/y.txt"
  printf 'z' > "$root/src/lib/z.txt"
  printf 'w' > "$root/src/lib/utils/w.txt"
  printf 'd1' > "$root/src/lib/utils/helpers/deep1.txt"
  printf 'd2' > "$root/src/lib/utils/helpers/more/deep2.txt"
}

depth_root="$TMPDIR_CASE/depth-fixture"
mkdir -p "$depth_root"
build_depth_fixture "$depth_root"
depth_out="$(run_inventory "$depth_root")"

if jq_check "$depth_out" '
    .file_counts_by_dir[""] == 2
    and .file_counts_by_dir["src"] == 2
    and .file_counts_by_dir["src/lib"] == 1
    and .file_counts_by_dir["src/lib/utils"] == 3
'; then
  pass "depth rollup: root/1-seg/2-seg/3-seg directories each report their own hand-counted file total"
else
  fail "depth rollup: root/1-seg/2-seg/3-seg directories each report their own hand-counted file total"
fi

if jq_check "$depth_out" '
    (.file_counts_by_dir | has("src/lib/utils/helpers") | not)
    and (.file_counts_by_dir | has("src/lib/utils/helpers/more") | not)
'; then
  pass "depth rollup: directories deeper than 3 segments never appear as their own key (files land on the depth-3 ancestor instead)"
else
  fail "depth rollup: directories deeper than 3 segments never appear as their own key (files land on the depth-3 ancestor instead)"
fi

echo
echo "── largest files by byte size ──"

# 25 files of distinct, precisely-controlled sizes (37, 74, ..., 925
# bytes). The 20 largest are files 06..25; files 01..05 (<=185 bytes) must
# be excluded, never padding the list out past what's asked for.
build_many_files_fixture() {
  local root="$1" n bytes
  mkdir -p "$root"
  for n in $(seq 1 25); do
    bytes=$((n * 37))
    head -c "$bytes" /dev/zero > "$root/$(printf 'file%02d.bin' "$n")"
  done
}

many_root="$TMPDIR_CASE/many-files-fixture"
mkdir -p "$many_root"
build_many_files_fixture "$many_root"
many_out="$(run_inventory "$many_root")"

if jq_check "$many_out" '
    (.largest_files | length) == 20
    and (.largest_files[0] == {"path": "file25.bin", "bytes": 925})
    and (.largest_files[19] == {"path": "file06.bin", "bytes": 222})
    and ([.largest_files[].path] | index("file05.bin") == null)
'; then
  pass "largest files: 25-file source caps the list at exactly 20, largest-to-smallest of the top 20 sizes, excludes the 5 smallest"
else
  fail "largest files: 25-file source caps the list at exactly 20, largest-to-smallest of the top 20 sizes, excludes the 5 smallest"
fi

if jq_check "$many_out" '
    [.largest_files[].bytes] as $b | $b == ($b | sort | reverse)
'; then
  pass "largest files: byte values are strictly non-increasing across the full 20-entry list"
else
  fail "largest files: byte values are strictly non-increasing across the full 20-entry list"
fi

# Fewer than 20 files on disk: the list must report exactly that many
# entries, not pad with placeholders.
build_few_files_fixture() {
  local root="$1"
  mkdir -p "$root"
  head -c 10 /dev/zero > "$root/small.bin"
  head -c 20 /dev/zero > "$root/medium.bin"
  head -c 30 /dev/zero > "$root/large.bin"
}

few_root="$TMPDIR_CASE/few-files-fixture"
mkdir -p "$few_root"
build_few_files_fixture "$few_root"
few_out="$(run_inventory "$few_root")"

if jq_check "$few_out" '
    (.largest_files | length) == 3
    and .largest_files[0] == {"path": "large.bin", "bytes": 30}
    and .largest_files[1] == {"path": "medium.bin", "bytes": 20}
    and .largest_files[2] == {"path": "small.bin", "bytes": 10}
'; then
  pass "largest files: a 3-file source reports exactly 3 entries (never padded to 20), correctly ordered"
else
  fail "largest files: a 3-file source reports exactly 3 entries (never padded to 20), correctly ordered"
fi

echo
echo "── doc-root detection ──"

# README.md, CHANGELOG (no extension), and docs/ all present at top level;
# a plain unrelated file and no doc/ singular. Exact-set match — nothing
# extra, nothing missing.
build_docroot_fixture() {
  local root="$1"
  mkdir -p "$root/docs"
  printf '# hi\n' > "$root/README.md"
  printf 'v1\n' > "$root/CHANGELOG"
  printf 'x\n' > "$root/docs/page.md"
  printf 'irrelevant\n' > "$root/notes.txt"
}

docroot_root="$TMPDIR_CASE/docroot-fixture"
mkdir -p "$docroot_root"
build_docroot_fixture "$docroot_root"
docroot_out="$(run_inventory "$docroot_root")"

if jq_check "$docroot_out" '
    (.doc_roots | sort) == (["README.md", "CHANGELOG", "docs"] | sort)
'; then
  pass "doc-root detection: README.md + CHANGELOG + docs/ all detected, unrelated top-level file excluded, doc/ correctly absent"
else
  fail "doc-root detection: README.md + CHANGELOG + docs/ all detected, unrelated top-level file excluded, doc/ correctly absent"
fi

# Case-insensitivity: a mixed-case README-shaped filename and a
# mixed-case docs-shaped directory name.
build_docroot_caseinsensitive_fixture() {
  local root="$1"
  mkdir -p "$root"
  printf 'x\n' > "$root/readme.TXT"
  mkdir -p "$root/DOCS"
}

ci_root="$TMPDIR_CASE/docroot-caseinsensitive-fixture"
mkdir -p "$ci_root"
build_docroot_caseinsensitive_fixture "$ci_root"
ci_out="$(run_inventory "$ci_root")"

if jq_check "$ci_out" '
    (.doc_roots | sort) == (["readme.TXT", "DOCS"] | sort)
'; then
  pass "doc-root detection: case-insensitive match on both a README-shaped filename and a docs-shaped directory name"
else
  fail "doc-root detection: case-insensitive match on both a README-shaped filename and a docs-shaped directory name"
fi

# doc/ (singular) triggers detection independently of docs/ (plural).
build_doc_singular_fixture() {
  local root="$1"
  mkdir -p "$root/doc"
  printf 'x\n' > "$root/doc/x.md"
}

doc_sing_root="$TMPDIR_CASE/doc-singular-fixture"
mkdir -p "$doc_sing_root"
build_doc_singular_fixture "$doc_sing_root"
doc_sing_out="$(run_inventory "$doc_sing_root")"

if jq_check "$doc_sing_out" '.doc_roots == ["doc"]'; then
  pass "doc-root detection: doc/ (singular) alone is detected"
else
  fail "doc-root detection: doc/ (singular) alone is detected"
fi

# Non-recursive: a README only under a subdirectory must not count.
build_docroot_nonrecursive_fixture() {
  local root="$1"
  mkdir -p "$root/sub"
  printf 'x\n' > "$root/sub/README.md"
}

nonrec_root="$TMPDIR_CASE/docroot-nonrecursive-fixture"
mkdir -p "$nonrec_root"
build_docroot_nonrecursive_fixture "$nonrec_root"
nonrec_out="$(run_inventory "$nonrec_root")"

if jq_check "$nonrec_out" '.doc_roots == []'; then
  pass "doc-root detection: a README nested under a subdirectory (not at the source root) is not detected — top-level only, no recursive search"
else
  fail "doc-root detection: a README nested under a subdirectory (not at the source root) is not detected — top-level only, no recursive search"
fi

echo
echo "── identical results with and without a local git checkout ──"

# The same tree, once as a plain directory and once as a real local git
# working copy (git init + a commit, fully offline). file_counts_by_dir,
# largest_files, and doc_roots must come out byte-identical either way —
# proof that .git/ never leaks into the signals, and that none of this
# depends on the source root being (or not being) a particular kind of
# directory. Neither path here is anywhere near
# ~/.cache/skill-engine/git-managed/, which is itself the black-box stand-in
# for "no local clone consented to" — the script never treats that path
# specially, so it can't degrade when it's absent.
build_equiv_fixture() {
  local root="$1"
  mkdir -p "$root/pkg"
  printf 'one\n' > "$root/README.md"
  printf 'two\n' > "$root/pkg/mod.txt"
}

equiv_plain_root="$TMPDIR_CASE/equiv-plain"
mkdir -p "$equiv_plain_root"
build_equiv_fixture "$equiv_plain_root"
equiv_plain_out="$(run_inventory "$equiv_plain_root")"

equiv_git_root="$TMPDIR_CASE/equiv-git"
mkdir -p "$equiv_git_root"
build_equiv_fixture "$equiv_git_root"
git -C "$equiv_git_root" init -q
git -C "$equiv_git_root" config user.email "test@example.com"
git -C "$equiv_git_root" config user.name "skill-engine tests"
git -C "$equiv_git_root" add -A
git -C "$equiv_git_root" commit -q -m "initial"
equiv_git_out="$(run_inventory "$equiv_git_root")"

equiv_ok=0
if printf '%s' "$equiv_plain_out" | jq -e . >/dev/null 2>&1 \
    && printf '%s' "$equiv_git_out" | jq -e . >/dev/null 2>&1; then
  equiv_diff="$(diff <(printf '%s' "$equiv_plain_out" | jq -S .) <(printf '%s' "$equiv_git_out" | jq -S .) || true)"
  [ -z "$equiv_diff" ] && equiv_ok=1
fi
if [ "$equiv_ok" -eq 1 ]; then
  pass "no cache/clone dependency: an identical tree reports byte-identical output whether it's a plain directory or a real git working copy (.git/ never leaks in)"
else
  fail "no cache/clone dependency: an identical tree reports byte-identical output whether it's a plain directory or a real git working copy (.git/ never leaks in)"
fi

echo
echo "── since-last-check summary (git-managed only, opt-in via a supplied sha) ──"

# A real local git repository (offline: git init + two local commits) with
# a known, hand-authored diff between the two commits: a.txt modified,
# c.txt added, b.txt untouched.
sll_repo="$TMPDIR_CASE/since-last-check-repo"
mkdir -p "$sll_repo"
git -C "$sll_repo" init -q
git -C "$sll_repo" config user.email "test@example.com"
git -C "$sll_repo" config user.name "skill-engine tests"
printf 'v1\n' > "$sll_repo/a.txt"
printf 'v1\n' > "$sll_repo/b.txt"
git -C "$sll_repo" add -A
git -C "$sll_repo" commit -q -m "initial"
sll_sha1="$(git -C "$sll_repo" rev-parse HEAD)"

printf 'v2\n' > "$sll_repo/a.txt"
printf 'new\n' > "$sll_repo/c.txt"
git -C "$sll_repo" add -A
git -C "$sll_repo" commit -q -m "second"
sll_sha2="$(git -C "$sll_repo" rev-parse HEAD)"

sll_with_sha_out="$(run_inventory "$sll_repo" --last-checked-sha "$sll_sha1")"

if jq_check "$sll_with_sha_out" '
    has("since_last_check")
    and .since_last_check.from_sha == $from
    and .since_last_check.to_sha == $to
    and ([.since_last_check.files[].path] | contains(["a.txt", "c.txt"]))
    and ([.since_last_check.files[].path] | index("b.txt") == null)
' --arg from "$sll_sha1" --arg to "$sll_sha2"; then
  pass "since-last-check: a supplied sha against a real local git repo names exactly the files touched since that sha (a.txt modified, c.txt added, b.txt excluded)"
else
  fail "since-last-check: a supplied sha against a real local git repo names exactly the files touched since that sha (a.txt modified, c.txt added, b.txt excluded)"
fi

sll_no_sha_out="$(run_inventory "$sll_repo")"
if jq_check "$sll_no_sha_out" 'has("since_last_check") | not'; then
  pass "since-last-check: field is entirely absent (not null, not empty) when no prior sha is supplied, even against a real git repo"
else
  fail "since-last-check: field is entirely absent (not null, not empty) when no prior sha is supplied, even against a real git repo"
fi

# ── since_last_check paths are repo paths, in every form git can print ──
#
# `git log --numstat` does not print plain paths unconditionally. It prints
# a rename as the single field `dir/{old.md => new.md}`, and it C-quotes and
# octal-escapes any path outside ASCII: `"docs/caf\303\251.md"`. Both split
# into exactly three tab fields, so neither is caught by the malformed-row
# guard, and both reach the emitted JSON verbatim.
#
# What consumes this is DISCOVER's pre-flight (cache-and-clone.md step 7),
# which intersects these paths with the corpus shape to decide what to
# re-harvest. A path in either of those forms matches nothing in
# file_counts_by_dir or largest_files, so the files that actually changed
# are silently dropped from the re-harvest and the corpus keeps stale
# content for them — a source that renames a directory, or carries one
# accented filename, quietly stops being refreshed.
#
# The fixture below is a single commit doing both: a git mv, and an edit to
# a UTF-8-named file.
sll_forms_repo="$TMPDIR_CASE/since-last-check-forms"
mkdir -p "$sll_forms_repo/docs"
git -C "$sll_forms_repo" init -q
git -C "$sll_forms_repo" config user.email "test@example.com"
git -C "$sll_forms_repo" config user.name "skill-engine tests"
printf 'original\n' > "$sll_forms_repo/docs/old.md"
printf 'accented\n' > "$sll_forms_repo/docs/café.md"
printf 'plain\n' > "$sll_forms_repo/docs/plain.md"
git -C "$sll_forms_repo" add -A
git -C "$sll_forms_repo" commit -q -m "initial"
sll_forms_base="$(git -C "$sll_forms_repo" rev-parse HEAD)"

git -C "$sll_forms_repo" mv docs/old.md docs/new.md
printf 'more\n' >> "$sll_forms_repo/docs/café.md"
git -C "$sll_forms_repo" add -A
git -C "$sll_forms_repo" commit -q -m "rename and edit"

sll_forms_out="$(run_inventory "$sll_forms_repo" --last-checked-sha "$sll_forms_base")"

# Fixture self-check: without it, an inventory that reported no changed
# files at all would pass every negative assertion below.
if jq_check "$sll_forms_out" '(.since_last_check.files | length) >= 2'; then
  pass "since-last-check forms: the fixture's rename-and-edit commit does produce changed-file rows to inspect"
else
  fail "since-last-check forms: the fixture's rename-and-edit commit does produce changed-file rows to inspect" \
    "$sll_forms_out"
fi

if jq_check "$sll_forms_out" '[.since_last_check.files[].path] | contains(["docs/café.md"])'; then
  pass "since-last-check forms: a UTF-8 filename is reported as the real path, not C-quoted and octal-escaped"
else
  fail "since-last-check forms: a UTF-8 filename is reported as the real path, not C-quoted and octal-escaped" \
    "$sll_forms_out"
fi

if jq_check "$sll_forms_out" '[.since_last_check.files[].path] | contains(["docs/new.md"])'; then
  pass "since-last-check forms: a renamed file's new path is reported on its own, not folded into a {old => new} field"
else
  fail "since-last-check forms: a renamed file's new path is reported on its own, not folded into a {old => new} field" \
    "$sll_forms_out"
fi

# Every emitted path has to be a path — something a consumer can match
# against the corpus shape. This is the assertion that fails on BOTH of
# git's decorated forms at once, whatever future form is added.
if jq_check "$sll_forms_out" '
    [.since_last_check.files[].path]
    | all(test("^[^\"{}]*$") and (test(" => ") | not))
'; then
  pass "since-last-check forms: no emitted path carries git's display decoration (no quotes, no braces, no \" => \")"
else
  fail "since-last-check forms: no emitted path carries git's display decoration (no quotes, no braces, no \" => \")" \
    "$sll_forms_out"
fi

# An untouched file must still be absent, so the fix cannot have been "emit
# every path in the tree".
if jq_check "$sll_forms_out" '[.since_last_check.files[].path] | index("docs/plain.md") == null'; then
  pass "since-last-check forms: a file untouched by the commit is still excluded"
else
  fail "since-last-check forms: a file untouched by the commit is still excluded" \
    "$sll_forms_out"
fi

sll_nongit_root="$TMPDIR_CASE/since-last-check-nongit"
mkdir -p "$sll_nongit_root"
printf 'x\n' > "$sll_nongit_root/a.txt"
sll_nongit_out="$(run_inventory "$sll_nongit_root" --last-checked-sha "0123456789abcdef0123456789abcdef01234567")"
if jq_check "$sll_nongit_out" 'has("since_last_check") | not'; then
  pass "since-last-check: field is entirely absent when a sha IS supplied but the source root is not a real local git repo"
else
  fail "since-last-check: field is entirely absent when a sha IS supplied but the source root is not a real local git repo"
fi

echo
echo "── no side effects: the script's only output is stdout JSON ──"

# The caller decides where (and whether) to persist the computed
# inventory under research/ — the script itself must not write anywhere,
# on disk, on its own. Run it with an unrelated tmpdir as cwd and confirm
# neither that cwd nor the source root gained any new file.
nse_control_dir="$TMPDIR_CASE/no-side-effects-control"
mkdir -p "$nse_control_dir"
nse_source_dir="$TMPDIR_CASE/no-side-effects-source"
mkdir -p "$nse_source_dir"
printf 'a\n' > "$nse_source_dir/a.txt"
printf 'b\n' > "$nse_source_dir/sub_placeholder.txt"

nse_source_before="$(find "$nse_source_dir" -type f | sort)"
nse_out="$(cd "$nse_control_dir" && python3 "$INV_SCRIPT" "$nse_source_dir" 2>/dev/null)"
nse_source_after="$(find "$nse_source_dir" -type f | sort)"
nse_control_listing="$(find "$nse_control_dir" -mindepth 1 | sort)"

nse_ok=0
if printf '%s' "$nse_out" | jq -e . >/dev/null 2>&1 \
    && [ "$nse_source_before" = "$nse_source_after" ] \
    && [ -z "$nse_control_listing" ]; then
  nse_ok=1
fi
if [ "$nse_ok" -eq 1 ]; then
  pass "no side effects: invoking the script writes nothing to its cwd or to the source root — a single valid JSON object on stdout is the entire effect"
else
  fail "no side effects: invoking the script writes nothing to its cwd or to the source root — a single valid JSON object on stdout is the entire effect"
fi

echo
echo "── cache-and-clone.md: the new pre-flight step ──"

# The declared shape: a new top-level numbered step 7 (sibling of the
# existing 0/1/1.5/2/3/4/5/6 steps), the same tests/-script invocation
# form already established for permalink_density.py
# ($CLAUDE_PLUGIN_ROOT/tests/<script>.py), targets research/, and states
# the inventory is recomputed every run rather than merged with a prior
# run's copy.
step7_block=""
if [ -f "$CACHE_AND_CLONE" ]; then
  step7_block="$(awk '
    /^7\. \*\*/ { f = 1 }
    f && /^## / { exit }
    f { print }
  ' "$CACHE_AND_CLONE")"
fi

step7_ok=1
[ -n "$step7_block" ] || step7_ok=0
printf '%s' "$step7_block" | grep -qF 'CLAUDE_PLUGIN_ROOT/tests/discover_inventory.py' || step7_ok=0
printf '%s' "$step7_block" | grep -qF 'research/' || step7_ok=0
printf '%s' "$step7_block" | grep -qiE 're-derived|recomputed|every run|each run|freshly comput' || step7_ok=0
if [ "$step7_ok" -eq 1 ]; then
  pass "cache-and-clone.md: a new step 7 writes the inventory under research/, invokes discover_inventory.py the same way permalink_density.py is already invoked, and states it is recomputed every run"
else
  fail "cache-and-clone.md: a new step 7 writes the inventory under research/, invokes discover_inventory.py the same way permalink_density.py is already invoked, and states it is recomputed every run"
fi

# The written file is framed the same way the sibling
# research/.discover-cache.json already is elsewhere in this same
# document: gitignored runtime state, not a reference artifact.
step7_runtime_ok=1
printf '%s' "$step7_block" | grep -qiE 'gitignored[^.]{0,20}runtime state|runtime state[^.]{0,40}gitignored' || step7_runtime_ok=0
if [ "$step7_runtime_ok" -eq 1 ]; then
  pass "cache-and-clone.md: the new step frames the written file as gitignored runtime state, matching the existing research/.discover-cache.json convention"
else
  fail "cache-and-clone.md: the new step frames the written file as gitignored runtime state, matching the existing research/.discover-cache.json convention"
fi

echo
echo "── discover/SKILL.md: the file offered as an available starting frame ──"

# The "Discovering essence" reasoning-aids list already carries two
# bullets (data/public-orgs.json, data/popular-names.json) introduced as
# optional, at-the-model's-discretion aids. A third bullet naming a
# research/-rooted inventory file, in the same register, must join them.
essence_section=""
if [ -f "$DISCOVER_SKILL_MD" ]; then
  essence_section="$(awk '
    /^## Discovering essence/ { f = 1; next }
    /^## / { f = 0 }
    f { print }
  ' "$DISCOVER_SKILL_MD")"
fi

essence_ok=1
[ -n "$essence_section" ] || essence_ok=0
printf '%s' "$essence_section" | grep -qF 'data/public-orgs.json' || essence_ok=0
printf '%s' "$essence_section" | grep -qF 'data/popular-names.json' || essence_ok=0
printf '%s' "$essence_section" | grep -qE '^- `research/' || essence_ok=0
printf '%s' "$essence_section" | grep -qi 'inventory' || essence_ok=0
if [ "$essence_ok" -eq 1 ]; then
  pass "discover/SKILL.md: Discovering essence lists a research/-rooted inventory file as a third reasoning aid, in the same bullet-list register as the two existing data/*.json aids"
else
  fail "discover/SKILL.md: Discovering essence lists a research/-rooted inventory file as a third reasoning aid, in the same bullet-list register as the two existing data/*.json aids"
fi

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
