#!/usr/bin/env bash
# Feature-scoped test runner for check 4's cache-scoped exception — the
# doctrine lint (locked decision #1: the engine performs no git mutations
# against any repository the user owns) must permit `fetch`,
# `sparse-checkout`, and `checkout` when, and only when, the invocation's
# `-C` target is a path under the engine's own clone cache
# (~/.cache/skill-engine/), and its scanner must actually be able to see
# those invocations in the first place.
#
# Two invariants this runner exists to pin, neither exercised by
# tests/doctrine-git-verbs/run.sh:
#
#   1. A verb sitting between two double-quoted variable references (e.g.
#      `git -C "$dest" fetch --depth=1 origin "$sha"`) must not be swallowed.
#      tests/lib/git_verb_scan.sh's literal-stripping loop treats the text
#      between the closing quote of the first reference and the opening
#      quote of the second as a stray quoted literal — with nothing between
#      them but plain words, that span (verb included) gets deleted before
#      the verb regex ever runs. This is exactly the shape a cache-root `-C`
#      argument takes once a second quoted ref/pattern argument follows it,
#      so the blind spot and the cache exception collide by construction:
#      an exception that only checks the allow-list can never fire on an
#      invocation the scanner never reported.
#
#   2. A `-C` target under ~/.cache/skill-engine/ is the one place these
#      three verbs are permitted; anywhere else (or with no `-C` at all)
#      they must still be denied by name, with the file, line, and verb
#      named in the failure, and the failure text itself must document the
#      cache-scoped exception so the rule is learned from the tool, not
#      from a document this file cannot see.
#
# A checker's characteristic failure is passing when it should fail —
# feeding it only conforming input never exercises that failure mode, so
# the must-reject cases below are not optional filler.
#
# -e is intentionally omitted: every assertion must run and report, not
# abort at the first red one.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_ROOT="$(cd "$TESTS_ROOT/.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

SCANNER="$TESTS_ROOT/lib/git_verb_scan.sh"
CI_LOCAL="$REPO_ROOT/scripts/ci-local.sh"

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

TMPDIR_CASE="$(mktemp -d "${TMPDIR:-/tmp}/git-verb-cache-scope.XXXXXX")"

# The one real-fixture location doctrine.sh's check 4 actually scans
# (per its own recommended technique for exercising the exception against
# real scan scope). Obviously-scratch, dot-prefixed name so it can never be
# mistaken for real content; removed unconditionally on exit so a killed or
# failing run never leaves untracked cruft under a real scan path.
SCRATCH_FILE="$PLUGIN_ROOT/skills/.oracle-git-verb-cache-scope-scratch.md"
SCRATCH_REL="skills/.oracle-git-verb-cache-scope-scratch.md"
SCRATCH_LINE=4

cleanup() {
  rm -rf "$TMPDIR_CASE"
  rm -f "$SCRATCH_FILE"
}
trap cleanup EXIT

# ---- scanner-level helpers (no real fixture file touched) -----------------

# scan_raw <shell-source-line> — the extractor's raw <path>:<line>:<verb>
# output for one probe line, or empty.
scan_raw() {
  local probe="$TMPDIR_CASE/probe.sh"
  printf '%s\n' "$1" > "$probe"
  bash "$SCANNER" --root "$TMPDIR_CASE/" "$probe" 2>/dev/null
}

# scan_verbs <shell-source-line> — just the verb candidates, space-separated.
scan_verbs() {
  scan_raw "$1" | awk -F: '{print $3}' | tr '\n' ' ' | sed 's/ $//'
}

# expect_verbs <label> <line> <expected-space-separated-verbs>
expect_verbs() {
  local label="$1" line="$2" expected="$3" got
  got="$(scan_verbs "$line")"
  if [ "$got" = "$expected" ]; then
    pass "$label"
  else
    fail "$label" "line:     $line" "expected: ${expected:-<nothing>}" "got:      ${got:-<nothing>}"
  fi
}

# expect_field3 <label> <raw-scanner-output> <expected-verb> — the
# <path>:<line>:<verb> consumer contract, isolated to the exact extraction
# an existing consumer performs.
expect_field3() {
  local label="$1" raw="$2" expected="$3" got
  got="$(printf '%s\n' "$raw" | awk -F: '{print $3}')"
  if [ "$got" = "$expected" ]; then
    pass "$label"
  else
    fail "$label" "raw: ${raw:-<empty>}" "expected field 3: ${expected:-<empty>}" "got: ${got:-<empty>}"
  fi
}

# ---- real-fixture helper (touches the actual scan scope) -------------------

