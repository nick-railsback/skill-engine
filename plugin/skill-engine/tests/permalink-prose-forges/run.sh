#!/usr/bin/env bash
# Prose oracle for the forge-neutrality of the permalink definition.
#
# THE INVARIANT. Every surface that tells the model — or the reader — what a
# permalink *is* must describe it as the SHA-pinned form in the grammar of the
# source's own forge, with the github.com shape shown as a worked example
# rather than stated as the definition.
#
# WHY IT MATTERS. The density lint (SELF-AUDIT Check 7) and the
# grounded-citation eval (Check 8) credit a SHA-pinned permalink on any
# hostname the contextualizer registers, in the grammar that forge serves. If
# the prose still calls that "a GitHub permalink", a maintainer whose sources
# live on GitHub Enterprise Server, GitLab, Bitbucket or Azure DevOps is
# instructed to emit a citation shape their forge cannot produce — and the
# engine's central trust claim degrades to "every paragraph is unverified" for
# them on day one.
#
# THE SURFACES. Eleven tracked prose files carry that definition: the artifact
# contract (twice — the canonical-form section and the Claims-policy contract
# summary), the DISCOVER pipeline chapter, the coverage-testing chapter, the
# engine chapter's SELF-AUDIT items, both navigator templates, the
# maintenance-agent template a hand-rolled install pastes as a system prompt,
# DISCOVER's post-run permalink guidance, the SELF-AUDIT router and its Check-7
# reference, and this repo's own dogfood navigator. They are enumerated in
# SCOPE below and every assertion here is confined to them. Nothing is asserted
# repo-wide, deliberately: "GitHub permalink" is a true, factual phrase in
# files this work may not edit — the dogfood reference corpus, the bundled
# examples, the corpus-refresh runner — so a repo-wide assertion could never go
# green. Because the checks are scope-limited, this runner's own directory
# needs no exclusion.
#
# DELIBERATE NON-GOAL. This runner does not transcribe the five forge URL
# grammars. Those are the density lint's subject, and the lint has its own
# runner; writing them here would fork one source of truth into two that can
# drift. What is asserted is that the prose *names* the forge families and
# routes the reader to the single place the grammars are written down.
#
# MATCHING DISCIPLINE. These are hard-wrapped markdown files, so every phrase
# assertion is wrap-normalized: newlines and whitespace runs collapse to one
# space before matching. A naive line-oriented grep silently misses any phrase
# that crosses a line break, which is how a prose check ships vacuous. The one
# deliberate exception is the pair of Claims-policy sentences the doctrine
# suite pins byte-for-byte in every bundled example: those are matched against
# raw bytes here too, because a template that rewrapped one would propagate the
# rewrap into the next stamped example and break that literal match.
#
# Cases are of two kinds and both are load-bearing. Some assert the
# forge-neutral wording; the rest assert what must NOT move — the ≥80% bar, the
# five-line window, the documented web-doc ceiling, the pinned sentences, the
# Check-7 definition chain's hops, the router byte ceilings.
#
# `set -e` is intentionally omitted: every assertion must run and report, not
# abort at the first failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Locate the repository root by a marker file, searching upward from this
# script's own directory first and from the working directory second, so the
# runner works both in place and when a copy is run from a checkout root.
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

# The prose surfaces under test, repo-relative. This mirrors a declared edit
# surface rather than a filesystem shape, so it cannot be discovered; it is the
# one list here that must be updated by hand when that surface moves. Where a
# set IS discoverable — the navigators — it is rebuilt from disk and compared.
SCOPE=(
  "plugin/skill-engine/docs/02-artifact-contract.md"
  "plugin/skill-engine/docs/08-discover-pipeline.md"
  "plugin/skill-engine/docs/13-coverage-testing.md"
  "plugin/skill-engine/docs/03-engine.md"
  "plugin/skill-engine/engine-bootstrap-templates/navigator.md.template"
  "plugin/skill-engine/engine-bootstrap-templates/navigator-multi-domain.md.template"
  "plugin/skill-engine/engine-bootstrap-templates/maintenance-agent.md.template"
  "plugin/skill-engine/skills/discover/references/proposal-and-post-run.md"
  "plugin/skill-engine/skills/self-audit/SKILL.md"
  "plugin/skill-engine/skills/self-audit/references/check-7-permalink-density.md"
  ".claude/skills/skill-engine-context/SKILL.md"
)

