#!/usr/bin/env bash
# The frontmatter-ceiling sweep's precision and reach. Every one of these
# already holds the day the sweep is written, so none of them can go
# red-then-green; each is instead broken on a scratch copy of the sweep by a
# control in `mutations/`, which requires this file red.
#
# Deliberately NOT called by `run.sh`. Everything `run.sh` reports is a fact
# still owed; a fact that already holds, reported there, would read green on
# the first run and prove nothing.
#
# WHAT IS HELD.
#   precision      — correct statements of the frontmatter contract, and an
#                    unrelated "two fields", are not flagged.
#   emphasis       — `*` inside a phrase cannot hide it.
#   hard-wrap      — a phrase split across two lines is still flagged.
#   derived set    — a tracked file at a path no test names is flagged; a
#                    file on disk that was never added is not. Tracked is
#                    the rule, not present-on-disk.
#   changelog      — the top-level CHANGELOG.md is skipped, and only it: a
#                    `docs/CHANGELOG-notes.md` is still flagged.
#   references     — `<x>-context/references/` is skipped, and only it: a
#                    `skills/<x>/references/` file is still flagged.
#   templates      — a `*.md.template` file is in the set.
#   relative paths — exclusions read the repo-relative path. The scratch
#                    repository lives under a directory pair that WOULD
#                    match the references exclusion if the sweep read
#                    absolute paths, so every flagged fixture would go quiet.
#   no self-trip   — this suite's own directory carries no tracked Markdown,
#                    and the sweep over this repository flags nothing in it.
#                    The fixtures that carry the phrase family are written
#                    at run time into a scratch repository and never
#                    committed here.
#
# Each fixture is matched on the sweep's report, never on its exit code
# alone, and an exit of 2 (the sweep could not run) is a failure in its own
# right: a broken listing must never read as a quiet tree.
#
# ENV INDIRECTION. SWEEP_SH names the sweep under test (default: the one
# beside this file), so a control can copy it, break the copy, and point
# this file at it.
#
# -e is intentionally omitted: every assertion runs and reports, rather than
# the run aborting at the first failure.

set -uo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
SWEEP_SH="${SWEEP_SH:-$SCRIPT_DIR/sweep.sh}"
SUITE_REL="${SCRIPT_DIR#"$REPO_ROOT"/}"

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

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The scratch repository sits under `<x>-context/references/` on purpose;
# see "relative paths" above.
repo="$work/probe-context/references/corpus"
mkdir -p "$repo"

# put <repo-relative path> <content> — write one fixture file.
put() {
  mkdir -p "$(dirname "$repo/$1")"
  printf '%s\n' "$2" > "$repo/$1"
}

# ── fixtures that must NOT be flagged ──────────────────────────────────────
put 'docs/ok-required.md' \
  'In navigator frontmatter, `name` and `description` are required.'
put 'docs/ok-optional-third.md' \
  'Frontmatter carries `name` and `description`, plus `paths:` as an optional third field.'
put 'docs/ok-two-required.md' \
  'A navigator must set the two required frontmatter fields before it loads.'
put 'docs/ok-unrelated.md' \
  'The old schema had two fields inherited the promise of a stable key.'
put 'CHANGELOG.md' \
  '- Retired the two-field frontmatter wording from the docs.'
put 'packs/foo-context/references/x.md' \
  'This generated reference still says two-field frontmatter.'
put 'notes/not-markdown.txt' \
  'A text file mentioning two-field frontmatter is outside the set.'
# Clean files at the two paths this repository's drift was first found in,
# so a sweep that reads a fixed list of them still scans something and goes
# red on the unlisted fixture below, not merely on an empty scan.
put 'plugin/skill-engine/docs/02-artifact-contract.md' \
  'Navigator frontmatter: `name`, `description`, and an optional `paths:`.'
put 'plugin/skill-engine/docs/11-walkthrough.md' \
  'The example navigator carries `name:` and `description:`; `paths:` is optional.'

