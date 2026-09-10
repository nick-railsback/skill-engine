#!/usr/bin/env bash
# Black-box oracle for tests/repin_citations.py, the mechanical half of a
# REFRESH against a git-managed source that advanced: re-pin every
# permalink whose cited text did not move, and list exactly the ones a
# reader has to look at.
#
# Why this exists. The 2026-09-09 dogfood refresh re-pinned 215 permalinks
# by hand: 160 into unchanged files, 46 shifted by a whole-line offset with
# byte-identical text, 9 overlapping a hunk. 206 of 215 were arithmetic and
# took the better part of an hour. The script does the arithmetic; this
# file freezes what "arithmetic" is allowed to mean, and — the must-reject
# input — what it must refuse to do on its own.
#
# Contract frozen here:
#
#   python3 repin_citations.py <references_dir> --repo <clone> \
#           --old-sha <sha> --new-sha <sha> [--out-dir <dir>]
#
#     Exit 0 on a completed run, whatever the report says; exit 1 on a
#     missing directory or a SHA that does not resolve in <clone>. One JSON
#     object on stdout carrying, at least:
#
#       "counts": {"unchanged_file": n, "remapped_range": n,
#                  "needs_review": n, "other": n}
#       "citations", "repinned", "all_repinned"
#       "needs_review": [{"reference", "path", "start", "end", "reason"}]
#       "rewritten": [<relative reference paths whose text changed>]
#       "written":   [<the subset actually written under --out-dir>]
#
#     A citation carrying <old_sha> is:
#       unchanged_file   swapped to <new_sha> when neither its path nor
#                        anything under it changed between the two commits;
#       remapped_range   swapped, with its #L range shifted by the net delta
#                        of every hunk wholly above it, when no hunk touches
#                        the range and the cited lines at the old commit are
#                        byte-equal to the shifted range at the new one;
#       needs_review     left byte-for-byte as it was otherwise — a hunk
#                        overlapping the range, an insertion inside it, a
#                        deleted path, a whole-file or directory citation
#                        whose target changed.
#     A citation at any other SHA is "other" and untouched.
#
#     The input directory is never written to. With --out-dir, each
#     reference whose text changed is written there at its own relative
#     path and nothing else is — a sparse copy-on-write, the shape a
#     .proposed/ tree has.
#
# Every git mutation below targets a throwaway tmpdir repo. Read-only over
# this repository.
#
# -e is intentionally omitted: every assertion must run and report, not
# abort at the first red one.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TESTS_ROOT="$PLUGIN_ROOT/tests"

REPIN_PY="$TESTS_ROOT/repin_citations.py"
DRIFT_PHASES="$PLUGIN_ROOT/skills/refresh/references/drift-detection-and-phases.md"
TOOL_MECHANICS="$PLUGIN_ROOT/skills/refresh/references/tool-and-output-mechanics.md"
REVIEW_SKILL="$PLUGIN_ROOT/skills/review/SKILL.md"

pass_count=0
fail_count=0

section() {
  printf '\n── %s ──\n' "$1"
}

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

json_field() {
  printf '%s' "$1" | jq -r "$2" 2>/dev/null || printf ''
}