# cache_line <home-form> <verb-and-args> — builds a realistic cache-scoped
# invocation, e.g. cache_line '$HOME' 'fetch --depth=1 origin "$sha"'.
cache_line() {
  local home="$1" verb_args="$2"
  printf 'git -C "%s/.cache/skill-engine/${source_id}-${sha}" %s' "$home" "$verb_args"
}

# with_scratch_fixture <line> — writes <line> as the sole invocation inside
# a fenced bash block in the scratch file, runs the real doctrine suite via
# its usual entry point, removes the fixture again, and leaves the result in
# the globals DOCTRINE_OUT / DOCTRINE_EXIT for the caller to inspect. Any
# scan-scope file is fair game for check 4; a dot-prefixed name under
# skills/ is intentional scratch, not smuggled real content.
DOCTRINE_OUT=""
DOCTRINE_EXIT=0
with_scratch_fixture() {
  {
    printf '%s\n' '# Scratch'
    printf '\n'
    printf '%s\n' '```bash'
    printf '%s\n' "$1"
    printf '%s\n' '```'
  } > "$SCRATCH_FILE"
  DOCTRINE_OUT="$(bash "$CI_LOCAL" doctrine 2>&1)"
  DOCTRINE_EXIT=$?
  rm -f "$SCRATCH_FILE"
}

section "the scanner blind spot: a verb between two double-quoted variables must not be swallowed"

# These two lines are the origin of this chunk: probing the scanner with
# them today reports neither verb, because the plain text between the two
# quoted variable references (nothing but the verb and its flags) matches
# the extractor's own "quoted literal, no \$ or backtick inside" stripper —
# which does not know it is looking at two unrelated quoted arguments
# rather than one literal spanning both.
expect_verbs "fetch between two quoted variables: git -C \"\$dest\" fetch --depth=1 origin \"\$new_sha\"" \
  'git -C "$dest" fetch --depth=1 origin "$new_sha"' 'fetch'
expect_verbs "diff between two quoted variables: git -C \"\$dest\" diff --name-only \"\$old_sha\" \"\$new_sha\"" \
  'git -C "$dest" diff --name-only "$old_sha" "$new_sha"' 'diff'

section "cache-scoped invocations are visible to the scanner, for every HOME spelling"

# The cache exception is only checkable once the invocation it is meant to
# exempt is not itself invisible. A realistic cache-cloned invocation for
# each of the three newly-permitted verbs carries the same
# quoted-arg/plain-words/quoted-arg shape as the blind spot above (a
# trailing quoted ref or pattern argument follows the -C target), so today
# every one of these is blind for the same reason, regardless of which
# literal HOME spelling precedes .cache/skill-engine/.
for home in '~' '$HOME' '${HOME}'; do
  expect_verbs "fetch under $home/.cache/skill-engine/... is a candidate" \
    "$(cache_line "$home" 'fetch --depth=1 origin "$sha"')" 'fetch'
  expect_verbs "sparse-checkout under $home/.cache/skill-engine/... is a candidate" \
    "$(cache_line "$home" 'sparse-checkout set "$pattern"')" 'sparse-checkout'
  expect_verbs "checkout under $home/.cache/skill-engine/... is a candidate" \
    "$(cache_line "$home" 'checkout "$sha"')" 'checkout'
done

section "check 4 does not flag a real cache-scoped invocation as a violation"

# Same nine invocations, this time dropped into the real scan scope and run
# through the real suite entry point. Today this is expected to report no
# violation for the wrong reason (the line above is invisible, not
# exempted) — the previous section is what makes that distinction visible;
# together they are non-vacuous at every future stage: once only the
# scanner blind spot is fixed, the previous section goes green while this
# one must still fail (correctly flagging a real violation, since no
# allow-list exception exists yet); once the cache exception itself is
# added, both must be green.
for home in '~' '$HOME' '${HOME}'; do
  for verb_args in \
    'fetch:fetch --depth=1 origin "$sha"' \
    'sparse-checkout:sparse-checkout set "$pattern"' \
    'checkout:checkout "$sha"'
  do
    verb="${verb_args%%:*}"
    args="${verb_args#*:}"
    with_scratch_fixture "$(cache_line "$home" "$args")"
    reported="$(printf '%s\n' "$DOCTRINE_OUT" | grep -F "$SCRATCH_REL:$SCRATCH_LINE" || true)"
    if [ -z "$reported" ]; then
      pass "$verb under $home/.cache/skill-engine/... passes check 4"
    else
      fail "$verb under $home/.cache/skill-engine/... passes check 4" \
        "doctrine reported a violation for the cache-scoped fixture:" "$reported"
    fi
  done
