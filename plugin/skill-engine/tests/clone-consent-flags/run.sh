#!/usr/bin/env bash
# Prose-and-executed oracle for consent flags on the local clone cache: a
# --clone-all flag that consents on behalf of every git-managed source in
# one gesture, and a --clone-none flag that declines on behalf of every
# git-managed source in one gesture, present at both the one-time bootstrap
# scaffold and at DISCOVER's per-run pre-flight, with the existing
# per-source "[y/N]" prompt as the unconditional default when neither flag
# is given.
#
# THE INVARIANTS.
#   - At bootstrap, --clone-all runs the consented-clone path for every
#     git-managed source with no prompt; --clone-none skips the cache seed
#     for every git-managed source with no prompt; with neither flag the
#     existing per-source [y/N] prompt fires exactly as it does today,
#     wrap-normalized byte-for-byte unchanged.
#   - At DISCOVER's cache-miss pre-flight, the same two flags carry the
#     same meaning, scoped to git-managed sources only: --clone-none is the
#     session-sticky decline for every in-scope git-managed source, so no
#     cache-miss prompt fires for any of them during the run. The web-doc
#     branch of that same pre-flight step is untouched by either flag —
#     its cache-miss prompt and consent handling stay exactly as they are
#     today.
#   - The two flags are mutually exclusive: giving both together halts
#     before any clone or prompt runs, with an error that names both
#     flags.
#   - No clone ever runs without either a per-source "y" or --clone-all;
#     both reference files say so, and the README's consent sentence names
#     --clone-all as a second opt-in alongside the per-source prompt,
#     without weakening its existing "(default: no)" clause.
#   - The flag names appear nowhere else in the shipped plugin surface or
#     the project README — not in either navigator SKILL.md, not in any
#     other reference.
#
# THIS IS A PROSE-ONLY SKILL PAIR. engine-bootstrap and discover run as a
# model reading SKILL.md and its references, not as a program a fixture
# can invoke directly — so most of this oracle greps the two reference
# files for the documented contract, wrap-normalized (collapse newlines
# and whitespace runs before matching; these are hand-wrapped Markdown
# files, and a naive line-oriented grep silently misses a phrase that
# happens to cross a line break). The one piece that IS executable is the
# mutual-exclusion guard: wherever a reference carries it as a fenced
# shell block delimited by the sentinel pair
#
#   <!-- doctrine:clone-consent-guard:start -->
#   ```bash
#   ...
#   ```
#   <!-- doctrine:clone-consent-guard:end -->
#
# (exactly one such pair per file — the convention is invented here, since
# nothing upstream pins it yet), this runner extracts the block and runs
# it as `bash <extracted-block> <flags...>` — the flags exactly as they
# would appear on the intake invocation, received as the block's own
# "$@", no angle-bracket placeholder substitution involved (unlike the
# per-source clone recipes elsewhere in these files, a mutual-exclusion
# guard has nothing per-source to substitute). Accepted input (either flag
# alone, or neither) is expected to exit 0; both together is expected to
# exit 1 with an stderr message naming both flags. Right now neither flag,
# nor any fenced guard block, exists in either reference, so every
# extraction below comes back empty and every assertion that depends on
# the new behavior fails for that reason — the behavior is absent, not
# the harness broken.
#
# PRESERVATION CHECKS RUN UNGATED. Unlike a check for brand-new text, "the
# existing prompt still fires when neither flag is given" is already true
# today, before any edit — so every preservation assertion below runs
# directly against the current wording and is expected to PASS right now.
# It keeps passing after the flags land only if that implementation
# leaves the original prompt copy alone.
#
# -e is intentionally omitted (see set -uo pipefail below): every
# assertion runs and reports, not abort at the first failing one. Every
# tmpdir this file creates is removed on exit.

set -uo pipefail

# ---------------------------------------------------------------------------
# Setup: locate the repo, load the surfaces under test, prepare a tmpdir.
# ---------------------------------------------------------------------------

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
PLUGIN_ROOT="$REPO_ROOT/plugin/skill-engine"

