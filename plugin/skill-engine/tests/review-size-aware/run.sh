#!/usr/bin/env bash
# Black-box test runner for the size-aware review gate.
#
# `review`'s second pass asks the reviewer for a set of disagreements. Two
# properties are under test here, plus the documents that carry them:
#
#   1. The number of disagreements asked for is a function of how big the
#      proposal actually is — the entries in `.review/manifest.json` whose
#      `status` is `added`, `modified` or `removed`. `unchanged` entries
#      describe the size of the *contextualizer*, not the size of the
#      *proposal*, and must not move the number. A three-file refresh of a
#      200-reference contextualizer is a small review.
#
#   2. When a proposal touches more than one catalog section, the
#      disagreements are written grouped by section rather than as one flat
#      ranked list, so a reviewer can sign off on the part of the corpus
#      they actually own.
#
# Both rules are executed here, not merely read. `review/SKILL.md` is a
# document an agent follows at runtime, so the deterministic half of each
# rule is carried in it as a shell expression this runner extracts and runs
# against fixture manifests and fixture navigators. The extraction contract
# is stated in full under "Extraction contract" below; it is deliberately
# plain so that an implementer can reproduce it by reading this header.
#
# The prose half is asserted wrap-normalized (every run of whitespace,
# newlines included, collapsed to one space) so that a phrase broken across
# two hand-wrapped lines still reads as present.
#
# ── Extraction contract ────────────────────────────────────────────────
#
# `plugin/skill-engine/skills/review/SKILL.md` carries exactly two fenced
# code blocks whose info strings are, respectively, `budget-rule` and
# `group-rule`. Each fence opens with three backticks immediately followed
# by the info string on a line of its own and closes with a bare
# three-backtick line. Each block's body is a self-contained shell script.
#
#   bash <budget-rule> <manifest.json>
#       Writes exactly one line to stdout: the lower bound, one space, the
#       upper bound — e.g. `5 9`. Exits 0. It counts the manifest's
#       `added`/`modified`/`removed` entries itself; nothing else is passed
#       to it, so the `unchanged`-exclusion rule lives inside the
#       expression rather than in its caller.
#
#   bash <group-rule> <manifest.json> <proposed-navigator> <live-navigator>
#       Writes `flat` or `grouped` on the first line, then one line per
#       group: the group's name, a tab, the number of counted entries in
#       it. A group's name is the text following `## Catalog: ` in the
#       navigator heading whose catalog row cites the entry — `acme` or
#       `acme/billing`. Counted entries no catalog row cites are collected
#       under the fixed name `Unattributed`. The group lines may appear in
#       any order. The verdict is `grouped` when more than one *named*
#       (non-`Unattributed`) group is present, and `flat` otherwise — the
#       unattributed residual never turns a single-section proposal into a
#       grouped one. `added` and `modified` entries are resolved against
#       the proposed navigator; `removed` entries against the live one,
#       which is the only navigator that can still cite them.
#
# ── What is expected to fail today ─────────────────────────────────────
#
# Everything. Neither expression exists yet, neither document carries the
# prose, and the gate in `tests/emission-gates/run.sh` still passes on an
# empty extraction. No assertion in this file holds at the commit it was
# written against; properties that already hold are exercised by mutation
# controls outside this file, not asserted here.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

REVIEW_SKILL="$PLUGIN_ROOT/skills/review/SKILL.md"
REVIEW_TEMPLATE="$PLUGIN_ROOT/engine-bootstrap-templates/REVIEW.md.template"
DELIVERY_DOC="$PLUGIN_ROOT/docs/04-delivery.md"

pass_count=0
fail_count=0
TAB="$(printf '\t')"

