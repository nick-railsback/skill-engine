#!/usr/bin/env bash
# Black-box oracle for this repo's own dogfood contextualizer's promotion
# record: .claude/skills/skill-engine-context/.review/manifest.json.
#
# What the manifest is for. It is what the last promotion left behind —
# one entry per contextualizer file, each carrying the content hash the
# engine itself wrote (`sha_after`). hand_edit_check.py reads it on the
# next REVIEW and flags any path whose live content has moved since: a
# hand edit, a SELF-AUDIT fix, anything that landed between promotions.
# The flag is only meaningful because `sha_after` is supposed to be a true
# statement about what is on disk.
#
# What goes wrong when it is not. A stale manifest does not under-report —
# it over-reports, on everything at once. Every path whose live content has
# moved since the record was written flags, so the first real REVIEW after
# a drifted promotion emits a wall of hand-edit warnings covering the whole
# corpus. A detector that fires on 100% of paths the first time it is used
# teaches its reader to skip it, and the one genuine hand edit it was built
# to catch arrives later inside that noise.
#
# Nothing kept the two in step. The manifest is tracked in git and the
# reference corpus is edited by ordinary commits, so the record and the
# tree drift apart with no gate between them — which is what this suite is.
# It is scoped to this repo's dogfood instance, not stamped into user
# trees: in a user's contextualizer a mismatch means a real hand edit,
# which is the feature. Here it means the tracked record is stale.
#
# Hash function: sha256 of the file's bytes, truncated to the first 7 hex
# characters. The artifact contract calls these "content-hashes" without
# naming the digest, so it is pinned here — a manifest whose algorithm
# nothing records is a manifest nothing can check. The two `unchanged`
# entries, whose sha_before and sha_after were equal and correct before
# this suite existed, are what identify it.
#
# Read-only over the live repo: writes only inside a throwaway tmpdir.
#
# -e is intentionally omitted: every assertion must run and report, not
# abort at the first red one.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

CTX_ROOT="$REPO_ROOT/.claude/skills/skill-engine-context"
MANIFEST="$CTX_ROOT/.review/manifest.json"
HAND_EDIT_CHECK="$PLUGIN_ROOT/tests/hand_edit_check.py"

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

TMPDIR_CASE="$(mktemp -d "${TMPDIR:-/tmp}/dogfood-review-manifest.XXXXXX")"
cleanup() { rm -rf "$TMPDIR_CASE"; }
trap cleanup EXIT

section "supporting files present"

for f in "$MANIFEST" "$HAND_EDIT_CHECK"; do
  if [ -f "$f" ]; then
    pass "present: ${f#"$REPO_ROOT"/}"
  else
    fail "present: ${f#"$REPO_ROOT"/}"
  fi
done

if [ ! -f "$MANIFEST" ] || [ ! -f "$HAND_EDIT_CHECK" ]; then
  echo
  echo "Passed: $pass_count"
  echo "Failed: $fail_count"
  exit 1
fi

# Recompute every entry's hash from the live tree once, and emit the whole
# comparison as JSON for the assertions below to read.
COMPARISON="$(python3 - "$MANIFEST" "$CTX_ROOT" <<'PY'
import hashlib, json, pathlib, sys

manifest_path, ctx_root = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

rows = []
for entry in manifest.get("entries", []):
    path = entry.get("path")
    recorded = entry.get("sha_after")
    live = ctx_root / path
    if live.is_file():
        actual = hashlib.sha256(live.read_bytes()).hexdigest()[:7]
    else:
        actual = None
    rows.append({
        "path": path,
        "status": entry.get("status"),
        "recorded": recorded,
        "actual": actual,
        "agrees": recorded == actual,
    })

print(json.dumps({"entries": rows}))
PY
)"

jq_check() {
  printf '%s' "$COMPARISON" | jq -e "$1" >/dev/null 2>&1
}

section "the manifest is a true record of what is on disk"

