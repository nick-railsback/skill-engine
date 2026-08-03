#!/usr/bin/env bash
# Black-box oracle: engine-bootstrap's own documentation states that Step 3
# stamps the eval harness — the three eval/*.template files plus a seeded
# evals.json — into a freshly scaffolded contextualizer, instead of leaving
# the harness as a doc reference nobody acts on. There is no script that
# "runs bootstrap" end to end (it is a prose procedure an LLM agent
# executes), so every assertion here is a read-only grep/parse over the
# plugin's shipped markdown: does the prose name the stamped files with the
# right substituted names, describe evals.json's seeded shape precisely
# enough to build from, retire the old "not stamped" labels, and update the
# exit message and its own line-count instruction in lockstep?
#
# -e is intentionally omitted: every assertion must run and report, not
# abort at the first red one.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

SKILL_MD="$PLUGIN_ROOT/skills/engine-bootstrap/SKILL.md"
STAMPING_REF="$PLUGIN_ROOT/skills/engine-bootstrap/references/stamping-and-templates.md"
TEMPLATES_README="$PLUGIN_ROOT/engine-bootstrap-templates/README.md"
EVAL_DOC="$PLUGIN_ROOT/docs/12-evaluation.md"
EVAL_TEMPLATES_DIR="$PLUGIN_ROOT/engine-bootstrap-templates/eval"

WATCHED_FILES="$SKILL_MD $STAMPING_REF $TEMPLATES_README $EVAL_DOC"

pass_count=0
fail_count=0

section() {
  printf '\n── %s ──\n' "$1"
}

pass() {
  printf 'PASS: %s\n' "$1"
  pass_count=$((pass_count + 1))
}

fail() {
  local label="$1"
  shift
  printf 'FAIL: %s\n' "$label"
  if [ "$#" -gt 0 ]; then
    printf '      %s\n' "$@"
  fi
  fail_count=$((fail_count + 1))
}

# join_lines — collapse hard-wrapped markdown to one space-normalized line so
# a sentence split across wrapped lines is still matchable as one string.
join_lines() {
  tr '\n' ' ' | tr -s ' '
}

# extract_section <heading-text> <file> — the named "## " heading through
# (not including) the next "## " heading, or end of file.
extract_section() {
  awk -v want="$1" '
    $0 ~ ("^## " want) { f = 1; print; next }
    f && /^## / { exit }
    f { print }
  ' "$2"
}

# extract_between <start-substr> <end-substr> <file> — lines from the first
# line containing start (inclusive) to the next line containing end
# (exclusive). Both markers matched as literal substrings, not regexes.
extract_between() {
  awk -v s="$1" -v e="$2" '
    f && index($0, e) { exit }
    index($0, s) { f = 1 }
    f { print }
  ' "$3"
}

# window_after <text> <needle> <width> — the first <width> characters of
# <text> starting at the first occurrence of <needle> (needle included), or
# empty if <needle> never appears. Keeps co-occurrence checks anchored to the
# material right after a specific mention rather than satisfied by unrelated
# text elsewhere in the same file.
window_after() {
  local text="$1" needle="$2" width="$3"
  local prefix idx
  prefix="${text%%"$needle"*}"
  if [ "$prefix" = "$text" ]; then
    printf ''
    return 1
  fi
  idx=${#prefix}
  printf '%s' "${text:$idx:$((${#needle} + width))}"
}

# word_to_int <english-number-word> — "four" -> 4, etc. Empty if unmapped.
word_to_int() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    one) printf '1' ;;
    two) printf '2' ;;
    three) printf '3' ;;
    four) printf '4' ;;
    five) printf '5' ;;
    six) printf '6' ;;
    seven) printf '7' ;;
    eight) printf '8' ;;
    *) printf '' ;;
  esac
}

hash_watched() {
  local f
  for f in $WATCHED_FILES; do
    if [ -f "$f" ]; then
      shasum -a 256 "$f"
    else
      printf 'MISSING %s\n' "$f"
    fi
  done
}