WORK="$(mktemp -d -t skill-engine-review-size-aware.XXXXXX)"
cleanup() { [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

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

report() {
  local ok="$1" label="$2"
  shift 2
  if [ "$ok" -eq 1 ]; then
    pass "$label"
  else
    fail "$label" "$@"
  fi
}

section() {
  printf '\n-- %s --\n' "$1"
}

# ── helpers ────────────────────────────────────────────────────────────

# normalize <text> — collapse every whitespace run, newlines included, to a
# single space. Hand-wrapped markdown breaks phrases across lines; a
# single-line grep would read correct prose as absent.
normalize() {
  printf '%s' "$1" | tr -s '[:space:]' ' '
}

# within <haystack> <needle-a> <needle-b> <window> — true when <needle-b>
# occurs within <window> characters after SOME occurrence of <needle-a>.
# Every occurrence of <needle-a> is tried, not just the first: "budget" and
# "disagreements" recur throughout the documents under test, and a window
# anchored on the first hit alone would silently skip the occurrence that
# actually carries the phrase. Written as an explicit walk rather than a
# bounded regex repetition so it is not subject to any grep's interval
# ceiling. Case-insensitive: whether a term is capitalised is a sentence
# accident, never the property under test.
#
# Named `within`, not `near`, on purpose. tests/near-helper-sigpipe/run.sh
# globs every suite for `^near()`, extracts it with `sed -n '/^near()/,/^}/p'`
# and evals it standalone against a ~1MB fixture with 32,000 anchors and a
# regex-alternation needle. That is a contract for one specific helper: the
# grep-pipeline shape, whose SIGPIPE hazard that suite exists to police. This
# helper is a different thing — a literal, case-insensitive bash walk, chosen
# precisely so it has no grep in it to be subject to BSD's 255-interval
# ceiling. Sharing the name would enlist it in a contract it was never written
# to meet, and did: it is quadratic on that fixture and matches literals, not
# alternations. Keep it self-contained too, so the extraction stays honest for
# whoever does write a `near()` here later.
within() {
  local hay a b span rest win
  hay="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  a="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
  b="$(printf '%s' "$3" | tr '[:upper:]' '[:lower:]')"
  span="$4"
  rest="$hay"
  while [ "${rest#*"$a"}" != "$rest" ]; do
    rest="${rest#*"$a"}"
    win="${rest:0:$span}"
    case "$win" in
      *"$b"*) return 0 ;;
    esac
  done
  return 1
}

# within_either <haystack> <needle-a> <needle-b> <window> — within() in either
# order. Which of two terms a sentence puts first is a writing choice, not
# a behaviour; only their proximity is being asserted.
within_either() {
  within "$1" "$2" "$3" "$4" || within "$1" "$3" "$2" "$4"
}

# extract_fence <file> <info-string> — the body of the first fenced block
# opened by three backticks plus exactly <info-string>.
extract_fence() {
  local file="$1" tag="$2"
  [ -f "$file" ] || return 0
  awk -v open="\`\`\`${tag}" '
    $0 == open && !inb { inb = 1; next }
    inb && $0 == "```" { exit }
    inb { print }
  ' "$file"
}

# count_fences <file> <info-string> — how many such fences the file opens.
count_fences() {
  local file="$1" tag="$2" found
  if [ ! -f "$file" ]; then
    printf '0'
    return 0
  fi
  # grep -c exits 1 on a zero count, which is not an error here.
  found="$(grep -cxF -- "\`\`\`${tag}" "$file" 2>/dev/null || true)"
  printf '%s' "${found:-0}"
}

# write_manifest <out> <counted> <unchanged> — a manifest carrying
# <counted> entries cycling through added/modified/removed plus <unchanged>
# entries that exist only to prove they do not move the budget.
write_manifest() {
  local out="$1" counted="$2" unchanged="$3"
  local i entry_status sep=''
  {
    printf '{\n  "schema_version": 1,\n  "entries": [\n'
    for ((i = 0; i < counted; i++)); do
      case $((i % 3)) in
        0) entry_status=added ;;
        1) entry_status=modified ;;
        *) entry_status=removed ;;
      esac
      printf '%s    {"path": "references/counted-%d.md", "status": "%s", "sha_before": %s, "sha_after": %s}' \
        "$sep" "$i" "$entry_status" \
        "$([ "$entry_status" = added ] && printf 'null' || printf '"b%d"' "$i")" \
        "$([ "$entry_status" = removed ] && printf 'null' || printf '"a%d"' "$i")"
      sep=$',\n'
    done
    for ((i = 0; i < unchanged; i++)); do
      printf '%s    {"path": "references/steady-%d.md", "status": "unchanged", "sha_before": "s%d", "sha_after": "s%d"}' \
        "$sep" "$i" "$i" "$i"
      sep=$',\n'
    done
    printf '\n  ]\n}\n'
  } > "$out"
}

# manifest_from_list <out> <path:status> ... — a manifest built from an
# explicit list, for the grouping fixtures where each entry's path has to
# line up with a catalog row.
manifest_from_list() {
  local out="$1"
  shift
  local item entry_path entry_status sep=''
  {
    printf '{\n  "schema_version": 1,\n  "entries": [\n'
    for item in "$@"; do
      entry_path="${item%%:*}"
      entry_status="${item##*:}"
      printf '%s    {"path": "%s", "status": "%s", "sha_before": %s, "sha_after": %s}' \
        "$sep" "$entry_path" "$entry_status" \
        "$([ "$entry_status" = added ] && printf 'null' || printf '"b"')" \
        "$([ "$entry_status" = removed ] && printf 'null' || printf '"a"')"
      sep=$',\n'
    done
    printf '\n  ]\n}\n'
  } > "$out"
}

# nav_open <file> <name> — navigator frontmatter plus the catalog
# container every per-section heading nests under.
nav_open() {
  local file="$1" name="$2"
  {
    printf -- '---\n'
    printf 'name: %s-context\n' "$name"
    printf 'description: Fixture navigator.\n'
    printf -- '---\n\n# %s\n\n## Catalog\n\n' "$name"
  } > "$file"
}

# nav_section <file> <section-name> <ref-path> ... — one
# `## Catalog: <section-name>` block whose rows cite the given paths.
nav_section() {
  local file="$1" name="$2"
  shift 2
  local ref
  {
    printf '## Catalog: %s\n\n' "$name"
    printf '| Reference | When to read |\n|---|---|\n'
    for ref in "$@"; do
      printf '| [%s](%s) | fixture |\n' "$(basename "$ref" .md)" "$ref"
    done
    printf '\n'
  } >> "$file"
}

BUDGET_EXPR="$WORK/budget-rule.sh"
GROUP_EXPR="$WORK/group-rule.sh"
extract_fence "$REVIEW_SKILL" budget-rule > "$BUDGET_EXPR"
extract_fence "$REVIEW_SKILL" group-rule > "$GROUP_EXPR"

# run_budget <manifest> — the extracted budget expression's stdout, or
# nothing at all when there is no expression to run.
run_budget() {
  [ -s "$BUDGET_EXPR" ] || return 1
  bash "$BUDGET_EXPR" "$1" 2>/dev/null
}

# run_group <manifest> <proposed-nav> <live-nav>
run_group() {
  [ -s "$GROUP_EXPR" ] || return 1
  bash "$GROUP_EXPR" "$1" "$2" "$3" 2>/dev/null
}

review_flat="$(normalize "$(cat "$REVIEW_SKILL" 2>/dev/null)")"
template_flat="$(normalize "$(cat "$REVIEW_TEMPLATE" 2>/dev/null)")"
delivery_flat="$(normalize "$(cat "$DELIVERY_DOC" 2>/dev/null)")"

# ── budget scales with counted entries ─────────────────────────────────

section "budget scales with counted entries"

ok=0
[ "$(count_fences "$REVIEW_SKILL" budget-rule)" -eq 1 ] && ok=1
report "$ok" "the budget rule is carried in review/SKILL.md as exactly one runnable budget-rule block" \
  "found $(count_fences "$REVIEW_SKILL" budget-rule) such fenced blocks"

# <label> <counted> <unchanged> <expected-lower> <expected-upper>
#
# 40 and 41 straddle the step boundary; 500 is above the point where the
# window stops moving. Each fixture carries unchanged entries alongside the
# counted ones, and the 12-entry fixture is deliberately dwarfed by them:
# 200 files in the contextualizer, 12 of them in this proposal.
while read -r label counted unchanged lo hi; do
  [ -n "$label" ] || continue
  manifest="$WORK/manifest-$label.json"
  write_manifest "$manifest" "$counted" "$unchanged"
  out="$(run_budget "$manifest")"
  ok=0
  [ "$out" = "$lo $hi" ] && ok=1
  report "$ok" "$counted counted entries alongside $unchanged unchanged ones ask for $lo-$hi disagreements" \
    "budget rule printed: ${out:-<nothing>}"
done <<'FIXTURES'
n12 12 188 5 9
n40 40 30 5 9
n41 41 37 7 11
n120 120 4 9 13
n500 500 12 21 25
FIXTURES

# A manifest the block cannot count must not read as a small proposal.
# The block opened `set -u` with no `set -e`, and `json.load(fh)["entries"]`
# is unguarded — so a missing, unparseable or entries-less manifest sent a
# traceback to stderr, left `n` empty, and bash arithmetic evaluated the
# empty operand as 0: `5 9`, exit 0. That is the floor, and also exactly
# what a legitimately small proposal prints, so a 5,000-entry proposal
# whose manifest is malformed would be reviewed at the smallest budget with
# nothing in the output saying the count had failed. The whole point of the
# feature is that the ask tracks the proposal's size.
#
# run_budget_rc <manifest> — the block's stdout in BUDGET_OUT and its exit
# status in BUDGET_RC, stderr discarded.
BUDGET_OUT=""
BUDGET_RC=0
run_budget_rc() {
  BUDGET_OUT="$(bash "$BUDGET_EXPR" "$1" 2>/dev/null)"
  BUDGET_RC=$?
}

if [ -s "$BUDGET_EXPR" ]; then
  printf '{"schema_version":1}\n' > "$WORK/manifest-no-entries.json"
  printf 'not json at all\n' > "$WORK/manifest-unparseable.json"

  for bad in no-entries unparseable missing; do
    case "$bad" in
      missing) target="$WORK/manifest-does-not-exist.json" ;;
      *)       target="$WORK/manifest-$bad.json" ;;
    esac
    run_budget_rc "$target"
    ok=1
    [ "$BUDGET_RC" -ne 0 ] || ok=0
    [ "$BUDGET_OUT" = "5 9" ] && ok=0
    report "$ok" "a $bad manifest fails the budget rule instead of silently printing the floor" \
      "budget rule printed: ${BUDGET_OUT:-<nothing>} (exit $BUDGET_RC)"
  done

  # Paired with the good case, so the assertions above cannot be satisfied
  # by a block that fails on everything.
  write_manifest "$WORK/manifest-good.json" 12 188
  run_budget_rc "$WORK/manifest-good.json"
  ok=1
  [ "$BUDGET_RC" -eq 0 ] || ok=0
  [ "$BUDGET_OUT" = "5 9" ] || ok=0
  report "$ok" "a countable manifest still prints its window and exits 0" \
    "budget rule printed: ${BUDGET_OUT:-<nothing>} (exit $BUDGET_RC)"

  # And the ceiling still clamps — the lines that clamp it are the ones
  # errexit is most likely to trip over.
  write_manifest "$WORK/manifest-huge.json" 5000 0
  run_budget_rc "$WORK/manifest-huge.json"
  ok=1
  [ "$BUDGET_RC" -eq 0 ] || ok=0
  [ "$BUDGET_OUT" = "21 25" ] || ok=0
  report "$ok" "a proposal above the cap still prints the ceiling pair and exits 0" \
    "budget rule printed: ${BUDGET_OUT:-<nothing>} (exit $BUDGET_RC)"
