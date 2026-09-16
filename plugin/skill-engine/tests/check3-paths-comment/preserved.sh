#!/usr/bin/env bash
# The navigator-frontmatter gate's behaviours that must survive its
# `paths:` rules: the trailing-comment discount, the multi-line and
# next-line readings, the no-value tokens and quoting. Every one of them
# already holds, so none of them can go red-then-green; each is instead
# broken on a scratch copy of the checker by a control in `mutations/`,
# which requires this file red.
#
# Deliberately NOT called by `run.sh`. Everything `run.sh` reports is a fact
# still owed; a fact that already holds, reported there, would read green on
# the first run and prove nothing.
#
# WHAT IS HELD, AND WHY IT IS AT RISK.
#   comment discount — a key that names at least one glob is accepted with a
#                      trailing comment, in all three spellings. At risk
#                      from a discount that eats the value along with the
#                      comment, and — for the block list — from deciding
#                      whether to read the lines under the key before the
#                      comment is discounted: a key line with a comment is
#                      not empty after the colon, so its items go unread.
#   multi-line flow  — a flow sequence whose items sit on the lines after
#                      the key is accepted. At risk from the fix that
#                      stopped a lone `[` counting as a glob: rejecting
#                      every sequence left open on the key line is the
#                      shortcut, and it refuses a spelling YAML accepts.
#   next-line empty  — an empty or never-closed flow sequence written on the
#                      line under the key is rejected. At risk from reading
#                      those lines at all: a sequence left open there has
#                      no `]` to strip, so its `[` would count as a glob
#                      unless the unclosed test looks at the whole value
#                      rather than the key line alone.
#   null lookalikes  — only a token that is exactly a YAML null (`~`,
#                      `null`, `Null`, `NULL`) or an empty mapping is no
#                      value. At risk from a prefix match, which drops
#                      `nullable/**` and `~vendor/**`, and from matching
#                      after unquoting, which drops the string `"null"`.
#   hash inside glob — a `#` starts a comment only when whitespace precedes
#                      it or it stands first in the value. A `#` glued to a
#                      path segment or a quote is part of the glob. At risk
#                      from the obvious strip-from-the-first-`#`: on a
#                      quoted scalar that leaves only a quote, which counts
#                      as nothing.
#                      Tracking quotes so a quoted `#` is kept carries the
#                      opposite risk: a quote that never closes hides the
#                      real comment after it.
#   key set          — name, description and paths are admitted; any other
#                      top-level key is rejected.
#   no interpreter   — the checker ships stamped into user repos, where a
#                      Python or yq dependency does not exist.
#   fixture matrix   — the pre-existing comment-free fixture matrix for this
#                      gate keeps every verdict. That matrix lives in
#                      monorepo-config-check, which honours VERIFY_SH, so
#                      its two controls here run that suite rather than a
#                      copy of its cells kept in this file.
#   shipped navs     — the in-repo navigator and the three bundled examples
#                      still pass the gate.
#
# The verdict is read from the checker's own `(navigator-skill)` section over
# a scratch contextualizer root — never from its exit code, which every other
# check in the file also moves.
#
# ENV INDIRECTION. VERIFY_SH names the checker under test (default: the
# template), so a control can copy it, break the copy, and point this file at
# it.
#
# -e is intentionally omitted: every assertion runs and reports, rather than
# the run aborting at the first failure.

set -uo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
VERIFY_SH="${VERIFY_SH:-$PLUGIN_ROOT/engine-bootstrap-templates/verify.sh}"

pass_count=0
fail_count=0

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

# shellcheck source=../lib/nav_gate.sh
. "$PLUGIN_ROOT/tests/lib/nav_gate.sh"

# expect <verdict> <label> <extra-frontmatter-lines> — the given lines,
# appended to a valid two-key frontmatter, get the given gate_case verdict
# (`accept`, or `reject:` and the reason). An empty third argument means the
# two-key frontmatter alone.
expect() {
  local want="$1" label="$2" body verdict
  body="name: acme-context
description: $NAV_DESC"
  if [ -n "$3" ]; then
    body="$body
$3"
  fi
  verdict="$(gate_case "$body")"
  if [ "$verdict" = "$want" ]; then
    pass "$label"
  else
    fail "$label" "want: $want, got: $verdict" "extra lines: ${3:-<none>}"
  fi
}

NAV_DESC='Use when answering questions about the acme corpus.'
REAL_NOTE='# optional; omit at the three fixed roots'

if [ ! -f "$VERIFY_SH" ]; then
  fail "checker under test is present" "no file at $VERIFY_SH"
fi

# ════════════════════════════════════════════════════════════════════════
# comment discount: a non-empty value with a trailing comment is accepted
# ════════════════════════════════════════════════════════════════════════

