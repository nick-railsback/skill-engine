#!/usr/bin/env bash
# Oracle for the `near()` window helper the prose-assertion suites share.
#
# THE DEFECT THIS EXISTS FOR:
#   `near()` asks whether a needle appears within N characters of an anchor
#   by cutting one window per anchor occurrence with `grep -o` and matching
#   the needle against that stream. It piped into `grep -q`. -q exits at the
#   FIRST match, closing the pipe while the upstream -o is still writing the
#   remaining windows; the upstream dies of SIGPIPE (141), and under the
#   `set -o pipefail` every one of these suites sets, the pipeline reports
#   141. A needle that WAS found therefore reads as a miss.
#
#   The failure is a function of how much the anchor matched, not of what
#   the assertion is about: below roughly a pipe buffer of window output the
#   upstream finishes writing before -q exits and the answer is right. That
#   is why it stayed green on macOS for every suite and every anchor, then
#   failed on Linux CI on exactly the three archive-detection assertions
#   anchored on 'unknown' -- a word frequent enough in that document to push
#   the window stream past the buffer.
#
# WHY IT IS ITS OWN SUITE:
#   The helper is duplicated verbatim into every suite that needs it (these
#   suites are deliberately self-contained -- nothing under tests/ sources a
#   shared shell library; tests/lib/git_verb_scan.sh is executed, not
#   sourced). A per-suite assertion would have to be written eight times and
#   would still not catch a ninth copy. This suite instead extracts and runs
#   whatever `near()` each suite actually ships, so a copy that drifts back
#   to the broken form fails here.
#
# CALIBRATION:
#   The first assertion runs the PRE-FIX form and requires it to get the
#   wrong answer. That is a mutation control, not a curiosity: without it a
#   fixture too small to overflow the pipe buffer would let every assertion
#   below pass against a still-broken helper. If that control ever passes,
#   this suite is not reproducing the condition any more and the greens
#   underneath it mean nothing -- which is what it reports.
#
# -e is intentionally omitted: every assertion runs and reports, not abort
# at the first red one.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ROOT_MARKER="plugin/skill-engine/docs/02-artifact-contract.md"
find_root() {
  local d="$1"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    if [ -f "$d/$ROOT_MARKER" ]; then
      printf '%s\n' "$d"
      return 0
    fi
    d="$(dirname "$d")"
  done
  return 1
}
REPO_ROOT="$(find_root "$SCRIPT_DIR" || find_root "$PWD")"
if [ -z "$REPO_ROOT" ]; then
  echo "ERROR: cannot locate the repository root — no $ROOT_MARKER above $SCRIPT_DIR or $PWD." >&2
  exit 69
fi
TESTS_ROOT="$REPO_ROOT/plugin/skill-engine/tests"

pass_count=0
fail_count=0

banner() { printf '\n== %s ==\n' "$1"; }

pass() {
  printf '  PASS  %s\n' "$1"
  pass_count=$((pass_count + 1))
}

fail() {
  local label="$1"
  shift
  printf '  FAIL  %s\n' "$label"
  local detail
  for detail in "$@"; do
    printf '%s\n' "$detail" | sed 's/^/        /'
  done
  fail_count=$((fail_count + 1))
}

# ---------------------------------------------------------------------------
# The fixture: an anchor-rich text whose needle matches in the FIRST window.
#
# Sizing note, because the arithmetic is not the obvious one: `grep -o` emits
# NON-OVERLAPPING matches, so one ~507-byte window consumes every anchor
# inside it -- roughly 16 of them at this filler width -- rather than
# producing one window per anchor. 32,000 anchors therefore yield about
# 2,300 windows and ~1.06MB of stream, not 32,000 windows. What has to be
# large is the STREAM, so that is what the assertion below measures; source
# length is not a proxy for it.
#
# ~1.06MB clears the 64KB pipe buffer Linux and macOS both default to by
# ~17x, and also clears the 1MB ceiling F_SETPIPE_SZ permits, so a reader
# that leaves early cannot be rescued by buffering however the pipe is
# sized. The upstream is guaranteed to still be writing.
# ---------------------------------------------------------------------------

ANCHOR_N=32000
WINDOW=250
ANCHOR='unknown'
NEEDLE='(no transition|not staged)'

BIG="$(awk -v n="$ANCHOR_N" 'BEGIN { for (i = 1; i <= n; i++) printf "unknown no transition filler-%d ", i }')"

