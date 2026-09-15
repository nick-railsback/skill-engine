#!/usr/bin/env bash
# Oracle for the optional `paths:` frontmatter key as the two navigator
# templates document it.
#
# `engine-bootstrap` stamps a contextualizer's navigator by copying one of
# these two templates wholesale, so whatever a template says about
# frontmatter is what every navigator stamped after it says. The artifact
# contract admits `paths:` as an optional third frontmatter field for
# scoping a contextualizer to a subset of a repository's files; these
# templates are where a builder reads about it, and the shape they teach is
# the shape that ships.
#
# THE INVARIANTS.
#   frontmatter example — each template documents the key as YAML comment
#                         lines INSIDE its own frontmatter block: a
#                         `# paths:` line followed by at least one
#                         `#   - <glob>` item line, i.e. a YAML block list
#                         written out as comments. Every explanatory
#                         sentence sits on its own comment line above the
#                         key, and that prose says what the key is for
#                         (nested and per-slice contextualizers) and that a
#                         contextualizer installed at one of the fixed
#                         skills roots leaves it out.
#   uncomment fidelity  — turning the example on is exactly "strip the
#                         leading `# ` from the key line and its item
#                         lines". So the key line and each item line carry
#                         nothing but `# ` and YAML — a trailing `#`
#                         comment on the `paths:` line would survive the
#                         strip, and the navigator gate then reads the
#                         comment's own words as globs, which is how a
#                         `paths:` key with no items at all slips through.
#                         Banning that layout in the template is what keeps
#                         the accept case below honest.
#   check-3 accept      — a navigator stamped from each template with the
#                         example uncommented is accepted by the shipped
#                         `verify.sh` navigator-frontmatter check.
#   check-3 reject      — the same stamped navigator with a `version:` key
#                         added is rejected by it. A template cannot ship a
#                         frontmatter shape the gate refuses, and the gate
#                         has not quietly stopped refusing anything else.
#
# WHY THE GATE CASES ARE CONDITIONED. The bare templates carry a two-field
# frontmatter the gate already accepts, and a `version:` key the gate
# already rejects. An accept/reject pair on its own would therefore be green
# before a word is written. Both cases below first require the stamped
# fixture to genuinely carry the uncommented key — a `paths:` line and at
# least one list item — and only then read the verdict.
#
# HOW PROSE IS MATCHED. The explanatory comment is hand-written markdown, so
# every prose assertion runs against the comment lines joined into one
# case-folded line with emphasis markers and backticks removed, and matches
# key terms co-occurring inside that extracted region — never a whole
# sentence, and never a bounded regex repetition (BSD grep refuses an
# interval above 255 and reports the refusal as a non-match, which passes
# under GNU grep with nothing to read).
#
# ENV INDIRECTION. Each file under test is reached through the variable
# named beside it, so a scratch copy can stand in for one file while every
# other resolves to the real tree.
#
# WHAT IS NOT HERE. Facts that already hold — the behaviours this work must
# not break — live in `preserved.sh` beside this file, exercised by the
# controls under `mutations/`. Everything below is still owed.
#
# -e is intentionally omitted: every assertion runs and reports, rather than
# the run aborting at the first failure.

set -uo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TEMPLATES_DIR="$PLUGIN_ROOT/engine-bootstrap-templates"
NAV_TEMPLATE="${NAV_TEMPLATE:-$TEMPLATES_DIR/navigator.md.template}"
NAV_MULTI_TEMPLATE="${NAV_MULTI_TEMPLATE:-$TEMPLATES_DIR/navigator-multi-domain.md.template}"
VERIFY_SH="${VERIFY_SH:-$TEMPLATES_DIR/verify.sh}"

# The slug placeholder a stamped navigator has substituted, and what it is
# substituted with here.
SLUG_PLACEHOLDER='<contextualizer-slug>'
FIXTURE_SLUG='acme'

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

section() {
  printf '\n== %s ==\n' "$1"
}

# ────────────────────────────────────────────────────────────────────────
# Reading a template
# ────────────────────────────────────────────────────────────────────────