# ── fixtures that MUST be flagged ──────────────────────────────────────────
put 'docs/emphasis.md' \
  'The navigator sets **only** the two standard frontmatter fields.'
printf '%s\n' \
  'Every navigator ships with two-field' \
  'frontmatter and a catalog.' > "$repo/docs/hard-wrap.md"
put 'deep/nowhere/unlisted-guide.md' \
  'SKILL.md uses two-field frontmatter.'
put 'docs/CHANGELOG-notes.md' \
  'Our navigators use two-field frontmatter.'
put 'skills/bar/references/y.md' \
  'The example keeps a two-field navigator.'
put 'templates/nav.md.template' \
  'Frontmatter: `name:` and `description:` only.'
put 'docs/only-name-desc.md' \
  'Frontmatter holds only name and description.'
put 'docs/exactly-two.md' \
  'Navigator frontmatter has exactly two fields.'
put 'docs/only-two-required.md' \
  'The example uses only the two required fields.'
put 'docs/upper-case.md' \
  'SKILL.md: TWO-FIELD FRONTMATTER.'

(
  cd "$repo" || exit 1
  git -c init.defaultBranch=main init -q . &&
    git add -f -A . &&
    git -c user.name=t -c user.email=t@example.invalid \
      -c commit.gpgsign=false commit -q --no-verify -m fixtures
) >/dev/null 2>&1 || fail "scratch repository builds" "git init/add/commit failed under $repo"

# Written after the commit and never added: on disk, not tracked.
put 'docs/untracked-note.md' \
  'This draft says two-field frontmatter but was never added.'

# ── one sweep run over the fixture corpus ──────────────────────────────────
report=""
rc=127
if [ -f "$SWEEP_SH" ]; then
  report="$(bash "$SWEEP_SH" "$repo" 2>"$work/sweep.err")"
  rc=$?
fi

echo
echo "── ceiling sweep: runs over a fixture repository ──"

if [ "$rc" -eq 1 ]; then
  pass "ceiling sweep: reports hits over the fixture corpus (exit 1)"
else
  fail "ceiling sweep: reports hits over the fixture corpus (exit 1)" \
    "exit: $rc" "stderr: $(cat "$work/sweep.err" 2>/dev/null)"
fi

# report_for <path> — the report lines for <path>, matched as a line prefix
# so `CHANGELOG.md` can never match `docs/CHANGELOG.md`.
report_for() {
  printf '%s\n' "$report" | awk -v p="$1: " 'index($0, p) == 1'
}

# flagged <path> — the report names <path>.
flagged() {
  [ -n "$(report_for "$1")" ]
}

# expect_flagged <label> <path> <phrase>
expect_flagged() {
  if printf '%s\n' "$report" | grep -qxF -- "$2: $3"; then
    pass "$1"
  else
    fail "$1" "expected report line: $2: $3" "report: ${report:-<empty>}"
  fi
}

# expect_quiet <label> <path>
expect_quiet() {
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
    fail "$1" "sweep could not run (exit $rc)"
  elif flagged "$2"; then
    fail "$1" "report: $(report_for "$2")"
  else
    pass "$1"
  fi
}

echo
echo "── precision: correct statements are not flagged ──"

expect_quiet "precision: 'name and description are required' is not flagged" \
  'docs/ok-required.md'
expect_quiet "precision: 'name and description, plus paths: as an optional third field' is not flagged" \
  'docs/ok-optional-third.md'
expect_quiet "precision: 'the two required frontmatter fields' is not flagged" \
  'docs/ok-two-required.md'
expect_quiet "precision: an unrelated 'two fields' is not flagged" \
  'docs/ok-unrelated.md'

echo
echo "── phrase family: each phrase is flagged, case-insensitively ──"

expect_flagged "phrase family: 'name: and description: only' in code spans is flagged" \
  'templates/nav.md.template' 'name: and description: only'