CONTRACT_DOC="$PLUGIN_ROOT/docs/02-artifact-contract.md"
PIPELINE_DOC="$PLUGIN_ROOT/docs/08-discover-pipeline.md"
COVERAGE_DOC="$PLUGIN_ROOT/docs/13-coverage-testing.md"
ENGINE_DOC="$PLUGIN_ROOT/docs/03-engine.md"
NAV_TPL="$PLUGIN_ROOT/engine-bootstrap-templates/navigator.md.template"
NAV_MULTI_TPL="$PLUGIN_ROOT/engine-bootstrap-templates/navigator-multi-domain.md.template"
MAINT_TPL="$PLUGIN_ROOT/engine-bootstrap-templates/maintenance-agent.md.template"
POST_RUN_REF="$PLUGIN_ROOT/skills/discover/references/proposal-and-post-run.md"
SELF_AUDIT_SKILL="$PLUGIN_ROOT/skills/self-audit/SKILL.md"
CHECK7_REF="$PLUGIN_ROOT/skills/self-audit/references/check-7-permalink-density.md"
DOGFOOD_NAV="$REPO_ROOT/.claude/skills/skill-engine-context/SKILL.md"
DISCOVER_SKILL="$PLUGIN_ROOT/skills/discover/SKILL.md"

# Every navigator the engine stamps or ships. Hard-coded so the runner stands
# alone, then rebuilt from disk below and compared — a navigator template added
# later, or a second contextualizer installed here, fails loudly instead of
# going unchecked.
NAVIGATORS=("$NAV_TPL" "$NAV_MULTI_TPL" "$DOGFOOD_NAV")

# The two Claims-policy sentences the doctrine suite pins byte-for-byte.
CLAIMS_SENTENCE_1="This inline permalink is what the grounded-citation eval (SELF-AUDIT Check 8) grades."
CLAIMS_SENTENCE_2="summary of what you read — not a substitute"

# Router byte ceiling and the self-audit combined floor the doctrine suite
# enforces, restated here so a break in a surface this work edits names itself
# instead of arriving as one opaque non-zero exit.
ROUTER_CEILING=8204
SELF_AUDIT_FLOOR=20290

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

