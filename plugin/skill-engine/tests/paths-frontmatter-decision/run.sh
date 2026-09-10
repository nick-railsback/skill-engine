#!/usr/bin/env bash
# Black-box oracle: the artifact contract's frontmatter doctrine has been
# amended to admit `paths:` as an optional third field, with the decision
# dated and rationaled, while the fields that stay banned remain banned and
# no other doc goes on restating a two-field ceiling the contract no longer
# states.
#
# All assertions are read-only greps over two shipped doctrine files. Prose
# is normalized to a single line before matching (hard-wrapped markdown
# must never flip a result), and patterns match key terms plus co-occurrence
# within an extracted section, never full sentences.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

CONTRACT_DOC="$PLUGIN_ROOT/docs/02-artifact-contract.md"
PRINCIPLES_DOC="$PLUGIN_ROOT/docs/01-principles.md"

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

# join_lines — collapse hard-wrapped markdown to one space-normalized line so
# a sentence split across wrapped lines is still matchable as one string.
join_lines() {
  tr '\n' ' ' | tr -s ' '
}

# extract_heading_section <heading-text-prefix> <file> — the "##" or "###"
# heading (never "####" — those are sub-headings a rewrite may add inside
# the section, not section boundaries) whose text, after the leading
# hashes, starts with the given prefix, through (not including) the next
# "##"/"###" heading, or end of file. Matched by prefix rather than exact
# text so a heading whose suffix is expected to change (e.g. a trailing
# field-count claim) is still found.
extract_heading_section() {
  awk -v want="$1" '
    /^###? / {
      if (found) exit
      title = $0
      sub(/^###?[ \t]*/, "", title)
      if (index(title, want) == 1) { found = 1; print; next }
      next
    }
    found { print }
  ' "$2"
}

