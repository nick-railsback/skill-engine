#!/usr/bin/env bash
# Feature-scoped test runner for the two helpers the dogfood-corpus oracle
# uses to decide whether its recorded pin can still be checked against this
# repo's history:
#
#   dogfood-corpus-refresh/pin_state.py
#   dogfood-corpus-refresh/permalink_scan.py --resolve-at <rev>
#
# Why this suite exists. The dogfood contextualizer pins its corpus to a
# commit of *this* repo, and the pin is necessarily recorded on the feature
# branch that harvests the corpus. This repo squash-merges: the branch
# commit the pin names is not an ancestor of main afterward, and once the
# branch ref is gone the commit object is not even reachable. An oracle that
# asserts `merge-base --is-ancestor <pin> HEAD` therefore cannot survive its
# own merge — it is green on the branch and red on main forever after, for a
# reason no re-run can fix.
#
# The fix is not to loosen the assertion but to split the three states apart
# and assert something true in each. pin_state.py is that classifier, and
# these fixtures are the squash-merge it has to survive, built offline in a
# throwaway repo:
#
#   ancestor      object present, and an ancestor of the named rev.
#                 The pin is checkable; the oracle's strict tier applies.
#   divergent     object present, NOT an ancestor, and some ref still
#                 contains it. A pin from a foreign or unmerged branch — a
#                 real defect, and the state the original ancestry
#                 assertion was written to catch.
#   unresolvable  no ref contains the object. The post-squash-merge state,
#                 and also what a fabricated sha looks like. Nothing about
#                 the pin can be checked; the oracle substitutes structural
#                 resolution against HEAD, which is what --resolve-at
#                 exists for.
#
# The last two are separated by ref reachability, not by whether the object
# is on disk, and the difference is not academic. Deleting a squash-merged
# branch leaves its commits in the object store until gc runs, so a
# presence test answers "yes, divergent" in the maintainer's clone for
# weeks while a fresh CI checkout — which never fetched the object — answers
# "no, unresolvable". One corpus, two verdicts, decided by whose disk it
# sits on. That is how a merge to main went red through this classifier
# despite the classifier existing to prevent it, and it is why the fixture
# below asserts the deleted-but-not-yet-collected state on its own.
#
# Contract frozen here, since nothing upstream pins either interface:
#
#   python3 pin_state.py --repo-root <path> --sha <sha> [--rev <rev>]
#
#     Exits 0 always — a data-gathering classifier, not a gate; the caller
#     applies its own assertions. Writes exactly one JSON object to stdout:
#
#       {"sha": "<as given>", "rev": "<as given, default HEAD>",
#        "object_present": <bool>, "ref_reachable": <bool>,
#        "is_ancestor": <bool>,
#        "state": "ancestor" | "divergent" | "unresolvable"}
#
#     is_ancestor is false whenever object_present is false — an absent
#     object is never reported as an ancestor. ref_reachable is false
#     whenever object_present is false, and is what separates 'divergent'
#     from 'unresolvable' when the object is present but not an ancestor.
#
#   python3 pin_state.py ... --tag-match <glob>
#
#     Additive: every key above is unchanged, and three more are emitted
#     (also emitted, with latest_tag null and compare_rev == rev, when the
#     flag is absent):
#
#       "latest_tag": "<tag>" | null,
#       "compare_rev": "<tag>" | "<sha>" | "<rev>",
#       "compare_reason": "<one line>"
#
#     latest_tag is the nearest tag matching <glob> reachable from <rev>
#     — the glob is what keeps a non-release tag out. compare_rev is the
#     revision the caller should diff the pin's cited paths against to
#     decide whether the corpus is stale in substance: the tag when the
#     pin precedes it (the window pin..tag is what a release would have
#     shipped without); the pin itself when the pin is at or past the tag
#     (an empty window — the corpus is at least as current as the last
#     release, and the next tag is what re-opens it); <rev> when no tag
#     matches (the strict HEAD-relative comparison this replaced) or the
#     pin is not an 'ancestor'. Why the tag and not HEAD: measured against
#     HEAD, every cited-path commit re-staled the dogfood corpus and the
#     oracle was red on main for nine consecutive pushes across two
#     releases; the property the corpus promises is "true as of the last
#     release".
#
#   python3 permalink_scan.py <refs> --repo-root <p> --expected-sha <s>
#           [--resolve-at <rev>]
#
#     With --resolve-at, the structural check resolves every permalink's
#     path and line range at <rev> instead of at the sha the permalink
#     itself cites. Everything else about the output is unchanged, and the
#     emitted JSON records which rev was used as "resolved_at".
#
# Read-only over this repo: every git mutation below targets a throwaway
# tmpdir repo this script creates and deletes.
#
# -e is intentionally omitted: every assertion must run and report, not
# abort at the first red one.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PIN_STATE_PY="$TESTS_ROOT/dogfood-corpus-refresh/pin_state.py"
PERMALINK_SCAN_PY="$TESTS_ROOT/dogfood-corpus-refresh/permalink_scan.py"

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