# norm — collapse every whitespace run, newlines included, to a single space,
# then trim the ends. Every in-body phrase assertion runs through this.
norm() { tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'; }

# sect <start-ere> <end-ere> — from stdin, the lines from the first line
# matching <start-ere> (inclusive) to the next line matching <end-ere>
# (exclusive). Raw lines out, so a nested extraction can run on the result.
# The patterns use bracket expressions rather than backslash escapes: awk -v
# performs its own escape processing on the value, and an undefined escape is
# not portable across awk implementations.
sect() {
  awk -v s="$1" -v e="$2" '
    f && $0 ~ e { exit }
    $0 ~ s { f = 1 }
    f { print }
  '
}

# near <text> <anchor-ere> <needle-ere> <window> — true when needle occurs
# within <window> characters of some occurrence of anchor. Used where the
# assertion is a co-occurrence rather than an exact sentence. 240, not more:
# BSD grep rejects an interval bound above 255 and the window is applied on
# both sides.
near() {
  local text="$1" anchor="$2" needle="$3" window="$4"
  printf '%s' "$text" \
    | grep -oiE ".{0,${window}}${anchor}.{0,${window}}" \
    | grep -qiE -- "$needle"
}

# assert_has — case-insensitive regex. For assertions on wording rather than
# on an exact string.
assert_has() {
  local label="$1" text="$2" pat="$3"
  if printf '%s' "$text" | grep -qiE -- "$pat"; then
    pass "$label"
  else
    fail "$label" "no match for /$pat/"
  fi
}

# assert_str — exact literal, case-sensitive. The default: most of what is
# asserted here is a specific string, not a family of phrasings.
assert_str() {
  local label="$1" text="$2" lit="$3"
  if printf '%s' "$text" | grep -qF -- "$lit"; then
    pass "$label"
  else
    fail "$label" "string not found: $lit"
  fi
}

# assert_link <label> <text> <target> — a markdown link whose target is
# <target>, with or without a trailing #fragment. Both forms are house style
# and an accurate fragment is the better link, so neither may be the thing that
# reds this runner; a link to any other file still fails. The pattern is built
# from bracket expressions rather than backslash escapes so it reads the same
# under every grep on the matrix.
assert_link() {
  local label="$1" text="$2" target="$3"
  local esc pat
  esc="$(printf '%s' "$target" | sed 's/[.]/[.]/g')"
  pat="[]][(]${esc}(#[^)]*)?[)]"
  if printf '%s' "$text" | grep -qE -- "$pat"; then
    pass "$label"
  else
    fail "$label" "no markdown link to $target (with or without a #fragment)"
  fi
}

# assert_nonempty — a renamed heading must be a failure, not a green run: an
# absence assertion against an empty haystack passes vacuously.
assert_nonempty() {
  local label="$1" text="$2"
  if [ -n "$text" ]; then
    pass "$label"
  else
    fail "$label" "section markers not found — assertions below would run against an empty string"
  fi
}

banner "scope inventory: the prose surfaces that define a permalink"

for rel in "${SCOPE[@]}"; do
  if [ ! -f "$REPO_ROOT/$rel" ]; then
    fail "tracked and present: $rel" "file not found"
  elif ! (cd "$REPO_ROOT" && git ls-files --error-unmatch -- "$rel" >/dev/null 2>&1); then
    fail "tracked and present: $rel" "present but untracked — an edit here would ship to nobody"
  else
    pass "tracked and present: $rel"
  fi
done

banner "canonical permalink definition: the contract enumerates every forge grammar the lint credits"

CANON="$(sect '^#### SHA-pinned permalinks' '^#### When to keep' < "$CONTRACT_DOC" | norm)"
assert_nonempty "the contract's canonical-permalink section is extractable" "$CANON"

# The forge families the lint credits are named where the canonical form is
# defined, so a reader on any of them finds their own shape there rather than
# inferring that github.com is the only shape that counts.
assert_str "canonical form names the GitHub family" "$CANON" "GitHub"
assert_str "canonical form names GitLab" "$CANON" "GitLab"
assert_str "canonical form names Bitbucket Server" "$CANON" "Bitbucket Server"
assert_str "canonical form names Bitbucket Cloud" "$CANON" "Bitbucket Cloud"
assert_str "canonical form names Azure DevOps" "$CANON" "Azure DevOps"

# Where the 40-hex commit SHA sits in the path differs per forge, so each
# family named above carries a SHA placeholder near it. Proximity, not grammar:
# the exact URL shapes belong to the lint, not to this file.
for pair in \
  "GitHub family|github" \
  "GitLab|gitlab" \
  "Bitbucket Server|bitbucket server" \
  "Bitbucket Cloud|bitbucket cloud" \
  "Azure DevOps|azure devops"; do
  fam="${pair%%|*}"
  anchor="${pair#*|}"
  if near "$CANON" "$anchor" '(<sha>|<commit-sha>|40-hex|40 hex|40-char|40 char)' 240; then
    pass "canonical form shows where the commit SHA sits for: $fam"
  else
    fail "canonical form shows where the commit SHA sits for: $fam" \
      "no 40-hex-SHA placeholder within 240 chars of /$anchor/"
  fi
done

# Hostname acceptance is a property of what the maintainer registered, not a
# constant, so the registration file is named where the rule is stated.
assert_str "canonical form derives accepted hostnames from the registered sources" \
  "$CANON" "research/source-paths.json"
assert_str "canonical form keeps github.com accepted" "$CANON" "github.com"

banner "pipeline density chapter: routes to the contract instead of restating one forge's shape"

DENSITY_08="$(sect '^### Paragraph→permalink density' '^### ' < "$PIPELINE_DOC" | norm)"
assert_nonempty "the pipeline chapter's density section is extractable" "$DENSITY_08"

assert_link "density section routes the reader to the contract's grammar list" \
  "$DENSITY_08" "02-artifact-contract.md"
# Preservation: the bar and the window are inherited, never re-derived.
assert_str "density section keeps the ≥80% bar" "$DENSITY_08" "≥80%"
assert_str "density section keeps the five-line window" "$DENSITY_08" "within 5 lines"

banner "coverage chapter: the documented ceiling names non-github.com git hosts"

# The lint learns its accepted hostnames from the registration file, so the
# three sentences that told the reader otherwise are gone.
COVERAGE_ALL="$(norm < "$COVERAGE_DOC")"
STALE_1='GitHub-permalink density is a git-source metric'
STALE_2='The lint is flat and source-blind: it walks `references/**/*.md` and counts paragraphs against the same threshold regardless of where those paragraphs originated.'
STALE_3='The flatness is deliberate — a check that read a self-authored `source-paths.json` field to decide whether to grade you would be gradeable on your own answer key.'
i=0
for stale in "$STALE_1" "$STALE_2" "$STALE_3"; do
  i=$((i + 1))
  if printf '%s' "$COVERAGE_ALL" | grep -qF -- "$stale"; then
    fail "coverage chapter no longer says the lint credits one host, sentence $i" \
      "still present: ${stale:0:78}…"
  else
    pass "coverage chapter no longer says the lint credits one host, sentence $i"
  fi
done

SCOPING="$(sect '^### Threshold scoping' '^## ' < "$COVERAGE_DOC" | norm)"
assert_nonempty "the coverage chapter's threshold-scoping section is extractable" "$SCOPING"

assert_str "threshold scoping names GitLab as covered" "$SCOPING" "GitLab"
assert_str "threshold scoping names Bitbucket Server as covered" "$SCOPING" "Bitbucket Server"
assert_str "threshold scoping names Bitbucket Cloud as covered" "$SCOPING" "Bitbucket Cloud"
assert_str "threshold scoping names Azure DevOps as covered" "$SCOPING" "Azure DevOps"
assert_str "threshold scoping derives hostname acceptance from the registered sources" \
  "$SCOPING" "research/source-paths.json"
# What no registration field can relax stays stated: the bar itself, and the
# fact that grading is still blind to where a paragraph came from.
assert_str "threshold scoping still states the unrelaxable ≥80% bar" "$SCOPING" "≥80%"
assert_str "threshold scoping still names what stays source-blind" "$SCOPING" "source-blind"
# Preservation: a pure web-doc source set remains uncreditable, and saying so
# is the honest half of this section that an over-correction would delete.
assert_str "threshold scoping keeps the pure web-doc ceiling documented" \
  "$SCOPING" "could not be credited by this check at all"

banner "claims policy: every navigator the engine stamps or ships cites in the source forge's grammar"

# Enumeration guard: rebuild the navigator set from disk and compare.
discovered=()
while IFS= read -r f; do
  [ -n "$f" ] && discovered+=("$f")
done < <(
  {
    find "$PLUGIN_ROOT/engine-bootstrap-templates" -maxdepth 1 -name 'navigator*.md.template' 2>/dev/null
    find "$REPO_ROOT/.claude/skills" -maxdepth 2 -path '*-context/SKILL.md' 2>/dev/null
  } | LC_ALL=C sort
)
expected_navs="$(printf '%s\n' "${NAVIGATORS[@]}" | LC_ALL=C sort)"
discovered_navs=""
if [ "${#discovered[@]}" -gt 0 ]; then
  discovered_navs="$(printf '%s\n' "${discovered[@]}" | LC_ALL=C sort)"
fi
if [ "$expected_navs" = "$discovered_navs" ]; then
  pass "the navigators on disk are exactly the ones checked here"
else
  fail "the navigators on disk are exactly the ones checked here" \
    "$(printf 'checked:\n%s\non disk:\n%s' "$expected_navs" "$discovered_navs")"
fi

placeholder_sets=()
for nav in "${NAVIGATORS[@]}"; do
  rel="${nav#"$REPO_ROOT"/}"
  block_raw="$(sect '^## Claims policy' '^## ' < "$nav")"
  item1="$(printf '%s\n' "$block_raw" | sect '^1[.] ' '^2[.] ' | norm)"

  assert_nonempty "claims-policy item 1 is extractable: $rel" "$item1"

  # The citation shape the model is told to emit is its own source forge's,
  # not one named host's.
  assert_has "item 1 names the source forge: $rel" "$item1" 'forge'
  # Preservation: the github.com shape survives as the worked example.
  assert_str "item 1 keeps a github.com worked example: $rel" "$item1" "https://github.com/"

  # Byte-exact, deliberately un-normalized: these two sentences are matched
  # literally across every stamped example elsewhere in the suite, so a rewrap
  # here would propagate into the next stamped copy and break that match.
  for sentence in "$CLAIMS_SENTENCE_1" "$CLAIMS_SENTENCE_2"; do
    if grep -qF -- "$sentence" "$nav"; then
      pass "pinned claims sentence is byte-identical in $rel: \"${sentence:0:38}…\""
    else
      fail "pinned claims sentence is byte-identical in $rel: \"${sentence:0:38}…\"" \
        "raw-byte match failed — a reflow counts as a change here"
    fi
  done

  placeholder_sets+=("$(printf '%s\n' "$block_raw" | norm \
    | grep -oE 'https://github[.]com/[^ `]*' \
    | grep -E '<[^>]*>' | LC_ALL=C sort -u | tr '\n' ' ')")
done

# The contract's Claims-policy summary must agree with the navigators on the
# permalink shape, or the contract and the artifact it summarizes disagree
# about the one thing the grounded-citation eval grades.
CONTRACT_CLAIMS="$(sect '^## Claims policy' '^```$' < "$CONTRACT_DOC" | norm)"
assert_nonempty "the contract's claims-policy summary block is extractable" "$CONTRACT_CLAIMS"
assert_str "contract summary keeps the grading sentence on item 1" \
  "$CONTRACT_CLAIMS" "$CLAIMS_SENTENCE_1"

placeholder_sets+=("$(printf '%s' "$CONTRACT_CLAIMS" \
  | grep -oE 'https://github[.]com/[^ `]*' \
  | grep -E '<[^>]*>' | LC_ALL=C sort -u | tr '\n' ' ')")

distinct_sets="$(printf '%s\n' "${placeholder_sets[@]}" | LC_ALL=C sort -u)"
if [ "$(printf '%s\n' "$distinct_sets" | wc -l | tr -d ' ')" -eq 1 ]; then
  pass "every claims policy shows the same permalink placeholder set: $distinct_sets"
else
  fail "every claims policy shows the same permalink placeholder set" \
    "$(printf '%s\n' "${placeholder_sets[@]}")"
fi

banner "discover permalink guidance: routes to the contract instead of restating one forge's shape"

DENSITY_REF="$(sect '^## Paragraph→permalink density' '^## ' < "$POST_RUN_REF" | norm)"
assert_nonempty "the discover guidance's density section is extractable" "$DENSITY_REF"

# A local relative path, not a hosted permalink back into this repo: the
# doctrine suite forbids the latter from anything under skills/.
assert_link "density guidance routes the model to the contract's grammar list" \
  "$DENSITY_REF" "../../../docs/02-artifact-contract.md"
# Preservation: this is the text DISCOVER hands the model, so the bar it emits
# against and the window it measures do not move either.
assert_str "density guidance keeps the ≥80% bar" "$DENSITY_REF" "≥80%"
assert_str "density guidance keeps the five-line window" "$DENSITY_REF" "within 5 lines"

banner "definition chain: the Check-7 definition chain ends at the contract, not at one forge"

ENGINE_ITEM7="$(sect '^7[.] [*][*]Paragraph→permalink density' '^8[.] ' < "$ENGINE_DOC" | norm)"
assert_nonempty "the engine chapter's SELF-AUDIT item 7 is extractable" "$ENGINE_ITEM7"
assert_str "engine chapter item 7 still hands the reader to the self-audit router" \
  "$ENGINE_ITEM7" "self-audit/SKILL.md"
assert_str "engine chapter item 7 still names the section it hands off to" \
  "$ENGINE_ITEM7" "§ Check 7"

MAINT_ITEM7="$(sect '^7[.] [*][*]Paragraph→permalink density' '^8[.] ' < "$MAINT_TPL" | norm)"
assert_nonempty "the maintenance-agent prompt's item 7 is extractable" "$MAINT_ITEM7"
assert_str "maintenance-agent item 7 still hands the model to the self-audit router" \
  "$MAINT_ITEM7" "self-audit/SKILL.md"
assert_str "maintenance-agent item 7 still names the section it hands off to" \
  "$MAINT_ITEM7" "§ Check 7"

SA_CHECK7="$(sect '^## Check 7' '^## Check 8' < "$SELF_AUDIT_SKILL" | norm)"
assert_nonempty "the self-audit router's Check 7 section is extractable" "$SA_CHECK7"
assert_str "self-audit router still hands the reader to the Check-7 reference" \
  "$SA_CHECK7" "references/check-7-permalink-density.md"

WHAT_COUNTS="$(sect '^[*][*]What counts[.][*][*]' '^[*][*]Aggregation[.][*][*]' < "$CHECK7_REF" | norm)"
assert_nonempty "the Check-7 reference's what-counts block is extractable" "$WHAT_COUNTS"
# The end of the chain routes to the contract rather than restating the grammar
# list in a second place that can drift from it.
assert_link "the end of the chain routes to the contract's grammar list" \
  "$WHAT_COUNTS" "../../../docs/02-artifact-contract.md"

# Two claims a multi-forge lint makes false, absent from every surface.
FALSE_1='Unpinned `blob/main/...` URLs and non-GitHub URLs do not satisfy the density check.'
FALSE_2='The permalink regex is imported from the Check 7 lint so the two checks share one source of truth.'
j=0
for falsehood in "$FALSE_1" "$FALSE_2"; do
  j=$((j + 1))
  offenders=""
  for rel in "${SCOPE[@]}"; do
    [ -f "$REPO_ROOT/$rel" ] || continue
    if norm < "$REPO_ROOT/$rel" | grep -qF -- "$falsehood"; then
      offenders+="$rel"$'\n'
    fi
  done
  if [ -z "$offenders" ]; then
    pass "no surface still makes the single-grammar claim, sentence $j"
  else
    fail "no surface still makes the single-grammar claim, sentence $j" \
      "${falsehood:0:78}…" "$(printf '%s' "$offenders")"
  fi
done

banner "example marker: no surface states one forge's shape as the definition"

# One pass over the surfaces, wrap-normalized the same way for both scans. The
# marker window below is 200 characters — counted in characters, not bytes, so
# an em-dash in the run-up cannot silently shrink it.
scan="$(python3 - "$REPO_ROOT" "${SCOPE[@]}" <<'PY'
import re
import sys

PHRASE = re.compile(r"GitHub[\s-]+permalink", re.I)
URL = re.compile(r"https://github\.com/[^\s\x60]*")
ANGLE = re.compile(r"<[^>]*>")
MARKER = re.compile(r"for example|e\.g\.|for instance", re.I)
WINDOW = 200

root = sys.argv[1].rstrip("/")
for rel in sys.argv[2:]:
    try:
        with open(root + "/" + rel, encoding="utf-8") as handle:
            text = re.sub(r"\s+", " ", handle.read())
    except (OSError, ValueError) as exc:
        print("error|%s|%s" % (rel, exc))
        continue
    for match in PHRASE.finditer(text):
        print("phrase|%s|%s" % (rel, match.group(0)))
    for match in URL.finditer(text):
        url = match.group(0)
        if not ANGLE.search(url):
            continue
        before = text[max(0, match.start() - WINDOW):match.start()]
        state = "marked" if MARKER.search(before) else "unmarked"
        print("placeholder|%s|%s|%s" % (state, rel, url))
PY
)"
scan_rc=$?

