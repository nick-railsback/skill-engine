#!/usr/bin/env bash
# The navigator-frontmatter gate rejects a `paths:` key that names no glob,
# whatever trailing YAML comment the key line carries.
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
# Every case here is a fact still owed. The behaviours that already hold and
# must keep holding (non-empty values with comments, a `#` inside a glob, the
# admitted key set, the existing fixture matrix, the shipped navigators) live
# in `preserved.sh` beside this file, with a mutation control each.
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

# nav_gate_report <contextualizer-root> — the navigator-frontmatter check's
# own section of a verify run over that root.
nav_gate_report() {
  local root cache out
  root="$1"
  cache="$(mktemp -d)"
  out="$(CTX_ROOT="$root" SKILL_ENGINE_CACHE_ROOT="$cache" bash "$VERIFY_SH" 2>&1)"
  rm -rf "$cache"
  printf '%s\n' "$out" | awk '
    index($0, "(navigator-skill)") > 0 && !found { found = 1; print; next }
    found && /^=== / { exit }
    found { print }
  '
}

# gate_case <frontmatter-body> — "accept", "reject" or "unreadable", from a
# scratch contextualizer whose navigator frontmatter is exactly those lines.
gate_case() {
  local root report
  root="$(mktemp -d)"
  mkdir -p "$root/research"
  {
    printf -- '---\n'
    printf '%s\n' "$1"
    printf -- '---\n\n# Acme\n'
  } > "$root/SKILL.md"
  printf '{"schema_version": 1, "sources": []}\n' > "$root/research/source-paths.json"
  report="$(nav_gate_report "$root")"
  rm -rf "$root"
  if [ -z "$report" ]; then
    printf 'unreadable'
  elif printf '%s\n' "$report" | grep -q '\[FAIL\]'; then
    printf 'reject'
  else
    printf 'accept'
  fi
}

# expect_reject <label> <paths-lines> — the given `paths:` lines, appended to
# a valid two-key frontmatter, must be rejected.
expect_reject() {
  local label="$1" verdict
  verdict="$(gate_case "name: acme-context
description: $NAV_DESC
$2")"
  if [ "$verdict" = "reject" ]; then
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
if [ "$verdict" = "reject" ]; then
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

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