# windows_around <joined-text> <term> <before> <after> — the <before>/<after>
# character window around EVERY case-insensitive occurrence of <term> in
# <joined-text>, concatenated (lowercased throughout — every caller matches
# case-insensitively or on digits, so this is never a correctness issue).
# Empty when <term> never appears. Windowing keeps a co-occurrence check
# anchored to specific mentions instead of being satisfied by an unrelated
# occurrence of the second term elsewhere in a long section; concatenating
# every occurrence (not just the first) means a second or third mention of
# <term> still gets its own shot at the co-occurrence check.
windows_around() {
  local hay="$1" term="$2" before="$3" after="$4"
  local rest lower_term prefix idx start span
  lower_term="$(printf '%s' "$term" | tr '[:upper:]' '[:lower:]')"
  rest="$(printf '%s' "$hay" | tr '[:upper:]' '[:lower:]')"
  span=$(( before + after + ${#term} ))
  while :; do
    prefix="${rest%%"$lower_term"*}"
    [ "$prefix" = "$rest" ] && break
    idx="${#prefix}"
    start=$(( idx > before ? idx - before : 0 ))
    printf '%s ' "${rest:$start:$span}"
    rest="${rest:$(( idx + ${#lower_term} ))}"
  done
}

echo
echo "── files under test exist ──"

for f in "$CONTRACT_DOC" "$PRINCIPLES_DOC"; do
  if [ -f "$f" ]; then
    pass "shipped file present: ${f#"$REPO_ROOT"/}"
  else
    fail "shipped file present: ${f#"$REPO_ROOT"/}"
  fi
done

# ---------------------------------------------------------------------------
# 02-artifact-contract.md § Frontmatter — the paths: admission itself.
# ---------------------------------------------------------------------------

fm_section="$(extract_heading_section 'Frontmatter' "$CONTRACT_DOC")"
fm_heading="$(printf '%s\n' "$fm_section" | head -n1)"
fm_joined="$(join_lines <<< "$fm_section")"

echo
echo "── artifact contract: paths: admitted, dated, and rationaled ──"

paths_window="$(windows_around "$fm_joined" 'paths' 200 400)"

if grep -qE '[0-9]{4}-[0-9]{2}-[0-9]{2}' <<< "$paths_window" \
    && grep -qiE 'admit|optional third|third field' <<< "$paths_window"; then
  pass "paths: admission is a dated statement (an ISO-shaped date sits by the admission, not pinned to a value)"
else
  fail "paths: admission is a dated statement (an ISO-shaped date sits by the admission, not pinned to a value)"
fi

if grep -qiE 'document' <<< "$paths_window" \
    && grep -qiE 'claude code|platform' <<< "$paths_window"; then
  pass "the admission's rationale names the platform's documented paths: support as the reason for revisiting"
else
  fail "the admission's rationale names the platform's documented paths: support as the reason for revisiting"
fi

if grep -qiE 'glob' <<< "$fm_joined" \
    && grep -qiE 'list|array' <<< "$fm_joined" \
    && grep -qiE 'non-empty|at least one|one or more' <<< "$fm_joined"; then
  pass "paths: value shape is defined as a non-empty list of glob strings"
else
  fail "paths: value shape is defined as a non-empty list of glob strings"
fi

if grep -qiE 'nested|per-slice' <<< "$fm_joined" \
    && grep -qiE 'omitted' <<< "$fm_joined" \
    && grep -qiE 'default' <<< "$fm_joined"; then
  pass "paths: intended use (nested/per-slice contextualizers) and omit-by-default posture are both stated"
else
  fail "paths: intended use (nested/per-slice contextualizers) and omit-by-default posture are both stated"
fi

if grep -qiE 'check 3' <<< "$fm_joined" \
    && grep -qiE 'accept' <<< "$fm_joined" \
    && grep -qiE 'reject' <<< "$fm_joined"; then
  pass "verify.sh Check 3 is stated to accept paths: as the third key and still reject any other third key"
else
  fail "verify.sh Check 3 is stated to accept paths: as the third key and still reject any other third key"
fi

if grep -qiE 'declin(e|ing|ed)[^.]{0,60}paths|paths[^.]{0,40}(not|isn.t)[^.]{0,30}(admit|allow|support|accept)|(^|[^a-z])no[^.]{0,15}paths[^.]{0,15}(field|key)' <<< "$fm_joined"; then
  fail "no sentence declining paths: remains in the section" "a declining phrasing is still present"
else
  pass "no sentence declining paths: remains in the section"
fi

if grep -qiE 'exactly two fields' <<< "$fm_heading"; then
  fail "the Frontmatter section heading no longer reads \"exactly two fields\"" "heading still: $fm_heading"
else
  pass "the Frontmatter section heading no longer reads \"exactly two fields\""
fi

# ---------------------------------------------------------------------------
# Same section — the disable-model-invocation ban survives the rewrite, and
# picks up a dated re-check note. One compound assertion: the ban half is
# already true at baseline, so it must not stand alone as a green check
# before anything has been edited.
# ---------------------------------------------------------------------------

echo
echo "── artifact contract: disable-model-invocation ban + dated re-check ──"

ban_remains=0
grep -qiE 'no[[:space:]]+`?disable-model-invocation`?' <<< "$fm_joined" && ban_remains=1

dmi_window="$(windows_around "$fm_joined" 'disable-model-invocation' 200 400)"
dated_recheck=0
if grep -qE '[0-9]{4}-[0-9]{2}-[0-9]{2}' <<< "$dmi_window" \
    && grep -qiE 're-check|rechecked|recheck|revisit' <<< "$dmi_window"; then
  dated_recheck=1
fi

if [ "$ban_remains" -eq 1 ] && [ "$dated_recheck" -eq 1 ]; then
  pass "disable-model-invocation stays banned AND a dated note records whether it was re-checked at this release"
else
  fail "disable-model-invocation stays banned AND a dated note records whether it was re-checked at this release" \
       "ban_remains=$ban_remains dated_recheck=$dated_recheck"
fi

# ---------------------------------------------------------------------------
# 01-principles.md — no exhaustive-two-field claim survives anywhere, and
# the sections that used to carry it point at the contract instead.
# ---------------------------------------------------------------------------

principles_joined="$(join_lines < "$PRINCIPLES_DOC")"

echo
echo "── principles: no exhaustive-two-field claim survives ──"

exhaustivity_pattern='exactly two|only two|only the two|stick to `?name`?[[:space:]]+and[[:space:]]+`?description`?|limited to `?name`?[[:space:]]+and[[:space:]]+`?description`?'

if grep -qiE "$exhaustivity_pattern" <<< "$principles_joined"; then
  fail "no sentence anywhere in 01-principles.md claims frontmatter is exhausted by name and description" \
       "a matching phrasing is still present somewhere in the file"
else
  pass "no sentence anywhere in 01-principles.md claims frontmatter is exhausted by name and description"
fi

issue_section="$(extract_heading_section 'Issue #22345' "$PRINCIPLES_DOC")"
issue_joined="$(join_lines <<< "$issue_section")"

# A bare mention of "02-artifact-contract.md" already exists at baseline
# (an unrelated description-quality pointer) — satisfied by deleting the
# restated limit and adding nothing back would be a false green. Require
# "frontmatter" to sit near a contract mention, so a new authority pointer
# — not the pre-existing unrelated one — is what the check is keying on.
issue_contract_windows="$(windows_around "$issue_joined" '02-artifact-contract.md' 100 100)"

if ! grep -qiE "$exhaustivity_pattern" <<< "$issue_joined" \
    && grep -qi 'frontmatter' <<< "$issue_contract_windows"; then
  pass "the disable-model-invocation decision section drops the restated limit and points at the contract's Frontmatter section instead"
else
  fail "the disable-model-invocation decision section drops the restated limit and points at the contract's Frontmatter section instead"
fi

discipline_section="$(extract_heading_section 'Frontmatter discipline' "$PRINCIPLES_DOC")"
discipline_joined="$(join_lines <<< "$discipline_section")"

if ! grep -qiE "$exhaustivity_pattern" <<< "$discipline_joined" \
    && grep -qF '02-artifact-contract.md' <<< "$discipline_joined"; then
  pass "the Frontmatter discipline section drops the restated limit and points at the contract instead"
else
  fail "the Frontmatter discipline section drops the restated limit and points at the contract instead"
fi

if grep -qiE 'required' <<< "$discipline_joined" \
    && grep -qiE 'exhaustive|does not mean|doesn.t mean|not the same as|no other fields' <<< "$discipline_joined"; then
  pass "the paragraph citing Anthropic's Complete Guide distinguishes required from exhaustive"
else
  fail "the paragraph citing Anthropic's Complete Guide distinguishes required from exhaustive"
fi

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
