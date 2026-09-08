#!/usr/bin/env bash
# Prose-and-executed oracle for an opt-in reachability probe at bootstrap
# intake: a `--probe` flag that runs one read-only `git ls-remote` per
# intaken git-managed source before anything is stamped, prints one table
# (reachable/unreachable, first error line), and asks once whether to
# continue when any source is unreachable. Absent the flag, intake makes
# no network call, exactly as today.
#
# THE INVARIANTS.
#   - The per-source reachability check is a real, executable shell
#     recipe reusing the engine's existing read-only `git ls-remote` form
#     (no other git verb) — never a description of what a future
#     implementation might do.
#   - A row for an unreachable source always carries non-blank detail:
#     the first line of git's own error text when git produced one, and a
#     stated "no error text was returned" fallback for the documented
#     quirk where a reachable repository probed against a nonexistent
#     branch exits with nothing on either stream.
#   - The table is described before the continue/abort question, in
#     whatever new section documents this; declining stamps nothing,
#     consenting stamps every source and excludes unreachable ones from
#     any `--clone-all` seed — and that exclusion is a real gate in
#     `cache-seeding.md` Step 3.5, not merely claimed in prose elsewhere.
#   - Without `--probe`, the no-network default survives: SKILL.md's two
#     "does NOT" bullets, its "Offer to seed local cache" paragraph, and
#     cache-seeding.md's own "only network operation" sentence all still
#     hold for the no-flag case, AND each names `--probe` as the opt-in
#     exception — never only one half of that pair.
#   - Preservation: the existing `--clone-all`/`--clone-none`
#     mutual-exclusion guard in cache-seeding.md and the existing
#     activation-guard directory-detection block in intake-and-detection.md
#     stay present, independently extractable, and functionally intact;
#     the new section documenting the probe does not bleed into either.
#   - `SKILL.md` stays at or under the router-sized byte ceiling, and this
#     plugin's own doctrine checks (including the git-verb allow-list) see
#     no new violation in any of the three touched files.
#
# THIS IS A PROSE-ONLY SKILL. engine-bootstrap runs as a model reading
# SKILL.md and its references, not a program a fixture can invoke
# end-to-end — so most of this oracle greps the three reference files for
# the documented contract, wrap-normalized (collapse newlines and
# whitespace runs before matching; these are hand-wrapped Markdown files,
# and a naive line-oriented grep silently misses a phrase that happens to
# cross a line break). The one piece that IS executable is the per-source
# reachability check itself: wherever the intake reference carries it as a
# fenced shell block delimited by the sentinel pair
#
#   <!-- doctrine:reachability-probe:start -->
#   ```bash
#   ...
#   ```
#   <!-- doctrine:reachability-probe:end -->
#
# (exactly one such pair — the convention, including the block's calling
# contract, is invented here, since nothing upstream pins it yet: the
# block is invoked as `bash <extracted-block> <url-or-path> <ref>`, `ref`
# defaulting to `HEAD` when empty, and it must print exactly one line to
# stdout, tab-separated, whose first field is the literal `reachable` or
# `unreachable` and whose third field — present only on `unreachable` — is
# the non-blank detail: git's first error line, or the stated no-error-text
# fallback). Nothing upstream produces this sentinel pair yet, so every
# extraction below comes back empty and every assertion that depends on it
# fails for that reason — the behavior is absent, not the harness broken.
#
# A NOTE FOR THE IMPLEMENTER: the documented git
# quirk this oracle exercises (fixture c below) is a reachable repository
# probed against a nonexistent branch — empirically this exits 0 with
# nothing on either stream, not non-zero. Classify unreachable on
# `rc != 0 OR stdout is empty`, never on exit code alone.
#
# PRESERVATION CHECKS RUN UNGATED — the same convention the sibling
# oracles in this directory use. "The clone-consent guard still enforces
# mutual exclusion," "the activation guard still detects a same-slug
# collision," and "SKILL.md is still at or under the byte ceiling" are all
# already true today, before the probe lands, so those assertions are
# expected to PASS on this very run. They keep passing afterward only if
# the new probe section is added without disturbing either existing
# surface — which is exactly the regression this oracle exists to catch.
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

SKILL_MD="$PLUGIN_ROOT/skills/engine-bootstrap/SKILL.md"
INTAKE_MD="$PLUGIN_ROOT/skills/engine-bootstrap/references/intake-and-detection.md"
CACHE_SEEDING_MD="$PLUGIN_ROOT/skills/engine-bootstrap/references/cache-seeding.md"
DOCTRINE_SCRIPT="$PLUGIN_ROOT/tests/doctrine.sh"
GIT_VERB_SCAN="$PLUGIN_ROOT/tests/lib/git_verb_scan.sh"

for f in "$SKILL_MD" "$INTAKE_MD" "$CACHE_SEEDING_MD" "$DOCTRINE_SCRIPT" "$GIT_VERB_SCAN"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: expected surface is missing entirely: $f" >&2
    exit 69
  fi
