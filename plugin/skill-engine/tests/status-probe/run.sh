#!/usr/bin/env bash
# Black-box test runner for the upstream-drift probe added to the status
# workflow: a `status_probe.py` script that answers "does the pinned sha
# still match upstream?" per git-managed source, plus the SKILL.md section
# that invokes it and renders the answer.
#
# Nothing upstream pins status_probe.py's CLI or output shape, so this
# suite designs and freezes both here, the same way each sibling
# deterministic script under this same tests/ directory (discover_inventory.py,
# navigator_budget.py, permalink_density.py) had its own CLI/output contract
# designed by its own oracle before it existed:
#
#   python3 status_probe.py <source-paths.json>
#
#   Exits 0 and writes exactly one JSON array to stdout: one object per
#   in-scope `kind: git-managed` source — in-scope meaning
#   `status ∈ {confirmed, proposed}`, `archived ≠ true`,
#   `lifecycle.state ≠ removed` (the same filter REFRESH's own pre-flight
#   already applies; this script does not invent a second definition).
#   Each element is shaped:
#
#   {
#     "source_id": "<id>",
#     "state": "match" | "mismatch" | "never_probed" | "error",
#     "recorded_sha": "<sha>" | null,
#     "live_sha": "<sha>" | null,
#     "error": "<message>"   // present only when state == "error", absent
#                            // (never null) otherwise
#   }
#
#   For every in-scope entry the script runs `git ls-remote -- <url> <ref>`
#   — `<ref>` is the entry's `branch` field when present, else `HEAD` — and
#   reads the first column of the first returned line as that source's live
#   upstream sha. A source whose `lifecycle.last_checked_sha` is null still
#   gets probed (the live sha is still fetched and reported) but is reported
#   as `never_probed` rather than compared against an absent value. A
#   source whose probe command itself fails (unreachable remote, non-zero
#   git exit) reports `state: "error"` with a diagnostic under `error` and
#   does not prevent the remaining in-scope sources from being probed and
#   reported. The script is read-only: it never writes to the file it reads,
#   and with zero in-scope sources it still writes a single valid (empty)
#   JSON array rather than nothing.
#
# Neither status_probe.py nor the SKILL.md section that invokes it exists
# yet — that is what makes this oracle red right now. It turns green once
# both land matching the contract above and the doc-side assertions below.
#
# Fixture style: throwaway local git repositories built under a tmpdir with
# `git init` plus local commits/branches, used directly as git ls-remote's
# `<url>` argument the same way a real remote URL would be — fully offline,
# nothing here ever touches the network.
#
# The SKILL.md section near the bottom asserts structural facts about
# prose+bash an agent reads and executes at runtime, by extracting the
# relevant block and grepping it — the convention this repo already uses
# elsewhere for behavior that isn't a standalone script.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROBE_SCRIPT="$PLUGIN_ROOT/tests/status_probe.py"
STATUS_SKILL="$PLUGIN_ROOT/skills/status/SKILL.md"

pass_count=0
fail_count=0

TMPDIR_CASE="$(mktemp -d -t skill-engine-status-probe.XXXXXX)"
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
# Fixture builders: disposable local git repositories used as git
# ls-remote's <url> argument, and a JSON generator for source-paths.json
# fixtures.
# ---------------------------------------------------------------------------

new_repo() {
  # new_repo <dir> — an empty repository with a deterministic default
  # branch name, one commit ("first"). Prints nothing; caller reads the sha
  # back out with `git -C <dir> rev-parse HEAD`.
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email "skill-engine-tests@example.com"
  git -C "$dir" config user.name "skill-engine tests"
  printf 'v1\n' > "$dir/content.txt"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "first"
}

advance_repo() {
  # advance_repo <dir> <tag> — one more commit on the current branch.
  local dir="$1" tag="$2"
  printf '%s\n' "$tag" >> "$dir/content.txt"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "$tag"
}