sha256_of_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# Collapse every run of whitespace to one space so a phrase assertion
# against a hard-wrapped reference does not depend on where it breaks.
normalize() {
  printf '%s' "$1" | tr -s '[:space:]' ' '
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/repin-citations.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

section "helper present"

if [ -f "$REPIN_PY" ]; then
  pass "present: ${REPIN_PY#"$TESTS_ROOT"/}"
else
  fail "present: ${REPIN_PY#"$TESTS_ROOT"/}"
fi

# ---------------------------------------------------------------------------
# Fixture: a throwaway repo advanced from OLD to NEW, with one file per
# case the contract names, and a corpus citing each at OLD.
# ---------------------------------------------------------------------------

REPO="$WORK/repo"
mkdir -p "$REPO/docs" "$REPO/docs2"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "skill-engine tests"

printf 'u1\nu2\nu3\n' > "$REPO/unchanged.md"
printf 's1\ns2\ns3\ns4\ns5\ns6\n' > "$REPO/shifted.md"
printf 'e1\ne2\ne3\ne4\ne5\n' > "$REPO/edited.md"
printf 'd1\nd2\n' > "$REPO/deleted.md"
printf 'a1\na2\na3\n' > "$REPO/appended.md"
printf 'i1\ni2\ni3\ni4\ni5\ni6\n' > "$REPO/inside.md"
printf 'docs a\n' > "$REPO/docs/a.md"
printf 'docs2 b\n' > "$REPO/docs2/b.md"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "old"
OLD="$(git -C "$REPO" rev-parse HEAD)"

# The advance: two lines inserted above shifted.md's cited range; line 3 of
# edited.md rewritten inside its cited range; deleted.md gone; two lines
# appended below appended.md's cited range; one line inserted strictly
# inside inside.md's cited range; docs/a.md changed; docs2/ untouched.
printf 'new0\nnew00\ns1\ns2\ns3\ns4\ns5\ns6\n' > "$REPO/shifted.md"
printf 'e1\ne2\nE3 CHANGED\ne4\ne5\n' > "$REPO/edited.md"
rm "$REPO/deleted.md"
printf 'a1\na2\na3\na4\na5\n' > "$REPO/appended.md"
printf 'i1\ni2\ni3\nINSERTED\ni4\ni5\ni6\n' > "$REPO/inside.md"
printf 'docs a changed\n' > "$REPO/docs/a.md"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "new"
NEW="$(git -C "$REPO" rev-parse HEAD)"

FOREIGN="0123456789abcdef0123456789abcdef01234567"

REFS="$WORK/references"
mkdir -p "$REFS/sub"
{
  printf 'Shifted: https://github.com/example/fixture/blob/%s/shifted.md#L4-L6\n\n' "$OLD"
  printf 'Edited: https://github.com/example/fixture/blob/%s/edited.md#L2-L4\n\n' "$OLD"
  printf 'Deleted: https://github.com/example/fixture/blob/%s/deleted.md#L1-L2\n\n' "$OLD"
  printf 'Appended: https://github.com/example/fixture/blob/%s/appended.md#L1-L3\n\n' "$OLD"
  printf 'Inside: https://github.com/example/fixture/blob/%s/inside.md#L2-L5\n\n' "$OLD"
  printf 'Whole file: https://github.com/example/fixture/blob/%s/edited.md\n\n' "$OLD"
  printf 'Changed dir: https://github.com/example/fixture/tree/%s/docs\n\n' "$OLD"
  printf 'Quiet dir: https://github.com/example/fixture/tree/%s/docs2\n' "$OLD"
} > "$REFS/fixture.md"
{
  printf 'Unchanged: https://github.com/example/fixture/blob/%s/unchanged.md#L1-L3\n\n' "$OLD"
  printf 'Foreign: https://github.com/example/fixture/blob/%s/unchanged.md#L1-L3\n' "$FOREIGN"
} > "$REFS/sub/nested.md"
printf 'Prose only, nothing to re-pin.\n' > "$REFS/quiet.md"

hash_refs() {
  local f
  for f in "$REFS/fixture.md" "$REFS/sub/nested.md" "$REFS/quiet.md"; do
    sha256_of_file "$f"
  done
}
BEFORE="$(hash_refs)"

repin() {
  python3 "$REPIN_PY" "$REFS" --repo "$REPO" --old-sha "$OLD" --new-sha "$NEW" "$@" 2>/dev/null || printf ''
}

# ---------------------------------------------------------------------------
# Dry report
# ---------------------------------------------------------------------------

section "dry run classifies every citation and writes nothing"

out="$(repin)"
python3 "$REPIN_PY" "$REFS" --repo "$REPO" --old-sha "$OLD" --new-sha "$NEW" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
  pass "a completed run exits 0 and prints a report"
else
  fail "a completed run exits 0 and prints a report" "rc=$rc output: ${out:-<empty>}"
fi

if [ "$(json_field "$out" '.citations')" = "10" ]; then
  pass "fixture: all ten planted citations are found (non-vacuous)"
else
  fail "fixture: all ten planted citations are found (non-vacuous)" "output: ${out:-<empty>}"
fi

if [ "$(json_field "$out" '.counts.unchanged_file')" = "2" ]; then
  pass "a citation into an unchanged file, and a directory citation nothing changed under, are re-pinned by SHA swap"
else
  fail "a citation into an unchanged file, and a directory citation nothing changed under, are re-pinned by SHA swap" \
    "counts: $(json_field "$out" '.counts')"
fi

if [ "$(json_field "$out" '.counts.remapped_range')" = "2" ]; then
  pass "a range below an insertion, and a range above an append, are remapped (offset 2 and offset 0)"
else
  fail "a range below an insertion, and a range above an append, are remapped (offset 2 and offset 0)" \
    "counts: $(json_field "$out" '.counts')"
fi

if [ "$(json_field "$out" '.counts.needs_review')" = "5" ] \
   && [ "$(json_field "$out" '.all_repinned')" = "false" ]; then
  pass "the five citations whose cited text may have changed are handed to a reader, not guessed"
else
  fail "the five citations whose cited text may have changed are handed to a reader, not guessed" \
    "counts: $(json_field "$out" '.counts')"
fi

if [ "$(json_field "$out" '.counts.other')" = "1" ]; then
  pass "a citation at a different SHA is not this advance and is left alone"
else
  fail "a citation at a different SHA is not this advance and is left alone" \
    "counts: $(json_field "$out" '.counts')"
fi

# The must-reject input: a hunk inside the cited range. This is the case
# that needs a human, and the one an offset-only remap would silently get
# wrong.
reason="$(json_field "$out" '.needs_review[] | select(.path == "edited.md" and .start == 2) | .reason')"
case "$reason" in
  *overlap*) pass "a hunk overlapping the cited range is refused with a reason naming the overlap" ;;
  *) fail "a hunk overlapping the cited range is refused with a reason naming the overlap" "reason: ${reason:-<none>}" ;;