CACHE_SEEDING_REL="skills/engine-bootstrap/references/cache-seeding.md"
CACHE_AND_CLONE_REL="skills/discover/references/cache-and-clone.md"
CACHE_SEEDING="$PLUGIN_ROOT/$CACHE_SEEDING_REL"
CACHE_AND_CLONE="$PLUGIN_ROOT/$CACHE_AND_CLONE_REL"
README="$REPO_ROOT/README.md"
BOOTSTRAP_SKILL="$PLUGIN_ROOT/skills/engine-bootstrap/SKILL.md"
DISCOVER_SKILL="$PLUGIN_ROOT/skills/discover/SKILL.md"

for f in "$CACHE_SEEDING" "$CACHE_AND_CLONE" "$README" "$BOOTSTRAP_SKILL" "$DISCOVER_SKILL"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: expected surface is missing entirely: $f" >&2
    exit 69
  fi
done

WORK="$(mktemp -d -t skill-engine-clone-consent-flags.XXXXXX)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

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

# norm — collapse every run of whitespace, newlines included, to one
# space, then trim the ends. Every multi-word phrase assertion below runs
# against normalized text so a hand-wrapped line break can never hide a
# phrase from a naive line-oriented grep.
norm() { tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'; }

norm_str() { printf '%s' "$1" | norm; }

# near <text> <anchor-ere> <needle-ere> <window> — true when <needle>
# occurs within <window> characters of some occurrence of <anchor> in
# <text>. 200, not more: some grep implementations reject an interval
# bound above 255, and the window applies on both sides of the anchor.
near() {
  local text="$1" anchor="$2" needle="$3" window="$4"
  printf '%s' "$text" \
    | grep -oiE ".{0,${window}}${anchor}.{0,${window}}" \
    | grep -qiE -- "$needle"
}

# near_all <text> <anchor-ere> <window> <needle-ere>... — true when EVERY
# given needle occurs somewhere within <window> characters of some
# occurrence of <anchor> (not necessarily the same occurrence, and not
# necessarily all in one needle's own window — tolerant on purpose, since
# the exact phrasing a future edit lands on isn't known yet).
near_all() {
  local text="$1" anchor="$2" window="$3"
  shift 3
  local needle
  for needle in "$@"; do
    near "$text" "$anchor" "$needle" "$window" || return 1
  done
  return 0
}

assert_str() {
  local label="$1" text="$2" lit="$3"
  if printf '%s' "$text" | grep -qF -- "$lit"; then
    pass "$label"
  else
    fail "$label" "string not found: $lit"
  fi
}

# ---------------------------------------------------------------------------
# Locate the sections under test within each reference, and the README's
# consent-sentence bullet, by heading/anchor rather than a hardcoded line
# number — the exact line a heading sits on can shift as prose is edited.
# ---------------------------------------------------------------------------

line_of() {
  local file="$1" pat="$2"
  grep -n -E -- "$pat" "$file" | head -n1 | cut -d: -f1
}

BOOTSTRAP_STEP_3_5_START="$(line_of "$CACHE_SEEDING" '^## Step 3\.5')"
BOOTSTRAP_STEP_3_6_START="$(line_of "$CACHE_SEEDING" '^## Step 3\.6')"
BOOTSTRAP_SOURCE_MAT_START="$(line_of "$CACHE_SEEDING" '^## Source materialization')"
if [ -z "$BOOTSTRAP_STEP_3_5_START" ] || [ -z "$BOOTSTRAP_STEP_3_6_START" ] || [ -z "$BOOTSTRAP_SOURCE_MAT_START" ]; then
  echo "ERROR: cannot locate the Step 3.5 / Step 3.6 / Source materialization headings in $CACHE_SEEDING" >&2
  exit 69
fi
RAW_BOOTSTRAP_STEP35="$(sed -n "${BOOTSTRAP_STEP_3_5_START},$((BOOTSTRAP_STEP_3_6_START - 1))p" "$CACHE_SEEDING")"
RAW_BOOTSTRAP_SOURCE_MAT="$(sed -n "${BOOTSTRAP_SOURCE_MAT_START},\$p" "$CACHE_SEEDING")"
NORM_BOOTSTRAP_STEP35="$(norm_str "$RAW_BOOTSTRAP_STEP35")"
NORM_BOOTSTRAP_SOURCE_MAT="$(norm_str "$RAW_BOOTSTRAP_SOURCE_MAT")"

DISCOVER_STEP6_START="$(line_of "$CACHE_AND_CLONE" '^6\. \*\*Cache-miss offer')"
DISCOVER_STEP7_START="$(line_of "$CACHE_AND_CLONE" '^7\. \*\*Pre-flight inventory')"
DISCOVER_SOURCE_MAT_START="$(line_of "$CACHE_AND_CLONE" '^## Source materialization')"
DISCOVER_LIFECYCLE_START="$(line_of "$CACHE_AND_CLONE" '^## Lifecycle handling')"
if [ -z "$DISCOVER_STEP6_START" ] || [ -z "$DISCOVER_STEP7_START" ] || [ -z "$DISCOVER_SOURCE_MAT_START" ] || [ -z "$DISCOVER_LIFECYCLE_START" ]; then
  echo "ERROR: cannot locate the pre-flight step 6/7, or Source materialization/Lifecycle handling headings in $CACHE_AND_CLONE" >&2
  exit 69
fi
RAW_DISCOVER_STEP6="$(sed -n "${DISCOVER_STEP6_START},$((DISCOVER_STEP7_START - 1))p" "$CACHE_AND_CLONE")"
RAW_DISCOVER_SOURCE_MAT="$(sed -n "${DISCOVER_SOURCE_MAT_START},$((DISCOVER_LIFECYCLE_START - 1))p" "$CACHE_AND_CLONE")"
NORM_DISCOVER_STEP6="$(norm_str "$RAW_DISCOVER_STEP6")"
NORM_DISCOVER_SOURCE_MAT="$(norm_str "$RAW_DISCOVER_SOURCE_MAT")"

README_CONSENT_LINE="$(line_of "$README" 'per-source opt-in prompt')"
if [ -z "$README_CONSENT_LINE" ]; then
  echo "ERROR: cannot locate the per-source opt-in consent sentence in $README" >&2
  exit 69
fi
RAW_README_CONSENT="$(sed -n "$((README_CONSENT_LINE - 2)),$((README_CONSENT_LINE + 2))p" "$README")"
NORM_README_CONSENT="$(norm_str "$RAW_README_CONSENT")"

# Frozen, wrap-normalized copies of the three prompts the flags must
# either suppress (git-managed) or leave alone (web-doc), captured now so
# a later edit can be checked against exactly this wording, not against
# whatever the file happens to contain when the check runs.
BOOTSTRAP_PROMPT_FROZEN='Pre-clone <source_id> from <url> into ~/.cache/skill-engine/git-managed/? This speeds up later DISCOVER runs. Skip if unsure. [y/N]'
DISCOVER_GIT_MANAGED_PROMPT_FROZEN='No local cache for <source_id>. Pre-clone from <url> into ~/.cache/skill-engine/git-managed/? This speeds up this DISCOVER run and future REFRESH cycles. Skip if unsure. [y/N]'
DISCOVER_WEBDOC_PROMPT_FROZEN='No local snapshot for <source_id>. Crawl <url> (<N> pages from sitemap) into ~/.cache/skill-engine/web-doc/? This speeds up this DISCOVER run and future REFRESH cycles. Skip if unsure. [y/N]'

NO_PROMPT_REGEX='(no prompt|without (a |the )?prompt|skips? (the |any )?prompt|does(n.t| not) prompt)'

# ---------------------------------------------------------------------------
# Bootstrap Step 3.5 — --clone-all / --clone-none / the unchanged default.
# ---------------------------------------------------------------------------

banner "bootstrap Step 3.5: --clone-all"

assert_str "bootstrap_clone_all_documented" "$NORM_BOOTSTRAP_STEP35" '--clone-all'

if near_all "$NORM_BOOTSTRAP_STEP35" '--clone-all' 200 "$NO_PROMPT_REGEX" 'every'; then
  pass "bootstrap_clone_all_runs_every_source_no_prompt"
else
  fail "bootstrap_clone_all_runs_every_source_no_prompt" \
    "expected --clone-all documented near both a no-prompt phrase and 'every' (every git-managed source, unconditionally consented)"
fi

assert_str "bootstrap_default_prompt_preserved_absent_clone_all" "$NORM_BOOTSTRAP_STEP35" "$BOOTSTRAP_PROMPT_FROZEN"

banner "bootstrap Step 3.5: --clone-none"

assert_str "bootstrap_clone_none_documented" "$NORM_BOOTSTRAP_STEP35" '--clone-none'

if near_all "$NORM_BOOTSTRAP_STEP35" '--clone-none' 200 "$NO_PROMPT_REGEX" 'every'; then
  pass "bootstrap_clone_none_skips_every_source_no_prompt"
else
  fail "bootstrap_clone_none_skips_every_source_no_prompt" \
    "expected --clone-none documented near both a no-prompt phrase and 'every' (skip the seed for every git-managed source, unconditionally declined)"
fi

assert_str "bootstrap_default_prompt_preserved_absent_clone_none" "$NORM_BOOTSTRAP_STEP35" "$BOOTSTRAP_PROMPT_FROZEN"

banner "bootstrap: no clone without a per-source y or --clone-all"

assert_str "bootstrap_consent_framing_names_clone_all" "$NORM_BOOTSTRAP_SOURCE_MAT" '--clone-all'

# ---------------------------------------------------------------------------
# DISCOVER pre-flight step 6 — same two flags, scoped to git-managed only.
# ---------------------------------------------------------------------------

banner "discover pre-flight step 6: --clone-all (git-managed only)"

assert_str "discover_clone_all_documented" "$NORM_DISCOVER_STEP6" '--clone-all'

if near_all "$NORM_DISCOVER_STEP6" '--clone-all' 200 "$NO_PROMPT_REGEX" 'git-managed'; then
  pass "discover_clone_all_no_prompt_git_managed_scope"
else
  fail "discover_clone_all_no_prompt_git_managed_scope" \
    "expected --clone-all documented near both a no-prompt phrase and 'git-managed' (scoped to the git-managed branch only)"
fi

assert_str "discover_default_git_managed_prompt_preserved_absent_clone_all" "$NORM_DISCOVER_STEP6" "$DISCOVER_GIT_MANAGED_PROMPT_FROZEN"

banner "discover pre-flight step 6: --clone-none (git-managed only)"

assert_str "discover_clone_none_documented" "$NORM_DISCOVER_STEP6" '--clone-none'

if near_all "$NORM_DISCOVER_STEP6" '--clone-none' 200 '(session.sticky|sticky decline)' 'git-managed'; then
  pass "discover_clone_none_session_sticky_git_managed_scope"
else
  fail "discover_clone_none_session_sticky_git_managed_scope" \
    "expected --clone-none documented near both a session-sticky-decline phrase and 'git-managed' (scoped to the git-managed branch only)"
fi

assert_str "discover_default_git_managed_prompt_preserved_absent_clone_none" "$NORM_DISCOVER_STEP6" "$DISCOVER_GIT_MANAGED_PROMPT_FROZEN"

banner "discover pre-flight step 6: web-doc branch unaffected"

assert_str "discover_webdoc_prompt_unaffected_preserved" "$NORM_DISCOVER_STEP6" "$DISCOVER_WEBDOC_PROMPT_FROZEN"

banner "discover: no clone without a per-source y or --clone-all"

assert_str "discover_consent_framing_names_clone_all" "$NORM_DISCOVER_SOURCE_MAT" '--clone-all'

# ---------------------------------------------------------------------------
# The mutual-exclusion guard: extracted from a sentinel-delimited fenced
# block (see header comment for the convention) and actually executed
# against argv fixtures.
# ---------------------------------------------------------------------------

banner "mutual exclusion: guard block extraction and execution"

GUARD_SENTINEL_START='<!-- doctrine:clone-consent-guard:start -->'
GUARD_SENTINEL_END='<!-- doctrine:clone-consent-guard:end -->'

# extract_guard_block <label> <file> — requires exactly one
# GUARD_SENTINEL_START/END pair in <file>, in that order. On success,
# writes the block body (fence delimiters stripped, syntax-checked with
# `bash -n`) to a fresh tmpfile and exposes its path via EXTRACTED_GUARD;
# on any other shape (zero pairs, more than one, out of order, empty body,
# invalid shell) reports FAIL under <label> and returns non-zero — a hard,
# clearly-labeled failure rather than a silent skip.
EXTRACTED_GUARD=""
extract_guard_block() {
  local label="$1" file="$2"
  EXTRACTED_GUARD=""
  local s_count e_count sl el
  s_count="$(grep -c -F -- "$GUARD_SENTINEL_START" "$file")"
  e_count="$(grep -c -F -- "$GUARD_SENTINEL_END" "$file")"

  if [ "$s_count" -eq 0 ] && [ "$e_count" -eq 0 ]; then
    fail "$label" "no ${GUARD_SENTINEL_START} / ${GUARD_SENTINEL_END} pair found in $file"
    return 1
  fi
  if [ "$s_count" -ne 1 ] || [ "$e_count" -ne 1 ]; then
    fail "$label" "$s_count start / $e_count end sentinels in $file (need exactly one of each)"
    return 1
  fi

  sl="$(grep -n -F -- "$GUARD_SENTINEL_START" "$file" | head -n1 | cut -d: -f1)"
  el="$(grep -n -F -- "$GUARD_SENTINEL_END" "$file" | head -n1 | cut -d: -f1)"
  if [ "$sl" -ge "$el" ]; then
    fail "$label" "end sentinel is not after start sentinel in $file"
    return 1
  fi

  local body
  body="$(sed -n "$((sl + 1)),$((el - 1))p" "$file" | grep -vE '^[[:space:]]*```')"
  if [ -z "${body//[$'\t\r\n ']/}" ]; then
    fail "$label" "sentinel pair found in $file but the block between them is empty"
    return 1
  fi

  local outfile
  outfile="$(mktemp "$WORK/guard-block-XXXXXX")"
  printf '%s\n' "$body" > "$outfile"
  local syntax_err
  syntax_err="$(mktemp "$WORK/guard-syntax-err-XXXXXX")"
  if ! bash -n "$outfile" 2>"$syntax_err"; then
    fail "$label" "extracted block from $file is not valid shell:" "$(cat "$syntax_err")"
    return 1
  fi

  pass "$label"
  EXTRACTED_GUARD="$outfile"
  return 0
}

# run_guard_block <block-file> <arg>... — runs the extracted guard as
# `bash <block-file> <arg>...`, so the fixture's flags land in the block's
# own "$@" exactly as they would on the real intake invocation. Sets
# GUARD_RC, GUARD_OUT (stdout), and GUARD_ERR (stderr) on return.
GUARD_RC=0
GUARD_OUT=""
GUARD_ERR=""
run_guard_block() {
  local block_file="$1"
  shift
  local outfile errfile
  outfile="$(mktemp "$WORK/guard-run-out-XXXXXX")"
  errfile="$(mktemp "$WORK/guard-run-err-XXXXXX")"
  bash "$block_file" "$@" >"$outfile" 2>"$errfile"
  GUARD_RC=$?
  GUARD_OUT="$(cat "$outfile")"
  GUARD_ERR="$(cat "$errfile")"
}

# assert_guard_fixture <label> <block-file> <expect-rc> <expect-both-named:0|1> <arg>...
assert_guard_fixture() {
  local label="$1" block_file="$2" expect_rc="$3" expect_both_named="$4"
  shift 4
  run_guard_block "$block_file" "$@"
  if [ "$GUARD_RC" -ne "$expect_rc" ]; then
    fail "$label" "expected exit $expect_rc, got $GUARD_RC" "stdout: $GUARD_OUT" "stderr: $GUARD_ERR"
    return
  fi
  if [ "$expect_both_named" -eq 1 ]; then
    if printf '%s' "$GUARD_ERR" | grep -qF -- '--clone-all' && printf '%s' "$GUARD_ERR" | grep -qF -- '--clone-none'; then
      pass "$label"
    else
      fail "$label" "exit code correct ($GUARD_RC) but stderr does not name both flags" "stderr: $GUARD_ERR"
    fi
  else
    pass "$label"
  fi
}

run_guard_fixture_set() {
  local prefix="$1" block_file="$2" reason="$3"
  if [ -z "$block_file" ]; then
    fail "${prefix}_clone_all_only_exit0" "$reason"
    fail "${prefix}_clone_none_only_exit0" "$reason"
    fail "${prefix}_neither_exit0" "$reason"
    fail "${prefix}_both_exit1_names_both_flags" "$reason"
    return
  fi
  assert_guard_fixture "${prefix}_clone_all_only_exit0" "$block_file" 0 0 --clone-all
  assert_guard_fixture "${prefix}_clone_none_only_exit0" "$block_file" 0 0 --clone-none
  assert_guard_fixture "${prefix}_neither_exit0" "$block_file" 0 0
  assert_guard_fixture "${prefix}_both_exit1_names_both_flags" "$block_file" 1 1 --clone-all --clone-none
}

NO_GUARD_REASON="cannot evaluate — no mutual-exclusion guard block found (see the extraction result above)"

BOOTSTRAP_GUARD=""
if extract_guard_block "mutual_exclusion_guard_bootstrap_present" "$CACHE_SEEDING"; then
  BOOTSTRAP_GUARD="$EXTRACTED_GUARD"
fi
run_guard_fixture_set "mutual_exclusion_guard_bootstrap" "$BOOTSTRAP_GUARD" "$NO_GUARD_REASON"

DISCOVER_GUARD=""
if extract_guard_block "mutual_exclusion_guard_discover_present" "$CACHE_AND_CLONE"; then
  DISCOVER_GUARD="$EXTRACTED_GUARD"
fi
run_guard_fixture_set "mutual_exclusion_guard_discover" "$DISCOVER_GUARD" "$NO_GUARD_REASON"

# ---------------------------------------------------------------------------
# The README consent sentence.
# ---------------------------------------------------------------------------

banner "README consent sentence"

assert_str "readme_default_no_clause_preserved" "$NORM_README_CONSENT" '(default: no)'

if near_all "$NORM_README_CONSENT" 'opt-in prompt' 150 '--clone-all' '\(default: no\)'; then
  pass "readme_consent_names_clone_all_second_optin"
else
  fail "readme_consent_names_clone_all_second_optin" \
    "expected --clone-all named as a second opt-in near the per-source opt-in prompt sentence, with '(default: no)' kept intact"
fi

# ---------------------------------------------------------------------------
# The flags appear nowhere outside the two references and the README
# consent sentence.
#
# This section used to also pin both navigator SKILL.md files
# byte-identical to their exact chunk-02-era SHA256 — a check that only
# ever meant "this chunk's own diff didn't touch these files," not "these
# files must never change again." As an absolute, un-expiring pin it broke
# the first time an unrelated, later, legitimate chunk edited
# engine-bootstrap/SKILL.md (chunk 03-activation-guard-slug, 2026-09-07),
# which the flag-scoping check below does not: the property that actually
# needs to survive future chunks — these two flags never leaking into a
# navigator — is exactly what it asserts. Retired rather than re-baselined,
# maintainer-approved, so the next legitimate navigator edit doesn't hit
# the same wall.
# ---------------------------------------------------------------------------

banner "flags scoped to the declared surfaces"

# The oracle's own test directory is excluded by path (not by grep's
# --exclude-dir, whose directory-matching semantics vary too much across
# grep implementations to trust here) — its own use of the flag names in
# comments and fixtures is not a documentation violation, and without this
# exclusion the check would find its own source and fail unconditionally.
# Built once via `find` into an explicit file list, then grepped as plain
# arguments — never recursively — so no implementation's own directory-
# exclusion quirks are in the loop at all.
SCOPE_SCAN_LIST="$(mktemp "$WORK/flag-scope-scan-list-XXXXXX")"
find "$PLUGIN_ROOT" -type f -not -path "*/tests/$(basename "$SCRIPT_DIR")/*" > "$SCOPE_SCAN_LIST"
printf '%s\n' "$README" >> "$SCOPE_SCAN_LIST"

ALLOWED_FLAG_FILES=("$CACHE_SEEDING" "$CACHE_AND_CLONE" "$README")

flag_scope_check() {
  local label="$1" flag="$2"
  local violation=""
  local scan_file allowed ok
  while IFS= read -r scan_file; do
    [ -z "$scan_file" ] && continue
    grep -qF -- "$flag" "$scan_file" 2>/dev/null || continue
    ok=0
    for allowed in "${ALLOWED_FLAG_FILES[@]}"; do
      if [ "$scan_file" = "$allowed" ]; then
        ok=1
        break
      fi
    done
    if [ "$ok" -eq 0 ]; then
      violation="${violation}${scan_file}\n"
    fi
  done < "$SCOPE_SCAN_LIST"

  if [ -z "$violation" ]; then
    pass "$label"
  else
    fail "$label" "found outside the declared surfaces:" "$(printf '%b' "$violation")"
  fi
}

flag_scope_check "flags_documented_only_in_scoped_surfaces_clone_all" '--clone-all'
flag_scope_check "flags_documented_only_in_scoped_surfaces_clone_none" '--clone-none'

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------

banner "summary"
printf 'passed: %d   failed: %d\n' "$pass_count" "$fail_count"

if [ "$fail_count" -gt 0 ]; then
  exit 1
fi
exit 0