# source_entry <id> <kind> <url> <curation-status> <archived: true|false>
#              <lifecycle-state> <last-checked-sha-or-null> [branch]
# Prints one source-paths.json entry as a standalone JSON object.
source_entry() {
  local id="$1" kind="$2" url="$3" curation_status="$4" archived="$5" lstate="$6" sha="$7" branch="${8:-}"
  local sha_json
  if [ "$sha" = "null" ]; then
    sha_json="null"
  else
    sha_json="$(jq -n --arg s "$sha" '$s')"
  fi
  if [ -n "$branch" ]; then
    jq -n --arg id "$id" --arg kind "$kind" --arg url "$url" --arg cs "$curation_status" \
      --argjson archived "$archived" --arg lstate "$lstate" --argjson sha "$sha_json" --arg branch "$branch" \
      '{id:$id, kind:$kind, url:$url, branch:$branch, status:$cs, archived:$archived,
        lifecycle:{state:$lstate, last_checked:null, last_checked_sha:$sha, proposed_url:null},
        discovered_via:null}'
  else
    jq -n --arg id "$id" --arg kind "$kind" --arg url "$url" --arg cs "$curation_status" \
      --argjson archived "$archived" --arg lstate "$lstate" --argjson sha "$sha_json" \
      '{id:$id, kind:$kind, url:$url, status:$cs, archived:$archived,
        lifecycle:{state:$lstate, last_checked:null, last_checked_sha:$sha, proposed_url:null},
        discovered_via:null}'
  fi
}

# write_sources_file <out-path> [entry-json ...]
write_sources_file() {
  local out="$1"
  shift
  printf '%s\n' "$@" | jq -s '{schema_version: 1, sources: .}' > "$out"
}

# run_probe <source-paths.json> — invokes the script under test, capturing
# stdout into PROBE_OUT and its exit code into PROBE_RC. Errors (script
# missing, a bad arg) collapse to empty stdout; every check below
# independently requires valid, specific JSON content, so a missing script
# always reads as a failure for the right reason rather than a vacuous pass.
run_probe() {
  PROBE_OUT="$(python3 "$PROBE_SCRIPT" "$1" 2>/dev/null)"
  PROBE_RC=$?
}

echo
echo "── sha compare: match, mismatch, never-probed ──"

match_repo="$TMPDIR_CASE/match-repo"
new_repo "$match_repo"
match_sha="$(git -C "$match_repo" rev-parse HEAD)"
match_fp="$TMPDIR_CASE/match.json"
write_sources_file "$match_fp" \
  "$(source_entry "match-src" "git-managed" "$match_repo" "confirmed" "false" "reachable" "$match_sha")"
run_probe "$match_fp"
if jq_check "$PROBE_OUT" '
    (first(.[] | select(.source_id == "match-src"))) as $e
    | $e != null and $e.state == "match"
    and $e.recorded_sha == $sha and $e.live_sha == $sha
' --arg sha "$match_sha"; then
  pass "sha compare: recorded sha equal to the live upstream sha reports state \"match\""
else
  fail "sha compare: recorded sha equal to the live upstream sha reports state \"match\"" \
    "stdout: ${PROBE_OUT:-<empty>}"
fi

mismatch_repo="$TMPDIR_CASE/mismatch-repo"
new_repo "$mismatch_repo"
mismatch_old_sha="$(git -C "$mismatch_repo" rev-parse HEAD)"
advance_repo "$mismatch_repo" "second"
mismatch_new_sha="$(git -C "$mismatch_repo" rev-parse HEAD)"
mismatch_fp="$TMPDIR_CASE/mismatch.json"
write_sources_file "$mismatch_fp" \
  "$(source_entry "mismatch-src" "git-managed" "$mismatch_repo" "confirmed" "false" "reachable" "$mismatch_old_sha")"
run_probe "$mismatch_fp"
if jq_check "$PROBE_OUT" '
    (first(.[] | select(.source_id == "mismatch-src"))) as $e
    | $e != null and $e.state == "mismatch"
    and $e.recorded_sha == $old and $e.live_sha == $new
' --arg old "$mismatch_old_sha" --arg new "$mismatch_new_sha"; then
  pass "sha compare: a recorded sha behind the live upstream sha reports state \"mismatch\" and surfaces both shas"
else
  fail "sha compare: a recorded sha behind the live upstream sha reports state \"mismatch\" and surfaces both shas" \
    "stdout: ${PROBE_OUT:-<empty>}"
fi