done

section "verbs outside the cache root are still rejected by name, line, and verb"

# The must-reject half: any -C target that is not under the cache root, or
# no -C at all, must still fail check 4 — and the failure must name the
# offending file, line, and verb, not just fail silently.
expect_reject() {
  local label="$1" line="$2" verb="$3" path_hit verb_hit
  with_scratch_fixture "$line"
  path_hit="$(printf '%s\n' "$DOCTRINE_OUT" | grep -F "$SCRATCH_REL:$SCRATCH_LINE" || true)"
  verb_hit="$(printf '%s\n' "$path_hit" | grep -F "git $verb" || true)"
  if [ "$DOCTRINE_EXIT" -ne 0 ] && [ -n "$verb_hit" ]; then
    pass "$label"
  else
    fail "$label" "exit: $DOCTRINE_EXIT" "matching output line: ${path_hit:-<none>}"
  fi
}

expect_reject "fetch with a -C target outside the cache root still fails" \
  'git -C "$repo" fetch origin main' 'fetch'
expect_reject "sparse-checkout with a -C target outside the cache root still fails" \
  'git -C "$repo" sparse-checkout set docs' 'sparse-checkout'
expect_reject "checkout with a -C target outside the cache root still fails" \
  'git -C "$repo" checkout main' 'checkout'
expect_reject "fetch with no -C at all still fails" \
  'git fetch origin main' 'fetch'
expect_reject "sparse-checkout with no -C at all still fails" \
  'git sparse-checkout set docs' 'sparse-checkout'
expect_reject "checkout with no -C at all still fails" \
  'git checkout main' 'checkout'

section "the failure message documents the cache-scoped exception"

# Reuse the must-reject shape to trigger a real failure, then look for a
# narrow, stable token that could only appear if the message states the
# cache-scoped rule — not a full sentence, since the exact wording is a
# plan-time choice.
with_scratch_fixture 'git -C "$repo" checkout main'
if printf '%s\n' "$DOCTRINE_OUT" | grep -qF '.cache/skill-engine'; then
  pass "check 4's failure output names the cache-scoped exception (.cache/skill-engine)"
else
  fail "check 4's failure output names the cache-scoped exception (.cache/skill-engine)" \
    "doctrine output did not mention .cache/skill-engine anywhere"
fi

section "the <path>:<line>:<verb> output contract survives a hypothetical 4th field"

# A representative sample of tests/doctrine-git-verbs/run.sh's existing
# cases, re-asserted at the field-3-extraction level this chunk's scope note
# calls out explicitly — not a full re-run of that suite, which stays
# green and unedited on its own.
expect_field3 "bare invocation: git push" \
  "$(scan_raw 'git push origin main')" 'push'
expect_field3 "an allow-listed verb is still a field-3-extractable candidate: git log" \
  "$(scan_raw 'git log --oneline')" 'log'
expect_field3 "option-carrying form: git -C \"\$repo\" push" \
  "$(scan_raw 'git -C "$repo" push')" 'push'
expect_field3 "a shell comment produces no candidate line to extract from" \
  "$(scan_raw '# git -C "$repo" push origin main')" ''
expect_field3 "a Markdown code span produces no candidate line to extract from" \
  "$(scan_raw 'The engine never runs `git -C "$repo" push` against your tree.')" ''

# A fourth field (e.g. carrying a -C target) is a plausible way the
# exception gets implemented, but nothing here claims that is what ships —
# only that existing field-3 consumers would be unaffected if it did.
synthetic_line='path:12:fetch:/some/target'
synthetic_got="$(printf '%s\n' "$synthetic_line" | awk -F: '{print $3}')"
if [ "$synthetic_got" = 'fetch' ]; then
  pass "a synthetic 4th field does not shift field-3 extraction"
else
  fail "a synthetic 4th field does not shift field-3 extraction" \
    "line: $synthetic_line" "got: $synthetic_got"
fi

section "the doctrine suite is clean with no scratch fixture present"

baseline_out="$(bash "$CI_LOCAL" doctrine 2>&1)"
baseline_exit=$?
if [ "$baseline_exit" -eq 0 ]; then
  pass "bash scripts/ci-local.sh doctrine passes on the repo as it stands"
else
  fail "bash scripts/ci-local.sh doctrine passes on the repo as it stands" \
    "exit: $baseline_exit" "$baseline_out"
fi

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"

[ "$fail_count" -eq 0 ]