TMPDIR_CASE="$(mktemp -d "${TMPDIR:-/tmp}/dogfood-pin-state.XXXXXX")"
cleanup() { rm -rf "$TMPDIR_CASE"; }
trap cleanup EXIT

section "helpers present"

for f in "$PIN_STATE_PY" "$PERMALINK_SCAN_PY"; do
  if [ -f "$f" ]; then
    pass "present: ${f#"$TESTS_ROOT"/}"
  else
    fail "present: ${f#"$TESTS_ROOT"/}"
  fi
done

# ---------------------------------------------------------------------------
# Fixture: a throwaway repo carrying the exact history shape this repo has.
#
#   main:     c1 ── c2 ─────────── squash
#   feature:        └── f1 ── f2        (merged with --squash, then deleted)
#   other:    └── o1                    (never merged; still referenced)
#
# After `git branch -D feature` plus a reflog expiry and a prune, f2's
# object is gone — the same view a fresh `actions/checkout` of main gets,
# where `fetch-depth: 0` fetches every ref but no unreachable object.
# ---------------------------------------------------------------------------

FIXTURE="$TMPDIR_CASE/repo"
mkdir -p "$FIXTURE"

git -C "$FIXTURE" init -q -b main
git -C "$FIXTURE" config user.email "test@example.com"
git -C "$FIXTURE" config user.name "skill-engine tests"
git -C "$FIXTURE" config gc.reflogExpire now
git -C "$FIXTURE" config gc.reflogExpireUnreachable now

printf 'line one\nline two\nline three\n' > "$FIXTURE/quoted.md"
git -C "$FIXTURE" add -A
git -C "$FIXTURE" commit -q -m "c1"
C1="$(git -C "$FIXTURE" rev-parse HEAD)"

printf 'line one\nline two\nline three\nline four\n' > "$FIXTURE/quoted.md"
git -C "$FIXTURE" add -A
git -C "$FIXTURE" commit -q -m "c2"
C2="$(git -C "$FIXTURE" rev-parse HEAD)"

# A branch that is never merged: its tip stays reachable (the ref holds it)
# but is not an ancestor of main.
git -C "$FIXTURE" checkout -q -b other
printf 'sideways\n' > "$FIXTURE/other.md"
git -C "$FIXTURE" add -A
git -C "$FIXTURE" commit -q -m "o1"
O1="$(git -C "$FIXTURE" rev-parse HEAD)"

# The feature branch that harvests the corpus and records the pin.
git -C "$FIXTURE" checkout -q main
git -C "$FIXTURE" checkout -q -b feature
printf 'line one\nline two\nline three\nline four\nline five\n' > "$FIXTURE/quoted.md"
git -C "$FIXTURE" add -A
git -C "$FIXTURE" commit -q -m "f1"
printf 'line one\nline two\nline three\nline four\nline five\nline six\n' > "$FIXTURE/quoted.md"
git -C "$FIXTURE" add -A
git -C "$FIXTURE" commit -q -m "f2"
F2="$(git -C "$FIXTURE" rev-parse HEAD)"