never_repo="$TMPDIR_CASE/never-probed-repo"
new_repo "$never_repo"
never_sha="$(git -C "$never_repo" rev-parse HEAD)"
never_fp="$TMPDIR_CASE/never-probed.json"
write_sources_file "$never_fp" \
  "$(source_entry "never-src" "git-managed" "$never_repo" "confirmed" "false" "reachable" "null")"
run_probe "$never_fp"
if jq_check "$PROBE_OUT" '
    (first(.[] | select(.source_id == "never-src"))) as $e
    | $e != null and $e.state == "never_probed" and $e.recorded_sha == null
    and $e.live_sha == $sha
' --arg sha "$never_sha"; then
  pass "sha compare: a null recorded sha (never probed) reports a distinct state rather than a false match or mismatch, and still carries the live sha"
else
  fail "sha compare: a null recorded sha (never probed) reports a distinct state rather than a false match or mismatch, and still carries the live sha" \
    "stdout: ${PROBE_OUT:-<empty>}"
fi

echo
echo "── ref selection: a branch field is honored; its absence falls back to HEAD ──"

branch_repo="$TMPDIR_CASE/branch-repo"
new_repo "$branch_repo"
branch_main_sha="$(git -C "$branch_repo" rev-parse HEAD)"
git -C "$branch_repo" checkout -q -b docs
advance_repo "$branch_repo" "on docs branch"
branch_docs_sha="$(git -C "$branch_repo" rev-parse HEAD)"
git -C "$branch_repo" checkout -q main
branch_fp="$TMPDIR_CASE/branch-selection.json"
write_sources_file "$branch_fp" \
  "$(source_entry "no-branch-src" "git-managed" "$branch_repo" "confirmed" "false" "reachable" "$branch_main_sha")" \
  "$(source_entry "docs-branch-src" "git-managed" "$branch_repo" "confirmed" "false" "reachable" "$branch_docs_sha" "docs")"
run_probe "$branch_fp"
if jq_check "$PROBE_OUT" '
    (first(.[] | select(.source_id == "no-branch-src"))) as $e
    | $e != null and $e.live_sha == $main
' --arg main "$branch_main_sha"; then
  pass "ref selection: a source entry with no branch field probes HEAD (the checked-out default branch), not some other ref"
else
  fail "ref selection: a source entry with no branch field probes HEAD (the checked-out default branch), not some other ref" \
    "stdout: ${PROBE_OUT:-<empty>}"
fi
if jq_check "$PROBE_OUT" '
    (first(.[] | select(.source_id == "docs-branch-src"))) as $e
    | $e != null and $e.live_sha == $docs and $e.live_sha != $main
' --arg docs "$branch_docs_sha" --arg main "$branch_main_sha"; then
  pass "ref selection: a source entry naming a branch field probes that branch, not HEAD, when the two diverge"
else
  fail "ref selection: a source entry naming a branch field probes that branch, not HEAD, when the two diverge" \
    "stdout: ${PROBE_OUT:-<empty>}"
fi

echo
echo "── in-scope filtering (kind, curation status, archived, lifecycle state) ──"

scope_repo="$TMPDIR_CASE/scope-repo"
new_repo "$scope_repo"
scope_sha="$(git -C "$scope_repo" rev-parse HEAD)"
scope_fp="$TMPDIR_CASE/scope.json"
write_sources_file "$scope_fp" \
  "$(source_entry "in-confirmed" "git-managed" "$scope_repo" "confirmed" "false" "reachable" "$scope_sha")" \
  "$(source_entry "in-proposed" "git-managed" "$scope_repo" "proposed" "false" "reachable" "$scope_sha")" \
  "$(source_entry "out-rejected" "git-managed" "$scope_repo" "rejected" "false" "reachable" "$scope_sha")" \
  "$(source_entry "out-archived" "git-managed" "$scope_repo" "confirmed" "true" "reachable" "$scope_sha")" \
  "$(source_entry "out-removed" "git-managed" "$scope_repo" "confirmed" "false" "removed" "$scope_sha")" \
  "$(source_entry "out-webdoc" "web-doc" "$scope_repo" "confirmed" "false" "reachable" "null")"
run_probe "$scope_fp"
if jq_check "$PROBE_OUT" '
    ([.[].source_id] | sort) == (["in-confirmed", "in-proposed"] | sort)