# fm_body <file> — the lines between the opening and closing `---`. A file
# with no frontmatter, or no file at all, yields nothing rather than an
# error: its absence is the answer to the assertions below.
fm_body() {
  [ -f "$1" ] || { printf ''; return 0; }
  awk '
    /^---[[:space:]]*$/ { state++; if (state == 2) exit; next }
    state == 1 { print }
  ' "$1"
}

# fm_shape — reads frontmatter lines on stdin and prints one line of counts
# describing the commented example:
#
#   key    line number of the `# paths:` line, 0 when there is none
#   items  item lines in the CONTIGUOUS run directly under that key line.
#          Contiguity is what separates a glob list from a prose bullet
#          list: an explanatory comment that happens to use dashes must not
#          be mistaken for the example's globs. An item line is `# ` then at
#          least one more space, then the dash — the indentation a YAML
#          block list needs once the comment marker comes off.
#   pb/pa  explanatory comment lines before / after the key line. A bare
#          `#` is a blank separator, neither prose nor item, and it ends the
#          item run like any other interruption.
#   bad    `#`-commented `paths:` lines carrying anything after the colon —
#          the trailing-comment layout the strip-`# ` operation would
#          preserve into live YAML.
#   ih     item lines in the run whose YAML carries a `#` of its own.
fm_shape() {
  awk '
    {
      n++
      line = $0
      if (line ~ /^#[[:space:]]*paths:[[:space:]]*[^[:space:]]/) {
        bad++; run = 0
        if (key) { pa++ } else { pb++ }
        next
      }
      if (line ~ /^# paths:[[:space:]]*$/) {
        if (key == 0) key = n
        run = 1
        next
      }
      if (run == 1 && line ~ /^# [[:space:]]+-[[:space:]]*[^[:space:]]/) {
        items++
        rest = line
        sub(/^# /, "", rest)
        if (index(rest, "#") > 0) ih++
        next
      }
      run = 0
      if (line ~ /^#[[:space:]]*$/) next
      if (line ~ /^#/) { if (key) { pa++ } else { pb++ } }
    }
    END {
      printf "key=%d items=%d pb=%d pa=%d bad=%d ih=%d\n",
        key + 0, items + 0, pb + 0, pa + 0, bad + 0, ih + 0
    }
  '
}

shape_field() {
  printf '%s\n' "$1" | tr ' ' '\n' | awk -F= -v k="$2" '$1 == k { print $2 }'
}

# fm_prose — the explanatory comment lines above the `# paths:` line, read
# from frontmatter lines on stdin, with the comment marker removed.
fm_prose() {
  awk '
    /^# paths:[[:space:]]*$/ { exit }
    /^#/ { line = $0; sub(/^#[[:space:]]?/, "", line); print line }
  '
}

# norm_prose — one case-folded line, whitespace runs squeezed, markdown
# emphasis markers and backticks deleted so a matched stem cannot be split
# by one.
norm_prose() {
  tr -d '`*_' | tr '\n' ' ' | tr -s '[:space:]' ' ' | tr '[:upper:]' '[:lower:]'
}

# ────────────────────────────────────────────────────────────────────────
# Stamping, and reading the navigator gate's verdict
# ────────────────────────────────────────────────────────────────────────

# stamp <template> — the navigator a builder gets from this template with
# the example turned on, on stdout: the slug placeholder substituted, and
# the leading `# ` stripped from the key line and its contiguous run of
# item lines. Nothing else in the frontmatter is uncommented — the
# explanatory sentences stay comments, which is why they are required to
# sit on their own lines above the key.
stamp() {
  [ -f "$1" ] || { printf ''; return 0; }
  sed "s|$SLUG_PLACEHOLDER|$FIXTURE_SLUG|g" "$1" | awk '
    /^---[[:space:]]*$/ { state++; run = 0; print; next }
    state == 1 {
      if ($0 ~ /^# paths:[[:space:]]*$/) {
        line = $0; sub(/^# /, "", line); run = 1; print line; next
      }
      if (run == 1 && $0 ~ /^# [[:space:]]+-[[:space:]]*[^[:space:]]/) {
        line = $0; sub(/^# /, "", line); print line; next
      }
      run = 0
      print; next
    }
    { print }
  '
}

# carries_uncommented_key <navigator-file> — 0 when the frontmatter holds a
# live `paths:` key in block form with at least one list item under it.
# This is the precondition both gate cases below are conditioned on.
carries_uncommented_key() {
  local fm items
  fm="$(fm_body "$1")"
  printf '%s\n' "$fm" | grep -qE '^paths:[[:space:]]*$' || return 1
  items="$(printf '%s\n' "$fm" | grep -cE '^[[:space:]]+-[[:space:]]*[^[:space:]]')" || items=0
  [ "$items" -ge 1 ]
}

# nav_gate_report <navigator-file> — the navigator-frontmatter check's own
# section of a verify run over a fixture carrying just this navigator and a
# minimal sources file. The verdict must be isolated to that section: a
# fixture this small reaches later checks that report on their own terms.
nav_gate_report() {
  local root cache out
  root="$(mktemp -d)"
  cache="$(mktemp -d)"
  mkdir -p "$root/research"
  cp "$1" "$root/SKILL.md"
  printf '{"schema_version": 1, "sources": []}\n' > "$root/research/source-paths.json"
  out="$(CTX_ROOT="$root" SKILL_ENGINE_CACHE_ROOT="$cache" bash "$VERIFY_SH" 2>&1)"
  rm -rf "$root" "$cache"
  printf '%s\n' "$out" | awk '
    index($0, "(navigator-skill)") > 0 && !found { found = 1; print; next }
    found && /^=== / { exit }
    found { print }
  '
}

# add_third_key <navigator-file> <key-line> — the same navigator with one
# more key appended to its frontmatter.
add_third_key() {
  awk -v extra="$2" '
    /^---[[:space:]]*$/ { state++; if (state == 2) print extra; print; next }
    { print }
  ' "$1"
}

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ════════════════════════════════════════════════════════════════════════
# One pass per template. Both are stamped into navigators by the same
# bootstrap step, so both must document the key — asserting over one
# representative would leave the other free to say nothing.
# ════════════════════════════════════════════════════════════════════════

check_template() {
  local tpl_file="$1"
  local name fm shape key items pb pa bad ih prose keys
  local stamped rejected report ok

  name="$(basename "$tpl_file")"
  section "$name"

  fm="$(fm_body "$tpl_file")"
  shape="$(printf '%s\n' "$fm" | fm_shape)"
  key="$(shape_field "$shape" key)"
  items="$(shape_field "$shape" items)"
  pb="$(shape_field "$shape" pb)"
  pa="$(shape_field "$shape" pa)"
  bad="$(shape_field "$shape" bad)"
  ih="$(shape_field "$shape" ih)"

  # ── frontmatter example ───────────────────────────────────────────────

  if [ "$key" -gt 0 ] && [ "$items" -ge 1 ]; then
    pass "frontmatter example: $name documents paths: as a commented YAML block list inside its frontmatter"
  else
    fail "frontmatter example: $name documents paths: as a commented YAML block list inside its frontmatter" \
      "wanted a '# paths:' line with at least one '#   - <glob>' line directly under it" \
      "found: $shape"
  fi

  if [ "$key" -gt 0 ] && [ "$items" -ge 1 ] && [ "$bad" -eq 0 ] && [ "$ih" -eq 0 ]; then
    pass "uncomment fidelity: $name's example lines carry nothing but '# ' and YAML"
  else
    fail "uncomment fidelity: $name's example lines carry nothing but '# ' and YAML" \
      "a trailing comment on the paths: line survives the strip and its words are then counted as globs" \
      "found: $shape"
  fi

  if [ "$key" -gt 0 ] && [ "$pb" -ge 1 ] && [ "$pa" -eq 0 ]; then
    pass "frontmatter example: $name keeps every explanatory sentence on its own comment line above the key"
  else
    fail "frontmatter example: $name keeps every explanatory sentence on its own comment line above the key" \
      "wanted at least one explanatory comment line before '# paths:' and none after it" \
      "found: $shape"
  fi

  prose="$(printf '%s\n' "$fm" | fm_prose | norm_prose)"

  ok=1
  printf '%s' "$prose" | grep -qE 'nested' || ok=0
  printf '%s' "$prose" | grep -qE 'slice' || ok=0
  printf '%s' "$prose" | grep -qE 'contextualizer|navigator|skill' || ok=0
  if [ "$ok" -eq 1 ]; then
    pass "frontmatter example: $name says the key scopes nested and per-slice contextualizers"
  else
    fail "frontmatter example: $name says the key scopes nested and per-slice contextualizers" \
      "the comment above the key must name both the nested case and the slice case" \
      "region read: ${prose:-<empty>}"
  fi

  ok=1
  printf '%s' "$prose" \
    | grep -qE 'omit|leave it out|leaves it out|left out|not set|unset|no paths|absent|drop it|skip it|without it|not need|no need|not required|do not set|do not add|does not need' || ok=0
  printf '%s' "$prose" \
    | grep -qE 'fixed root|standard root|skills root|install root|top-level|installed at|\.claude/skills|one of the three|root' || ok=0
  if [ "$ok" -eq 1 ]; then
    pass "frontmatter example: $name says a contextualizer at one of the fixed roots omits the key"
  else
    fail "frontmatter example: $name says a contextualizer at one of the fixed roots omits the key" \
      "the comment above the key must state the default: a contextualizer installed at one of the fixed skills roots leaves it out" \
      "region read: ${prose:-<empty>}"
  fi

  # ── uncomment fidelity, executed ──────────────────────────────────────

  stamped="$WORK/$name.stamped.md"
  stamp "$tpl_file" > "$stamped"

  ok=1
  carries_uncommented_key "$stamped" || ok=0
  if [ "$ok" -eq 1 ]; then
    keys="$(fm_body "$stamped" | grep -oE '^[A-Za-z0-9_.-]+:' | sed 's/:$//' | LC_ALL=C sort -u | tr '\n' ' ')"
    case "$keys" in
      'description name paths ') ;;
      *) ok=0 ;;
    esac
  fi
  if [ "$ok" -eq 1 ]; then
    pass "uncomment fidelity: stripping '# ' from $name's example lines yields live block-form YAML and no other key"
  else
    fail "uncomment fidelity: stripping '# ' from $name's example lines yields live block-form YAML and no other key" \
      "wanted a 'paths:' line with at least one indented '-' item, and exactly the keys name, description, paths" \
      "frontmatter after stripping: $(fm_body "$stamped" | tr '\n' '|')"
  fi

  # ── check-3 accept ────────────────────────────────────────────────────

  if ! carries_uncommented_key "$stamped"; then
    fail "check-3 accept: a navigator stamped from $name with the example on is accepted" \
      "the stamped navigator carries no uncommented paths: block — nothing was exercised"
  else
    report="$(nav_gate_report "$stamped")"
    if [ -n "$report" ] && ! printf '%s\n' "$report" | grep -q '\[FAIL\]'; then
      pass "check-3 accept: a navigator stamped from $name with the example on is accepted"
    else
      fail "check-3 accept: a navigator stamped from $name with the example on is accepted" \
        "navigator-skill section: ${report:-<empty>}"
    fi
  fi

  # ── check-3 reject ────────────────────────────────────────────────────

  rejected="$WORK/$name.rejected.md"
  add_third_key "$stamped" 'version: 1.0' > "$rejected"

  if ! carries_uncommented_key "$rejected"; then
    fail "check-3 reject: the same stamped navigator from $name with a version: key is rejected" \
      "the stamped navigator carries no uncommented paths: block — the gate was not exercised from the template side"
  else
    report="$(nav_gate_report "$rejected")"
    if printf '%s\n' "$report" | grep -q '\[FAIL\].*version'; then
      pass "check-3 reject: the same stamped navigator from $name with a version: key is rejected"
    else
      fail "check-3 reject: the same stamped navigator from $name with a version: key is rejected" \
        "navigator-skill section: ${report:-<empty>}"
    fi
  fi
}

check_template "$NAV_TEMPLATE"
check_template "$NAV_MULTI_TEMPLATE"

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