section "pin_state classifies a pin that is an ancestor of the named rev"

pin_state() {
  python3 "$PIN_STATE_PY" --repo-root "$FIXTURE" --sha "$1" ${2:+--rev "$2"} 2>/dev/null || printf ''
}

json_field() {
  printf '%s' "$1" | jq -r "$2" 2>/dev/null || printf ''
}

# On the feature branch, the pin the branch just recorded is an ancestor of
# HEAD — the state every pre-merge run sees, and the only one the original
# assertion handled.
out="$(pin_state "$F2")"
if [ "$(json_field "$out" '.state')" = "ancestor" ] \
   && [ "$(json_field "$out" '.object_present')" = "true" ] \
   && [ "$(json_field "$out" '.is_ancestor')" = "true" ]; then
  pass "a pin naming a commit on the checked-out branch classifies as 'ancestor'"
else
  fail "a pin naming a commit on the checked-out branch classifies as 'ancestor'" \
    "pin_state output: ${out:-<empty — helper did not run>}"
fi

out="$(pin_state "$C1")"
if [ "$(json_field "$out" '.state')" = "ancestor" ]; then
  pass "a pin naming an older commit on the same line classifies as 'ancestor'"
else
  fail "a pin naming an older commit on the same line classifies as 'ancestor'" \
    "pin_state output: ${out:-<empty — helper did not run>}"
fi

section "pin_state separates a foreign pin from an absent one"

# The defect the ancestry assertion was actually written to catch: a sha
# that resolves, but belongs to a branch this history never took up. It
# must stay a hard failure, so it cannot be folded into the absent case.
out="$(pin_state "$O1")"
if [ "$(json_field "$out" '.state')" = "divergent" ] \
   && [ "$(json_field "$out" '.object_present')" = "true" ] \
   && [ "$(json_field "$out" '.is_ancestor')" = "false" ]; then
  pass "a pin naming an unmerged sibling branch's tip classifies as 'divergent'"
else
  fail "a pin naming an unmerged sibling branch's tip classifies as 'divergent'" \
    "pin_state output: ${out:-<empty — helper did not run>}"
fi

# A sha of the right shape that names nothing. Structurally identical, from
# git's point of view, to a pin whose commit has been squashed away.
FABRICATED="0123456789abcdef0123456789abcdef01234567"
out="$(pin_state "$FABRICATED")"
if [ "$(json_field "$out" '.state')" = "unresolvable" ] \
   && [ "$(json_field "$out" '.object_present')" = "false" ] \
   && [ "$(json_field "$out" '.is_ancestor')" = "false" ]; then
  pass "a well-formed sha naming no object classifies as 'unresolvable', never as an ancestor"
else
  fail "a well-formed sha naming no object classifies as 'unresolvable', never as an ancestor" \
    "pin_state output: ${out:-<empty — helper did not run>}"
fi

section "pin_state survives the squash-merge that orphans the pin"

# The merge this repo actually performs, and the deletion + prune that
# follows it. F2 is the pin recorded on the branch; after this it names
# nothing.
git -C "$FIXTURE" checkout -q main
git -C "$FIXTURE" merge -q --squash feature >/dev/null 2>&1
git -C "$FIXTURE" commit -q -m "squash: feature"
SQUASH="$(git -C "$FIXTURE" rev-parse HEAD)"
git -C "$FIXTURE" branch -q -D feature

# Assert the intermediate state before collecting it away. This is where a
# maintainer's clone sits from the moment the PR merges until gc happens to
# run — which may be never — and the fixture used to step straight over it,
# which is why the presence-vs-reachability bug survived the suite.
if git -C "$FIXTURE" cat-file -e "${F2}^{commit}" 2>/dev/null; then
  pass "fixture: deleting the branch leaves the pinned commit's object on disk, uncollected"
else
  fail "fixture: deleting the branch leaves the pinned commit's object on disk, uncollected" \
    "$F2 is already absent — the fixture skipped the state these two assertions exist to cover"
