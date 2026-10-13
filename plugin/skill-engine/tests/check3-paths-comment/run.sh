#!/usr/bin/env bash
# The navigator-frontmatter gate rejects a `paths:` key that names no glob,
# whatever trailing YAML comment the key line carries and however the empty
# value is spelled.
#
# A trailing comment is not a glob. The gate's rule is: discount the comment
# (a `#` preceded by whitespace, or standing first in the value), then reject
# iff the key names zero globs. That holds across all three admitted
# spellings — a block list, a flow sequence, a comma-separated string — so
# every zero-glob spelling below is paired with a spread of comment shapes:
# plain words, words carrying commas, words carrying brackets, quotes, a
# bare `#`, and the realistic "optional" note a stamped navigator would
# carry.
#
# A value is not always on the key line. YAML reads the indented lines under
# a bare key as its value too, so a flow sequence, a plain string or a block
# scalar written there names globs the gate must count, not reject.
#
# Every case here is a fact still owed. The behaviours that already hold and
# must keep holding (non-empty values with comments, a `#` inside a glob, the
# admitted key set, the shipped navigators) live in `preserved.sh` beside
# this file, with a mutation control each; the existing comment-free fixture
# matrix lives in monorepo-config-check, and two of those controls run it.
#
# The verdict is read from the checker's own `(navigator-skill)` section over
# a scratch contextualizer root — never from its exit code, which every other
# check in the file also moves. VERIFY_SH points the run at another copy of
# the checker.
#
# -e is intentionally omitted: every assertion runs and reports, rather than
# the run aborting at the first failure.

set -uo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
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

# expect_reject <label> <paths-lines> — the given `paths:` lines, appended to
# a valid two-key frontmatter, must be rejected by the paths: gate alone.
expect_reject() {
  local label="$1" verdict
  verdict="$(gate_case "name: acme-context
description: $NAV_DESC
$2")"
  if [ "$verdict" = "reject:paths" ]; then
    pass "$label"
  else
    fail "$label" "verdict: $verdict" "paths lines: $2"
  fi
}

# expect_accept <label> <paths-lines> — the given `paths:` lines, appended to
# a valid two-key frontmatter, must be accepted.
expect_accept() {
  local label="$1" verdict
  verdict="$(gate_case "name: acme-context
description: $NAV_DESC
$2")"
  if [ "$verdict" = "accept" ]; then
    pass "$label"
  else
    fail "$label" "verdict: $verdict" "paths lines: $2"
  fi
}

NAV_DESC='Use when answering questions about the acme corpus.'
REAL_NOTE='# optional; omit at the three fixed roots'

if [ ! -f "$VERIFY_SH" ]; then
  fail "checker under test is present" "no file at $VERIFY_SH"
fi

# ════════════════════════════════════════════════════════════════════════
# comment discount: a key with no value and no block items
# ════════════════════════════════════════════════════════════════════════

expect_reject "comment discount: a bare key with a plain-word comment is rejected" \
  "paths:  # note"
expect_reject "comment discount: a bare key with a single-space comment is rejected" \
  "paths: # note"
expect_reject "comment discount: a bare key with a comment and no space after the hash is rejected" \
  "paths:  #note"
expect_reject "comment discount: a bare key with a bare hash is rejected" \
  "paths:  #"
expect_reject "comment discount: a bare key with a comma-bearing comment is rejected" \
  "paths:  # a, b, c"
expect_reject "comment discount: a bare key with a bracket-bearing comment is rejected" \
  "paths:  # [x, y]"
expect_reject "comment discount: a bare key with a quote-bearing comment is rejected" \
  "paths:  # \"quoted\""
expect_reject "comment discount: a bare key with the optional-field note is rejected" \
  "paths:  $REAL_NOTE"
expect_reject "comment discount: a bare key with a note and only a commented-out item below is rejected" \
  "paths:  $REAL_NOTE
  # - src/auth/**"

