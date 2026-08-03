#!/usr/bin/env bash
# Black-box oracle for this repo's own contextualizer at
# .claude/skills/skill-engine-context/ against the gate the engine stamps
# into every user's tree: its own verify.sh.
#
# The engine ships a contextualizer auditor and installs it beside every
# contextualizer it scaffolds. This repo dogfoods the engine — it carries a
# contextualizer describing itself — so the one instance whose corpus is
# pinned, permalink-scanned and eval-graded by five suites in this tree is
# also the one instance that can demonstrate the auditor works on a real
# corpus rather than on fixtures. It has to pass.
#
# It did not, and nothing said so. ci-local's run_examples loops
# `examples/*/verify.sh`, which never includes this path, so `make ci-local`
# and CI both reported green while the only shipped contextualizer failing
# the gate was the repo's own.
#
# -e is intentionally omitted: every assertion must run and report, not
# abort at the first red one.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

CTX_ROOT="$REPO_ROOT/.claude/skills/skill-engine-context"
CTX_VERIFY="$CTX_ROOT/verify.sh"
NAV="$CTX_ROOT/SKILL.md"

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

section "the dogfood contextualizer is present and auditable"

for f in "$CTX_VERIFY" "$NAV"; do
  if [ -f "$f" ]; then
    pass "present: ${f#"$REPO_ROOT"/}"
  else
    fail "present: ${f#"$REPO_ROOT"/}"
  fi
done

if [ ! -f "$CTX_VERIFY" ] || [ ! -f "$NAV" ]; then
  echo
  echo "Passed: $pass_count"
  echo "Failed: $fail_count"
  exit 1
fi

section "it passes the gate the engine stamps into every user's tree"

VERIFY_OUT="$(bash "$CTX_VERIFY" 2>&1)"
VERIFY_RC=$?

if [ "$VERIFY_RC" -eq 0 ]; then
  pass "verify.sh exits 0 against this repo's own contextualizer"
else
  fail "verify.sh exits 0 against this repo's own contextualizer" \
    "$(printf '%s' "$VERIFY_OUT" | grep -E '^\s*\[FAIL\]' | head -10 | tr '\n' '~')"
fi

# Non-vacuity: an auditor that skipped everything would also exit 0. The
# corpus is real, so real checks have to have run against it.
if printf '%s' "$VERIFY_OUT" | grep -qE 'Passed: [1-9]'; then
  pass "the run is non-vacuous — checks actually executed against the corpus rather than all skipping"
else
  fail "the run is non-vacuous — checks actually executed against the corpus rather than all skipping" \
    "$(printf '%s' "$VERIFY_OUT" | tail -5 | tr '\n' '~')"
fi

if printf '%s' "$VERIFY_OUT" | grep -qE '^\s*\[FAIL\]'; then
  fail "no check reports FAIL" \
    "$(printf '%s' "$VERIFY_OUT" | grep -E '^\s*\[FAIL\]' | head -10 | tr '\n' '~')"
else
  pass "no check reports FAIL"
fi

section "reference links live in the Catalog, and only there"

# Check 4 harvests every `(references/...)` markdown link in the navigator,
# not only the rows of the Catalog table, and holds the resulting set to a
# strict 1:1 bijection with references/. A prose link to a reference that
# the Catalog also lists is therefore two targets for one file, and reads
# out as a duplicate-row violation.
#
# That harvest matches the convention the whole corpus already follows:
# both navigator templates and all three shipped examples put
# `(references/...)` links in Catalog rows and nowhere else. This asserts
# the dogfood navigator follows it too — a cheaper, more specific signal
# than the whole-file exit code above, and the one that names what to fix.
dupes=$(grep -oE '\(references/[^()]+\)' "$NAV" 2>/dev/null | LC_ALL=C sort | uniq -d)

if [ -z "$dupes" ]; then
  pass "no reference is linked twice from the navigator (prose links do not shadow a Catalog row)"
else
  fail "no reference is linked twice from the navigator (prose links do not shadow a Catalog row)" \
    "linked more than once: $(printf '%s' "$dupes" | tr '\n' ' ')"
fi

# Guard the assertion above against a navigator that links nothing at all.
link_count=$(grep -coE '\(references/[^()]+\)' "$NAV" 2>/dev/null || printf '0')
if [ "$link_count" -ge 9 ]; then
  pass "the navigator does carry its Catalog links ($link_count found) — the duplicate check is not vacuous"