esac

reason="$(json_field "$out" '.needs_review[] | select(.path == "inside.md") | .reason')"
case "$reason" in
  *inserted*inside*) pass "an insertion strictly inside the cited range is refused — the cited lines are no longer contiguous" ;;
  *) fail "an insertion strictly inside the cited range is refused — the cited lines are no longer contiguous" "reason: ${reason:-<none>}" ;;
esac

reason="$(json_field "$out" '.needs_review[] | select(.path == "deleted.md") | .reason')"
case "$reason" in
  *deleted*) pass "a citation into a deleted path is refused with a reason saying so" ;;
  *) fail "a citation into a deleted path is refused with a reason saying so" "reason: ${reason:-<none>}" ;;
esac

n="$(json_field "$out" '[.needs_review[] | select(.path == "edited.md" and .start == null)] | length')"
m="$(json_field "$out" '[.needs_review[] | select(.path == "docs")] | length')"
if [ "$n" = "1" ] && [ "$m" = "1" ]; then
  pass "a whole-file citation into a changed file, and a directory citation something changed under, are refused"
else
  fail "a whole-file citation into a changed file, and a directory citation something changed under, are refused" \
    "needs_review: $(json_field "$out" '.needs_review')"
fi

if [ "$(json_field "$out" '.rewritten | sort | join(",")')" = "fixture.md,sub/nested.md" ] \
   && [ "$(json_field "$out" '.written | length')" = "0" ]; then
  pass "the report names the references whose text would change, and a dry run writes none of them"
else
  fail "the report names the references whose text would change, and a dry run writes none of them" \
    "rewritten: $(json_field "$out" '.rewritten') written: $(json_field "$out" '.written')"
fi

if [ "$(hash_refs)" = "$BEFORE" ]; then
  pass "the input references are byte-for-byte untouched after a dry run"
else
  fail "the input references are byte-for-byte untouched after a dry run"
fi

# ---------------------------------------------------------------------------
# Writing to a proposed tree
# ---------------------------------------------------------------------------

section "--out-dir writes a sparse copy of the rewritten references"

OUT="$WORK/proposed"
out="$(repin --out-dir "$OUT")"

if [ -f "$OUT/fixture.md" ] && [ -f "$OUT/sub/nested.md" ] \
   && [ "$(json_field "$out" '.written | sort | join(",")')" = "fixture.md,sub/nested.md" ]; then
  pass "each rewritten reference lands under --out-dir at its own relative path, nested directories included"
else
  fail "each rewritten reference lands under --out-dir at its own relative path, nested directories included" \
    "written: $(json_field "$out" '.written')"
fi

if [ ! -e "$OUT/quiet.md" ]; then
  pass "a reference with nothing to re-pin is not copied — the proposed tree stays sparse"
else
  fail "a reference with nothing to re-pin is not copied — the proposed tree stays sparse"
fi

written="$(cat "$OUT/fixture.md" 2>/dev/null || printf '')"

if printf '%s' "$written" | grep -Fq "blob/$NEW/shifted.md#L6-L8"; then
  pass "a range below a two-line insertion is rewritten to the new SHA and shifted by two"
else
  fail "a range below a two-line insertion is rewritten to the new SHA and shifted by two" \
    "$(printf '%s' "$written" | grep -F 'shifted.md' || printf '<no shifted citation>')"
fi

if printf '%s' "$written" | grep -Fq "blob/$NEW/appended.md#L1-L3"; then
  pass "a range above an append is rewritten to the new SHA with its numbers unchanged"
else
  fail "a range above an append is rewritten to the new SHA with its numbers unchanged" \
    "$(printf '%s' "$written" | grep -F 'appended.md' || printf '<no appended citation>')"
