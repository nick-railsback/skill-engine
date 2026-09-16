#!/usr/bin/env bash
# The behaviours that must survive documenting `paths:` in the two navigator
# templates. Every one of them already holds today, and every one of them is
# owned somewhere else — the forge-prose oracle, the slice-catalog oracle,
# the navigator byte-budget lint, the navigator-frontmatter gate's own
# oracle, the local install check. Those suites are what enforce them in a
# full run; this file restates the same facts in one place so each can be
# broken in a scratch copy and watched to flip, which is what the controls
# beside it do.
#
# Deliberately NOT called by `run.sh`. Everything `run.sh` reports is a fact
# the work still owes; a fact that already holds, reported there, would read
# green on the first run and prove nothing.
#
# WHAT IS HELD, AND WHY IT IS AT RISK.
#   claims policy   — the forge-prose oracle reads both templates' `## Claims
#                     policy` section and pins two sentences byte-for-byte; a
#                     reflow counts as a change. The same oracle requires the
#                     section's first item to name the source forge and keep
#                     its worked github.com example.
#   forge scan      — the same oracle scans each template whole-file,
#                     wrap-normalized: no "GitHub permalink" phrase anywhere,
#                     and every github.com URL carrying an angle-bracket
#                     placeholder introduced as an example within the
#                     preceding 200 characters. A frontmatter comment sits at
#                     the very top of the file, where that look-behind window
#                     is nearly empty — so a forge URL used as a glob example
#                     would break this.
#   single forge    — no surface may restate either of the two retired
#                     claims that one forge's grammar is the whole
#                     definition.
#   cache layout    — no surface may reintroduce an unmarked flat clone-cache
#                     path.
#   slice catalog   — the multi-source template documents both the abstract
#                     per-source catalog heading and the abstract slice
#                     heading, and its Catalog container keeps a worked
#                     two-slice example and both per-source example slugs.
#   standing budget — the byte-budget lint skips everything through the
#                     closing `---`, so frontmatter costs a stamped navigator
#                     nothing. That is only true while the documentation
#                     stays inside the block: the same prose below the
#                     delimiter lands on every stamped navigator's standing
#                     instructions, and these two already sit over budget.
#   shipped navs    — the in-repo navigator and each bundled example still
#                     pass the navigator-frontmatter gate.
#   frontmatter gate— that gate still accepts a two-field frontmatter and a
#                     `paths:` block list, and still rejects any other third
#                     key.
#   template bundle — the local install check's required template list still
#                     names both navigator templates, and each listed file is
#                     on disk.
#
# ENV INDIRECTION. Each file is reached through the variable named beside it,
# so a control copies one file, breaks the copy, and leaves every other file
# resolving to the real tree — which is what makes the pristine run a
# meaningful baseline rather than an artefact of a partial copy.
#
# -e is intentionally omitted: every assertion runs and reports, rather than
# the run aborting at the first failure.

set -uo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

TEMPLATES_DIR="$PLUGIN_ROOT/engine-bootstrap-templates"
NAV_TEMPLATE="${NAV_TEMPLATE:-$TEMPLATES_DIR/navigator.md.template}"
NAV_MULTI_TEMPLATE="${NAV_MULTI_TEMPLATE:-$TEMPLATES_DIR/navigator-multi-domain.md.template}"
VERIFY_SH="${VERIFY_SH:-$TEMPLATES_DIR/verify.sh}"
BUDGET_PY="${BUDGET_PY:-$PLUGIN_ROOT/tests/navigator_budget.py}"
INSTALL_LOCALLY_SH="${INSTALL_LOCALLY_SH:-$PLUGIN_ROOT/bin/install-locally.sh}"
# The directory the install check's template-bundle paths resolve against.
BUNDLE_ROOT="${BUNDLE_ROOT:-$PLUGIN_ROOT}"
DOGFOOD_NAV_ROOT="${DOGFOOD_NAV_ROOT:-$REPO_ROOT/.claude/skills/skill-engine-context}"
EXAMPLES_DIR="${EXAMPLES_DIR:-$REPO_ROOT/examples}"