scan_ok=1
if [ "$scan_rc" -ne 0 ]; then
  scan_ok=0
  fail "the surfaces can be scanned" "the scanner exited $scan_rc"
elif printf '%s\n' "$scan" | grep -q '^error|'; then
  scan_ok=0
  fail "the surfaces can be scanned" "$(printf '%s\n' "$scan" | grep '^error|')"
else
  pass "the surfaces can be scanned"
fi

# "a GitHub permalink" names one forge as the whole answer. No surface says it.
phrase_hits="$(printf '%s\n' "$scan" | grep '^phrase|' || true)"
if [ "$scan_ok" -ne 1 ]; then
  fail "no surface calls the citation shape a GitHub permalink" \
    "the scan did not complete — this case is undecided, not clean"
elif [ -z "$phrase_hits" ]; then
  pass "no surface calls the citation shape a GitHub permalink"
else
  fail "no surface calls the citation shape a GitHub permalink" \
    "$(printf '%s\n' "$phrase_hits" | wc -l | tr -d ' ') occurrence(s), by file:" \
    "$(printf '%s\n' "$phrase_hits" | cut -d'|' -f2 | LC_ALL=C sort | uniq -c)"
fi

# A github.com URL template may be shown, but only behind a marker that labels
# it an example — never standing alone as the definition.
placeholders="$(printf '%s\n' "$scan" | grep '^placeholder|' || true)"
unmarked="$(printf '%s\n' "$placeholders" | grep '^placeholder|unmarked|' || true)"
if [ "$scan_ok" -ne 1 ]; then
  fail "every github.com URL template is introduced as an example" \
    "the scan did not complete — this case is undecided, not clean"