fi

if printf '%s' "$written" | grep -Fq "tree/$NEW/docs2"; then
  pass "a directory citation nothing changed under is rewritten to the new SHA"
else
  fail "a directory citation nothing changed under is rewritten to the new SHA"
fi

if printf '%s' "$written" | grep -Fq "blob/$OLD/edited.md#L2-L4" \
   && printf '%s' "$written" | grep -Fq "blob/$OLD/deleted.md#L1-L2" \
   && printf '%s' "$written" | grep -Fq "blob/$OLD/inside.md#L2-L5" \
   && printf '%s' "$written" | grep -Fq "blob/$OLD/edited.md" \
   && printf '%s' "$written" | grep -Fq "tree/$OLD/docs"; then
  pass "every needs-review citation is written back byte-for-byte at the old SHA — the report is the worklist, the file is not guessed at"
else
  fail "every needs-review citation is written back byte-for-byte at the old SHA — the report is the worklist, the file is not guessed at" \
    "$(printf '%s' "$written" | grep -F "$OLD" || printf '<no old-sha citation survived>')"
fi

nested="$(cat "$OUT/sub/nested.md" 2>/dev/null || printf '')"
if printf '%s' "$nested" | grep -Fq "blob/$NEW/unchanged.md#L1-L3" \
   && printf '%s' "$nested" | grep -Fq "blob/$FOREIGN/unchanged.md#L1-L3"; then
  pass "in one file, the old-SHA citation is re-pinned and the foreign-SHA citation beside it is untouched"
else
  fail "in one file, the old-SHA citation is re-pinned and the foreign-SHA citation beside it is untouched" \
    "$nested"
fi

if [ "$(hash_refs)" = "$BEFORE" ]; then
  pass "the input references are byte-for-byte untouched after a write — only --out-dir received anything"
else
  fail "the input references are byte-for-byte untouched after a write — only --out-dir received anything"
fi

# ---------------------------------------------------------------------------
# Usage errors
# ---------------------------------------------------------------------------

section "usage errors are loud"

python3 "$REPIN_PY" "$REFS" --repo "$REPO" --old-sha "$OLD" --new-sha "$FOREIGN" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 1 ]; then
  pass "a SHA that does not resolve in the clone exits 1 rather than reporting an empty advance"
else
  fail "a SHA that does not resolve in the clone exits 1 rather than reporting an empty advance" "rc=$rc"
fi

python3 "$REPIN_PY" "$WORK/no-such-dir" --repo "$REPO" --old-sha "$OLD" --new-sha "$NEW" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 1 ]; then
  pass "a missing references directory exits 1"
else
  fail "a missing references directory exits 1" "rc=$rc"
fi

# ---------------------------------------------------------------------------
# Doctrine wiring: REFRESH runs the re-pin before its re-read, reports the
# counts, and the reviewer knows an all-mechanical run has an empty
# disagreement set by construction.
# ---------------------------------------------------------------------------

section "doctrine names the re-pin step"

drift="$(normalize "$(cat "$DRIFT_PHASES" 2>/dev/null || printf '')")"
case "$drift" in
  *repin_citations.py*--out-dir*)
    pass "drift-detection-and-phases.md § Re-read scoping invokes repin_citations.py with --out-dir before the re-read" ;;
  *)
    fail "drift-detection-and-phases.md § Re-read scoping invokes repin_citations.py with --out-dir before the re-read" ;;
esac

case "$drift" in
  *needs_review*)
    pass "drift-detection-and-phases.md tells the model the needs_review list is what it reads" ;;
  *)
    fail "drift-detection-and-phases.md tells the model the needs_review list is what it reads" ;;
esac

mech="$(normalize "$(cat "$TOOL_MECHANICS" 2>/dev/null || printf '')")"
case "$mech" in
  *"Re-pinned:"*)
    pass "tool-and-output-mechanics.md § Post-run summary carries the re-pin counts line in the Coverage report" ;;
  *)
    fail "tool-and-output-mechanics.md § Post-run summary carries the re-pin counts line in the Coverage report" ;;
esac

review="$(normalize "$(cat "$REVIEW_SKILL" 2>/dev/null || printf '')")"
case "$review" in
  *"Re-pinned:"*)
    pass "review/SKILL.md Step 2 carries the re-pin counts as a report-only line, and expects an empty disagreement set from an all-mechanical run" ;;
  *)
    fail "review/SKILL.md Step 2 carries the re-pin counts as a report-only line, and expects an empty disagreement set from an all-mechanical run" ;;
esac

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"

[ "$fail_count" -eq 0 ]