# The two sentences the forge-prose oracle matches raw, un-normalized, in
# every navigator it reads — both templates among them. A rewrap here
# propagates into the next stamped copy and breaks that match.
CLAIMS_SENTENCE_1="This inline permalink is what the grounded-citation eval (SELF-AUDIT Check 8) grades."
CLAIMS_SENTENCE_2="summary of what you read — not a substitute"

# The two retired single-forge claims no prose surface may restate.
RETIRED_CLAIM_1='Unpinned `blob/main/...` URLs and non-GitHub URLs do not satisfy the density check.'
RETIRED_CLAIM_2='The permalink regex is imported from the Check 7 lint so the two checks share one source of truth.'

# Standing-instruction byte counts as they stand, per template. Not a design
# ceiling — both already sit above the 5,120-byte budget the lint reports
# against. They are here as a "does not grow" line: documentation added
# inside the frontmatter block costs zero standing-instruction bytes, and
# any growth here means it did not stay there.
NAV_STANDING_MAX=5197
NAV_MULTI_STANDING_MAX=6684

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

# ────────────────────────────────────────────────────────────────────────
# Helpers
# ────────────────────────────────────────────────────────────────────────

# norm — whitespace runs, newlines included, squeezed to one space, so a
# phrase hand-wrapped across two lines matches as one phrase.
norm() {
  tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'
}

# md_region <file> <start-ere> <end-ere> — from the first line matching
# start (inclusive) to the next line matching end (exclusive).
md_region() {
  [ -f "$1" ] || { printf ''; return 0; }
  awk -v s="$2" -v e="$3" '
    f && $0 ~ e { exit }
    $0 ~ s { f = 1 }
    f { print }
  ' "$1"
}

# body_below_frontmatter <file> — everything after the closing `---`, which
# is the region the byte-budget lint actually counts.
body_below_frontmatter() {
  [ -f "$1" ] || { printf ''; return 0; }
  awk '
    /^---[[:space:]]*$/ { state++; if (state <= 2) next }
    state >= 2 { print }
  ' "$1"
}

# catalog_container <file> — the `## Catalog` heading and everything under
# it up to the next non-Catalog `## ` heading, matching how the
# slice-catalog oracle scopes its container assertions.
catalog_container() {
  [ -f "$1" ] || { printf ''; return 0; }
  local line
  local in_block=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "## Catalog"|"## Catalog:"*|"## Catalog "*)
        in_block=1
        printf '%s\n' "$line"
        continue
        ;;
    esac
    if [ "$in_block" -eq 1 ]; then
      case "$line" in
        "## "*) in_block=0 ;;
        *) printf '%s\n' "$line" ;;
      esac
    fi
  done < "$1"
}

# standing_bytes <file> — the byte count the navigator budget lint reports.
# Read out of the lint's own output rather than recomputed, so this and the
# lint cannot drift apart. Prints nothing when it cannot be read.
standing_bytes() {
  [ -f "$1" ] || { printf ''; return 0; }
  [ -f "$BUDGET_PY" ] || { printf ''; return 0; }
  python3 "$BUDGET_PY" "$1" 2>/dev/null \
    | grep -oE '[0-9][0-9,]* bytes' \
    | head -n1 \
    | tr -d ', bytes'
}

# shellcheck source=../lib/nav_gate.sh
. "$PLUGIN_ROOT/tests/lib/nav_gate.sh"