elif [ -z "$unmarked" ]; then
  if [ -z "$placeholders" ]; then
    pass "every github.com URL template is introduced as an example (none present)"
  else
    pass "every github.com URL template is introduced as an example ($(printf '%s\n' "$placeholders" | wc -l | tr -d ' ') checked)"
  fi
else
  fail "every github.com URL template is introduced as an example" \
    "$(printf '%s\n' "$unmarked" | cut -d'|' -f3- | sed 's/|/ /')"
fi

banner "doctrine preservation: the shipped doctrine suite still passes"

doctrine_out="$(cd "$REPO_ROOT" && bash scripts/ci-local.sh doctrine 2>&1)" \
  && doctrine_rc=0 || doctrine_rc=$?
if [ "$doctrine_rc" -eq 0 ]; then
  pass "the doctrine suite exits clean"
else
  fail "the doctrine suite exits clean" "$(printf 'rc=%d\n%s' "$doctrine_rc" "$doctrine_out")"
fi

# The same two pinned sentences, in the bundled examples this work does not
# touch. Discovered from disk, the same way the doctrine suite finds them, so a
# fourth example is covered the day it lands. Asserted here as well so a break
# names its own cause instead of arriving as one opaque exit code.
while IFS= read -r ex; do
  [ -n "$ex" ] || continue
  rel="${ex#"$REPO_ROOT"/}"
  for sentence in "$CLAIMS_SENTENCE_1" "$CLAIMS_SENTENCE_2"; do
    if grep -qF -- "$sentence" "$ex"; then
      pass "pinned claims sentence survives in $rel: \"${sentence:0:38}…\""
    else
      fail "pinned claims sentence survives in $rel: \"${sentence:0:38}…\""
    fi
  done