fi

out="$(pin_state "$F2")"
if [ "$(json_field "$out" '.state')" = "unresolvable" ] \
   && [ "$(json_field "$out" '.object_present')" = "true" ] \
   && [ "$(json_field "$out" '.ref_reachable')" = "false" ]; then
  pass "an orphaned pin still on disk classifies as 'unresolvable' — the same verdict a fresh checkout reaches, on the same corpus"
else
  fail "an orphaned pin still on disk classifies as 'unresolvable' — the same verdict a fresh checkout reaches, on the same corpus" \
    "pin_state output: ${out:-<empty — helper did not run>}"
fi

# The guard on that split: 'other' is still a live ref, so its tip must
# stay 'divergent'. Reachability must not have folded the defect case into
# the lifecycle case.
out="$(pin_state "$O1")"
if [ "$(json_field "$out" '.state')" = "divergent" ] \
   && [ "$(json_field "$out" '.ref_reachable')" = "true" ]; then
  pass "a pin on a branch that still exists stays 'divergent' — reachability narrowed the hard-fail arm without emptying it"
else
  fail "a pin on a branch that still exists stays 'divergent' — reachability narrowed the hard-fail arm without emptying it" \
    "pin_state output: ${out:-<empty — helper did not run>}"
fi

git -C "$FIXTURE" reflog expire --expire=now --expire-unreachable=now --all
git -C "$FIXTURE" gc --prune=now --quiet

if [ "$SQUASH" != "$C2" ]; then
  pass "fixture: the squash produced a new commit on main (the branch's own commits are not on its first-parent line)"
else
  fail "fixture: the squash produced a new commit on main (the branch's own commits are not on its first-parent line)"
fi

if git -C "$FIXTURE" cat-file -e "${F2}^{commit}" 2>/dev/null; then
  fail "fixture: the pinned branch commit's object is gone after the squash-merge, branch deletion, and prune" \
    "$F2 is still present — the fixture did not reproduce the state a fresh checkout of main sees"
else
  pass "fixture: the pinned branch commit's object is gone after the squash-merge, branch deletion, and prune"
fi

# This is the finding. Before the split, the oracle asserted ancestry here
# and went red on main with no re-run able to fix it.
out="$(pin_state "$F2")"
if [ "$(json_field "$out" '.state')" = "unresolvable" ] \
   && [ "$(json_field "$out" '.is_ancestor')" = "false" ]; then
  pass "the pin recorded on the branch classifies as 'unresolvable' — not 'divergent' — once squash-merged away"
else
  fail "the pin recorded on the branch classifies as 'unresolvable' — not 'divergent' — once squash-merged away" \
    "pin_state output: ${out:-<empty — helper did not run>}"
fi

# The squash commit itself is a perfectly good pin. Re-pinning is the cure
# for 'unresolvable', and the classifier has to say so.
out="$(pin_state "$SQUASH")"
if [ "$(json_field "$out" '.state')" = "ancestor" ]; then
  pass "re-pinning to the squash commit restores the 'ancestor' state"
else
  fail "re-pinning to the squash commit restores the 'ancestor' state" \
    "pin_state output: ${out:-<empty — helper did not run>}"
fi

section "permalink_scan resolves at an explicit rev when asked"

# A corpus whose permalinks cite the orphaned pin. Resolving at the cited
# sha is impossible now; resolving at HEAD is both possible and meaningful,
# because a squash-merge leaves HEAD's tree equal to the branch tip's.
REFS="$TMPDIR_CASE/references"
mkdir -p "$REFS"
{
  printf 'Body text.\n\n'
  printf 'A citation: https://github.com/example/fixture/blob/%s/quoted.md#L1-L6\n' "$F2"
} > "$REFS/fixture.md"

scan() {
  python3 "$PERMALINK_SCAN_PY" "$REFS" --repo-root "$FIXTURE" \
    --expected-sha "$F2" --owner-repo example/fixture "$@" 2>/dev/null || printf ''
}