# The commented key is not the last key: the block-list count must stop at
# the next key, not reach past it.
verdict="$(gate_case "name: acme-context
paths:  # note
description: $NAV_DESC")"
if [ "$verdict" = "reject:paths" ]; then
  pass "comment discount: a bare commented key followed by another key is rejected"
else
  fail "comment discount: a bare commented key followed by another key is rejected" "verdict: $verdict"
fi

# ════════════════════════════════════════════════════════════════════════
# comment discount: an empty flow sequence
# ════════════════════════════════════════════════════════════════════════

expect_reject "comment discount: an empty flow sequence with a plain-word comment is rejected" \
  "paths: []  # note"
expect_reject "comment discount: an empty flow sequence with a bare hash is rejected" \
  "paths: []  #"
expect_reject "comment discount: an empty flow sequence with a comma-bearing comment is rejected" \
  "paths: []  # a, b"
expect_reject "comment discount: an empty flow sequence with a bracket-bearing comment is rejected" \
  "paths: []  # [x, y]"
expect_reject "comment discount: an empty flow sequence with the optional-field note is rejected" \
  "paths: []  $REAL_NOTE"
expect_reject "comment discount: a blank flow sequence with a plain-word comment is rejected" \
  "paths: [ ]  # note"

# ════════════════════════════════════════════════════════════════════════
# comment discount: separators only
# ════════════════════════════════════════════════════════════════════════

expect_reject "comment discount: a separator-only flow sequence with a plain-word comment is rejected" \
  "paths: [ , , ]  # note"
expect_reject "comment discount: a separator-only flow sequence with a bare hash is rejected" \
  "paths: [ , , ]  #"
expect_reject "comment discount: a separator-only flow sequence with a bracket-bearing comment is rejected" \
  "paths: [ , , ]  # [x, y]"
expect_reject "comment discount: a bare comma with a plain-word comment is rejected" \
  "paths: ,  # note"
expect_reject "comment discount: a bare comma with a bare hash is rejected" \
  "paths: ,  #"
expect_reject "comment discount: a bare comma with a comma-bearing comment is rejected" \
  "paths: ,  # a, b"
expect_reject "comment discount: a bare comma with the optional-field note is rejected" \
  "paths: ,  $REAL_NOTE"

# ════════════════════════════════════════════════════════════════════════
# empty block items: a dash that carries nothing is not a glob
# ════════════════════════════════════════════════════════════════════════

# The comment discount applies to an item line as it does to the key line,
# and a quoted empty item counts as nothing in the block spelling exactly as
# `[""]` does in the flow spelling.
expect_reject "empty block item: a dash carrying only a comment is rejected" \
  "paths:
  - # todo"
expect_reject "empty block item: a bare dash is rejected" \
  "paths:
  -"
expect_reject "empty block item: two bare dashes are rejected" \
  "paths:
  -
  -"
expect_reject "empty block item: a double-quoted empty item is rejected" \
  "paths:
  - \"\""
expect_reject "empty block item: a single-quoted empty item is rejected" \
  "paths:
  - ''"
expect_reject "empty block item: a commented key over a quoted empty item is rejected" \
  "paths:  # note
  - \"\""

# ════════════════════════════════════════════════════════════════════════
# multi-line flow sequences: a bracket is never a glob
# ════════════════════════════════════════════════════════════════════════

expect_reject "multi-line flow: an empty sequence split over two lines is rejected" \
  "paths: [
]"
expect_reject "multi-line flow: an empty sequence with a comment on the opening line is rejected" \
  "paths: [   # globs go here
]"
expect_reject "multi-line flow: a sequence holding only a commented-out glob is rejected" \
  "paths: [
  # a/**
]"
# A ` #` inside a flow sequence opens a comment that swallows the closing
# bracket, so the sequence never closes and a YAML loader refuses it.
expect_reject "multi-line flow: a comment that swallows the closing bracket is rejected" \
  "paths: [a/**, #b/**]"
expect_reject "multi-line flow: a sequence still open at the end of the frontmatter is rejected" \
  "paths: [a/**,"