# bundle_paths <install-script> — the required template files the local
# install check walks, one per line, read out of the array it iterates
# rather than retyped here.
bundle_paths() {
  [ -f "$1" ] || { printf ''; return 0; }
  awk '
    /^template_bundle=\(/ { cap = 1; next }
    cap && /^[[:space:]]*\)[[:space:]]*$/ { exit }
    cap {
      line = $0
      sub(/^[[:space:]]*"/, "", line)
      sub(/"[[:space:]]*$/, "", line)
      if (line != "") print line
    }
  ' "$1"
}

TEMPLATES=("$NAV_TEMPLATE" "$NAV_MULTI_TEMPLATE")

# ════════════════════════════════════════════════════════════════════════
# claims policy
# ════════════════════════════════════════════════════════════════════════

for tpl in "${TEMPLATES[@]}"; do
  label="$(basename "$tpl")"
  ok=1
  [ -s "$tpl" ] || ok=0
  claims_block="$(md_region "$tpl" '^## Claims policy' '^## ')"
  item1="$(printf '%s\n' "$claims_block" | awk '
    f && /^2[.] / { exit }
    /^1[.] / { f = 1 }
    f { print }
  ' | norm)"
  [ -n "$item1" ] || ok=0
  printf '%s' "$item1" | grep -qi 'forge' || ok=0
  printf '%s' "$item1" | grep -qF -- 'https://github.com/' || ok=0
  for sentence in "$CLAIMS_SENTENCE_1" "$CLAIMS_SENTENCE_2"; do
    grep -qF -- "$sentence" "$tpl" 2>/dev/null || ok=0
  done
  if [ "$ok" -eq 1 ]; then
    pass "claims policy: $label keeps its forge-grammar first item and both byte-pinned sentences"
  else
    fail "claims policy: $label keeps its forge-grammar first item and both byte-pinned sentences" \
      "item 1 read: ${item1:-<empty>}"
  fi
done

# ════════════════════════════════════════════════════════════════════════
# forge scan
# ════════════════════════════════════════════════════════════════════════

# The same scan the forge-prose oracle runs, over the two templates only:
# the phrase that names one forge as the whole answer, and any github.com
# URL carrying an angle-bracket placeholder that is not introduced as an
# example within the preceding 200 characters of wrap-normalized text.
scan="$(python3 - "${TEMPLATES[@]}" <<'PY'
import re
import sys

PHRASE = re.compile(r"GitHub[\s-]+permalink", re.I)
URL = re.compile(r"https://github\.com/[^\s\x60]*")
ANGLE = re.compile(r"<[^>]*>")
MARKER = re.compile(r"for example|e\.g\.|for instance", re.I)
WINDOW = 200

for name in sys.argv[1:]:
    try:
        with open(name, encoding="utf-8") as handle:
            text = re.sub(r"\s+", " ", handle.read())
    except (OSError, ValueError) as exc:
        print("error|%s|%s" % (name, exc))
        continue
    for match in PHRASE.finditer(text):
        print("phrase|%s|%s" % (name, match.group(0)))
    for match in URL.finditer(text):
        url = match.group(0)
        if not ANGLE.search(url):
            continue
        before = text[max(0, match.start() - WINDOW):match.start()]
        state = "marked" if MARKER.search(before) else "unmarked"
        print("placeholder|%s|%s|%s" % (state, name, url))
PY
)"
scan_rc=$?

ok=1
[ "$scan_rc" -eq 0 ] || ok=0
printf '%s\n' "$scan" | grep -q '^error|' && ok=0
printf '%s\n' "$scan" | grep -q '^phrase|' && ok=0
printf '%s\n' "$scan" | grep -q '^placeholder|unmarked|' && ok=0
if [ "$ok" -eq 1 ]; then
  pass "forge scan: neither template names one forge as the citation shape or shows an unexampled forge URL template"
else
  fail "forge scan: neither template names one forge as the citation shape or shows an unexampled forge URL template" \
    "scanner rc=$scan_rc" \
    "$(printf '%s\n' "$scan" | grep -E '^(error|phrase|placeholder\|unmarked)\|' || printf '<no offending line>')"
fi

# ════════════════════════════════════════════════════════════════════════
# single forge
# ════════════════════════════════════════════════════════════════════════

ok=1
offenders=""
for tpl in "${TEMPLATES[@]}"; do
  [ -f "$tpl" ] || continue
  for claim in "$RETIRED_CLAIM_1" "$RETIRED_CLAIM_2"; do
    if norm < "$tpl" | grep -qF -- "$claim"; then
      ok=0
      offenders="$offenders$(basename "$tpl"): ${claim:0:48}"$'\n'
    fi
  done
done
if [ "$ok" -eq 1 ]; then
  pass "single forge: neither template restates a retired single-grammar claim"
else
  fail "single forge: neither template restates a retired single-grammar claim" "$offenders"
fi

# ════════════════════════════════════════════════════════════════════════
# cache layout
# ════════════════════════════════════════════════════════════════════════

ok=1
offenders=""
for tpl in "${TEMPLATES[@]}"; do
  [ -f "$tpl" ] || continue
  if grep -F 'cache/skill-engine/<source_id>' "$tpl" 2>/dev/null \
    | grep -qv -F '<!-- doctrine:legacy-cache-layout -->'; then
    ok=0
    offenders="$offenders$(basename "$tpl")"$'\n'
  fi
done
if [ "$ok" -eq 1 ]; then
  pass "cache layout: neither template introduces an unmarked flat clone-cache path"
else
  fail "cache layout: neither template introduces an unmarked flat clone-cache path" "$offenders"
fi

# ════════════════════════════════════════════════════════════════════════
# slice catalog
# ════════════════════════════════════════════════════════════════════════

multi_text="$(cat "$NAV_MULTI_TEMPLATE" 2>/dev/null)"
ok=1
printf '%s\n' "$multi_text" | grep -qF -- '## Catalog: <slug>/<slice-id>' || ok=0
printf '%s\n' "$multi_text" | grep -qF -- '## Catalog: <source-slug>' || ok=0
if [ "$ok" -eq 1 ]; then
  pass "slice catalog: the multi-source template still documents both abstract catalog heading shapes"
else
  fail "slice catalog: the multi-source template still documents both abstract catalog heading shapes"
fi

container="$(catalog_container "$NAV_MULTI_TEMPLATE")"
slice_headings="$(printf '%s\n' "$container" \
  | grep -E '^[[:space:]]*## Catalog: [^/[:space:]]+/[^/[:space:]]+[[:space:]]*$' \
  | grep -vF -- '<slug>/<slice-id>' \
  | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
  | LC_ALL=C sort -u)"
