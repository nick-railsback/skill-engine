#!/usr/bin/env bash
# Prose-and-executed oracle for the bootstrap activation guard's slug
# scope: bootstrapping a second contextualizer in a project that already
# holds one for a *different* slug must proceed without any confirmation
# pause; a same-slug collision must still pause exactly as it does today.
#
# THE INVARIANTS.
#   - The guard's directory-detection step matches only the contextualizer
#     slug being created, not any "*-context" directory. Scanning a
#     project whose .claude/skills/ holds a non-empty ledger-context/ for
#     a slug of "payments" must find nothing; scanning the same tree for
#     a slug of "ledger" must find the existing directory. The literal
#     wide-glob find flag (`-name '*-context'`) must not survive anywhere
#     in either file, not just inside the extraction below.
#   - Everything the guard does once it fires on a same-slug collision —
#     the one-line warning naming the path, the pause for explicit
#     confirmation, the corrupted-state-marker nuance (files-present, not
#     a parseable research/.research-state.json, is what decides the
#     guard), and the note that using-skill-engine routes both new and
#     corrupt-marker directories through this same pause — survives
#     relocation into the intake reference verbatim, not paraphrased.
#   - The blanket "no contextualizer is installed under
#     .claude/skills/*-context/ yet" framing — accurate only when the
#     guard fired on any slug — no longer appears in either file, since it
#     stops being true once the guard is slug-scoped.
#   - The guard's heading sits after the slug becomes known (the
#     contextualizer-name confirmation step) and before the file-stamping
#     step, in that order, in the navigator body; the intake reference
#     states that same ordering in its own prose.
#   - The navigator stays at or under the router-sized byte ceiling, and
#     this plugin's doctrine checks for that ceiling and for the
#     size-split floor both pass.
#
# THIS IS A PROSE-AND-STRUCTURE ORACLE over two Markdown files a model
# reads, not a program with its own CLI — so most of this checks the
# documented contract directly: wrap-normalized phrase/substring matches
# against hand-wrapped Markdown (collapse newlines and whitespace runs
# before matching; a naive line-oriented grep silently misses a phrase
# that happens to cross a line break) and heading-order line numbers. The
# one piece that IS executable is the directory-detection step itself:
# wherever the intake reference carries it as a fenced shell block
# delimited by the sentinel pair
#
#   <!-- doctrine:activation-guard-find:start -->
#   ```bash
#   ...
#   ```
#   <!-- doctrine:activation-guard-find:end -->
#
# (exactly one such pair — the convention is invented here, since nothing
# upstream pins it yet), this runner extracts the block and runs it as
# `bash <extracted-block> <slug>` from inside a scratch project
# directory, with the slug landing in the block's own "$1" exactly as it
# would receive the confirmed contextualizer name on the real intake
# invocation. Right now no such sentinel pair exists in the intake
# reference, so the extraction comes back empty and every assertion that
# depends on it fails for that reason — the behavior is absent, not the
# harness broken.
#
# PRESERVATION AND REMOVAL CHECKS RUN UNGATED. "The warning/pause
# behavior reads a certain way today" and "the blanket any-slug sentence
# is present today" are both already true before any edit, so the
# preservation asserts run directly against a copy of today's wording
# frozen into this file, and the removal asserts run directly against
# both files' current content — expected to behave oppositely to how
# they will once the guard is relocated and narrowed.
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
DOCTRINE_SCRIPT="$PLUGIN_ROOT/tests/doctrine.sh"

for f in "$SKILL_MD" "$INTAKE_MD" "$DOCTRINE_SCRIPT"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: expected surface is missing entirely: $f" >&2
    exit 69
  fi
done

WORK="$(mktemp -d -t skill-engine-activation-guard-slug.XXXXXX)"
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

assert_str() {
  local label="$1" text="$2" lit="$3"
  if printf '%s' "$text" | grep -qF -- "$lit"; then
    pass "$label"
  else
    fail "$label" "string not found: $lit"
  fi
}

assert_not_str() {
  local label="$1" text="$2" lit="$3"
  if printf '%s' "$text" | grep -qF -- "$lit"; then
    fail "$label" "string still present (expected it removed): $lit"
  else
    pass "$label"
  fi
}

line_of() {
  local file="$1" pat="$2"
  grep -n -E -- "$pat" "$file" | head -n1 | cut -d: -f1
}