# The next key ends an open sequence rather than being read into it.
verdict="$(gate_case "name: acme-context
paths: [a/**,
description: $NAV_DESC")"
if [ "$verdict" = "reject:paths" ]; then
  pass "multi-line flow: a sequence still open at the next key is rejected"
else
  fail "multi-line flow: a sequence still open at the next key is rejected" "verdict: $verdict"
fi

# ════════════════════════════════════════════════════════════════════════
# no-value spellings: YAML null, an empty mapping, an empty block scalar
# ════════════════════════════════════════════════════════════════════════

# `paths:` and `paths: ~` are the same YAML value, so they get the same
# verdict.
expect_reject "no-value spelling: a tilde is rejected" \
  "paths: ~"
expect_reject "no-value spelling: a lowercase null is rejected" \
  "paths: null"
expect_reject "no-value spelling: a capitalized null with a comment is rejected" \
  "paths: Null  # none yet"
expect_reject "no-value spelling: an uppercase null is rejected" \
  "paths: NULL"
expect_reject "no-value spelling: an empty mapping is rejected" \
  "paths: {}"
expect_reject "no-value spelling: nulls inside a flow sequence are rejected" \
  "paths: [~, null]"
expect_reject "no-value spelling: a null block item is rejected" \
  "paths:
  - null"
expect_reject "no-value spelling: a bare literal block indicator is rejected" \
  "paths: |"
expect_reject "no-value spelling: a folded block indicator over only a comment is rejected" \
  "paths: >-
  # nothing"

# ════════════════════════════════════════════════════════════════════════
# next-line values: the value may start on the line after the key
# ════════════════════════════════════════════════════════════════════════

expect_accept "next-line value: a flow sequence under a commented key is accepted" \
  "paths:  # note
  [a/**, b/**]"
expect_accept "next-line value: a flow sequence under a bare key is accepted" \
  "paths:
  [a/**]"
expect_accept "next-line value: a flow sequence spread over the lines under the key is accepted" \
  "paths:
  [
    a/**,
  ]"
expect_accept "next-line value: a plain string under a bare key is accepted" \
  "paths:
  a/**"
expect_accept "next-line value: a literal block scalar carrying a glob is accepted" \
  "paths: |
  a/**"

# ════════════════════════════════════════════════════════════════════════
# quoted hash: a `#` inside a quoted scalar never starts a comment
# ════════════════════════════════════════════════════════════════════════

# YAML's comment rule applies to plain scalars only. Each value below names
# a glob solely through a quoted ` #`, so a discount blind to quoting
# leaves nothing (or an unclosed `[`) to count.
expect_accept "quoted hash: a double-quoted glob with a space before its hash is accepted" \
  "paths: \" #drafts/**\""
expect_accept "quoted hash: a single-quoted glob with a space before its hash is accepted" \
  "paths: ' # x/**'"
expect_accept "quoted hash: a flow sequence of such globs is accepted" \
  "paths: [\" #a/**\", \" #b/**\"]"
expect_accept "quoted hash: a block item holding such a glob is accepted" \
  "paths:
  - \" #drafts/**\""

# ════════════════════════════════════════════════════════════════════════
# repeated keys: which occurrence a loader keeps is not the gate's to guess
# ════════════════════════════════════════════════════════════════════════

# Loaders disagree on a repeated key: a last-wins loader keeps the second
# occurrence and a strict one refuses the document. Whichever occurrence
# the gate read, it would be judging a value some loader never sees.
verdict="$(gate_case "name: acme-context
description: $NAV_DESC
paths: a/**
paths: b/**")"
if [ "$verdict" = "reject:keys" ]; then
  pass "repeated key: two named paths: keys are rejected"
else
  fail "repeated key: two named paths: keys are rejected" "verdict: $verdict"
fi

verdict="$(gate_case "name: acme-context
description: $NAV_DESC
description: $NAV_DESC")"
if [ "$verdict" = "reject:keys" ]; then
  pass "repeated key: a repeated description: is rejected"
else
  fail "repeated key: a repeated description: is rejected" "verdict: $verdict"
fi

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