fi

# The counted set is a stated rule in the document, not an accident of the
# expression: the three counting statuses are named, and the exclusion of
# unchanged from the count is written down.
ok=1
printf '%s' "$review_flat" | grep -qiE 'counted entr' || ok=0
within_either "$review_flat" 'counted' 'added' 250 || ok=0
within_either "$review_flat" 'counted' 'removed' 250 || ok=0
report "$ok" "review/SKILL.md names the counted entries as the added, modified and removed ones"

ok=0
if within_either "$review_flat" 'unchanged' 'counted' 250 \
  || within_either "$review_flat" 'unchanged' 'excluded' 250; then
  ok=1
fi
report "$ok" "review/SKILL.md states that unchanged entries are excluded from the count"

# The table's own rows. Each bound pair is written adjacently, whatever
# dash or separator joins them; all four are required together so that the
# pair that happens to be the old fixed wording cannot carry the assertion
# on its own.
ok=1
printf '%s' "$review_flat" | grep -qE '5[^0-9]{1,5}9' || ok=0
printf '%s' "$review_flat" | grep -qE '7[^0-9]{1,5}11' || ok=0
printf '%s' "$review_flat" | grep -qE '9[^0-9]{1,5}13' || ok=0
printf '%s' "$review_flat" | grep -qE '21[^0-9]{1,5}25' || ok=0
report "$ok" "review/SKILL.md tabulates the rising window: 5-9, 7-11, 9-13, up to 21-25"

