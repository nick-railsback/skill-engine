#!/usr/bin/env bash
# Feature-scoped test runner for the git-verb extractor behind doctrine
# check 4 — the lint asserting the engine invokes no mutating git verb
# against a repository the user owns.
#
# The extractor used to require a lowercase letter immediately after
# `git `, so it saw `git push` and did not see `git -C "$repo" push`. Every
# form carrying one of git's own options before the verb — `-C <dir>`,
# `-c <cfg>`, `--git-dir=`, `--no-pager` — was invisible to it. A shipped
# skill or bin script writing `git -C "$repo" push origin main` or
# `git -C "$ctx" reset --hard` passed `make ci-local` clean while the engine
# mutated the user's repo, and .claude/settings.json's ask-gates were
# described as "belt-and-suspenders with the git.readonly lint" — a lint
# that could not see the form.
#
# The extraction is pulled out of doctrine.sh into tests/lib/git_verb_scan.sh
# so it can be exercised against fixtures instead of only against whatever
# the repo happens to contain today. Contract frozen here:
#
#   bash git_verb_scan.sh --root <prefix> <file>...
#
#     Writes one line per candidate git invocation:
#
#       <path-with-prefix-stripped>:<line-number>:<verb>
#
#     "Candidate" is the operative word. This layer answers "what token
#     follows a git invocation", not "is that token a mutating verb" —
#     doctrine.sh owns the allow-list and the known-verbs filter that turn
#     candidates into violations, so prose like "no git mutations" is
#     expected to come out of here as the candidate `mutations` and be
#     dropped there.
#
#     Not candidates, and stripped before extraction: HTML comments,
#     Markdown code spans, shell line comments, and double-quoted literals
#     carrying no command substitution.
#
# -e is intentionally omitted: every assertion must run and report, not
# abort at the first red one.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SCANNER="$TESTS_ROOT/lib/git_verb_scan.sh"
DOCTRINE="$TESTS_ROOT/doctrine.sh"

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

TMPDIR_CASE="$(mktemp -d "${TMPDIR:-/tmp}/doctrine-git-verbs.XXXXXX")"
cleanup() { rm -rf "$TMPDIR_CASE"; }
trap cleanup EXIT

section "extractor present"

if [ -f "$SCANNER" ]; then
  pass "present: tests/lib/git_verb_scan.sh"
else
  fail "present: tests/lib/git_verb_scan.sh"
fi

# scan_line <shell-source-line> — the verbs the extractor reports for one
# line of a fixture file, space-separated on one line, or empty.
scan_line() {
  local probe="$TMPDIR_CASE/probe.sh"
  printf '%s\n' "$1" > "$probe"
  if [ ! -f "$SCANNER" ]; then
    printf ''
    return
  fi
  bash "$SCANNER" --root "$TMPDIR_CASE/" "$probe" 2>/dev/null \
    | awk -F: '{print $3}' | tr '\n' ' ' | sed 's/ $//'
}

# expect_verbs <label> <line> <expected-space-separated-verbs>
expect_verbs() {
  local label="$1" line="$2" expected="$3" got
  got="$(scan_line "$line")"
  if [ "$got" = "$expected" ]; then
    pass "$label"
  else
    fail "$label" "line:     $line" "expected: ${expected:-<nothing>}" "got:      ${got:-<nothing>}"
  fi
}

section "the plain form still works (regression guard)"

expect_verbs "bare invocation: git push" \
  'git push origin main' 'push'
expect_verbs "bare invocation: an allow-listed verb is still reported as a candidate" \
  'git log --oneline' 'log'
expect_verbs "two invocations on one line are both reported" \
  'git status && git commit -m x' 'status commit'

section "git's own options no longer hide the verb"

# The exact invocations the audit named, and the two forms this repo's own
# .claude/settings.json ask-gates exist to stop.
expect_verbs "-C with a quoted variable directory: git -C \"\$repo\" push" \
  'git -C "$repo" push origin main' 'push'
expect_verbs "-C with a quoted variable directory: git -C \"\$ctx\" reset --hard" \
  'git -C "$ctx" reset --hard' 'reset'
expect_verbs "-C with an unquoted path" \
  'git -C /tmp/scratch commit -q -m initial' 'commit'
expect_verbs "-c config assignment before the verb" \
  'git -c user.email=t@e.com commit -m x' 'commit'
expect_verbs "-c and -C together" \
  'git -c core.quotePath=false -C "$d" push' 'push'
expect_verbs "--git-dir= long option with an attached value" \
  'git --git-dir=/srv/x/.git status' 'status'
expect_verbs "--no-pager valueless long option" \
  'git --no-pager log' 'log'
expect_verbs "an option form does not swallow the verb as its value" \
  'git --no-pager reset --hard' 'reset'

section "the strippers still apply to the option-carrying form"

# Every guard doctrine check 4 documents has to survive the widened match,
# or widening it trades a false negative for a pile of false positives.
expect_verbs "a shell comment naming the form is not an invocation" \
  '# git -C "$repo" push origin main' ''
expect_verbs "a trailing comment does not add an invocation" \
  'ls   # git -C "$repo" push' ''
expect_verbs "a Markdown code span naming the form is not an invocation" \
  'The engine never runs `git -C "$repo" push` against your tree.' ''
expect_verbs "an HTML comment naming the form is not an invocation" \
  '<!-- git -C "$repo" push -->' ''
expect_verbs "a double-quoted literal naming the form is not an invocation" \
  'echo "git -C /tmp push"' ''
expect_verbs "a command substitution inside the quotes is still scanned" \
  'echo "$(git -C /tmp push)"' 'push'

section "prose is still left for doctrine's verb filter to drop"

# This layer does not decide what is a verb. A noun phrase comes out as a
# candidate and doctrine.sh's known-verbs set drops it — asserted here so
# the division of labour is pinned rather than assumed.
expect_verbs "a prose noun phrase is emitted as a candidate, not silently swallowed" \
  'The engine performs no git mutations against your repository.' 'mutations'

section "doctrine.sh consumes this extractor and still denies the verbs"

if grep -qF 'git_verb_scan.sh' "$DOCTRINE" 2>/dev/null; then
  pass "doctrine.sh's check 4 runs tests/lib/git_verb_scan.sh rather than an inlined copy"
else
  fail "doctrine.sh's check 4 runs tests/lib/git_verb_scan.sh rather than an inlined copy"
fi

# The extractor is only half the lint. If a widened match were paired with
# an allow-list that had quietly grown to cover the newly-visible verbs,
# nothing would have changed.
allow_block="$(sed -n '/# Allow-list: read-only relative to user repo state\./,/# Known real git verbs/p' "$DOCTRINE" 2>/dev/null)"
denied_ok=1
for verb in push commit reset checkout merge rebase tag init add rm mv; do
  printf '%s' "$allow_block" | grep -qF "allow[\"$verb\"]" && denied_ok=0
done
if [ "$denied_ok" -eq 1 ] && [ -n "$allow_block" ]; then
  pass "no mutating verb has been added to check 4's allow-list"
else
  fail "no mutating verb has been added to check 4's allow-list" \
    "allow-list block: $(printf '%s' "$allow_block" | tr '\n' '~')"
fi

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"

[ "$fail_count" -eq 0 ]