out="$(scan)"
if [ "$(json_field "$out" '.permalink_count')" = "1" ]; then
  pass "fixture: the scan finds the single permalink planted in the corpus (non-vacuous)"
else
  fail "fixture: the scan finds the single permalink planted in the corpus (non-vacuous)" \
    "scan output: ${out:-<empty — scan did not run>}"
fi

if [ "$(json_field "$out" '.structural_fail_count')" = "1" ]; then
  pass "without --resolve-at, a permalink citing the orphaned sha cannot resolve (the state the oracle must not assert into)"
else
  fail "without --resolve-at, a permalink citing the orphaned sha cannot resolve (the state the oracle must not assert into)" \
    "scan output: ${out:-<empty — scan did not run>}"
fi

out="$(scan --resolve-at HEAD)"
if [ "$(json_field "$out" '.structural_fail_count')" = "0" ] \
   && [ "$(json_field "$out" '.structural_ok_count')" = "1" ]; then
  pass "with --resolve-at HEAD, the same permalink's path and line range resolve against the merged tree"
else
  fail "with --resolve-at HEAD, the same permalink's path and line range resolve against the merged tree" \
    "scan output: ${out:-<empty — scan did not run>}"
fi

if [ "$(json_field "$out" '.resolved_at')" = "HEAD" ]; then
  pass "the scan records which rev it resolved against, so a degraded run cannot be mistaken for a strict one"
else
  fail "the scan records which rev it resolved against, so a degraded run cannot be mistaken for a strict one" \
    "scan output: ${out:-<empty — scan did not run>}"
fi

# The fallback still has teeth: a citation whose line range runs past the
# end of the file at HEAD is a real corpus defect, and resolving at HEAD
# has to keep catching it.
{
  printf 'Body text.\n\n'
  printf 'An overrun: https://github.com/example/fixture/blob/%s/quoted.md#L1-L99\n' "$F2"
} > "$REFS/fixture.md"

out="$(scan --resolve-at HEAD)"
if [ "$(json_field "$out" '.structural_fail_count')" = "1" ]; then
  pass "resolving at HEAD still fails a citation whose line range overruns the file (the fallback is a check, not a bypass)"
else
  fail "resolving at HEAD still fails a citation whose line range overruns the file (the fallback is a check, not a bypass)" \
    "scan output: ${out:-<empty — scan did not run>}"
fi

section "pin_state names the release tag the pin should be diffed against"

# The fixture's main line is now c1 ── c2 ── squash. Tags are laid down
# here, after every classification case above ran untagged, so nothing
# above depended on them.
#
# A non-release tag on the newest commit first: it must never be chosen.
# Then a release tag on c2, with the squash commit sitting past it — the
# shape main has between a release and the next one, with the pin either
# side of the tag.
git -C "$FIXTURE" tag post-fixture "$SQUASH"
git -C "$FIXTURE" tag v0.1.0 "$C2"

TAG_GLOB="v[0-9]*"

pin_state_tagged() {
  python3 "$PIN_STATE_PY" --repo-root "$FIXTURE" --sha "$1" --tag-match "$TAG_GLOB" 2>/dev/null || printf ''
}

# Pin before the tag: the window pin..tag is the one that matters.
out="$(pin_state_tagged "$C1")"
if [ "$(json_field "$out" '.latest_tag')" = "v0.1.0" ] \
   && [ "$(json_field "$out" '.compare_rev')" = "v0.1.0" ] \
   && [ "$(json_field "$out" '.state')" = "ancestor" ]; then
  pass "a pin that precedes the latest release tag is compared against that tag, not HEAD"
else
  fail "a pin that precedes the latest release tag is compared against that tag, not HEAD" \
    "pin_state output: ${out:-<empty — helper did not run>}"
fi

# The non-release tag sits on the newest commit; the glob must skip it.
if [ "$(json_field "$out" '.latest_tag')" != "post-fixture" ]; then
  pass "a tag outside the release glob on a newer commit is not read as the latest release"