done

WORK="$(mktemp -d -t skill-engine-bootstrap-probe.XXXXXX)"
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

line_of() {
  local file="$1" pat="$2"
  grep -n -E -- "$pat" "$file" | head -n1 | cut -d: -f1
}

assert_str() {
  local label="$1" text="$2" lit="$3"
  if printf '%s' "$text" | grep -qF -- "$lit"; then
    pass "$label"
  else
    fail "$label" "string not found: $lit"
  fi
}

# near <text> <anchor-ere> <needle-ere> <window> — true when <needle>
# occurs within <window> characters of some occurrence of <anchor> in
# <text>. 200-ish, not more: some grep implementations reject an interval
# bound above 255, and the window applies on both sides of the anchor.
near() {
  local text="$1" anchor="$2" needle="$3" window="$4"
  printf '%s' "$text" \
    | grep -oiE ".{0,${window}}${anchor}.{0,${window}}" \
    | grep -qiE -- "$needle"
}

# near_all <text> <anchor-ere> <window> <needle-ere>... — true when EVERY
# given needle occurs somewhere within <window> characters of some
# occurrence of <anchor> (not necessarily the same occurrence).
near_all() {
  local text="$1" anchor="$2" window="$3"
  shift 3
  local needle
  for needle in "$@"; do
    near "$text" "$anchor" "$needle" "$window" || return 1
  done
  return 0
}

# assert_near <label> <text> <anchor-ere> <needle-ere> <window> — like
# near(), but distinguishes an absent anchor from a present anchor whose
# needle isn't nearby, so a first failing run reads as "the new content
# isn't here yet" rather than an ambiguous "framing not found."
assert_near() {
  local label="$1" text="$2" anchor="$3" needle="$4" window="$5"
  if ! printf '%s' "$text" | grep -qiE -- "$anchor"; then
    fail "$label" "anchor not found in text: $anchor"
    return
  fi
  if near "$text" "$anchor" "$needle" "$window"; then
    pass "$label"
  else
    fail "$label" "anchor found but needle not within ${window} chars: $needle"
  fi
}

assert_near_all() {
  local label="$1" text="$2" anchor="$3" window="$4"
  shift 4
  if ! printf '%s' "$text" | grep -qiE -- "$anchor"; then
    fail "$label" "anchor not found in text: $anchor"
    return
  fi
  if near_all "$text" "$anchor" "$window" "$@"; then
    pass "$label"
  else
    fail "$label" "anchor found but not every needle was within ${window} chars: $*"
  fi
}

# ---------------------------------------------------------------------------
# Sentinel-block extraction, generic across the three sentinel pairs this
# file cares about (its own new one, plus the two pre-existing ones it
# must not disturb).
# ---------------------------------------------------------------------------

# extract_sentinel_block <label> <file> <start-marker> <end-marker> —
# requires exactly one start/end pair, in order, non-empty, valid shell
# (`bash -n`). On success, writes the block body to a fresh tmpfile and
# sets EXTRACTED_BLOCK / EXTRACTED_BLOCK_START_LINE / _END_LINE; on any
# other shape reports FAIL under <label> and returns non-zero.
EXTRACTED_BLOCK=""
EXTRACTED_BLOCK_START_LINE=0
EXTRACTED_BLOCK_END_LINE=0
extract_sentinel_block() {
  local label="$1" file="$2" start_marker="$3" end_marker="$4"
  EXTRACTED_BLOCK=""
  local s_count e_count sl el
  s_count="$(grep -c -F -- "$start_marker" "$file")"
  e_count="$(grep -c -F -- "$end_marker" "$file")"

  if [ "$s_count" -eq 0 ] && [ "$e_count" -eq 0 ]; then
    fail "$label" "no ${start_marker} / ${end_marker} pair found in $file"
    return 1
  fi
  if [ "$s_count" -ne 1 ] || [ "$e_count" -ne 1 ]; then
    fail "$label" "$s_count start / $e_count end sentinels in $file (need exactly one of each)"
    return 1
  fi

  sl="$(grep -n -F -- "$start_marker" "$file" | head -n1 | cut -d: -f1)"
  el="$(grep -n -F -- "$end_marker" "$file" | head -n1 | cut -d: -f1)"
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

  local outfile syntax_err
  outfile="$(mktemp "$WORK/block-XXXXXX")"
  printf '%s\n' "$body" >"$outfile"
  syntax_err="$(mktemp "$WORK/block-syntax-err-XXXXXX")"
  if ! bash -n "$outfile" 2>"$syntax_err"; then
    fail "$label" "extracted block from $file is not valid shell:" "$(cat "$syntax_err")"
    return 1
  fi

  pass "$label"
  EXTRACTED_BLOCK="$outfile"
  EXTRACTED_BLOCK_START_LINE="$sl"
  EXTRACTED_BLOCK_END_LINE="$el"
  return 0
}