else
  fail "the navigator does carry its Catalog links — the duplicate check is not vacuous" \
    "only $link_count (references/...) links found"
fi

section "the auditor it runs is the auditor the engine ships"

# The dogfood contextualizer's verify.sh is tracked in this repo, and it is
# a stamped copy of engine-bootstrap-templates/verify.sh — the same
# relationship every examples/<slug>/verify.sh has. Doctrine check 7 exists
# because that relationship does not hold by itself: a template edit that
# misses a copy leaves a ~1,300-line script quietly disagreeing with the one
# it came from.
#
# Check 7, `make sync` and ci-local all discovered copies by globbing
# `examples/`, so this one was outside every one of them at once. The repo
# shipped, tracked, a contextualizer whose auditor disagreed with the
# auditor it teaches — passing checks the shipped engine would fail, and
# widening on every future template edit. Worse, pre-commit.sh.template
# globs exactly `.claude/skills/*-context/verify.sh`, so a maintainer who
# installs the stamped hook in this repo gates every commit on that stale
# script.
TEMPLATE="$PLUGIN_ROOT/engine-bootstrap-templates/verify.sh"
INVENTORY="$REPO_ROOT/scripts/stamped-verify-copies.sh"

if [ -f "$TEMPLATE" ] && cmp -s "$TEMPLATE" "$CTX_VERIFY"; then
  pass "the tracked verify.sh is byte-identical to engine-bootstrap-templates/verify.sh"
else
  fail "the tracked verify.sh is byte-identical to engine-bootstrap-templates/verify.sh" \
    "run \`make sync\`; diff summary: $(diff "$TEMPLATE" "$CTX_VERIFY" 2>&1 | head -4 | tr '\n' '~')"
fi

# One inventory, not three hand-mirrored find expressions. Check 7 and
# `make sync` are the detector and the fix for the same invariant, and they
# drifted apart precisely because each carried its own glob.
if [ -x "$INVENTORY" ]; then
  pass "present and executable: scripts/stamped-verify-copies.sh"
else
  fail "present and executable: scripts/stamped-verify-copies.sh"
fi

if [ -x "$INVENTORY" ]; then
  listed="$("$INVENTORY" 2>/dev/null)"

  if printf '%s\n' "$listed" | grep -qxF "$CTX_VERIFY"; then
    pass "the inventory lists this repo's own contextualizer, not only examples/"
  else
    fail "the inventory lists this repo's own contextualizer, not only examples/" \
      "listed: $(printf '%s' "$listed" | tr '\n' ' ')"
  fi

  listed_examples=$(printf '%s\n' "$listed" | grep -c "/examples/" || true)
  if [ "$listed_examples" -ge 3 ]; then
    pass "the inventory still lists every examples/<slug>/verify.sh ($listed_examples found)"
  else
    fail "the inventory still lists every examples/<slug>/verify.sh" \
      "only $listed_examples found under examples/"
  fi

  # Every listed copy must actually match — the inventory is only worth
  # having if what it names is what gets compared.
  drifted=""
  while IFS= read -r copy; do
    [ -n "$copy" ] || continue
    cmp -s "$TEMPLATE" "$copy" || drifted="${drifted:+$drifted, }${copy#"$REPO_ROOT"/}"
  done <<< "$listed"
  if [ -z "$drifted" ]; then
    pass "every copy the inventory names is byte-identical to the template"
  else
    fail "every copy the inventory names is byte-identical to the template" \
      "diverged: $drifted"
  fi
fi

# Wiring: the detector and the fix both have to read the shared inventory,
# or the next path added to it is covered by one and not the other.
DOCTRINE="$PLUGIN_ROOT/tests/doctrine.sh"
MAKEFILE="$REPO_ROOT/Makefile"

if grep -qF 'stamped-verify-copies.sh' "$DOCTRINE" 2>/dev/null; then
  pass "doctrine.sh's drift check reads the shared inventory rather than its own glob"
else
  fail "doctrine.sh's drift check reads the shared inventory rather than its own glob"
fi

if grep -qF 'stamped-verify-copies.sh' "$MAKEFILE" 2>/dev/null; then
  pass "the Makefile's sync target reads the shared inventory rather than its own glob"
else
  fail "the Makefile's sync target reads the shared inventory rather than its own glob"
fi

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"

[ "$fail_count" -eq 0 ]