ok=0
within_either "$review_flat" 'cap' '25' 250 && ok=1
report "$ok" "review/SKILL.md states the ceiling the window stops rising at"

# ── the second pass reads the budget, it does not recite it ────────────

section "the second pass reads the budget, it does not recite it"

# The two numbered steps of the second pass must stop hard-coding a single
# pair of numbers in their own headings: the number asked for is whatever
# the manifest in front of the reviewer works out to. This is also what
# keeps a downstream extraction anchored on those headings honest.
second_pass_headings="$(awk '
  /^## Second pass/ { p = 1; next }
  /^## / { p = 0 }
  p && /^[0-9]+\. \*\*/ { print }
' "$REVIEW_SKILL")"

if [ -z "$second_pass_headings" ]; then
  fail "fixture error: no numbered step headings found under the second pass in $REVIEW_SKILL"
else
  ok=1
  printf '%s' "$second_pass_headings" | grep -oE '^[0-9]+\. \*\*[^*]*\*\*' \
    | grep -qE '5[^0-9]{1,5}9' && ok=0
  report "$ok" "the second pass's step headings name the budget rather than a fixed pair of numbers"
fi

# ── grouping by catalog section ────────────────────────────────────────

section "grouping by catalog section"

ok=0
[ "$(count_fences "$REVIEW_SKILL" group-rule)" -eq 1 ] && ok=1
report "$ok" "the grouping rule is carried in review/SKILL.md as exactly one runnable group-rule block" \
  "found $(count_fences "$REVIEW_SKILL" group-rule) such fenced blocks"