# run_block <block-file> <arg>... — runs the extracted block as
# `bash <block-file> <arg>...`. Sets BLOCK_RC, BLOCK_OUT, BLOCK_ERR.
BLOCK_RC=0
BLOCK_OUT=""
BLOCK_ERR=""
run_block() {
  local block_file="$1"
  shift
  local outfile errfile
  outfile="$(mktemp "$WORK/run-out-XXXXXX")"
  errfile="$(mktemp "$WORK/run-err-XXXXXX")"
  bash "$block_file" "$@" >"$outfile" 2>"$errfile"
  BLOCK_RC=$?
  BLOCK_OUT="$(cat "$outfile")"
  BLOCK_ERR="$(cat "$errfile")"
}

# heading_before/heading_after <file> <line> — the nearest ATX heading
# line at or before / strictly after <line>, or empty when none exists.
# Used to locate "whatever new section documents the probe" by where its
# own sentinel block actually lives, rather than by guessing the heading
# text a future edit will choose.
heading_before() {
  local file="$1" ln="$2"
  awk -v ln="$ln" '/^#+ / { if (NR <= ln) h = NR } END { if (h) print h }' "$file"
}
heading_after() {
  local file="$1" ln="$2"
  awk -v ln="$ln" '/^#+ / { if (NR > ln && !found) { print NR; found = 1 } }' "$file"
}

# section_text <file> <start-line> <end-line-or-empty-for-eof>
section_text() {
  local file="$1" start="$2" end="$3"
  if [ -n "$end" ]; then
    sed -n "${start},$((end - 1))p" "$file"
  else
    sed -n "${start},\$p" "$file"
  fi
}

# new_repo <dir> — a throwaway local repository with one commit, used
# directly as `git ls-remote`'s repository argument the same way a real
# remote URL would be. Fully offline.
new_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email "skill-engine-tests@example.com"
  git -C "$dir" config user.name "skill-engine tests"
  printf 'v1\n' >"$dir/content.txt"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "first"
}

# ---------------------------------------------------------------------------
# Read and normalize the surfaces under test.
# ---------------------------------------------------------------------------

RAW_INTAKE_MD="$(cat "$INTAKE_MD")"
NORM_INTAKE_MD="$(norm_str "$RAW_INTAKE_MD")"

# Frozen, wrap-normalized copies of today's wording, used by the
# ungated preservation checks further down.
BOOTSTRAP_PROMPT_FROZEN='Pre-clone <source_id> from <url> into ~/.cache/skill-engine/git-managed/? This speeds up later DISCOVER runs. Skip if unsure. [y/N]'
FROZEN_CORRUPTED_MARKER='The condition is files-present, NOT a parseable `research/.research-state.json`: a corrupted state marker must not bypass this guard, because the directory may still hold a curated `SKILL.md` and a populated `research/source-paths.json` that stamping would overwrite.'

# The sentinel pairs this file cares about.
PROBE_SENTINEL_START='<!-- doctrine:reachability-probe:start -->'
PROBE_SENTINEL_END='<!-- doctrine:reachability-probe:end -->'
GUARD_FIND_SENTINEL_START='<!-- doctrine:activation-guard-find:start -->'
GUARD_FIND_SENTINEL_END='<!-- doctrine:activation-guard-find:end -->'
CLONE_GUARD_SENTINEL_START='<!-- doctrine:clone-consent-guard:start -->'
CLONE_GUARD_SENTINEL_END='<!-- doctrine:clone-consent-guard:end -->'

# ---------------------------------------------------------------------------
# The probe recipe: extraction, syntax, and its own new documentation
# section (located by where the sentinel block lives, not by heading text).
# ---------------------------------------------------------------------------

banner "reachability probe recipe: extraction and syntax"

INTAKE_PROBE_BLOCK=""
if extract_sentinel_block "probe_recipe_block_present_and_valid_shell" "$INTAKE_MD" \
  "$PROBE_SENTINEL_START" "$PROBE_SENTINEL_END"; then
  INTAKE_PROBE_BLOCK="$EXTRACTED_BLOCK"
  PROBE_BLOCK_START_LINE="$EXTRACTED_BLOCK_START_LINE"
  PROBE_BLOCK_END_LINE="$EXTRACTED_BLOCK_END_LINE"
else
  PROBE_BLOCK_START_LINE=0
  PROBE_BLOCK_END_LINE=0
fi

NO_PROBE_BLOCK_REASON="cannot evaluate — no reachability-probe recipe block found (see the extraction result above)"

# The section documenting the probe: whatever heading pair straddles the
# sentinel block. Empty when the block itself wasn't found — every
# assertion against it below fails for that same underlying reason.
PROBE_SECTION_NORM=""
if [ -n "$INTAKE_PROBE_BLOCK" ]; then
  sec_start="$(heading_before "$INTAKE_MD" "$PROBE_BLOCK_START_LINE")"
  sec_end="$(heading_after "$INTAKE_MD" "$PROBE_BLOCK_END_LINE")"
  if [ -n "$sec_start" ]; then
    PROBE_SECTION_NORM="$(norm_str "$(section_text "$INTAKE_MD" "$sec_start" "$sec_end")")"
  fi