slice_count="$(printf '%s\n' "$slice_headings" | grep -c .)" || slice_count=0
ok=1
[ "$slice_count" -ge 2 ] || ok=0
printf '%s\n' "$container" | grep -qF -- '<source-slug-1>' || ok=0
printf '%s\n' "$container" | grep -qF -- '<source-slug-2>' || ok=0
if [ "$ok" -eq 1 ]; then
  pass "slice catalog: the Catalog container keeps its worked two-slice example and both per-source example slugs"
else
  fail "slice catalog: the Catalog container keeps its worked two-slice example and both per-source example slugs" \
    "distinct concrete slice headings in container: $slice_count"
fi

# ════════════════════════════════════════════════════════════════════════
# standing budget
# ════════════════════════════════════════════════════════════════════════

check_standing() {
  local tpl="$1" ceiling="$2" label bytes
  label="$(basename "$tpl")"
  bytes="$(standing_bytes "$tpl")"
  if [ -n "$bytes" ] && [ "$bytes" -le "$ceiling" ]; then
    pass "standing budget: $label costs a stamped navigator no more standing-instruction bytes than it does today ($bytes/$ceiling)"
  else
    fail "standing budget: $label costs a stamped navigator no more standing-instruction bytes than it does today" \
      "read ${bytes:-<unreadable>}, ceiling $ceiling — frontmatter is skipped by the lint, the body is not"
  fi
}

check_standing "$NAV_TEMPLATE" "$NAV_STANDING_MAX"
check_standing "$NAV_MULTI_TEMPLATE" "$NAV_MULTI_STANDING_MAX"

ok=1
offenders=""
for tpl in "${TEMPLATES[@]}"; do
  [ -f "$tpl" ] || continue
  if body_below_frontmatter "$tpl" | grep -q 'paths:'; then
    ok=0
    offenders="$offenders$(basename "$tpl")"$'\n'
  fi