expect_flagged "phrase family: 'only name and description' is flagged" \
  'docs/only-name-desc.md' 'only name and description'
expect_flagged "phrase family: 'exactly two fields' is flagged" \
  'docs/exactly-two.md' 'exactly two fields'
expect_flagged "phrase family: 'only the two required fields' is flagged" \
  'docs/only-two-required.md' 'only the two required fields'
expect_flagged "phrase family: 'two-field navigator' is flagged" \
  'skills/bar/references/y.md' 'two-field navigator'
expect_flagged "phrase family: an upper-case phrase is flagged" \
  'docs/upper-case.md' 'two-field frontmatter'

echo
echo "── emphasis and hard-wraps do not hide a match ──"

expect_flagged "emphasis: '**only** the two standard frontmatter fields' is flagged" \
  'docs/emphasis.md' 'only the two standard frontmatter fields'
expect_flagged "hard-wrap: a phrase split across two lines is flagged" \
  'docs/hard-wrap.md' 'two-field frontmatter'

echo
echo "── derived set: tracked files, not a list and not the disk ──"

expect_flagged "derived set: a tracked file at a path no test names is flagged" \
  'deep/nowhere/unlisted-guide.md' 'two-field frontmatter'
expect_quiet "derived set: an untracked file on disk is not flagged" \
  'docs/untracked-note.md'
expect_quiet "derived set: a tracked non-Markdown file is not flagged" \
  'notes/not-markdown.txt'
expect_flagged "templates: a tracked .md.template file is flagged" \
  'templates/nav.md.template' 'name: and description: only'

echo
echo "── exclusions: exactly the two, by repo-relative path ──"

expect_quiet "changelog: the top-level CHANGELOG.md is not flagged" \
  'CHANGELOG.md'
expect_flagged "changelog: docs/CHANGELOG-notes.md is still flagged" \
  'docs/CHANGELOG-notes.md' 'two-field frontmatter'
expect_quiet "references: a <x>-context/references/ file is not flagged" \
  'packs/foo-context/references/x.md'
expect_flagged "references: a skills/<x>/references/ file is still flagged" \
  'skills/bar/references/y.md' 'two-field navigator'

hit_count=0
[ -n "$report" ] && hit_count="$(printf '%s\n' "$report" | grep -c .)"
if [ "$hit_count" -eq 10 ]; then
  pass "exclusions: the fixture corpus yields exactly its 10 expected hits"
else
  fail "exclusions: the fixture corpus yields exactly its 10 expected hits" \
    "hits: $hit_count" "report: ${report:-<empty>}"
fi

echo
echo "── no self-trip: this suite carries no phrase it sweeps for ──"

own_md="$(git -C "$REPO_ROOT" ls-files -- "$SUITE_REL/*.md" "$SUITE_REL/*.md.template")"
if [ -z "$own_md" ]; then
  pass "no self-trip: no tracked Markdown under this suite's directory"
else
  fail "no self-trip: no tracked Markdown under this suite's directory" "$own_md"
fi

if [ -f "$SWEEP_SH" ]; then
  repo_report="$(bash "$SWEEP_SH" "$REPO_ROOT" 2>/dev/null)"
  repo_rc=$?
else
  repo_report=""
  repo_rc=127
fi
if [ "$repo_rc" -ne 0 ] && [ "$repo_rc" -ne 1 ]; then
  fail "no self-trip: the sweep over this repository flags nothing in this suite" \
    "sweep could not run over $REPO_ROOT (exit $repo_rc)"
elif printf '%s\n' "$repo_report" | grep -qF -- "$SUITE_REL/"; then
  fail "no self-trip: the sweep over this repository flags nothing in this suite" \
    "$(printf '%s\n' "$repo_report" | grep -F -- "$SUITE_REL/")"
else
  pass "no self-trip: the sweep over this repository flags nothing in this suite"
fi

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