fi

# ---------------------------------------------------------------------------
# The probe recipe: executed against three fixtures, plus the strong-form
# no-other-git-verb check.
# ---------------------------------------------------------------------------

banner "reachability probe recipe: reachable / unreachable / no-error-text fallback"

NO_ERROR_TEXT_REGEX='no.*error.*(text|return)'

if [ -n "$INTAKE_PROBE_BLOCK" ]; then
  REACHABLE_REPO="$(mktemp -d "$WORK/reachable-repo-XXXXXX")"
  new_repo "$REACHABLE_REPO"

  # (a) reachable repo, default ref.
  run_block "$INTAKE_PROBE_BLOCK" "$REACHABLE_REPO" "HEAD"
  first_field="$(printf '%s' "$BLOCK_OUT" | head -n1 | cut -f1)"
  if [ "$first_field" = "reachable" ]; then
    pass "probe_recipe_reachable_repo_classified_reachable"
  else
    fail "probe_recipe_reachable_repo_classified_reachable" \
      "expected first field 'reachable', got: $BLOCK_OUT" "stderr: $BLOCK_ERR"
  fi

  # An omitted/empty ref must default to HEAD — the same default the
  # branch field's absence resolves to everywhere else in this reference.
  run_block "$INTAKE_PROBE_BLOCK" "$REACHABLE_REPO" ""
  first_field="$(printf '%s' "$BLOCK_OUT" | head -n1 | cut -f1)"
  if [ "$first_field" = "reachable" ]; then
    pass "probe_recipe_empty_ref_defaults_to_head"
  else
    fail "probe_recipe_empty_ref_defaults_to_head" \
      "expected an empty ref argument to default to HEAD and classify reachable, got: $BLOCK_OUT" "stderr: $BLOCK_ERR"
  fi

  # (b) nonexistent path — real, non-empty git error text on the first line.
  GONE_PATH="$WORK/does-not-exist-xyz"
  GROUND_TRUTH_ERR="$(git ls-remote -- "$GONE_PATH" HEAD 2>&1 >/dev/null | head -n1)"
  run_block "$INTAKE_PROBE_BLOCK" "$GONE_PATH" "HEAD"
  first_field="$(printf '%s' "$BLOCK_OUT" | head -n1 | cut -f1)"
  detail_field="$(printf '%s' "$BLOCK_OUT" | head -n1 | cut -f3)"
  if [ "$first_field" = "unreachable" ] && [ -n "$detail_field" ] \
    && [ "$detail_field" = "$GROUND_TRUTH_ERR" ] \
    && ! printf '%s' "$detail_field" | grep -qiE -- "$NO_ERROR_TEXT_REGEX"; then
    pass "probe_recipe_nonexistent_path_classified_unreachable_with_real_error_text"
  else
    fail "probe_recipe_nonexistent_path_classified_unreachable_with_real_error_text" \
      "expected first field 'unreachable' and third field equal to git's own first stderr line" \
      "got: $BLOCK_OUT" "expected detail: $GROUND_TRUTH_ERR" "stderr: $BLOCK_ERR"
  fi

  # (c) reachable repo, nonexistent branch ref — the documented quirk:
  # no native error text on either stream. The row must still be
  # non-blank and must say plainly that no error text was returned.
  run_block "$INTAKE_PROBE_BLOCK" "$REACHABLE_REPO" "totally-bogus-branch-xyz"
  first_field="$(printf '%s' "$BLOCK_OUT" | head -n1 | cut -f1)"
  detail_field="$(printf '%s' "$BLOCK_OUT" | head -n1 | cut -f3)"
  if [ "$first_field" = "unreachable" ] && [ -n "$detail_field" ] \
    && printf '%s' "$detail_field" | grep -qiE -- "$NO_ERROR_TEXT_REGEX"; then
    pass "probe_recipe_bad_ref_classified_unreachable_with_no_error_text_fallback"
  else
    fail "probe_recipe_bad_ref_classified_unreachable_with_no_error_text_fallback" \
      "expected first field 'unreachable' and a non-blank third field stating plainly that no error text was returned" \
      "got: $BLOCK_OUT" "stderr: $BLOCK_ERR"
  fi

  # Strong form: no git subcommand other than ls-remote anywhere in the
  # block, regardless of whether doctrine.sh's own known-verbs filter
  # would even recognize the token as a verb.
  verb_lines="$(bash "$GIT_VERB_SCAN" --root "" "$INTAKE_PROBE_BLOCK" 2>/dev/null)"
  bad_verbs="$(printf '%s\n' "$verb_lines" | awk -F: '$3 != "" && $3 != "ls-remote" { print }')"
  if [ -z "$bad_verbs" ]; then
    pass "probe_recipe_uses_no_git_verb_other_than_ls_remote"
  else
    fail "probe_recipe_uses_no_git_verb_other_than_ls_remote" "$bad_verbs"
  fi

  # The `--` argument-injection guard cache-seeding.md's own clone
  # recipes already carry, so a URL beginning with `-` cannot be read as
  # a flag. A verb-scan pass alone would not catch its absence.
  if grep -qE 'ls-remote[[:space:]]+--([[:space:]]|$)' "$INTAKE_PROBE_BLOCK"; then
    pass "probe_recipe_ls_remote_uses_double_dash_separator"
  else
    fail "probe_recipe_ls_remote_uses_double_dash_separator" \
      "expected 'git ls-remote -- <url> <ref>' — the '--' separator was not found before the url argument"
  fi