# Fixture A — two sections, one written in each of the two shipped catalog
# heading shapes: a plain source slug and a slug/slice-id pair. Both are
# cited by the proposed navigator.
fixture_a="$WORK/two-sections"
mkdir -p "$fixture_a"
nav_open "$fixture_a/proposed.md" acme
nav_section "$fixture_a/proposed.md" acme references/acme-api.md references/acme-cli.md
nav_section "$fixture_a/proposed.md" acme/billing references/billing-invoices.md
cp "$fixture_a/proposed.md" "$fixture_a/live.md"
manifest_from_list "$fixture_a/manifest.json" \
  'references/acme-api.md:modified' \
  'references/acme-cli.md:added' \
  'references/billing-invoices.md:added' \
  'references/steady.md:unchanged'
out="$(run_group "$fixture_a/manifest.json" "$fixture_a/proposed.md" "$fixture_a/live.md")"
ok=1
[ "$(printf '%s\n' "$out" | head -1)" = "grouped" ] || ok=0
printf '%s\n' "$out" | grep -qxF "acme${TAB}2" || ok=0
printf '%s\n' "$out" | grep -qxF "acme/billing${TAB}1" || ok=0
report "$ok" "a proposal spanning two catalog sections groups under both heading shapes, each with its counted-entry count" \
  "grouping rule printed: ${out:-<nothing>}"

# Fixture B — the purge. Thirty references are dropped from one section and
# a handful added under another. No catalog row in the PROPOSED navigator
# can cite a dropped path, by definition: a path is removed precisely
# because the proposed catalog stopped citing it. The live navigator is the
# only place those thirty entries can be attributed from. Resolving them
# against the proposed navigator instead files all thirty as unattributed,
# which is the largest proposal shape a reviewer ever sees, mislabelled.
fixture_b="$WORK/purge"
mkdir -p "$fixture_b"
purged=()
for i in $(seq 1 30); do purged+=("references/acme-legacy-$i.md"); done
nav_open "$fixture_b/live.md" acme
nav_section "$fixture_b/live.md" acme "${purged[@]}"
nav_section "$fixture_b/live.md" acme/billing references/billing-invoices.md
nav_open "$fixture_b/proposed.md" acme
nav_section "$fixture_b/proposed.md" acme/billing references/billing-invoices.md references/billing-dunning.md
entries=()
for ref in "${purged[@]}"; do entries+=("$ref:removed"); done
entries+=('references/billing-invoices.md:modified' 'references/billing-dunning.md:added')
manifest_from_list "$fixture_b/manifest.json" "${entries[@]}"
out="$(run_group "$fixture_b/manifest.json" "$fixture_b/proposed.md" "$fixture_b/live.md")"
ok=1
[ "$(printf '%s\n' "$out" | head -1)" = "grouped" ] || ok=0
printf '%s\n' "$out" | grep -qxF "acme${TAB}30" || ok=0
printf '%s\n' "$out" | grep -qxF "acme/billing${TAB}2" || ok=0
printf '%s\n' "$out" | grep -qF "Unattributed" && ok=0
report "$ok" "thirty references purged from one section are attributed to that section, not left unattributed" \
  "grouping rule printed: ${out:-<nothing>}"