'; then
  pass "in-scope filtering: confirmed and proposed git-managed sources are probed; rejected, archived, lifecycle-removed, and non-git-managed sources are excluded"
else
  fail "in-scope filtering: confirmed and proposed git-managed sources are probed; rejected, archived, lifecycle-removed, and non-git-managed sources are excluded" \
    "stdout: ${PROBE_OUT:-<empty>}"
fi

echo
echo "── a single source's probe failure does not blank the rest of the report ──"

fail_good_repo="$TMPDIR_CASE/fail-good-repo"
new_repo "$fail_good_repo"
fail_good_sha="$(git -C "$fail_good_repo" rev-parse HEAD)"
fail_bad_path="$TMPDIR_CASE/no-such-repo-here"
fail_fp="$TMPDIR_CASE/failure-isolation.json"
write_sources_file "$fail_fp" \
  "$(source_entry "good-src" "git-managed" "$fail_good_repo" "confirmed" "false" "reachable" "$fail_good_sha")" \
  "$(source_entry "bad-src" "git-managed" "$fail_bad_path" "confirmed" "false" "reachable" "null")"
run_probe "$fail_fp"
if [ "$PROBE_RC" -eq 0 ]; then
  pass "probe failure isolation: the run's own exit code stays 0 even though one of its two sources is unreachable"
else
  fail "probe failure isolation: the run's own exit code stays 0 even though one of its two sources is unreachable" \
    "exit code: $PROBE_RC"
fi
if jq_check "$PROBE_OUT" '
    (first(.[] | select(.source_id == "good-src"))) as $e
    | $e != null and $e.state == "match" and $e.live_sha == $sha
' --arg sha "$fail_good_sha"; then
  pass "probe failure isolation: the reachable source alongside a failing one still reports its correct result"
else
  fail "probe failure isolation: the reachable source alongside a failing one still reports its correct result" \
    "stdout: ${PROBE_OUT:-<empty>}"
fi
if jq_check "$PROBE_OUT" '
    (first(.[] | select(.source_id == "bad-src"))) as $e
    | $e != null and $e.state == "error" and $e.live_sha == null
    and ($e | has("error")) and ($e.error | type == "string") and ($e.error | length) > 0
'; then
  pass "probe failure isolation: an unreachable source reports state \"error\" inline with a non-empty diagnostic, instead of aborting the run"
else
  fail "probe failure isolation: an unreachable source reports state \"error\" inline with a non-empty diagnostic, instead of aborting the run" \
    "stdout: ${PROBE_OUT:-<empty>}"
fi

echo
echo "── the probe is read-only: it never writes to the file it reads ──"

readonly_repo="$TMPDIR_CASE/readonly-repo"
new_repo "$readonly_repo"
readonly_sha="$(git -C "$readonly_repo" rev-parse HEAD)"
readonly_fp="$TMPDIR_CASE/readonly.json"
write_sources_file "$readonly_fp" \
  "$(source_entry "readonly-src" "git-managed" "$readonly_repo" "confirmed" "false" "reachable" "$readonly_sha")"
readonly_before="$(sha256_of_file "$readonly_fp")"
run_probe "$readonly_fp"
readonly_after="$(sha256_of_file "$readonly_fp")"
if [ "$readonly_before" = "$readonly_after" ]; then
  pass "read-only: source-paths.json is byte-identical before and after a probe run (last_checked_sha / last_checked untouched)"
else
  fail "read-only: source-paths.json is byte-identical before and after a probe run (last_checked_sha / last_checked untouched)" \
    "sha256 before=$readonly_before after=$readonly_after"
fi

echo
echo "── zero in-scope sources report an empty result, not a crash or empty output ──"

empty_fp="$TMPDIR_CASE/empty-sources.json"
write_sources_file "$empty_fp"
run_probe "$empty_fp"
if [ "$PROBE_RC" -eq 0 ] && jq_check "$PROBE_OUT" '. == []'; then
  pass "zero in-scope sources: no sources registered at all yields a valid empty JSON array, exit 0"
else
  fail "zero in-scope sources: no sources registered at all yields a valid empty JSON array, exit 0" \
    "rc=$PROBE_RC stdout: ${PROBE_OUT:-<empty>}"