done < <(find "$REPO_ROOT/examples" -mindepth 2 -maxdepth 2 -name SKILL.md -not -path '*/.*' 2>/dev/null | LC_ALL=C sort)

# The clone cache is partitioned by source kind; no surface may reintroduce an
# unmarked flat-layout path while being rewritten.
flat_hits=""
for rel in "${SCOPE[@]}"; do
  [ -f "$REPO_ROOT/$rel" ] || continue
  if grep -F 'cache/skill-engine/<source_id>' "$REPO_ROOT/$rel" 2>/dev/null \
    | grep -qv -F '<!-- doctrine:legacy-cache-layout -->'; then
    flat_hits+="$rel"$'\n'
  fi
done
if [ -z "$flat_hits" ]; then
  pass "no surface introduces an unmarked flat cache-layout path"
else
  fail "no surface introduces an unmarked flat cache-layout path" "$(printf '%s' "$flat_hits")"
fi

# A doctrine pointer from a skill to a file that already ships on disk must be
# a local relative read, never a hosted permalink back into this repo.
hosted_hits=""
for rel in "${SCOPE[@]}"; do
  case "$rel" in
    plugin/skill-engine/skills/*) ;;
    *) continue ;;
  esac
  [ -f "$REPO_ROOT/$rel" ] || continue
  if grep -qE 'github[.]com/nick-railsback/skill-engine/(blob|tree)/main/plugin/skill-engine/' "$REPO_ROOT/$rel"; then
    hosted_hits+="$rel"$'\n'
  fi
done
if [ -z "$hosted_hits" ]; then
  pass "no skill surface points at this plugin's own tree by hosted permalink"
else
  fail "no skill surface points at this plugin's own tree by hosted permalink" \
    "$(printf '%s' "$hosted_hits")"
fi

# Router size discipline: the two routers that bear on this work stay inside
# the ceiling, and the self-audit router plus its references stay above the
# floor that keeps trimmed content in tracked files rather than deleted.
for router in "$DISCOVER_SKILL" "$SELF_AUDIT_SKILL"; do
  rel="${router#"$REPO_ROOT"/}"
  bytes="$(wc -c < "$router" | tr -d ' ')"
  if [ "$bytes" -le "$ROUTER_CEILING" ]; then
    pass "$rel is $bytes bytes, within the ${ROUTER_CEILING}-byte router ceiling"
  else
    fail "$rel is $bytes bytes, over the ${ROUTER_CEILING}-byte router ceiling"
  fi
done

sa_combined="$(cat "$SELF_AUDIT_SKILL" "$PLUGIN_ROOT"/skills/self-audit/references/*.md 2>/dev/null | wc -c | tr -d ' ')"
if [ "$sa_combined" -ge "$SELF_AUDIT_FLOOR" ]; then
  pass "self-audit router plus its references is $sa_combined bytes, at or above the ${SELF_AUDIT_FLOOR}-byte floor"
else
  fail "self-audit router plus its references is $sa_combined bytes, below the ${SELF_AUDIT_FLOOR}-byte floor"
fi

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