# Fixture C — one cited section plus entries no catalog row cites: the
# research directory and the navigator itself. The residual is a group, but
# it is not a second opinion-holder, so it must not by itself turn a
# single-section proposal into a grouped one.
fixture_c="$WORK/residual"
mkdir -p "$fixture_c"
nav_open "$fixture_c/proposed.md" acme
nav_section "$fixture_c/proposed.md" acme references/acme-api.md references/acme-cli.md
cp "$fixture_c/proposed.md" "$fixture_c/live.md"
manifest_from_list "$fixture_c/manifest.json" \
  'references/acme-api.md:modified' \
  'references/acme-cli.md:modified' \
  'research/source-paths.json:modified' \
  'SKILL.md:modified'
out="$(run_group "$fixture_c/manifest.json" "$fixture_c/proposed.md" "$fixture_c/live.md")"
ok=1
[ "$(printf '%s\n' "$out" | head -1)" = "flat" ] || ok=0
printf '%s\n' "$out" | grep -qxF "acme${TAB}2" || ok=0
printf '%s\n' "$out" | grep -qxF "Unattributed${TAB}2" || ok=0
report "$ok" "entries no catalog row cites form a residual group that does not by itself trigger grouping" \
  "grouping rule printed: ${out:-<nothing>}"

# Fixture D — the small proposal, unchanged behaviour: twelve counted
# entries in a 200-file contextualizer, all in one section. A flat list and
# the smallest window.
fixture_d="$WORK/small"
mkdir -p "$fixture_d"
small_paths=()
for i in $(seq 1 12); do small_paths+=("references/acme-$i.md"); done
nav_open "$fixture_d/proposed.md" acme
nav_section "$fixture_d/proposed.md" acme "${small_paths[@]}"
cp "$fixture_d/proposed.md" "$fixture_d/live.md"
entries=()
for ref in "${small_paths[@]}"; do entries+=("$ref:modified"); done
for i in $(seq 1 188); do entries+=("references/steady-$i.md:unchanged"); done
manifest_from_list "$fixture_d/manifest.json" "${entries[@]}"
out="$(run_group "$fixture_d/manifest.json" "$fixture_d/proposed.md" "$fixture_d/live.md")"
budget_out="$(run_budget "$fixture_d/manifest.json")"
ok=1
[ "$(printf '%s\n' "$out" | head -1)" = "flat" ] || ok=0
printf '%s\n' "$out" | grep -qxF "acme${TAB}12" || ok=0
[ "$budget_out" = "5 9" ] || ok=0
report "$ok" "a twelve-entry proposal in one catalog section keeps a flat list and the smallest window" \
  "grouping rule printed: ${out:-<nothing>}" \
  "budget rule printed: ${budget_out:-<nothing>}"

# Fixture E — the directory form. A multimodal reference is a DIRECTORY
# containing a canonical primary `.md` of the same basename plus its
# assets, and `02-artifact-contract.md` makes it first-class: the catalog
# row's target carries a trailing slash, while every manifest entry under
# it carries a full file path. Those two strings never agree, so raw string
# equality files every byte of a multimodal reference under the residual —
# and a refresh touching only directory-form references in two sections
# computes no named groups at all and prints `flat`, dropping the
# per-owner sub-headings the whole feature exists to produce.
#
# Both resolution directions are exercised in one fixture: `added` and
# `modified` entries against the proposed navigator, and a `removed`
# directory-form reference against the live one.
fixture_e="$WORK/directory-form"
mkdir -p "$fixture_e"
nav_open "$fixture_e/live.md" acme
nav_section "$fixture_e/live.md" acme \
  references/acme-api.md references/acme-diagrams/ references/acme-legacy-pack/
nav_section "$fixture_e/live.md" acme/billing references/billing-refunds/
nav_open "$fixture_e/proposed.md" acme
nav_section "$fixture_e/proposed.md" acme \
  references/acme-api.md references/acme-diagrams/