else
  fail "probe_recipe_reachable_repo_classified_reachable" "$NO_PROBE_BLOCK_REASON"
  fail "probe_recipe_empty_ref_defaults_to_head" "$NO_PROBE_BLOCK_REASON"
  fail "probe_recipe_nonexistent_path_classified_unreachable_with_real_error_text" "$NO_PROBE_BLOCK_REASON"
  fail "probe_recipe_bad_ref_classified_unreachable_with_no_error_text_fallback" "$NO_PROBE_BLOCK_REASON"
  fail "probe_recipe_uses_no_git_verb_other_than_ls_remote" "$NO_PROBE_BLOCK_REASON"
  fail "probe_recipe_ls_remote_uses_double_dash_separator" "$NO_PROBE_BLOCK_REASON"
fi

# ---------------------------------------------------------------------------
# Prose: the probe's documented behavior in whatever section carries it.
# ---------------------------------------------------------------------------

banner "reachability probe: documented ordering and table shape"

if [ -n "$PROBE_SECTION_NORM" ]; then
  assert_near "probe_runs_before_stamping_stated_in_prose" "$PROBE_SECTION_NORM" \
    '--probe' 'before.{0,40}(step 3|stamp)' 250

  assert_near_all "probe_table_describes_row_per_url_reachable_or_unreachable" "$PROBE_SECTION_NORM" \
    'table' 250 'row' 'reachable' 'unreachable'

  assert_near "probe_table_describes_first_error_line_for_unreachable_rows" "$PROBE_SECTION_NORM" \
    'unreachable' 'first.{0,20}(line|error)' 200

  if near "$PROBE_SECTION_NORM" 'table' '(above|before|precede[sd]?).{0,60}(question|prompt|confirm|ask)' 250 \
    || near "$PROBE_SECTION_NORM" '(ask|confirm|question|prompt)' '(after|below|beneath|following).{0,60}table' 250; then
    pass "probe_table_stated_before_confirmation_prompt"
  else
    fail "probe_table_stated_before_confirmation_prompt" \
      "expected prose stating the table is shown above/before the continue question (or the question after/below the table)"
  fi

  assert_near "decline_outcome_states_nothing_stamped" "$PROBE_SECTION_NORM" \
    '(decline|answers?.{0,10}no|says?.{0,10}no)' 'nothing.{0,20}(is |gets )?stamped' 200

  assert_near "consent_outcome_states_every_source_stamped" "$PROBE_SECTION_NORM" \
    '(consent|continues?|answers?.{0,10}yes|proceeds)' 'every source.{0,40}stamped' 250

  assert_near "consent_outcome_excludes_unreachable_from_clone_all_seed" "$PROBE_SECTION_NORM" \
    'unreachable' '(exclud|omit|skip).{0,60}--clone-all|--clone-all.{0,60}(exclud|omit|skip)' 250
else
  fail "probe_runs_before_stamping_stated_in_prose" "$NO_PROBE_BLOCK_REASON"
  fail "probe_table_describes_row_per_url_reachable_or_unreachable" "$NO_PROBE_BLOCK_REASON"
  fail "probe_table_describes_first_error_line_for_unreachable_rows" "$NO_PROBE_BLOCK_REASON"
  fail "probe_table_stated_before_confirmation_prompt" "$NO_PROBE_BLOCK_REASON"
  fail "decline_outcome_states_nothing_stamped" "$NO_PROBE_BLOCK_REASON"
  fail "consent_outcome_states_every_source_stamped" "$NO_PROBE_BLOCK_REASON"
  fail "consent_outcome_excludes_unreachable_from_clone_all_seed" "$NO_PROBE_BLOCK_REASON"
fi

# ---------------------------------------------------------------------------
# cache-seeding.md: the --clone-all exclusion is a real, localized gate,
# not merely claimed elsewhere in the file.
# ---------------------------------------------------------------------------

banner "cache-seeding.md: --clone-all exclusion is structural, not just claimed"