else
  fail "a tag outside the release glob on a newer commit is not read as the latest release" \
    "pin_state output: ${out:-<empty — helper did not run>}"
fi

# Pin exactly at the tag: an ancestor of itself, so the window is pin..tag
# and empty.
out="$(pin_state_tagged "$C2")"
if [ "$(json_field "$out" '.compare_rev')" = "v0.1.0" ]; then
  pass "a pin at the tagged commit itself is compared against the tag (an empty window)"
else
  fail "a pin at the tagged commit itself is compared against the tag (an empty window)" \
    "pin_state output: ${out:-<empty — helper did not run>}"
fi

# Pin past the tag: the corpus is more current than the release. Nothing
# to diff — the comparison revision is the pin itself, and the reason
# says so. This is the state main is in after a mid-cycle refresh, and it
# is green, not red.
out="$(pin_state_tagged "$SQUASH")"
if [ "$(json_field "$out" '.latest_tag')" = "v0.1.0" ] \
   && [ "$(json_field "$out" '.compare_rev')" = "$SQUASH" ] \
   && [ "$(json_field "$out" '.state')" = "ancestor" ]; then
  pass "a pin past the latest release tag is compared against itself — an empty window, not a HEAD-relative one"
else
  fail "a pin past the latest release tag is compared against itself — an empty window, not a HEAD-relative one" \
    "pin_state output: ${out:-<empty — helper did not run>}"
fi

# The next release re-opens the window: tag the newest commit and the pin
# that was past v0.1.0 now precedes v0.2.0. This is the post-release red
# that names the owed refresh.
git -C "$FIXTURE" tag v0.2.0 "$SQUASH"
out="$(pin_state_tagged "$C2")"
if [ "$(json_field "$out" '.latest_tag')" = "v0.2.0" ] \
   && [ "$(json_field "$out" '.compare_rev')" = "v0.2.0" ]; then
  pass "a new release tag past the pin re-opens the window: the pin is compared against the new tag"
else
  fail "a new release tag past the pin re-opens the window: the pin is compared against the new tag" \
    "pin_state output: ${out:-<empty — helper did not run>}"
fi

# A glob that matches nothing falls back to <rev>: the strict comparison
# this flag replaced, not a silently empty window.
out="$(python3 "$PIN_STATE_PY" --repo-root "$FIXTURE" --sha "$C1" --tag-match 'release-[0-9]*' 2>/dev/null || printf '')"
if [ "$(json_field "$out" '.latest_tag')" = "null" ] \
   && [ "$(json_field "$out" '.compare_rev')" = "HEAD" ]; then
  pass "with no tag matching the glob, the comparison falls back to the named rev (HEAD)"
else
  fail "with no tag matching the glob, the comparison falls back to the named rev (HEAD)" \
    "pin_state output: ${out:-<empty — helper did not run>}"
fi

# The keys are additive: a caller that never passes the flag sees the
# same six keys it always did, with the three new ones inert.
out="$(pin_state "$C1")"
if [ "$(json_field "$out" '.state')" = "ancestor" ] \
   && [ "$(json_field "$out" '.latest_tag')" = "null" ] \
   && [ "$(json_field "$out" '.compare_rev')" = "HEAD" ]; then
  pass "without --tag-match the classification is unchanged and the comparison is the named rev"
else
  fail "without --tag-match the classification is unchanged and the comparison is the named rev" \
    "pin_state output: ${out:-<empty — helper did not run>}"
fi

# A divergent pin is decided by its state; no tag can rescue it.
out="$(pin_state_tagged "$O1")"
if [ "$(json_field "$out" '.state')" = "divergent" ] \
   && [ "$(json_field "$out" '.compare_rev')" = "HEAD" ]; then
  pass "a divergent pin stays divergent under --tag-match; the tag never softens the hard-fail arm"
else
  fail "a divergent pin stays divergent under --tag-match; the tag never softens the hard-fail arm" \
    "pin_state output: ${out:-<empty — helper did not run>}"
fi

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"

[ "$fail_count" -eq 0 ]