# near <text> <anchor-ere> <needle-ere> <window> — true when <needle>
# occurs within <window> characters of some occurrence of <anchor> in
# <text>. 200, not more: some grep implementations reject an interval
# bound above 255, and the window applies on both sides of the anchor.
near() {
  local text="$1" anchor="$2" needle="$3" window="$4"
  # `grep -c ... > /dev/null`, not `grep -q`: -q exits at its first match,
  # SIGPIPE-ing the upstream -o while that is still writing its remaining
  # windows. Under `set -o pipefail` the pipeline then reports 141 and a
  # needle that WAS found reads as a miss -- the more occurrences of the
  # anchor, the likelier it fires. -c carries the same 0/1 match semantics
  # but drains its input to EOF, so the verdict no longer depends on the
  # anchor's frequency or on the pipe buffer size.
  printf '%s' "$text" \
    | grep -oiE ".{0,${window}}${anchor}.{0,${window}}" \
    | grep -ciE -- "$needle" > /dev/null
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

# ---------------------------------------------------------------------------
# Read and normalize the two surfaces under test.
# ---------------------------------------------------------------------------

RAW_SKILL_MD="$(cat "$SKILL_MD")"
NORM_SKILL_MD="$(norm_str "$RAW_SKILL_MD")"
RAW_INTAKE_MD="$(cat "$INTAKE_MD")"
NORM_INTAKE_MD="$(norm_str "$RAW_INTAKE_MD")"

# Frozen, wrap-normalized copies of the guard's same-slug-collision prose,
# captured from today's navigator body — the behavior under test must
# survive relocation into the intake reference byte-for-byte (modulo
# rewrapping), not be paraphrased along the way.
FROZEN_WARNING_PAUSE='surface a one-line warning naming the path, list the files that would be overwritten, and pause for explicit confirmation before continuing.'
FROZEN_CORRUPTED_MARKER='The condition is files-present, NOT a parseable `research/.research-state.json`: a corrupted state marker must not bypass this guard, because the directory may still hold a curated `SKILL.md` and a populated `research/source-paths.json` that stamping would overwrite.'
FROZEN_ROUTER_ROUTING='The `using-skill-engine` router sends both new and corrupt-marker directories here; either way, existing files pause for confirmation.'

# The blanket any-slug framing that must NOT survive in the navigator —
# it stops being an accurate description once the guard only fires on a
# same-slug collision.
FROZEN_BLANKET_ANY_SLUG='This skill assumes no contextualizer is installed under `.claude/skills/*-context/` yet.'

# ---------------------------------------------------------------------------
# Preservation: the collision behavior's prose relocates into the intake
# reference verbatim.
# ---------------------------------------------------------------------------

banner "same-slug collision behavior relocated verbatim into the intake reference"

assert_str "warning_pause_behavior_preserved_in_intake_reference" "$NORM_INTAKE_MD" "$FROZEN_WARNING_PAUSE"
assert_str "corrupted_state_marker_nuance_preserved_in_intake_reference" "$NORM_INTAKE_MD" "$FROZEN_CORRUPTED_MARKER"
assert_str "using_skill_engine_router_routing_sentence_preserved_in_intake_reference" "$NORM_INTAKE_MD" "$FROZEN_ROUTER_ROUTING"

# ---------------------------------------------------------------------------
# Removal: the blanket any-slug framing no longer describes the guard.
# ---------------------------------------------------------------------------

banner "blanket any-slug framing removed from the navigator"

assert_not_str "blanket_any_slug_assumption_removed_from_skill_md" "$NORM_SKILL_MD" "$FROZEN_BLANKET_ANY_SLUG"

# A relocation that carries the same-slug-collision prose over verbatim
# must not carry this sentence along with it — it would land in the
# intake reference just as inaccurately as it would if left in the
# navigator.
assert_not_str "blanket_any_slug_assumption_absent_from_intake_reference" "$NORM_INTAKE_MD" "$FROZEN_BLANKET_ANY_SLUG"

# The literal wide-glob find flag must not survive anywhere in either
# file — not just inside the extracted block above. A leftover use
# outside the sentinel pair (a second, forgotten copy of the detection
# step) would slip past the extraction-only check.
FROZEN_WIDE_GLOB_FIND_FLAG="-name '*-context'"
assert_not_str "wide_glob_find_flag_absent_from_skill_md" "$NORM_SKILL_MD" "$FROZEN_WIDE_GLOB_FIND_FLAG"
assert_not_str "wide_glob_find_flag_absent_from_intake_reference" "$NORM_INTAKE_MD" "$FROZEN_WIDE_GLOB_FIND_FLAG"

# ---------------------------------------------------------------------------
# Structural position: the guard's heading sits after the slug is known
# (the contextualizer-name confirmation step) and before stamping.
# ---------------------------------------------------------------------------

banner "guard heading position: after name confirmation, before stamping"

STEP_2_5_LINE="$(line_of "$SKILL_MD" '^## Step 2\.5[[:space:]]')"
STEP_3_LINE="$(line_of "$SKILL_MD" '^## Step 3[[:space:]]')"
GUARD_LINE="$(line_of "$SKILL_MD" '^## .*[Aa]ctivation [Gg]uard')"

if [ -n "$STEP_2_5_LINE" ] && [ -n "$STEP_3_LINE" ] && [ -n "$GUARD_LINE" ] \
  && [ "$GUARD_LINE" -gt "$STEP_2_5_LINE" ] && [ "$GUARD_LINE" -lt "$STEP_3_LINE" ]; then
  pass "activation_guard_heading_between_name_confirmation_and_stamping"
else
  fail "activation_guard_heading_between_name_confirmation_and_stamping" \
    "expected the Activation guard heading line to fall strictly between the Step 2.5 and Step 3 heading lines in $SKILL_MD" \
    "Step 2.5 line: ${STEP_2_5_LINE:-<not found>}, Activation guard line: ${GUARD_LINE:-<not found>}, Step 3 line: ${STEP_3_LINE:-<not found>}"
fi

# The intake reference is the place the ordering rule (guard runs once
# the slug is known, before anything is stamped) must be stated in
# prose, not just embodied by where the SKILL.md heading sits. Loosely
# matched — the exact phrasing a future edit lands on isn't known yet —
# against some mention of the guard: an "after/once ... slug or name"
# clause and a "before ... stamp" clause, not necessarily in the same
# sentence.
banner "intake reference states the guard's ordering in prose"

if near_all "$NORM_INTAKE_MD" '([Gg]uard|activation.guard.find)' 200 \
  '(after|once|when).{0,100}(slug|name)' 'before.{0,100}stamp'; then
  pass "intake_reference_states_guard_runs_after_slug_before_stamping"
else
  fail "intake_reference_states_guard_runs_after_slug_before_stamping" \
    "expected prose near a mention of the guard stating it runs after the slug/name is known and before stamping"
fi

# ---------------------------------------------------------------------------
# Behavioral: extract the guard's find-based detection block from the
# intake reference and run it against a scratch project tree.
# ---------------------------------------------------------------------------

banner "directory-detection block: extraction"

GUARD_FIND_SENTINEL_START='<!-- doctrine:activation-guard-find:start -->'
GUARD_FIND_SENTINEL_END='<!-- doctrine:activation-guard-find:end -->'

# extract_find_block <label> <file> — requires exactly one
# GUARD_FIND_SENTINEL_START/END pair in <file>, in that order. On
# success, writes the block body (fence delimiters stripped,
# syntax-checked with `bash -n`) to a fresh tmpfile and exposes its path
# via EXTRACTED_FIND_BLOCK; on any other shape (zero pairs, more than
# one, out of order, empty body, invalid shell) reports FAIL under
# <label> and returns non-zero — a hard, clearly-labeled failure rather
# than a silent skip.
EXTRACTED_FIND_BLOCK=""
extract_find_block() {
  local label="$1" file="$2"
  EXTRACTED_FIND_BLOCK=""
  local s_count e_count sl el
  s_count="$(grep -c -F -- "$GUARD_FIND_SENTINEL_START" "$file")"
  e_count="$(grep -c -F -- "$GUARD_FIND_SENTINEL_END" "$file")"

  if [ "$s_count" -eq 0 ] && [ "$e_count" -eq 0 ]; then
    fail "$label" "no ${GUARD_FIND_SENTINEL_START} / ${GUARD_FIND_SENTINEL_END} pair found in $file"
    return 1
  fi
  if [ "$s_count" -ne 1 ] || [ "$e_count" -ne 1 ]; then
    fail "$label" "$s_count start / $e_count end sentinels in $file (need exactly one of each)"
    return 1
  fi

  sl="$(grep -n -F -- "$GUARD_FIND_SENTINEL_START" "$file" | head -n1 | cut -d: -f1)"
  el="$(grep -n -F -- "$GUARD_FIND_SENTINEL_END" "$file" | head -n1 | cut -d: -f1)"
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
  outfile="$(mktemp "$WORK/find-block-XXXXXX")"
  printf '%s\n' "$body" >"$outfile"
  local syntax_err
  syntax_err="$(mktemp "$WORK/find-block-syntax-err-XXXXXX")"
  if ! bash -n "$outfile" 2>"$syntax_err"; then
    fail "$label" "extracted block from $file is not valid shell:" "$(cat "$syntax_err")"
    return 1
  fi

  pass "$label"
  EXTRACTED_FIND_BLOCK="$outfile"
  return 0
}

INTAKE_FIND_BLOCK=""
if extract_find_block "activation_guard_find_block_present_in_intake_reference" "$INTAKE_MD"; then
  INTAKE_FIND_BLOCK="$EXTRACTED_FIND_BLOCK"
fi

banner "directory-detection block: same-slug collision vs. different-slug pass-through"

# Scratch project tree: a non-empty ledger-context/ already installed,
# standing in for "a contextualizer already exists for slug X".
SCRATCH_ROOT="$(mktemp -d "$WORK/scratch-project-XXXXXX")"
mkdir -p "$SCRATCH_ROOT/.claude/skills/ledger-context"
printf '# placeholder — a non-empty installed contextualizer\n' \
  >"$SCRATCH_ROOT/.claude/skills/ledger-context/SKILL.md"

FIND_RC=0
FIND_OUT=""
FIND_ERR=""

# run_find_block <block-file> <slug> — runs the extracted block as
# `bash <block-file> <slug>` from inside the scratch project root, so the
# slug lands in the block's own "$1" exactly as the confirmed
# contextualizer name would on the real intake invocation. Sets FIND_RC,
# FIND_OUT (stdout), and FIND_ERR (stderr) on return.
run_find_block() {
  local block_file="$1" slug="$2"
  local outfile errfile
  outfile="$(mktemp "$WORK/find-run-out-XXXXXX")"
  errfile="$(mktemp "$WORK/find-run-err-XXXXXX")"
  (cd "$SCRATCH_ROOT" && bash "$block_file" "$slug") >"$outfile" 2>"$errfile"
  FIND_RC=$?
  FIND_OUT="$(cat "$outfile")"
  FIND_ERR="$(cat "$errfile")"
}

NO_FIND_BLOCK_REASON="cannot evaluate — no activation-guard directory-detection block found (see the extraction result above)"

if [ -n "$INTAKE_FIND_BLOCK" ]; then
  # Different slug than the one already installed: no collision, no output.
  run_find_block "$INTAKE_FIND_BLOCK" "payments"
  if [ -z "$FIND_OUT" ]; then
    pass "different_slug_no_collision_produces_no_output"
  else
    fail "different_slug_no_collision_produces_no_output" \
      "slug 'payments' against an existing ledger-context/ should print nothing" \
      "exit: $FIND_RC, stdout: $FIND_OUT" "stderr: $FIND_ERR"
  fi

  # Same slug as the one already installed: collision, must-detect input.
  run_find_block "$INTAKE_FIND_BLOCK" "ledger"
  if printf '%s' "$FIND_OUT" | grep -q 'ledger-context'; then
    pass "same_slug_collision_prints_matching_directory"
  else
    fail "same_slug_collision_prints_matching_directory" \
      "slug 'ledger' against an existing ledger-context/ should print the matching directory" \
      "exit: $FIND_RC, stdout: $FIND_OUT" "stderr: $FIND_ERR"
  fi
else
  fail "different_slug_no_collision_produces_no_output" "$NO_FIND_BLOCK_REASON"
  fail "same_slug_collision_prints_matching_directory" "$NO_FIND_BLOCK_REASON"
fi

# ---------------------------------------------------------------------------
# Size: the navigator stays at or under the router-sized byte ceiling,
# and the plugin's own doctrine checks for that ceiling and the
# size-split floor both pass.
# ---------------------------------------------------------------------------

banner "navigator size: byte ceiling and doctrine checks"

skill_md_bytes="$(wc -c <"$SKILL_MD" | tr -d ' ')"
if [ "$skill_md_bytes" -le 8204 ]; then
  pass "engine_bootstrap_skill_md_at_or_under_8204_bytes"
else
  fail "engine_bootstrap_skill_md_at_or_under_8204_bytes" \
    "SKILL.md is $skill_md_bytes bytes — over the 8,204-byte ceiling"
fi

DOCTRINE_OUT="$(bash "$DOCTRINE_SCRIPT" 2>&1)"

# Isolate the two named doctrine checks this reference cares about by the
# file-pair substring unique to each — running the real script rather
# than reimplementing its thresholds, so this oracle can't drift from the
# actual check.
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

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------

banner "summary"
printf 'passed: %d   failed: %d\n' "$pass_count" "$fail_count"

if [ "$fail_count" -gt 0 ]; then
  exit 1
fi
exit 0