nav_section "$fixture_e/proposed.md" acme/billing references/billing-refunds/
manifest_from_list "$fixture_e/manifest.json" \
  'references/acme-api.md:modified' \
  'references/acme-diagrams/acme-diagrams.md:modified' \
  'references/acme-diagrams/flow.svg:added' \
  'references/acme-legacy-pack/acme-legacy-pack.md:removed' \
  'references/acme-legacy-pack/schema.png:removed' \
  'references/billing-refunds/billing-refunds.md:added'
out="$(run_group "$fixture_e/manifest.json" "$fixture_e/proposed.md" "$fixture_e/live.md")"
ok=1
[ "$(printf '%s\n' "$out" | head -1)" = "grouped" ] || ok=0
printf '%s\n' "$out" | grep -qxF "acme${TAB}5" || ok=0
printf '%s\n' "$out" | grep -qxF "acme/billing${TAB}1" || ok=0
printf '%s\n' "$out" | grep -qF "Unattributed" && ok=0
report "$ok" "a directory-form reference's primary and its assets are attributed to the section citing the directory" \
  "grouping rule printed: ${out:-<nothing>}"

# Fixture F — the shape the consequence is stated in: a refresh that
# touches ONLY directory-form references, in two different sections. Under
# raw string equality this prints `flat` with everything residual, which is
# indistinguishable from a single-section proposal.
fixture_f="$WORK/directory-form-only"
mkdir -p "$fixture_f"
nav_open "$fixture_f/proposed.md" acme
nav_section "$fixture_f/proposed.md" acme references/acme-diagrams/
nav_section "$fixture_f/proposed.md" acme/billing references/billing-refunds/
cp "$fixture_f/proposed.md" "$fixture_f/live.md"
manifest_from_list "$fixture_f/manifest.json" \
  'references/acme-diagrams/acme-diagrams.md:modified' \
  'references/billing-refunds/billing-refunds.md:modified'
out="$(run_group "$fixture_f/manifest.json" "$fixture_f/proposed.md" "$fixture_f/live.md")"
ok=1
[ "$(printf '%s\n' "$out" | head -1)" = "grouped" ] || ok=0
printf '%s\n' "$out" | grep -qxF "acme${TAB}1" || ok=0
printf '%s\n' "$out" | grep -qxF "acme/billing${TAB}1" || ok=0
report "$ok" "a proposal of nothing but directory-form references still groups by section rather than collapsing to flat" \
  "grouping rule printed: ${out:-<nothing>}"

# The grouping rule is documented, not only executed.
ok=1
printf '%s' "$review_flat" | grep -qE 'Catalog: <[a-z-]+>[^/]' || ok=0
printf '%s' "$review_flat" | grep -qE 'Catalog: <[a-z-]+>/<[a-z-]+>' || ok=0
report "$ok" "review/SKILL.md names both catalog heading shapes a group can come from"

ok=1
printf '%s' "$review_flat" | grep -qi 'live navigator' || ok=0
within_either "$review_flat" 'removed' 'live navigator' 250 || ok=0
report "$ok" "review/SKILL.md states that removed entries are resolved against the live navigator"

ok=0
if within_either "$review_flat" 'residual' 'never' 250 \
  || within_either "$review_flat" 'unattributed' 'never' 250; then
  ok=1
fi
report "$ok" "review/SKILL.md states that the residual group never triggers grouping on its own"

ok=1
printf '%s' "$review_flat" | grep -qiE 'sub-?heading' || ok=0
within_either "$review_flat" 'group' 'flat' 250 || ok=0
report "$ok" "review/SKILL.md states that one group stays a flat list and more than one gets a sub-heading each"

# ── the reviewer's own copy says the same thing ────────────────────────

section "the reviewer's own copy says the same thing"

ok=1
printf '%s' "$template_flat" | grep -qi 'budget' || ok=0
within_either "$template_flat" 'budget' 'counted' 250 || ok=0
report "$ok" "REVIEW.md.template explains that the number of disagreements follows the proposal's counted entries"

ok=1
printf '%s' "$template_flat" | grep -qiE 'sub-?heading|grouped' || ok=0
within_either "$template_flat" 'catalog' 'group' 250 || ok=0
report "$ok" "REVIEW.md.template documents the grouped form of the disagreement set"