done
if [ "$ok" -eq 1 ]; then
  pass "standing budget: neither template documents the frontmatter key below the closing delimiter"
else
  fail "standing budget: neither template documents the frontmatter key below the closing delimiter" \
    "the lint counts everything under the closing --- into every stamped navigator's standing instructions" \
    "$offenders"
fi

# ════════════════════════════════════════════════════════════════════════
# shipped navs
# ════════════════════════════════════════════════════════════════════════

# Enumerated from disk rather than counted: a fourth bundled example is
# covered the day it lands, and a missing one is a failure rather than a
# silently empty loop.
nav_roots=("$DOGFOOD_NAV_ROOT")
while IFS= read -r ex; do
  [ -n "$ex" ] || continue
  nav_roots+=("$(dirname "$ex")")
done < <(find "$EXAMPLES_DIR" -mindepth 2 -maxdepth 2 -name SKILL.md -not -path '*/.*' 2>/dev/null | LC_ALL=C sort)

if [ "${#nav_roots[@]}" -lt 2 ]; then
  fail "shipped navs: the in-repo navigator and every bundled example were located" \
    "found ${#nav_roots[@]} navigator root(s) — nothing was exercised"
else
  pass "shipped navs: the in-repo navigator and every bundled example were located (${#nav_roots[@]})"
fi

for root in "${nav_roots[@]}"; do
  label="${root#"$REPO_ROOT"/}"
  if [ ! -f "$root/SKILL.md" ]; then
    fail "shipped navs: $label passes the navigator-frontmatter gate" "no SKILL.md at $root"
    continue
  fi
  report="$(nav_gate_report "$root")"
  if [ -n "$report" ] && ! printf '%s\n' "$report" | grep -q '\[FAIL\]'; then
    pass "shipped navs: $label passes the navigator-frontmatter gate"
  else
    fail "shipped navs: $label passes the navigator-frontmatter gate" \
      "navigator-skill section: ${report:-<empty>}"
  fi
done

# ════════════════════════════════════════════════════════════════════════
# frontmatter gate
# ════════════════════════════════════════════════════════════════════════

NAV_DESC='Use when answering questions about the acme corpus.'

ok=1
verdict_two="$(gate_case "name: acme-context
description: $NAV_DESC")"
[ "$verdict_two" = "accept" ] || ok=0
verdict_paths="$(gate_case "name: acme-context
description: $NAV_DESC
paths:
  - \"packages/billing/**\"
  - \"shared/**\"")"
[ "$verdict_paths" = "accept" ] || ok=0
verdict_version="$(gate_case "name: acme-context
description: $NAV_DESC
version: 1.0")"
[ "$verdict_version" = "reject" ] || ok=0
if [ "$ok" -eq 1 ]; then
  pass "frontmatter gate: a two-field frontmatter and a paths: block list are accepted, a version: third key is rejected"
else
  fail "frontmatter gate: a two-field frontmatter and a paths: block list are accepted, a version: third key is rejected" \
    "two-field=$verdict_two paths-block=$verdict_paths version=$verdict_version"
fi

# ════════════════════════════════════════════════════════════════════════
# template bundle
# ════════════════════════════════════════════════════════════════════════

listed="$(bundle_paths "$INSTALL_LOCALLY_SH")"
ok=1
[ -n "$listed" ] || ok=0
for want in engine-bootstrap-templates/navigator.md.template \
            engine-bootstrap-templates/navigator-multi-domain.md.template; do
  printf '%s\n' "$listed" | grep -qxF -- "$want" || ok=0
done
missing=""
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  [ -f "$BUNDLE_ROOT/$rel" ] || missing="$missing$rel"$'\n'
done <<< "$listed"
[ -z "$missing" ] || ok=0
if [ "$ok" -eq 1 ]; then
  pass "template bundle: the required template list names both navigator templates and every listed file is on disk"
else
  fail "template bundle: the required template list names both navigator templates and every listed file is on disk" \
    "listed: $(printf '%s' "$listed" | tr '\n' ' ')" \
    "missing on disk: ${missing:-<none>}"
fi

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