BEFORE_HASH="$(hash_watched)"

section "files under test exist"

for f in "$SKILL_MD" "$STAMPING_REF" "$TEMPLATES_README" "$EVAL_DOC"; do
  if [ -f "$f" ]; then
    pass "shipped file present: ${f#"$REPO_ROOT"/}"
  else
    fail "shipped file present: ${f#"$REPO_ROOT"/}"
  fi
done

for f in run-eval.sh eval-viewer.html render-eval-results.sh; do
  if [ -f "$EVAL_TEMPLATES_DIR/$f.template" ]; then
    pass "source template present: engine-bootstrap-templates/eval/$f.template"
  else
    fail "source template present: engine-bootstrap-templates/eval/$f.template"
  fi
done

STAMPING_JOINED="$(join_lines < "$STAMPING_REF")"

# ---------------------------------------------------------------------------
# The eval templates are stamped into evals/ with substituted names, the
# same way the other four Step 3 items are already stamped.
# ---------------------------------------------------------------------------

section "evals templates stamped into evals/ with substituted names"

if grep -qF 'evals/run-eval.sh' <<<"$STAMPING_JOINED" \
    && grep -qF 'evals/eval-viewer.html' <<<"$STAMPING_JOINED" \
    && grep -qF 'evals/render-eval-results.sh' <<<"$STAMPING_JOINED"; then
  pass "stamping doc names all three destination files under evals/, .template suffix stripped"
else
  fail "stamping doc names all three destination files under evals/, .template suffix stripped"
fi

if grep -qF 'run-eval.sh.template' <<<"$STAMPING_JOINED" \
    && grep -qF 'eval-viewer.html.template' <<<"$STAMPING_JOINED" \
    && grep -qF 'render-eval-results.sh.template' <<<"$STAMPING_JOINED"; then
  pass "stamping doc identifies engine-bootstrap-templates/eval/ as the source of each copy"
else
  fail "stamping doc identifies engine-bootstrap-templates/eval/ as the source of each copy"
fi

RUN_EVAL_WINDOW="$(window_after "$STAMPING_JOINED" 'evals/run-eval.sh' 250)"
RENDER_WINDOW="$(window_after "$STAMPING_JOINED" 'evals/render-eval-results.sh' 250)"

if grep -qF 'chmod +x' <<<"$RUN_EVAL_WINDOW" && grep -qF 'chmod +x' <<<"$RENDER_WINDOW"; then
  pass "stamping doc marks both copied .sh harness files executable"
else
  fail "stamping doc marks both copied .sh harness files executable"
fi

# Anchored on the first mention of "eval" (case-folded) rather than searched
# across the whole file: stamping-and-templates.md already contains
# unrelated, pre-existing mentions of both <area-domain> (the retired
# navigator-template placeholder discussion) and <slug>-context (the slug-
# derivation section) today, so an unanchored search would pass on content
# that has nothing to do with stamping the eval templates.
STAMPING_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"$STAMPING_JOINED")"
EVAL_ANCHOR_WINDOW="$(window_after "$STAMPING_LOWER" 'eval' 8000)"

if grep -qF '<area-domain>' <<<"$EVAL_ANCHOR_WINDOW" \
    && grep -qE '<(contextualizer-)?slug>-context' <<<"$EVAL_ANCHOR_WINDOW"; then
  pass "stamping doc replaces the templates' <area-domain> placeholder with the stamped contextualizer's own <slug>-context name"
else
  fail "stamping doc replaces the templates' <area-domain> placeholder with the stamped contextualizer's own <slug>-context name"
fi

# ---------------------------------------------------------------------------
# evals.json is stamped seeded — one entry per registered source, in
# registration order, each entry's query/expected/notes non-empty and
# shaped as a labeled placeholder.
# ---------------------------------------------------------------------------

section "evals.json seeded with one placeholder entry per registered source"

EVALS_JSON_WINDOW="$(window_after "$STAMPING_JOINED" 'evals.json' 1600)"