CACHE_SEEDING_STEP35_START="$(line_of "$CACHE_SEEDING_MD" '^## Step 3\.5')"
CACHE_SEEDING_STEP36_START="$(line_of "$CACHE_SEEDING_MD" '^## Step 3\.6')"
if [ -z "$CACHE_SEEDING_STEP35_START" ] || [ -z "$CACHE_SEEDING_STEP36_START" ]; then
  echo "ERROR: cannot locate the Step 3.5 / Step 3.6 headings in $CACHE_SEEDING_MD" >&2
  exit 69
fi
RAW_STEP35="$(section_text "$CACHE_SEEDING_MD" "$CACHE_SEEDING_STEP35_START" "$CACHE_SEEDING_STEP36_START")"
NORM_STEP35="$(norm_str "$RAW_STEP35")"

assert_near_all "clone_all_exclusion_structural_in_cache_seeding" "$NORM_STEP35" \
  '--clone-all' 250 'unreachable' '(exclud|omit|skip|except)'

# ---------------------------------------------------------------------------
# Default no-network framing + --probe opt-in, paired: never assert only
# the flag-present half. Four anchors: SKILL.md's two "does NOT" bullets,
# its "Offer to seed local cache" paragraph, and cache-seeding.md's own
# "only network operation" sentence.
# ---------------------------------------------------------------------------

banner "default no-network framing survives, --probe named as the opt-in exception"

ONLY_NETWORK_OP_ANCHOR='only\*{0,2} network operation'
REACHABILITY_ANCHOR='reachability'
DEFAULT_FRAMING_NEEDLE='(without|unless|absent|default)'

NOT_DO_START="$(line_of "$SKILL_MD" '^## What this skill does NOT do')"
if [ -z "$NOT_DO_START" ]; then
  echo "ERROR: cannot locate the 'What this skill does NOT do' heading in $SKILL_MD" >&2
  exit 69
fi
NORM_NOT_DO="$(norm_str "$(section_text "$SKILL_MD" "$NOT_DO_START" "")")"

assert_near "probe_named_as_opt_in_exception_does_not_bullet_network_operation" "$NORM_NOT_DO" \
  "$ONLY_NETWORK_OP_ANCHOR" '--probe' 200
assert_near "default_no_network_framing_survives_does_not_bullet_network_operation" "$NORM_NOT_DO" \
  "$ONLY_NETWORK_OP_ANCHOR" "$DEFAULT_FRAMING_NEEDLE" 150

assert_near "probe_named_as_opt_in_exception_does_not_bullet_reachability_validation" "$NORM_NOT_DO" \
  "$REACHABILITY_ANCHOR" '--probe' 200
assert_near "default_no_network_framing_survives_does_not_bullet_reachability_validation" "$NORM_NOT_DO" \
  "$REACHABILITY_ANCHOR" "$DEFAULT_FRAMING_NEEDLE" 150

OFFER_START="$(line_of "$SKILL_MD" '^## Offer to seed local cache')"
STEP4_START="$(line_of "$SKILL_MD" '^## Step 4')"
if [ -z "$OFFER_START" ] || [ -z "$STEP4_START" ]; then
  echo "ERROR: cannot locate the 'Offer to seed local cache' / 'Step 4' headings in $SKILL_MD" >&2
  exit 69
fi
NORM_OFFER="$(norm_str "$(section_text "$SKILL_MD" "$OFFER_START" "$STEP4_START")")"

assert_near "probe_named_as_opt_in_exception_offer_to_seed_paragraph" "$NORM_OFFER" \
  "$ONLY_NETWORK_OP_ANCHOR" '--probe' 200
assert_near "default_no_network_framing_survives_offer_to_seed_paragraph" "$NORM_OFFER" \
  "$ONLY_NETWORK_OP_ANCHOR" "$DEFAULT_FRAMING_NEEDLE" 150

assert_near "probe_named_as_opt_in_exception_cache_seeding_only_network_sentence" "$NORM_STEP35" \
  "$ONLY_NETWORK_OP_ANCHOR" '--probe' 200
assert_near "default_no_network_framing_survives_cache_seeding_only_network_sentence" "$NORM_STEP35" \
  "$ONLY_NETWORK_OP_ANCHOR" "$DEFAULT_FRAMING_NEEDLE" 150

# ---------------------------------------------------------------------------
# Preservation: the existing clone-consent guard and default --clone-all
# framing in cache-seeding.md. Ungated — these already hold today.
# ---------------------------------------------------------------------------

banner "preservation: clone-consent mutual-exclusion guard (cache-seeding.md)"

CLONE_GUARD_BLOCK=""
if extract_sentinel_block "preservation_clone_consent_guard_still_extractable" "$CACHE_SEEDING_MD" \
  "$CLONE_GUARD_SENTINEL_START" "$CLONE_GUARD_SENTINEL_END"; then
  CLONE_GUARD_BLOCK="$EXTRACTED_BLOCK"
fi

