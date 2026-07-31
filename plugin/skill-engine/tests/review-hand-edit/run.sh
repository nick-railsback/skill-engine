#!/usr/bin/env bash
# Black-box test runner for the hand-edit detector: a comparison that tells
# a reviewer when a file they are about to re-generate was hand-edited in
# the live tree since the engine itself last wrote it.
#
# The idea: every promoted contextualizer carries, at
# `<live>/.review/manifest.json`, the exact manifest that drove its most
# recent promotion — including the `sha_after` this engine itself wrote for
# every file at that time (an already-shipped convention; see
# `promotion-and-reconciliation.md` § Promotion step 3, which moves
# `<proposed>/.review/manifest.json` to that live path on every apply). A
# newly staged proposal's own manifest,
# `<proposed>/.review/manifest.json`, records `sha_before` for each
# `modified` entry — the hash the live file had when this run started. If
# the live manifest's `sha_after` for that path no longer matches the new
# proposal's `sha_before`, something touched the live file after the engine
# wrote it and before this run staged its comparison — most plausibly a
# hand edit. `review` is where a human is already looking at a proposal, so
# it is where this gets surfaced.
#
# Nothing upstream pins this comparison's CLI or output shape, so this
# suite designs and freezes both here, the same way each sibling
# deterministic script under this same tests/ directory (status_probe.py,
# decay_check.py, navigator_budget.py, permalink_density.py) had its own
# CLI/output contract designed by its own oracle before it existed:
#
#   python3 hand_edit_check.py <proposal-manifest.json> <live-manifest.json>
#
#   Positional arguments are file paths, not directories: the caller
#   resolves `<install>/<name>-context.proposed/.review/manifest.json` and
#   `<install>/<name>-context/.review/manifest.json` itself and hands both
#   paths straight through. `<live-manifest.json>` is allowed not to exist
#   on disk at all — the contextualizer's first-ever promotion has not
#   happened yet, so there is no live `.review/` directory yet either — and
#   the script must treat that exactly like "no data to compare against"
#   rather than raising an error: a live-manifest argument that turns out
#   missing, unreadable, or unparseable reads as an empty set of live
#   entries, and the run proceeds with an empty comparison result for every
#   path it would otherwise have compared. `<proposal-manifest.json>` is
#   expected to exist (a proposal without a manifest is a distinct,
#   already-handled failure mode elsewhere in `review`'s own edge cases,
#   not this comparison's job).
#
#   Exits 0 and writes exactly one JSON array to stdout, one object per
#   flagged path — a path is flagged only when ALL of the following hold:
#     - its entry in the proposal manifest has `status == "modified"`
#       (an `added`, `removed`, or `unchanged` proposal entry is never even
#       considered, regardless of what values its `sha_before`/`sha_after`
#       carry);
#     - the live manifest has an entry for the same `path` whose
#       `sha_after` is present and non-null (a live entry that doesn't
#       exist, or exists with a null `sha_after`, contributes no flag for
#       that path — there is nothing to compare against);
#     - that live entry's `sha_after` differs from the proposal entry's
#       `sha_before`.
#   Each flagged element is shaped:
#
#   {
#     "path": "<path>",
#     "proposal_sha_before": "<sha the new proposal recorded before this run's own edits>",
#     "live_sha_after": "<sha the live manifest recorded when it was last written by a promotion>"
#   }
#
#   A run with zero flagged paths still writes a valid, empty JSON array
#   (`[]`) — the same "always emit valid JSON, even when the interesting
#   set is empty" convention status_probe.py and decay_check.py already
#   use — so a caller can always safely parse stdout. The array is never
#   truncated: every flagged path is included, with no upper bound (in
#   particular, nothing here caps output at 9 elements — that cap belongs
#   to a different, unrelated ranked list `review` builds elsewhere, not to
#   this comparison). The script is read-only: it never writes to either
#   manifest file, and it makes no network call — its two arguments are
#   local file paths, and every comparison it performs reads bytes already
#   on disk.
#
# Neither hand_edit_check.py nor the review/SKILL.md section that invokes
# it exists yet — that is what makes this oracle red right now. It turns
# green once both land matching the contract above and the doc-side
# assertions below.
#
# Fixture style: plain JSON manifest files (and, for the read-only checks,
# a small fixture directory tree standing in for a live/proposed
# contextualizer pair) built under a tmpdir — no git repo and no network
# involved anywhere in this comparison.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HAND_EDIT_SCRIPT="$PLUGIN_ROOT/tests/hand_edit_check.py"
REVIEW_SKILL="$PLUGIN_ROOT/skills/review/SKILL.md"