fi

none_in_scope_fp="$TMPDIR_CASE/none-in-scope.json"
write_sources_file "$none_in_scope_fp" \
  "$(source_entry "only-rejected" "git-managed" "$scope_repo" "rejected" "false" "reachable" "$scope_sha")" \
  "$(source_entry "only-archived" "git-managed" "$scope_repo" "confirmed" "true" "reachable" "$scope_sha")" \
  "$(source_entry "only-removed" "git-managed" "$scope_repo" "confirmed" "false" "removed" "$scope_sha")" \
  "$(source_entry "only-webdoc" "web-doc" "$scope_repo" "confirmed" "false" "reachable" "null")"
run_probe "$none_in_scope_fp"
if [ "$PROBE_RC" -eq 0 ] && jq_check "$PROBE_OUT" '. == []'; then
  pass "zero in-scope sources: sources registered but every one archived/removed/rejected/other-kind yields a valid empty JSON array, exit 0"
else
  fail "zero in-scope sources: sources registered but every one archived/removed/rejected/other-kind yields a valid empty JSON array, exit 0" \
    "rc=$PROBE_RC stdout: ${PROBE_OUT:-<empty>}"
fi

# ===========================================================================
# SKILL.md: the doc-prose half of the contract. status_probe.py is invoked
# from a new section of plugin/skill-engine/skills/status/SKILL.md; these
# checks assert what that section documents, and that it leaves the rest of
# the file alone. Extraction-and-grep against the live doc, the same
# convention already used elsewhere in this repo for behavior that lives in
# prose+bash an agent runs rather than in a standalone script.
# ===========================================================================

# extract_named_section <heading-text> <file> — the named "## " heading
# through (not including) the next "## " heading, or end of file.
extract_named_section() {
  local want="$1" file="$2"
  awk -v want="$want" '
    $0 ~ ("^## " want) { f = 1; print; next }
    f && /^## / { exit }
    f { print }
  ' "$file"
}

# extract_probe_section <file> — the first "## "-level heading whose text
# mentions "probe", through the next "## " heading or end of file. Located
# by content, not by a name this suite would otherwise have to guess and
# pin ahead of the doc being written.
extract_probe_section() {
  awk '
    /^## / {
      if (capturing) { exit }
      if (tolower($0) ~ /probe/) { capturing = 1; print; next }
      next
    }
    capturing { print }
  ' "$1"
}

echo
echo "── SKILL.md: default (non-flag) behavior and existing sections are untouched ──"

# The two existing bash-block sections (cache listing, pending-proposal
# review state) are unrelated to upstream drift and are not this addition's
# job to touch — verified against a hash of their current content rather
# than a literal copy pasted into this file, so a future editorial pass on
# this test file can't silently drift from the real baseline.
cache_surface_hash="$(extract_named_section "Cache surface" "$STATUS_SKILL" | sha256_of_stdin)"
if [ "$cache_surface_hash" = "90e12c756e284a1367903a43567d3c94ca21f3524dab2bf694334f2900063c5d" ]; then
  pass "SKILL.md: the existing Cache surface section is untouched"
else
  fail "SKILL.md: the existing Cache surface section is untouched" \
    "sha256: $cache_surface_hash"
fi

pending_proposals_hash="$(extract_named_section "Pending proposals" "$STATUS_SKILL" | sha256_of_stdin)"
if [ "$pending_proposals_hash" = "6f68a00587ac4c8c87a8f6dde0c2f812c9cec9f4b0bd9038fd81258d164d1c8f" ]; then
  pass "SKILL.md: the existing Pending proposals section is untouched"
else
  fail "SKILL.md: the existing Pending proposals section is untouched" \
    "sha256: $pending_proposals_hash"
fi

# The script that reaches upstream is invoked only from the new opt-in
# section — never from anywhere else in the doc, which would make it run
# on a plain, flag-less status invocation.
full_invocations="$(grep -c 'status_probe\.py' "$STATUS_SKILL" 2>/dev/null || true)"
full_invocations="${full_invocations:-0}"
section_invocations="$(extract_probe_section "$STATUS_SKILL" | grep -c 'status_probe\.py' 2>/dev/null || true)"
section_invocations="${section_invocations:-0}"
if [ "$full_invocations" -gt 0 ] && [ "$full_invocations" -eq "$section_invocations" ]; then
  pass "SKILL.md: status_probe.py is invoked only from the new probe section, never from an unconditional (default-path) block"
