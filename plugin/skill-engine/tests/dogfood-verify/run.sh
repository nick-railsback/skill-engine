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

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"

[ "$fail_count" -eq 0 ]