if jq_check '(.entries | length) >= 10'; then
  pass "the manifest carries the contextualizer's file set (non-vacuous — an empty manifest would satisfy every check below)"
else
  fail "the manifest carries the contextualizer's file set (non-vacuous — an empty manifest would satisfy every check below)" \
    "entries: $(printf '%s' "$COMPARISON" | jq -r '.entries | length')"
fi

if jq_check '[.entries[] | select(.actual == null)] | length == 0'; then
  pass "every path the manifest names exists in the live tree"
else
  fail "every path the manifest names exists in the live tree" \
    "missing: $(printf '%s' "$COMPARISON" | jq -r '[.entries[] | select(.actual == null) | .path] | join(", ")')"
fi

if jq_check '[.entries[] | select(.agrees | not)] | length == 0'; then
  pass "every entry's sha_after is the live file's own hash — the record and the tree have not drifted apart"
else
  fail "every entry's sha_after is the live file's own hash — the record and the tree have not drifted apart" \
    "$(printf '%s' "$COMPARISON" | jq -r '[.entries[] | select(.agrees | not) | "\(.path): records \(.recorded), hashes to \(.actual // "<missing>")"] | join("; ")')"
fi

section "the next REVIEW against this contextualizer flags nothing"

# The scenario the manifest exists to serve, run for real. A REVIEW builds
# a proposal manifest whose sha_before values are computed from the live
# files, and hand_edit_check.py compares those against the live manifest's
# sha_after. Anything it flags here is a path this repo would be told had
# been hand-edited since the engine last wrote it.
PROPOSAL="$TMPDIR_CASE/proposal-manifest.json"
printf '%s' "$COMPARISON" | jq '{
  schema_version: 1,
  entries: [.entries[] | {path: .path, status: "modified", sha_before: .actual, sha_after: .actual}]
}' > "$PROPOSAL"

FLAGGED="$(python3 "$HAND_EDIT_CHECK" "$PROPOSAL" "$MANIFEST" 2>/dev/null || printf '')"

if [ -n "$FLAGGED" ] && printf '%s' "$FLAGGED" | jq -e 'length == 0' >/dev/null 2>&1; then
  pass "hand_edit_check reports no hand-edited path against the live manifest"
else
  fail "hand_edit_check reports no hand-edited path against the live manifest" \
    "flagged $(printf '%s' "$FLAGGED" | jq -r 'length' 2>/dev/null || printf '?') of $(printf '%s' "$COMPARISON" | jq -r '.entries | length') paths: $(printf '%s' "$FLAGGED" | jq -r '[.[].path] | join(", ")' 2>/dev/null || printf '<unparseable>')"
fi

# Negative control. The assertion above is only worth anything if the
# detector would have spoken up — a hand_edit_check that flagged nothing
# ever would pass it just as well.
PERTURBED="$TMPDIR_CASE/perturbed-manifest.json"
printf '%s' "$COMPARISON" | jq '{
  schema_version: 1,
  entries: [.entries[] | {
    path: .path,
    status: "modified",
    sha_before: (if .path == "SKILL.md" then "0000000" else .actual end),
    sha_after: .actual
  }]
}' > "$PERTURBED"

PERTURBED_FLAGGED="$(python3 "$HAND_EDIT_CHECK" "$PERTURBED" "$MANIFEST" 2>/dev/null || printf '')"

if printf '%s' "$PERTURBED_FLAGGED" | jq -e '(length == 1) and (.[0].path == "SKILL.md")' >/dev/null 2>&1; then
  pass "negative control: a single perturbed hash IS flagged, so the clean result above is the detector agreeing, not the detector silent"
else
  fail "negative control: a single perturbed hash IS flagged, so the clean result above is the detector agreeing, not the detector silent" \
    "flagged: ${PERTURBED_FLAGGED:-<empty — the checker did not run>}"
fi

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"

[ "$fail_count" -eq 0 ]