else
  fail "SKILL.md: status_probe.py is invoked only from the new probe section, never from an unconditional (default-path) block" \
    "total mentions=$full_invocations, mentions inside the probe section=$section_invocations"
fi

probe_section_content="$(extract_probe_section "$STATUS_SKILL")"

echo
echo "── SKILL.md: the new section exists and is wired to the probe script ──"

if [ -n "$probe_section_content" ]; then
  pass "SKILL.md: a new heading section about probing exists"
else
  fail "SKILL.md: a new heading section about probing exists"
fi

if printf '%s' "$probe_section_content" | grep -qF -- '--probe'; then
  pass "SKILL.md: the new section documents the --probe flag"
else
  fail "SKILL.md: the new section documents the --probe flag"
fi

if printf '%s' "$probe_section_content" | grep -qF 'status_probe.py'; then
  pass "SKILL.md: the new section invokes status_probe.py, the same tests/ script pattern as its siblings"
else
  fail "SKILL.md: the new section invokes status_probe.py, the same tests/ script pattern as its siblings"
fi

if printf '%s' "$probe_section_content" | grep -qF 'git-managed' \
    && printf '%s' "$probe_section_content" | grep -qF 'source-paths.json'; then
  pass "SKILL.md: the new section scopes itself to git-managed sources in source-paths.json"
else
  fail "SKILL.md: the new section scopes itself to git-managed sources in source-paths.json"
fi

echo
echo "── SKILL.md: the new section documents each per-source outcome ──"

if printf '%s' "$probe_section_content" | grep -qiE 'current|match(es)?\b'; then
  pass "SKILL.md: the new section documents the current/matching-sha outcome"
else
  fail "SKILL.md: the new section documents the current/matching-sha outcome"
fi

if printf '%s' "$probe_section_content" | grep -qiE '(record|store|pin)[a-z]*[^.]{0,60}(live|current|upstream)|behind' \
    && printf '%s' "$probe_section_content" | grep -qiE 'both'; then
  pass "SKILL.md: the new section documents that a mismatch surfaces both the recorded and the live sha"
else
  fail "SKILL.md: the new section documents that a mismatch surfaces both the recorded and the live sha"
fi

if printf '%s' "$probe_section_content" | grep -qiE 'never[- ]?(been )?probed|not (yet )?(been )?(probed|checked)|no prior (probe|check)'; then
  pass "SKILL.md: the new section documents a distinct never-probed outcome for a null recorded sha"
else
  fail "SKILL.md: the new section documents a distinct never-probed outcome for a null recorded sha"
fi

if printf '%s' "$probe_section_content" | grep -qiE 'nothing to probe'; then
  pass "SKILL.md: the new section states an explicit \"nothing to probe\" line for the zero-in-scope-sources case"
else
  fail "SKILL.md: the new section states an explicit \"nothing to probe\" line for the zero-in-scope-sources case"
fi

if printf '%s' "$probe_section_content" | grep -qiE '(fail|error|unreachable)[^.]{0,120}(remaining|other|rest of the)|(remaining|other|rest of the)[^.]{0,120}(fail|error|unreachable)'; then
  pass "SKILL.md: the new section documents that one source's probe failure does not stop the rest from being reported"
else
  fail "SKILL.md: the new section documents that one source's probe failure does not stop the rest from being reported"
fi

echo
echo "── SKILL.md: --probe stays read-only over source-paths.json ──"

whole_doc="$(cat "$STATUS_SKILL")"
if printf '%s' "$whole_doc" | grep -qiE 'does not (write|modify|persist|update|change)[^.]{0,80}(source-paths\.json|last_checked_sha|lifecycle)'; then
  pass "SKILL.md: the doc states --probe does not write source-paths.json / lifecycle.last_checked_sha"
else
  fail "SKILL.md: the doc states --probe does not write source-paths.json / lifecycle.last_checked_sha"
fi

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