NO_CLONE_GUARD_REASON="cannot evaluate — no clone-consent-guard block found (see the extraction result above)"
if [ -n "$CLONE_GUARD_BLOCK" ]; then
  run_block "$CLONE_GUARD_BLOCK"
  if [ "$BLOCK_RC" -eq 0 ]; then
    pass "preservation_clone_consent_guard_neither_flag_exit0"
  else
    fail "preservation_clone_consent_guard_neither_flag_exit0" "expected exit 0, got $BLOCK_RC" "stderr: $BLOCK_ERR"
  fi

  run_block "$CLONE_GUARD_BLOCK" --clone-all --clone-none
  if [ "$BLOCK_RC" -eq 1 ] && printf '%s' "$BLOCK_ERR" | grep -qF -- '--clone-all' \
    && printf '%s' "$BLOCK_ERR" | grep -qF -- '--clone-none'; then
    pass "preservation_clone_consent_guard_both_flags_exit1_names_both"
  else
    fail "preservation_clone_consent_guard_both_flags_exit1_names_both" \
      "expected exit 1 with stderr naming both flags" "exit: $BLOCK_RC" "stderr: $BLOCK_ERR"
  fi
else
  fail "preservation_clone_consent_guard_neither_flag_exit0" "$NO_CLONE_GUARD_REASON"
  fail "preservation_clone_consent_guard_both_flags_exit1_names_both" "$NO_CLONE_GUARD_REASON"
fi

assert_str "preservation_clone_all_default_prompt_frozen_text_present" "$NORM_STEP35" "$BOOTSTRAP_PROMPT_FROZEN"

assert_near_all "preservation_clone_all_every_source_no_prompt_framing_present" "$NORM_STEP35" \
  '--clone-all' 200 'every' '(no prompt|without (a |the )?prompt|skips? (the |any )?prompt|does(n.t| not) prompt)'

# ---------------------------------------------------------------------------
# Preservation: the existing activation-guard section and directory-
# detection block in intake-and-detection.md, plus non-interference with
# the new probe section.
# ---------------------------------------------------------------------------

banner "preservation: activation guard (intake-and-detection.md), non-interference with the new section"

GUARD_FIND_BLOCK=""
if extract_sentinel_block "preservation_activation_guard_find_still_extractable" "$INTAKE_MD" \
  "$GUARD_FIND_SENTINEL_START" "$GUARD_FIND_SENTINEL_END"; then
  GUARD_FIND_BLOCK="$EXTRACTED_BLOCK"
  GUARD_FIND_START_LINE="$EXTRACTED_BLOCK_START_LINE"
  GUARD_FIND_END_LINE="$EXTRACTED_BLOCK_END_LINE"
else
  GUARD_FIND_START_LINE=0
  GUARD_FIND_END_LINE=0
fi

NO_GUARD_FIND_REASON="cannot evaluate — no activation-guard directory-detection block found (see the extraction result above)"
if [ -n "$GUARD_FIND_BLOCK" ]; then
  SCRATCH_ROOT="$(mktemp -d "$WORK/scratch-project-XXXXXX")"
  mkdir -p "$SCRATCH_ROOT/.claude/skills/ledger-context"
  printf '# placeholder — a non-empty installed contextualizer\n' \
    >"$SCRATCH_ROOT/.claude/skills/ledger-context/SKILL.md"
  # Run directly (rather than through run_block) so the cwd change via a
  # subshell doesn't lose the captured output back in this shell.
  outfile="$(mktemp "$WORK/guard-find-out-XXXXXX")"
  (cd "$SCRATCH_ROOT" && bash "$GUARD_FIND_BLOCK" "ledger") >"$outfile" 2>/dev/null
  guard_find_out="$(cat "$outfile")"
  if printf '%s' "$guard_find_out" | grep -q 'ledger-context'; then
    pass "preservation_activation_guard_same_slug_collision_still_detected"
  else
    fail "preservation_activation_guard_same_slug_collision_still_detected" \
      "slug 'ledger' against an existing ledger-context/ should print the matching directory" \
      "stdout: $guard_find_out"
  fi
else
  fail "preservation_activation_guard_same_slug_collision_still_detected" "$NO_GUARD_FIND_REASON"
fi

assert_str "preservation_activation_guard_corrupted_marker_sentence_present" "$NORM_INTAKE_MD" "$FROZEN_CORRUPTED_MARKER"

if [ -n "$INTAKE_PROBE_BLOCK" ] && [ -n "$GUARD_FIND_BLOCK" ]; then
  if [ "$PROBE_BLOCK_END_LINE" -lt "$GUARD_FIND_START_LINE" ] || [ "$GUARD_FIND_END_LINE" -lt "$PROBE_BLOCK_START_LINE" ]; then
    pass "new_probe_sentinel_does_not_overlap_activation_guard_sentinel"
  else
    fail "new_probe_sentinel_does_not_overlap_activation_guard_sentinel" \
      "probe block lines $PROBE_BLOCK_START_LINE-$PROBE_BLOCK_END_LINE overlap guard block lines $GUARD_FIND_START_LINE-$GUARD_FIND_END_LINE in $INTAKE_MD"
  fi