if grep -qF 'evals.json' <<<"$STAMPING_JOINED" \
    && grep -qE 'schema_version["`: ]{0,10}1\b' <<<"$EVALS_JSON_WINDOW" \
    && grep -qiE 'single file|not the train.{0,20}test|not.{0,10}split' <<<"$EVALS_JSON_WINDOW"; then
  pass "stamping doc says a single evals.json (schema_version 1), not the train/test split, is stamped"
else
  fail "stamping doc says a single evals.json (schema_version 1), not the train/test split, is stamped"
fi

if grep -qiE 'one entry per (registered )?source' <<<"$EVALS_JSON_WINDOW" \
    && grep -qiE 'registration order|order (they were )?registered|order supplied|same order' <<<"$EVALS_JSON_WINDOW"; then
  pass "stamping doc says exactly one entry per registered source, in registration order"
else
  fail "stamping doc says exactly one entry per registered source, in registration order"
fi

if grep -qi 'query' <<<"$EVALS_JSON_WINDOW" \
    && grep -qiE 'contains.{0,15}id|id.{0,15}substring|substring' <<<"$EVALS_JSON_WINDOW"; then
  pass "stamping doc says each entry's query contains the source's id as a substring"
else
  fail "stamping doc says each entry's query contains the source's id as a substring"
fi

if grep -qi 'expected' <<<"$EVALS_JSON_WINDOW" \
    && grep -qiE "equal|same as|set to|matches the source|source.?s own id" <<<"$EVALS_JSON_WINDOW"; then
  pass "stamping doc says each entry's expected field is set to the source's own id"
else
  fail "stamping doc says each entry's expected field is set to the source's own id"
fi

if grep -qi 'notes' <<<"$EVALS_JSON_WINDOW" \
    && grep -qiE 'placeholder|seed' <<<"$EVALS_JSON_WINDOW" \
    && grep -qi 'discover' <<<"$EVALS_JSON_WINDOW" \
    && grep -qiE 'correct|real reference' <<<"$EVALS_JSON_WINDOW"; then
  pass "stamping doc says each entry's notes flag the bootstrap-seeded placeholder and point at correcting expected after discover runs"
else
  fail "stamping doc says each entry's notes flag the bootstrap-seeded placeholder and point at correcting expected after discover runs"
fi

# ---------------------------------------------------------------------------
# engine-bootstrap's own documentation says the harness is stamped, not left
# to a doc reference nobody acts on.
# ---------------------------------------------------------------------------

section "engine-bootstrap's own docs say the harness is stamped, not just documented"

STAMP_LIST_REGION="$(extract_between 'Copy the following files' '### Stamping' "$STAMPING_REF" | join_lines)"

if grep -qi 'eval' <<<"$STAMP_LIST_REGION"; then
  pass "the Step 3 file list in stamping-and-templates.md names evals/ alongside the other four stamped items"
else
  fail "the Step 3 file list in stamping-and-templates.md names evals/ alongside the other four stamped items"
fi

EVAL_ROWS="$(grep -E '`eval/(run-eval\.sh|eval-viewer\.html|render-eval-results\.sh)\.template`' "$TEMPLATES_README" || true)"

if [ -n "$EVAL_ROWS" ] && ! grep -qiE "not\\*\\* stamped|not stamped" <<<"$EVAL_ROWS"; then
  pass "engine-bootstrap-templates/README.md no longer marks any eval/*.template row 'not stamped by engine-bootstrap'"
else
  fail "engine-bootstrap-templates/README.md no longer marks any eval/*.template row 'not stamped by engine-bootstrap'"
fi

if grep -qF 'stamps four things' "$TEMPLATES_README"; then
  fail "engine-bootstrap-templates/README.md's intro no longer says bootstrap 'stamps four things'"
else
  pass "engine-bootstrap-templates/README.md's intro no longer says bootstrap 'stamps four things'"
fi

# ---------------------------------------------------------------------------
# The exit message names the new harness, and the instruction governing its
# line count is updated in lockstep so the two do not drift apart.
# ---------------------------------------------------------------------------