pass_count=0
fail_count=0

TMPDIR_CASE="$(mktemp -d -t skill-engine-review-hand-edit.XXXXXX)"
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

sha256_of_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

# jq_check <json> <jq-boolean-program> [--arg name value ...] — true (rc 0)
# only when the input is valid JSON AND the boolean program evaluates true.
jq_check() {
  local json="$1" program="$2"
  shift 2
  printf '%s' "$json" | jq -e "$@" "$program" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Fixture builders: manifest.json entries/files, matching the schema
# documented in staging-and-contextualizer-model.md (schema_version 1,
# entries[].path/.status/.sha_before/.sha_after, with the null-field
# convention: added ⇒ sha_before null, removed ⇒ sha_after null,
# unchanged ⇒ both populated and equal).
# ---------------------------------------------------------------------------

# manifest_entry <path> <status> <sha-before-or-"null"> <sha-after-or-"null">
# Prints one manifest entry as a standalone JSON object.
manifest_entry() {
  local entry_path="$1" entry_status="$2" sha_before="$3" sha_after="$4"
  local before_json after_json
  if [ "$sha_before" = "null" ]; then
    before_json="null"
  else
    before_json="$(jq -n --arg s "$sha_before" '$s')"
  fi
  if [ "$sha_after" = "null" ]; then
    after_json="null"
  else
    after_json="$(jq -n --arg s "$sha_after" '$s')"
  fi
  jq -n --arg entry_path "$entry_path" --arg entry_status "$entry_status" --argjson before "$before_json" --argjson after "$after_json" \
    '{path: $entry_path, status: $entry_status, sha_before: $before, sha_after: $after}'
}

# write_manifest_file <out-path> [entry-json ...]
write_manifest_file() {
  local out="$1"
  shift
  if [ "$#" -eq 0 ]; then
    printf '{"schema_version":1,"entries":[]}\n' > "$out"
  else
    printf '%s\n' "$@" | jq -s '{schema_version: 1, entries: .}' > "$out"
  fi
}

# run_check <proposal-manifest> <live-manifest> — invokes the script under
# test, capturing stdout into HAND_EDIT_OUT and its exit code into
# HAND_EDIT_RC. A missing script (today) collapses to empty stdout and a
# non-zero exit; every check below independently requires valid, specific
# JSON content or rc == 0, so a missing script always reads as a failure
# for the right reason rather than a vacuous pass.
run_check() {
  HAND_EDIT_OUT="$(python3 "$HAND_EDIT_SCRIPT" "$1" "$2" 2>/dev/null)"
  HAND_EDIT_RC=$?
}

# path_flagged <output> <path> <expected-proposal-sha-before> <expected-live-sha-after>
path_flagged() {
  jq_check "$1" '
      (first(.[] | select(.path == $p))) as $e
      | $e != null and $e.proposal_sha_before == $b and $e.live_sha_after == $a
  ' --arg p "$2" --arg b "$3" --arg a "$4"
}

# path_absent <output> <path> — the path names no element in the array at
# all (whether because it was never a candidate or because it compared
# equal).
path_absent() {
  jq_check "$1" '([.[].path] | index($p)) == null' --arg p "$2"
}

echo
echo "── hand-edit mismatch: a modified entry's proposal sha_before differing from the live manifest's sha_after is flagged with both values ──"

mismatch_proposal="$TMPDIR_CASE/mismatch-proposal.json"
mismatch_live="$TMPDIR_CASE/mismatch-live.json"
write_manifest_file "$mismatch_proposal" \
  "$(manifest_entry "references/mismatched.md" "modified" "prop-before-111" "prop-after-222")" \
  "$(manifest_entry "references/matched.md" "modified" "same-333" "prop-after-444")"
write_manifest_file "$mismatch_live" \
  "$(manifest_entry "references/mismatched.md" "modified" "live-before-000" "live-after-999")" \
  "$(manifest_entry "references/matched.md" "modified" "live-before-555" "same-333")"
run_check "$mismatch_proposal" "$mismatch_live"

if path_flagged "$HAND_EDIT_OUT" "references/mismatched.md" "prop-before-111" "live-after-999"; then
  pass "a modified entry whose proposal sha_before differs from the live manifest's sha_after for the same path is flagged, carrying both the proposal's sha_before and the live manifest's sha_after"
else
  fail "a modified entry whose proposal sha_before differs from the live manifest's sha_after for the same path is flagged, carrying both the proposal's sha_before and the live manifest's sha_after" \
    "stdout: ${HAND_EDIT_OUT:-<empty>}"
fi

if path_absent "$HAND_EDIT_OUT" "references/matched.md"; then
  pass "a modified entry whose proposal sha_before equals the live manifest's sha_after for the same path is not flagged"
else
  fail "a modified entry whose proposal sha_before equals the live manifest's sha_after for the same path is not flagged" \
    "stdout: ${HAND_EDIT_OUT:-<empty>}"
fi

echo
echo "── missing live data degrades to no flag, never an error ──"

absent_manifest_proposal="$TMPDIR_CASE/absent-manifest-proposal.json"
absent_manifest_live="$TMPDIR_CASE/no-such-live-manifest.json"
write_manifest_file "$absent_manifest_proposal" \
  "$(manifest_entry "references/first-promotion.md" "modified" "prop-before-aaa" "prop-after-bbb")"
run_check "$absent_manifest_proposal" "$absent_manifest_live"

if [ "$HAND_EDIT_RC" -eq 0 ] && jq_check "$HAND_EDIT_OUT" '. == []'; then
  pass "a live manifest that does not exist on disk at all (the contextualizer has never been promoted) produces an empty result and a clean exit, not an error"
else
  fail "a live manifest that does not exist on disk at all (the contextualizer has never been promoted) produces an empty result and a clean exit, not an error" \
    "rc=$HAND_EDIT_RC stdout: ${HAND_EDIT_OUT:-<empty>}"
fi

nomatch_proposal="$TMPDIR_CASE/nomatch-proposal.json"
nomatch_live="$TMPDIR_CASE/nomatch-live.json"
write_manifest_file "$nomatch_proposal" \
  "$(manifest_entry "references/no-live-counterpart.md" "modified" "prop-before-ccc" "prop-after-ddd")" \
  "$(manifest_entry "references/has-live-counterpart.md" "modified" "prop-before-eee" "prop-after-fff")"
write_manifest_file "$nomatch_live" \
  "$(manifest_entry "references/an-unrelated-path.md" "modified" "live-before-ggg" "live-after-hhh")" \
  "$(manifest_entry "references/has-live-counterpart.md" "modified" "live-before-iii" "live-after-jjj")"
run_check "$nomatch_proposal" "$nomatch_live"

if path_absent "$HAND_EDIT_OUT" "references/no-live-counterpart.md"; then
  pass "a modified entry whose path has no entry at all in an otherwise-present live manifest is not flagged"
else
  fail "a modified entry whose path has no entry at all in an otherwise-present live manifest is not flagged" \
    "stdout: ${HAND_EDIT_OUT:-<empty>}"
fi

if path_flagged "$HAND_EDIT_OUT" "references/has-live-counterpart.md" "prop-before-eee" "live-after-jjj"; then
  pass "a missing live counterpart for one path does not suppress a real mismatch correctly detected for a different path in the same run"
else
  fail "a missing live counterpart for one path does not suppress a real mismatch correctly detected for a different path in the same run" \
    "stdout: ${HAND_EDIT_OUT:-<empty>}"
fi

nullsha_proposal="$TMPDIR_CASE/nullsha-proposal.json"
nullsha_live="$TMPDIR_CASE/nullsha-live.json"
write_manifest_file "$nullsha_proposal" \
  "$(manifest_entry "references/live-side-removed.md" "modified" "prop-before-kkk" "prop-after-lll")"
write_manifest_file "$nullsha_live" \
  "$(manifest_entry "references/live-side-removed.md" "removed" "live-before-mmm" "null")"
run_check "$nullsha_proposal" "$nullsha_live"

if path_absent "$HAND_EDIT_OUT" "references/live-side-removed.md"; then
  pass "a live manifest entry for the same path with a null sha_after is not treated as a comparable value — no flag"
else
  fail "a live manifest entry for the same path with a null sha_after is not treated as a comparable value — no flag" \
    "stdout: ${HAND_EDIT_OUT:-<empty>}"
fi

echo
echo "── added, removed, and unchanged proposal entries are never flagged, even when their recorded shas would otherwise look mismatched ──"

statuses_proposal="$TMPDIR_CASE/statuses-proposal.json"
statuses_live="$TMPDIR_CASE/statuses-live.json"
write_manifest_file "$statuses_proposal" \
  "$(manifest_entry "references/added.md" "added" "null" "prop-after-new")" \
  "$(manifest_entry "references/removed.md" "removed" "prop-before-old" "null")" \
  "$(manifest_entry "references/unchanged.md" "unchanged" "same-shared" "same-shared")" \
  "$(manifest_entry "references/genuinely-modified.md" "modified" "prop-before-real" "prop-after-real")"
write_manifest_file "$statuses_live" \
  "$(manifest_entry "references/added.md" "modified" "live-before-x" "live-after-DIFFERENT-1")" \
  "$(manifest_entry "references/removed.md" "modified" "live-before-y" "live-after-DIFFERENT-2")" \
  "$(manifest_entry "references/unchanged.md" "modified" "live-before-z" "live-after-DIFFERENT-3")" \
  "$(manifest_entry "references/genuinely-modified.md" "modified" "live-before-w" "live-after-DIFFERENT-4")"
run_check "$statuses_proposal" "$statuses_live"

if path_flagged "$HAND_EDIT_OUT" "references/genuinely-modified.md" "prop-before-real" "live-after-DIFFERENT-4"; then
  pass "control: a genuinely modified entry among added/removed/unchanged siblings is still correctly flagged (proves the exclusions below are not just a blanket empty result)"
else
  fail "control: a genuinely modified entry among added/removed/unchanged siblings is still correctly flagged (proves the exclusions below are not just a blanket empty result)" \
    "stdout: ${HAND_EDIT_OUT:-<empty>}"
fi

if path_absent "$HAND_EDIT_OUT" "references/added.md"; then
  pass "an added proposal entry is never flagged, regardless of what the live manifest records for that path"
else
  fail "an added proposal entry is never flagged, regardless of what the live manifest records for that path" \
    "stdout: ${HAND_EDIT_OUT:-<empty>}"
fi

if path_absent "$HAND_EDIT_OUT" "references/removed.md"; then
  pass "a removed proposal entry is never flagged, regardless of what the live manifest records for that path"
else
  fail "a removed proposal entry is never flagged, regardless of what the live manifest records for that path" \
    "stdout: ${HAND_EDIT_OUT:-<empty>}"
fi

if path_absent "$HAND_EDIT_OUT" "references/unchanged.md"; then
  pass "an unchanged proposal entry is never flagged, regardless of what the live manifest records for that path"
else
  fail "an unchanged proposal entry is never flagged, regardless of what the live manifest records for that path" \
    "stdout: ${HAND_EDIT_OUT:-<empty>}"
fi

echo
echo "── every flagged path is reported, with no upper bound on how many ──"

uncapped_entries=()
uncapped_live_entries=()
uncapped_expected_count=12
for i in $(seq 1 "$uncapped_expected_count"); do
  uncapped_entries+=("$(manifest_entry "references/many-$i.md" "modified" "prop-before-$i" "prop-after-$i")")
  uncapped_live_entries+=("$(manifest_entry "references/many-$i.md" "modified" "live-before-$i" "live-after-$i")")
done
uncapped_proposal="$TMPDIR_CASE/uncapped-proposal.json"
uncapped_live="$TMPDIR_CASE/uncapped-live.json"
write_manifest_file "$uncapped_proposal" "${uncapped_entries[@]}"
write_manifest_file "$uncapped_live" "${uncapped_live_entries[@]}"
run_check "$uncapped_proposal" "$uncapped_live"

if jq_check "$HAND_EDIT_OUT" '(. | length) == $n' --argjson n "$uncapped_expected_count"; then
  pass "12 genuinely mismatched paths in one run all appear in the result — nothing here truncates output the way a separate, unrelated 5-9-item ranked list does elsewhere"
else
  fail "12 genuinely mismatched paths in one run all appear in the result — nothing here truncates output the way a separate, unrelated 5-9-item ranked list does elsewhere" \
    "stdout: ${HAND_EDIT_OUT:-<empty>}"
fi

echo
echo "── zero mismatches produce a clean empty result, not a placeholder entry ──"

clean_proposal="$TMPDIR_CASE/clean-proposal.json"
clean_live="$TMPDIR_CASE/clean-live.json"
write_manifest_file "$clean_proposal" \
  "$(manifest_entry "references/added-only.md" "added" "null" "prop-after-aaa")" \
  "$(manifest_entry "references/unchanged-only.md" "unchanged" "same-bbb" "same-bbb")" \
  "$(manifest_entry "references/matches.md" "modified" "same-ccc" "prop-after-ddd")"
write_manifest_file "$clean_live" \
  "$(manifest_entry "references/matches.md" "modified" "live-before-eee" "same-ccc")"
run_check "$clean_proposal" "$clean_live"

if [ "$HAND_EDIT_RC" -eq 0 ] && jq_check "$HAND_EDIT_OUT" '. == []'; then
  pass "a run with no hand-edit mismatches anywhere still emits a valid, empty JSON result and exits cleanly"
else
  fail "a run with no hand-edit mismatches anywhere still emits a valid, empty JSON result and exits cleanly" \
    "rc=$HAND_EDIT_RC stdout: ${HAND_EDIT_OUT:-<empty>}"
fi

echo
echo "── read-only: no writes to either manifest, REVIEW.md, the live tree, or the proposed tree ──"

# A fixture directory tree standing in for a real <install>/<name>-context/
# and its sibling <install>/<name>-context.proposed/, each carrying a
# .review/manifest.json, a .review/REVIEW.md, and a references/ file — the
# full set of things this comparison must leave untouched while it reads
# the two manifest.json files out of that tree.
tree_root="$TMPDIR_CASE/install"
mkdir -p "$tree_root/demo-context/.review" "$tree_root/demo-context/references" \
         "$tree_root/demo-context.proposed/.review" "$tree_root/demo-context.proposed/references"
printf '# live reference content\n' > "$tree_root/demo-context/references/foo.md"
printf '# proposed reference content\n' > "$tree_root/demo-context.proposed/references/foo.md"
printf '# live REVIEW.md\n' > "$tree_root/demo-context/.review/REVIEW.md"
printf '# proposed REVIEW.md\n' > "$tree_root/demo-context.proposed/.review/REVIEW.md"
write_manifest_file "$tree_root/demo-context/.review/manifest.json" \
  "$(manifest_entry "references/foo.md" "modified" "live-before-readonly" "live-after-readonly")"
write_manifest_file "$tree_root/demo-context.proposed/.review/manifest.json" \
  "$(manifest_entry "references/foo.md" "modified" "prop-before-readonly" "prop-after-readonly")"

tree_snapshot() {
  local root="$1"
  ( cd "$root" && find . -type f | sort | while IFS= read -r f; do
      printf '%s  %s\n' "$(sha256_of_file "$f")" "$f"
    done )
}

readonly_before="$(tree_snapshot "$tree_root")"
run_check "$tree_root/demo-context.proposed/.review/manifest.json" "$tree_root/demo-context/.review/manifest.json"
readonly_after="$(tree_snapshot "$tree_root")"

if [ "$readonly_before" = "$readonly_after" ]; then
  pass "every file under the live tree and the proposed tree — both manifests, both REVIEW.md files, both references files — is byte-identical before and after a run, and no new file appears"
else
  fail "every file under the live tree and the proposed tree — both manifests, both REVIEW.md files, both references files — is byte-identical before and after a run, and no new file appears" \
    "before:
$readonly_before
after:
$readonly_after"
fi

# ===========================================================================
# review/SKILL.md: the doc-prose half of the contract. review is an
# agent-executed skill, not a standalone program, so the observable
# black-box behavior of "how review surfaces this to the user" is what the
# skill's own prose commits to — the same convention already used
# elsewhere in this repo (e.g. status/SKILL.md's probe section) for
# behavior that lives in prose an agent reads and follows rather than in a
# script's own stdout.
# ===========================================================================

whole_review_doc="$(cat "$REVIEW_SKILL" 2>/dev/null || true)"

echo
echo "── review/SKILL.md: an existing, unrelated section is untouched ──"

resolving_name_hash="$(awk '
    $0 ~ ("^## Resolving") { f = 1; print; next }
    f && /^## / { exit }
    f { print }
  ' "$REVIEW_SKILL" 2>/dev/null | sha256_of_stdin)"
if [ "$resolving_name_hash" = "ed70f0db85c044aca222dc7547fe8390f9bb12d11d47a4b00d58880ede9e9001" ]; then
  pass "review/SKILL.md: the existing 'Resolving <name>' section, unrelated to hand-edit detection, is untouched"
else
  fail "review/SKILL.md: the existing 'Resolving <name>' section, unrelated to hand-edit detection, is untouched" \
    "sha256: $resolving_name_hash"
fi

echo
echo "── review/SKILL.md: the comparison is documented and wired to the script this suite pins ──"

if printf '%s' "$whole_review_doc" | grep -qiE 'hand[- ]edit'; then
  pass "review/SKILL.md mentions hand-edit detection at all"
else
  fail "review/SKILL.md mentions hand-edit detection at all"
fi

if printf '%s' "$whole_review_doc" | grep -qF 'hand_edit_check.py'; then
  pass "review/SKILL.md invokes hand_edit_check.py, the same tests/ script pattern as its siblings"
else
  fail "review/SKILL.md invokes hand_edit_check.py, the same tests/ script pattern as its siblings"
fi

if printf '%s' "$whole_review_doc" | grep -qiE 'sha_before' \
    && printf '%s' "$whole_review_doc" | grep -qiE 'sha_after'; then
  pass "review/SKILL.md names both sha_before and sha_after as the values this comparison reads"
else
  fail "review/SKILL.md names both sha_before and sha_after as the values this comparison reads"
fi

echo
echo "── review/SKILL.md: the flag is documented as distinct from, and never capped by, the ranked disagreement set ──"

if printf '%s' "$whole_review_doc" | grep -qiE 'hand[- ]edit[^.]{0,200}(distinct|separate)|( distinct| separate)[^.]{0,200}hand[- ]edit'; then
  pass "review/SKILL.md documents that the hand-edit flag is surfaced distinctly from the disagreement set, not folded into it"
else
  fail "review/SKILL.md documents that the hand-edit flag is surfaced distinctly from the disagreement set, not folded into it"
fi

if printf '%s' "$whole_review_doc" | grep -qiE 'hand[- ]edit[^.]{0,250}(5.?.?9|cap|budget|not counted|regardless of how many)|(5.?.?9|cap|budget|not counted|regardless of how many)[^.]{0,250}hand[- ]edit'; then
  pass "review/SKILL.md documents that the hand-edit flag does not compete for, and is not capped by, the ranked disagreement set's slot budget"
else
  fail "review/SKILL.md documents that the hand-edit flag does not compete for, and is not capped by, the ranked disagreement set's slot budget"
fi

echo
echo "── review/SKILL.md: silence on zero mismatches matches review's existing empty-bucket convention ──"

if printf '%s' "$whole_review_doc" | grep -qiE 'hand[- ]edit[^.]{0,250}(omit|silen|no .{0,20}line|not (printed|surfaced|shown))|(omit|silen|not (printed|surfaced|shown))[^.]{0,250}hand[- ]edit'; then
  pass "review/SKILL.md documents that zero hand-edit mismatches produce no output at all, rather than an explicit \"no hand edits found\" line"
else
  fail "review/SKILL.md documents that zero hand-edit mismatches produce no output at all, rather than an explicit \"no hand edits found\" line"
fi

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