expect accept "comment discount: a commented key over a block list is accepted" \
  "paths:  # note
  - src/auth/**"
expect accept "comment discount: a key carrying the optional-field note over a two-item block list is accepted" \
  "paths:  $REAL_NOTE
  - \"packages/billing/**\"
  - \"shared/**\""
expect accept "comment discount: a key with a bare hash over a block list is accepted" \
  "paths:  #
  - src/auth/**"
expect accept "comment discount: a flow sequence with a trailing comment is accepted" \
  "paths: [a/**, b/**]  # note"
expect accept "comment discount: a flow sequence with a bracket-bearing comment is accepted" \
  "paths: [a/**, b/**]  # [x, y]"
expect accept "comment discount: a comma-separated string with a trailing comment is accepted" \
  "paths: a/**, b/**  # note"
expect accept "comment discount: a single-glob string with a comma-bearing comment is accepted" \
  "paths: a/**  # a, b"

# ════════════════════════════════════════════════════════════════════════
# multi-line flow: a sequence spread over several lines is still a list
# ════════════════════════════════════════════════════════════════════════

expect accept "multi-line flow: a sequence split over several lines is accepted" \
  "paths: [
  packages/billing/**,
  shared/**,
]"
expect accept "multi-line flow: a sequence with a comment on its opening line is accepted" \
  "paths: [  # note
  packages/billing/**]"

# ════════════════════════════════════════════════════════════════════════
# next-line emptiness: reading the lines under the key finds no glob there
# ════════════════════════════════════════════════════════════════════════

expect reject:paths "next-line value: an empty flow sequence under the key is rejected" \
  "paths:
  []"
expect reject:paths "next-line value: a flow sequence under the key that never closes is rejected" \
  "paths:
  [a/**,"

# ════════════════════════════════════════════════════════════════════════
# null lookalikes: a glob that only starts like a null is a glob
# ════════════════════════════════════════════════════════════════════════

expect accept "null lookalike: a glob that starts with null is accepted" \
  "paths: nullable/**"
expect accept "null lookalike: a glob that starts with a tilde is accepted" \
  "paths: ~vendor/**"
expect accept "null lookalike: a quoted null is a string and is accepted" \
  "paths: [\"null\"]"

# ════════════════════════════════════════════════════════════════════════
# hash inside glob: a `#` not preceded by whitespace belongs to the glob
# ════════════════════════════════════════════════════════════════════════

expect accept "hash inside glob: a glob with a hash inside a path segment is accepted" \
  "paths: docs/#-anchors/**"
expect accept "hash inside glob: a double-quoted glob that opens with a hash is accepted" \
  "paths: \"#a/**\""
expect accept "hash inside glob: a single-quoted glob that opens with a hash is accepted" \
  "paths: '#a/**'"
expect accept "hash inside glob: a double-quoted hash glob with a trailing comment is accepted" \
  "paths: \"#a/**\"  # note"
expect accept "hash inside glob: a block item with a hash inside a path segment is accepted" \
  "paths:
  - docs/#-anchors/**"
expect reject:paths "hash inside glob: a comment after a closed empty quote is still discounted" \
  "paths: \"\"  # \"x/**\""

# ════════════════════════════════════════════════════════════════════════
# key set: name, description and paths admitted; nothing else
# ════════════════════════════════════════════════════════════════════════

expect accept "key set: name + description alone is accepted" ""
expect accept "key set: name + description + paths is accepted" \
  "paths:
  - src/**"
expect reject:keys "key set: a version: key is rejected" "version: 1.0"
expect reject:keys "key set: an author: key is rejected" "author: someone"
expect reject:keys "key set: a disable-model-invocation: key is rejected" "disable-model-invocation: true"

# ════════════════════════════════════════════════════════════════════════
# no interpreter: the checker names neither Python nor yq
# ════════════════════════════════════════════════════════════════════════

if [ -f "$VERIFY_SH" ]; then
  interp_hits="$(grep -nE 'python3?|yq' "$VERIFY_SH")"
  if [ -z "$interp_hits" ]; then
    pass "no interpreter: the checker names neither python nor yq"
  else
    fail "no interpreter: the checker names neither python nor yq" "$interp_hits"
  fi
else
  fail "no interpreter: the checker names neither python nor yq" "no file at $VERIFY_SH"
fi

# ════════════════════════════════════════════════════════════════════════
# shipped navs: the in-repo navigator and the bundled examples pass
# ════════════════════════════════════════════════════════════════════════

shipped_navs=(
  ".claude/skills/skill-engine-context"
  "examples/inspect-ai-context"
  "examples/langchain-context"
  "examples/modelcontextprotocol-python-sdk-context"
)
for rel in "${shipped_navs[@]}"; do
  root="$REPO_ROOT/$rel"
  if [ ! -f "$root/SKILL.md" ]; then
    fail "shipped navs: $rel passes the gate" "no SKILL.md at $root"
    continue
  fi
  report="$(nav_gate_report "$root")"
  if [ -n "$report" ] && ! printf '%s\n' "$report" | grep -q '\[FAIL\]'; then
    pass "shipped navs: $rel passes the gate"
  else
    fail "shipped navs: $rel passes the gate" "navigator-skill section: ${report:-<empty>}"
  fi
done

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