section "exit message names the new harness"

STEP4_SECTION="$(extract_section 'Step 4' "$SKILL_MD")"
FENCED_BLOCK="$(awk '/^```/{c++; if (c == 1) next; if (c == 2) exit} c == 1 {print}' <<<"$STEP4_SECTION")"
INTRO_TEXT="$(awk '/^```/{exit} {print}' <<<"$STEP4_SECTION" | join_lines)"
FENCED_JOINED="$(join_lines <<<"$FENCED_BLOCK")"

if grep -qi 'eval' <<<"$FENCED_JOINED" && grep -qiE 'seed|corpus|starting' <<<"$FENCED_JOINED"; then
  pass "the rendered exit message names the stamped eval harness and its seeded starting corpus"
else
  fail "the rendered exit message names the stamped eval harness and its seeded starting corpus"
fi

STATED_WORD="$(grep -oE 'exactly [A-Za-z]+ lines' <<<"$INTRO_TEXT" | head -1 | awk '{print $2}')"
STATED_NUM="$(word_to_int "${STATED_WORD:-}")"
ACTUAL_COUNT="$(printf '%s\n' "$FENCED_BLOCK" | grep -c '.')"

if [ -n "$STATED_NUM" ] && [ "$STATED_NUM" -eq "$ACTUAL_COUNT" ]; then
  pass "the 'render exactly N lines' instruction still matches the fenced message's actual line count"
else
  fail "the 'render exactly N lines' instruction still matches the fenced message's actual line count" \
    "instruction says '${STATED_WORD:-<none found>}', fenced block has $ACTUAL_COUNT line(s)"
fi

# ---------------------------------------------------------------------------
# The evaluation chapter doesn't contradict the new stamped behavior.
# ---------------------------------------------------------------------------

section "evaluation chapter doesn't contradict the new stamped behavior"

THREE_TEMPLATES_JOINED="$(extract_section 'The three templates' "$EVAL_DOC" | join_lines)"
EVAL_DOC_JOINED="$(join_lines < "$EVAL_DOC")"

if grep -qi 'automat' <<<"$THREE_TEMPLATES_JOINED"; then
  pass "'The three templates' section says engine-bootstrap copies them into a fresh contextualizer automatically"
else
  fail "'The three templates' section says engine-bootstrap copies them into a fresh contextualizer automatically"
fi

# Anchored on the first "seed" mention rather than searched across the whole
# chapter: the chapter already uses "placeholder" and "edit" in unrelated
# sentences today, so an unanchored co-occurrence check would risk passing
# on two facts that happen to both be true of the document but are not
# actually about the same sentence.
EVAL_DOC_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"$EVAL_DOC_JOINED")"
SEED_WINDOW="$(window_after "$EVAL_DOC_LOWER" 'seed' 400)"

if [ -n "$SEED_WINDOW" ] && grep -qE 'starting point|placeholder|edit' <<<"$SEED_WINDOW"; then
  pass "the chapter documents the bootstrap-seeded entries as an edited starting point, not a finished corpus"
else
  fail "the chapter documents the bootstrap-seeded entries as an edited starting point, not a finished corpus"
fi

if grep -qF 'Ship a fixed eval set. Each contextualizer authors its own.' "$EVAL_DOC"; then
  pass "the 'ship a fixed eval set' non-goal still holds"
else
  fail "the 'ship a fixed eval set' non-goal still holds"
fi

# ---------------------------------------------------------------------------
# Read-only guarantee: this oracle only greps/parses; it never edits any
# file it inspects.
# ---------------------------------------------------------------------------

section "read-only: files under test untouched"

AFTER_HASH="$(hash_watched)"

if [ "$BEFORE_HASH" = "$AFTER_HASH" ]; then
  pass "this run left the four shipped doc files byte-for-byte unchanged"
else
  fail "this run left the four shipped doc files byte-for-byte unchanged"
fi

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"

[ "$fail_count" -eq 0 ]