else
  fail "new_probe_sentinel_does_not_overlap_activation_guard_sentinel" \
    "cannot evaluate — one or both sentinel blocks not found yet (see extraction results above)"
fi

# The activation-guard section (located by its own heading, independent
# of where the new probe section lands) must not have picked up probe
# vocabulary — proof the new section didn't get merged into it.
GUARD_HEADING_LINE="$(line_of "$INTAKE_MD" '^## .*[Aa]ctivation [Gg]uard')"
if [ -n "$GUARD_HEADING_LINE" ]; then
  GUARD_SECTION_END="$(heading_after "$INTAKE_MD" "$GUARD_HEADING_LINE")"
  NORM_GUARD_SECTION="$(norm_str "$(section_text "$INTAKE_MD" "$GUARD_HEADING_LINE" "$GUARD_SECTION_END")")"
  if printf '%s' "$NORM_GUARD_SECTION" | grep -qiE -- '--probe|reachability-probe'; then
    fail "new_probe_section_does_not_bleed_into_activation_guard_section" \
      "the activation-guard section now mentions probe vocabulary — the two sections have merged"
  else
    pass "new_probe_section_does_not_bleed_into_activation_guard_section"
  fi
else
  fail "new_probe_section_does_not_bleed_into_activation_guard_section" \
    "cannot locate the Activation guard heading in $INTAKE_MD"
fi

# ---------------------------------------------------------------------------
# Size: SKILL.md stays at or under the router-sized byte ceiling, and this
# plugin's own doctrine checks see no new violation in the three touched
# files.
# ---------------------------------------------------------------------------

banner "byte ceiling and doctrine"

skill_md_bytes="$(wc -c <"$SKILL_MD" | tr -d ' ')"
if [ "$skill_md_bytes" -le 8204 ]; then
  pass "engine_bootstrap_skill_md_at_or_under_8204_bytes"
else
  fail "engine_bootstrap_skill_md_at_or_under_8204_bytes" \
    "SKILL.md is $skill_md_bytes bytes — over the 8,204-byte ceiling"
fi

DOCTRINE_OUT="$(bash "$DOCTRINE_SCRIPT" 2>&1)"

if printf '%s\n' "$DOCTRINE_OUT" | grep -qE 'FAIL:.*engine-bootstrap/SKILL\.md is'; then
  fail "doctrine_size_ceiling_check_passes" \
    "$(printf '%s\n' "$DOCTRINE_OUT" | grep -E 'FAIL:.*engine-bootstrap/SKILL\.md is')"
else
  pass "doctrine_size_ceiling_check_passes"
fi

if printf '%s\n' "$DOCTRINE_OUT" | grep -qE 'FAIL:.*engine-bootstrap/SKILL\.md \+ engine-bootstrap/references/ combined'; then
  fail "doctrine_size_split_floor_check_passes" \
    "$(printf '%s\n' "$DOCTRINE_OUT" | grep -E 'FAIL:.*engine-bootstrap/SKILL\.md \+ engine-bootstrap/references/ combined')"
else
  pass "doctrine_size_split_floor_check_passes"
fi

if printf '%s\n' "$DOCTRINE_OUT" | grep -qE 'engine-bootstrap/references/intake-and-detection\.md:[0-9]+  git '; then
  fail "doctrine_check4_passes_for_intake_reference" \
    "$(printf '%s\n' "$DOCTRINE_OUT" | grep -E 'engine-bootstrap/references/intake-and-detection\.md:[0-9]+  git ')"
else
  pass "doctrine_check4_passes_for_intake_reference"
fi

if printf '%s\n' "$DOCTRINE_OUT" | grep -qE 'engine-bootstrap/references/cache-seeding\.md:[0-9]+  git '; then
  fail "doctrine_check4_passes_for_cache_seeding_reference" \
    "$(printf '%s\n' "$DOCTRINE_OUT" | grep -E 'engine-bootstrap/references/cache-seeding\.md:[0-9]+  git ')"
else
  pass "doctrine_check4_passes_for_cache_seeding_reference"
fi

DOCTRINE_TOUCHED_FAIL="$(printf '%s\n' "$DOCTRINE_OUT" | grep -E 'FAIL' \
  | grep -E 'engine-bootstrap/SKILL\.md|intake-and-detection\.md|cache-seeding\.md' || true)"
if [ -z "$DOCTRINE_TOUCHED_FAIL" ]; then
  pass "doctrine_reports_no_failures_naming_the_touched_files"
else
  fail "doctrine_reports_no_failures_naming_the_touched_files" "$DOCTRINE_TOUCHED_FAIL"
fi

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------

banner "summary"
printf 'passed: %d   failed: %d\n' "$pass_count" "$fail_count"

if [ "$fail_count" -gt 0 ]; then
  exit 1
fi
exit 0