# wc drains to EOF, so measuring the stream cannot itself trip the defect.
STREAM_BYTES="$(printf '%s' "$BIG" \
  | grep -oiE ".{0,${WINDOW}}${ANCHOR}.{0,${WINDOW}}" | wc -c | tr -d ' ')"

if [ "${STREAM_BYTES:-0}" -gt 262144 ]; then
  pass "fixture: the window stream is $STREAM_BYTES bytes, past any pipe buffer a reader can be given"
else
  fail "fixture: the window stream is past any pipe buffer a reader can be given" \
    "measured only ${STREAM_BYTES:-0} bytes of stream from ${#BIG} bytes of source;" \
    "the control below cannot reproduce the defect at this size"
fi

# ---------------------------------------------------------------------------
# Mutation control: the pre-fix helper, verbatim, must get this wrong.
# ---------------------------------------------------------------------------

banner "mutation control: the pre-fix -q form reports a found needle as a miss"

near_prefix_form() {
  local text="$1" anchor="$2" needle="$3" window="$4"
  printf '%s' "$text" \
    | grep -oiE ".{0,${window}}${anchor}.{0,${window}}" \
    | grep -qiE -- "$needle"
}

if near_prefix_form "$BIG" "$ANCHOR" "$NEEDLE" "$WINDOW"; then
  fail "pre-fix form returns the wrong answer (mutation control)" \
    "The -q form answered TRUE, so this environment is NOT reproducing the" \
    "SIGPIPE condition and every assertion below passes vacuously." \
    "Do not read the greens under this line as evidence the helper is fixed."
else
  rc=$?
  pass "pre-fix form returns the wrong answer (mutation control, rc=$rc)"
fi

# ---------------------------------------------------------------------------
# Every shipped copy of the helper answers correctly.
# ---------------------------------------------------------------------------

banner "every suite's shipped near() answers TRUE on the same fixture"

# Newline-delimited rather than an array, and a here-string rather than a
# pipe: the loops below increment the counters, and bash 3.2 (what macOS
# ships, and what this runs under locally) has no mapfile — while a piped
# `while read` would run in a subshell and silently discard every count.
NEAR_SUITES="$(grep -rln '^near()' "$TESTS_ROOT"/*/run.sh | sort)"
NEAR_COUNT="$(printf '%s\n' "$NEAR_SUITES" | grep -c . || true)"

if [ "$NEAR_COUNT" -gt 0 ]; then
  pass "found $NEAR_COUNT suite(s) shipping a near() helper (non-vacuous)"
else
  fail "found suites shipping a near() helper" \
    "no run.sh defines near(); this suite is asserting on nothing"
fi

while IFS= read -r suite; do
  [ -n "$suite" ] || continue
  label="$(basename "$(dirname "$suite")")"
  fn="$(sed -n '/^near()/,/^}/p' "$suite")"

  if [ -z "$fn" ]; then
    fail "$label: near() extracted from the suite" "extraction produced nothing"
    continue
  fi

  if ( set -uo pipefail; eval "$fn"; near "$BIG" "$ANCHOR" "$NEEDLE" "$WINDOW" ); then
    pass "$label: shipped near() finds a needle present in the first window"
  else
    fail "$label: shipped near() finds a needle present in the first window" \
      "returned $? -- 141 means the helper still pipes into an early-exiting reader"
  fi
done <<< "$NEAR_SUITES"

# ---------------------------------------------------------------------------
# Shape guard: no copy pipes window output into a reader that leaves early.
# ---------------------------------------------------------------------------

banner "no shipped near() pipes its window stream into an early-exiting reader"

while IFS= read -r suite; do
  [ -n "$suite" ] || continue
  label="$(basename "$(dirname "$suite")")"
  fn="$(sed -n '/^near()/,/^}/p' "$suite")"

  if printf '%s' "$fn" | grep -qE '\|[[:space:]]*grep[[:space:]]+-[a-zA-Z]*q'; then
    fail "$label: near() drains its window stream" \
      "the helper pipes into 'grep -q', which exits at the first match and" \
      "SIGPIPEs the upstream -o; use 'grep -c ... > /dev/null', which has the" \
      "same 0/1 match semantics but reads to EOF"
  else
    pass "$label: near() drains its window stream"
  fi
done <<< "$NEAR_SUITES"

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------

banner "summary"
printf 'passed: %d   failed: %d\n' "$pass_count" "$fail_count"

if [ "$fail_count" -gt 0 ]; then
  exit 1
fi
exit 0