ok=1
printf '%s' "$template_flat" | grep -qi 'density' || ok=0
printf '%s' "$template_flat" | grep -qiF 'Re-emit candidates' || ok=0
within_either "$template_flat" 'density' 'report-only' 250 || ok=0
within_either "$template_flat" 're-emit candidates' 'report-only' 250 || ok=0
report "$ok" "REVIEW.md.template keeps the density and re-emit-candidate lines report-only and outside the budget"

# ── who signs what ─────────────────────────────────────────────────────

section "who signs what"

ok=1
within_either "$delivery_flat" 'owner' 'sign' 250 || ok=0
printf '%s' "$delivery_flat" | grep -qF 'source-paths.json' || ok=0
report "$ok" "04-delivery.md states that a contextualizer's recorded owner signs its own proposals"

ok=1
printf '%s' "$delivery_flat" | grep -qi 'provisional' || ok=0
within_either "$delivery_flat" 'provisional' 'spot' 250 || ok=0
report "$ok" "04-delivery.md describes a platform team spot-checking by applying under the provisional tier"

ok=0
within_either "$delivery_flat" 'provisional' 'reviewed' 250 && ok=1
report "$ok" "04-delivery.md states that a reviewer who is not the recorded owner ticks provisional rather than reviewed"

ok=1
printf '%s' "$review_flat" | grep -qi 'owner' || ok=0
if ! within_either "$review_flat" 'owner' 'absent' 250 \
  && ! within_either "$review_flat" 'owner' 'not recorded' 250; then
  ok=0
fi
report "$ok" "review/SKILL.md names the recorded owner in the second pass and stays silent when none is recorded"

# ── vacuous-extraction gate ────────────────────────────────────────────

section "vacuous-extraction gate"

# A sibling suite checks that the density figure is not ranked as a
# disagreement category, by extracting the second pass's category block
# between two numbered step headings and grepping the extraction. Rename
# either heading and the extraction is empty — and a grep for an unwanted
# word over an empty string reports the good news. The check has to treat
# an empty extraction as a failure, or it reports PASS over a file it never
# read.
#
# That suite derives its own plugin root from where it sits, so the only
# honest way to ask the question is to copy the plugin tree, break the copy
# and run the copy's suite. The break is located structurally — the first
# numbered step heading under the second pass, whatever it is called today
# — so that renaming that heading for any reason does not quietly turn this
# assertion into a no-op.
mutate_first_step_heading() {
  local file="$1" target
  target="$(awk '/^## Second pass/ { p = 1 } p && /^2\. \*\*/ { print NR; exit }' "$file")"
  [ -n "$target" ] || return 1
  awk -v n="$target" '
    NR == n { sub(/^2\. \*\*[^*]*\*\*/, "2. **A step under a different name**") }
    { print }
  ' "$file" > "$file.mutated" || return 1
  mv "$file.mutated" "$file"
}

gate_pristine="$WORK/gate-pristine"
gate_broken="$WORK/gate-broken"
mkdir -p "$gate_pristine" "$gate_broken"
cp -R "$PLUGIN_ROOT" "$gate_pristine/plugin"
cp -R "$PLUGIN_ROOT" "$gate_broken/plugin"

broken_skill="$gate_broken/plugin/skills/review/SKILL.md"
if ! mutate_first_step_heading "$broken_skill"; then
  fail "fixture error: could not locate the first numbered step heading under the second pass"
elif cmp -s "$broken_skill" "$gate_pristine/plugin/skills/review/SKILL.md"; then
  fail "fixture error: renaming the step heading left the navigator byte-identical"
else
  bash "$gate_pristine/plugin/tests/emission-gates/run.sh" >/dev/null 2>&1
  rc_pristine=$?
  bash "$gate_broken/plugin/tests/emission-gates/run.sh" >/dev/null 2>&1
  rc_broken=$?
  ok=1
  [ "$rc_pristine" -eq 0 ] || ok=0
  [ "$rc_broken" -ne 0 ] || ok=0
  report "$ok" "renaming the step heading the category-block extraction is anchored on turns that check red instead of green" \
    "untouched copy exited $rc_pristine (want 0); renamed copy exited $rc_broken (want non-zero)"
fi

# ── summary ────────────────────────────────────────────────────────────

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
