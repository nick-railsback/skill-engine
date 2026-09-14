#!/usr/bin/env bash
# Oracle for distributing a finished contextualizer to the engineers who
# need it.
#
# THE INVARIANTS.
#   plugin shape    — a recipe at `docs/recipes/distribute.md` documents the
#                     skills-only plugin end to end: the manifest at
#                     `.claude-plugin/plugin.json` declaring no hooks, the
#                     skills found by convention under the plugin's own
#                     `skills/<slug>-context/` rather than enumerated in the
#                     manifest, the two commands a consumer runs to add the
#                     marketplace and install, and REFRESH's output reaching
#                     consumers as a new plugin version.
#   depth-1 layout  — the same recipe documents the shared context
#                     repository, says when each shape fits, and names a
#                     layout the root resolution actually reaches: the
#                     contextualizer directories are the immediate children
#                     of `~/.claude/skills/` or `~/.claude/local/skills/`,
#                     landed either by cloning the repository as that
#                     directory or by one symlink per contextualizer — and a
#                     repository cloned into a subdirectory of either root
#                     leaves them a level too deep to be found.
#   access scoping  — the recipe forbids registering a source the intended
#                     audience cannot read, and names per-domain
#                     contextualizers aligned to repository permissions as
#                     the mitigation.
#   zero hooks      — a contextualizer plugin manifest template ships, is a
#                     JSON object, declares no `hooks` key, and is listed
#                     among the paths the json validator runs `jq` over.
#   cross-links     — the delivery chapter reaches the recipe by an absolute
#                     URL, and the capability ledger's distribution chapter
#                     names the recipe and both contextualizer-distribution
#                     shapes, with its contents entry saying so too.
#   templates index — the templates README carries a row for the new
#                     template, marked as one a builder copies rather than
#                     one bootstrap stamps.
#
# HOW PROSE IS MATCHED. Four of these are properties of hand-wrapped
# markdown, so every prose assertion runs against a blob with whitespace
# runs (newlines included) collapsed to one space and case folded, and
# windows around a literal anchor with `window_has`, never with a bounded
# regex repetition: BSD grep refuses an interval above 255 and reports the
# refusal as a non-match, which passes under GNU grep in CI with nothing to
# read. Where a sentence can honestly be anchored on more than one word, the
# anchors are tried in turn and any one of them carrying the window
# satisfies the assertion — the phrasing is the writer's, only the fact is
# the contract.
#
# ENV INDIRECTION. Every file under test may be pointed at a scratch copy
# through the variable named beside it below, so a property can be mutated
# in a copy and the assertion checked for the flip without touching the
# tracked file.
#
# WHAT IS NOT HERE. Assertions that already hold — the properties the edits
# behind this work must not break — live in `preserved.sh` beside this file,
# exercised by the controls under `mutations/` and, in a full run, by the
# sibling suites that own those properties. This file reports only what is
# still owed.
#
# -e is intentionally omitted: every assertion runs and reports, rather than
# the run aborting at the first failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

RECIPE_MD="${RECIPE_MD:-$REPO_ROOT/docs/recipes/distribute.md}"
DELIVERY_MD="${DELIVERY_MD:-$PLUGIN_ROOT/docs/04-delivery.md}"
CAPABILITIES_MD="${CAPABILITIES_MD:-$REPO_ROOT/CAPABILITIES.md}"
TEMPLATES_README_MD="${TEMPLATES_README_MD:-$PLUGIN_ROOT/engine-bootstrap-templates/README.md}"
CI_LOCAL_SH="${CI_LOCAL_SH:-$REPO_ROOT/scripts/ci-local.sh}"

MANIFEST_TEMPLATE_PATH="plugin/skill-engine/engine-bootstrap-templates/contextualizer-plugin.json.template"

# shellcheck source=/dev/null
. "$SCRIPT_DIR/hooks-check.sh"

pass_count=0
fail_count=0

report() {
  local ok="$1" name="$2"
  if [ "$ok" -eq 1 ]; then
    printf '  PASS  %s\n' "$name"
    pass_count=$((pass_count + 1))
  else
    printf '  FAIL  %s\n' "$name"
    fail_count=$((fail_count + 1))
  fi
}

# ────────────────────────────────────────────────────────────────────────
# Text helpers
# ────────────────────────────────────────────────────────────────────────

# flatten <file> — one case-folded line with whitespace runs squeezed, so a
# phrase hand-wrapped across two lines matches as one phrase and an anchor
# is found whatever the sentence capitalised. A file that is not there
# flattens to the empty string rather than to an error: its absence is the
# answer to several of the assertions below, not a fixture problem.
flatten() {
  [ -f "$1" ] || { printf ''; return 0; }
  tr '\n' ' ' < "$1" | tr -s '[:space:]' ' ' | tr '[:upper:]' '[:lower:]'
}

flatten_stdin() {
  tr '\n' ' ' | tr -s '[:space:]' ' ' | tr '[:upper:]' '[:lower:]'
}

# window <marker> <before> <after> — reads a blob on stdin and prints, one
# per line, the slice of text around each occurrence of a literal marker.
# Windowing happens here rather than through a bounded regex repetition
# because BSD grep refuses an interval above 255 and reports the refusal as
# a non-match.
window() {
  awk -v m="$1" -v b="$2" -v a="$3" '
    {
      s = $0; start = 1
      while ((p = index(substr(s, start), m)) > 0) {
        abs = start + p - 1
        lo = abs - b; if (lo < 1) lo = 1
        print substr(s, lo, (abs - lo) + length(m) + a)
        start = abs + length(m)
      }
    }'
}

# window_has <blob> <anchor> <before> <after> <ere...> — 1 when some window
# around some occurrence of the anchor matches every extended regex given.
# Every occurrence is tried: these documents repeat their own vocabulary,
# and a window anchored on the first hit alone would skip the sentence that
# actually carries the fact.
window_has() {
  local blob="$1" anchor="$2" before="$3" after="$4"
  shift 4
  local wins win re hit
  wins="$(printf '%s' "$blob" | window "$anchor" "$before" "$after")"
  [ -n "$wins" ] || return 1
  while IFS= read -r win; do
    [ -n "$win" ] || continue
    hit=1
    for re in "$@"; do
      printf '%s' "$win" | grep -qiE -- "$re" || hit=0
    done
    [ "$hit" -eq 1 ] && return 0
  done <<< "$wins"
  return 1
}

# h2_section <file> <heading-text> — the body of one `## ` section. Selected
# by the `## ` heading rather than by any `### ` inside it: the ledger
# repeats `### what's deliberately not built` under several chapters, so a
# heading-text match at that level reads whichever one comes first.
h2_section() {
  [ -f "$1" ] || { printf ''; return 0; }
  awk -v h2="$2" '
    /^## / { cur = substr($0, 4); cap = (cur == h2) ? 1 : 0; next }
    /^# /  { cap = 0; next }
    cap { print }
  ' "$1"
}

# md_region <file> <start-substring> <end-substring> — from the first line
# containing start (inclusive) to the next line containing end (exclusive).
md_region() {
  [ -f "$1" ] || { printf ''; return 0; }
  awk -v s="$2" -v e="$3" '
    f && index($0, e) { exit }
    index($0, s) { f = 1 }
    f { print }
  ' "$1"
}

# json_paths <ci-script> — the paths the json validator walks, one per line,
# read out of the array it iterates rather than retyped here, so this and
# the file cannot drift apart.
json_paths() {
  [ -f "$1" ] || { printf ''; return 0; }
  awk '
    /^run_json\(\)/ { inf = 1 }
    inf && /paths=\(/ { cap = 1; next }
    cap && /^[[:space:]]*\)[[:space:]]*$/ { exit }
    cap {
      line = $0
      sub(/^[[:space:]]*"/, "", line)
      sub(/"[[:space:]]*$/, "", line)
      if (line != "") print line
    }
  ' "$1"
}

# ────────────────────────────────────────────────────────────────────────
# Blobs
# ────────────────────────────────────────────────────────────────────────

RECIPE="$(flatten "$RECIPE_MD")"
DISTRIBUTED_SECTION="$(h2_section "$CAPABILITIES_MD" "How it's distributed" | flatten_stdin)"
DELIVERY_SURFACES="$(md_region "$DELIVERY_MD" \
  '## The case for multiple delivery surfaces' '## Surface 1' | flatten_stdin)"

# ════════════════════════════════════════════════════════════════════════
# plugin shape — a skills-only plugin, documented end to end
# ════════════════════════════════════════════════════════════════════════

ok=1
[ -s "$RECIPE_MD" ] || ok=0
report "$ok" "plugin shape: a distribution recipe ships at docs/recipes/distribute.md"

ok=1
printf '%s' "$RECIPE" | grep -qF -- '.claude-plugin/plugin.json' || ok=0
report "$ok" "plugin shape: the recipe puts the plugin manifest at .claude-plugin/plugin.json"

ok=1
window_has "$RECIPE" 'hooks' 400 400 \
  'declares no|no .{0,3}hooks|zero .{0,3}hooks|without .{0,3}hooks|omits|hook-free|free of|never' || ok=0
report "$ok" "plugin shape: the recipe states the published manifest declares no hooks"

ok=1
printf '%s' "$RECIPE" | grep -qE 'skills/(<[a-z-]+>|\*)-context' || ok=0
printf '%s' "$RECIPE" | grep -qE 'convention' || ok=0
report "$ok" "plugin shape: the recipe locates contextualizer skills by convention under the plugin's skills directory"

ok=1
# Every bounded repetition here is capped well under 255. BSD grep refuses
# a larger interval and reports the refusal as a non-match, so an assertion
# written past the ceiling fails unconditionally on a developer's machine
# and passes in CI, with nothing for anyone to read.
printf '%s' "$RECIPE" | grep -qE \
  'not enumerat|does not enumerat|never enumerat|rather than enumerat|instead of enumerat|not listed|does not list|never list|nothing lists|no .{0,4}skills.{0,4} (key|field|array|list|entry)|without a .{0,4}skills.{0,4} (key|field|array|list|entry)|(not|never|no|nothing)[^.]{0,80}(enumerat|list)[^.]{0,60}skill|skill[^.]{0,60}(not|never)[^.]{0,40}(enumerat|list)' || ok=0
report "$ok" "plugin shape: the recipe states the manifest does not enumerate the skills it ships"

ok=1
printf '%s' "$RECIPE" | grep -qF -- '/plugin marketplace add' || ok=0
printf '%s' "$RECIPE" | grep -qF -- '/plugin install' || ok=0
report "$ok" "plugin shape: the recipe gives both commands a consumer runs to add the marketplace and install"

ok=1
window_has "$RECIPE" 'refresh' 500 500 'version' || ok=0
report "$ok" "plugin shape: the recipe states a refreshed contextualizer reaches consumers as a new plugin version"

# ════════════════════════════════════════════════════════════════════════
# depth-1 layout — a shared context repository the root scan actually finds
# ════════════════════════════════════════════════════════════════════════

ok=1
printf '%s' "$RECIPE" | grep -qE 'context repositor|shared repositor|context repo\b|repository of contextualizer' || ok=0
report "$ok" "depth-1 layout: the recipe documents a shared context repository as the second shape"

ok=0
for anchor in 'shape' 'shapes'; do
  window_has "$RECIPE" "$anchor" 400 400 \
    'when|choose|choosing|pick|fits|prefer|reach for|suits|use the' && { ok=1; break; }
done
report "$ok" "depth-1 layout: the recipe says when each of the two shapes fits"

# Written as a regex with a leading context class rather than as a literal
# starting with a tilde: a quoted word beginning with one reads to the
# linter as a home directory the shell was meant to expand.
ok=1
printf '%s' "$RECIPE" | grep -qE '(^|[^[:alnum:]])~/\.claude/skills/' || ok=0
printf '%s' "$RECIPE" | grep -qE '(^|[^[:alnum:]])~/\.claude/local/skills/' || ok=0
report "$ok" "depth-1 layout: the recipe names both user-level roots a contextualizer can be installed at"

ok=1
printf '%s' "$RECIPE" | grep -qE \
  'depth.?1|depth of 1|immediate child|children of|immediately (under|below|inside|in)|directly (under|below|inside|in)|one level (under|below|deep|down)|top-level entr|first level|not nested' || ok=0
report "$ok" "depth-1 layout: the recipe states the contextualizer directories sit as immediate children of either root"

ok=0
for anchor in 'symlink' 'symbolic link'; do
  window_has "$RECIPE" "$anchor" 600 600 'clon' && { ok=1; break; }
done
report "$ok" "depth-1 layout: the recipe gives both ways to land them there — cloning the repository as the root, or one symlink per contextualizer"

ok=0
# Two requirements on the same window rather than one alternation of
# phrasings: a negation, and a verb about finding or loading. Which words a
# writer reaches for is theirs; that the sentence says the layout is not
# found is the contract.
for anchor in 'depth 2' 'depth-2' 'two levels' 'a level down' 'one level down' 'subdirector' 'sub-director' 'deeper' 'nested'; do
  window_has "$RECIPE" "$anchor" 450 450 \
    'not|never|no longer|cannot|can.t|won.t|fails|misses|invisible|out of reach|too deep' \
    'reach|find|found|see|seen|scan|load|enumerat|locate|discover|pick(s| ) ?up|resolv' && { ok=1; break; }
done
report "$ok" "depth-1 layout: the recipe warns that cloning into a subdirectory of either root leaves them too deep to be found"

# ════════════════════════════════════════════════════════════════════════
# access scoping — a shared contextualizer shares what it was built from
# ════════════════════════════════════════════════════════════════════════

ok=0
for anchor in 'registr' 'register' 'audience' 'cannot read' "can't read" 'no access' 'cannot open' 'cannot access'; do
  window_has "$RECIPE" "$anchor" 450 450 \
    'source' \
    'cannot|can.t|no access|lacks? access|unable|not able|denied|without access|not read|not open|no right' && { ok=1; break; }
done
report "$ok" "access scoping: the recipe forbids registering a source the intended audience cannot read"

ok=0
for anchor in 'per-domain' 'per domain' 'one contextualizer per' 'a contextualizer per' 'one per' 'access boundar' 'mitigat' 'align'; do
  window_has "$RECIPE" "$anchor" 600 600 \
    'contextualizer' \
    'acl|permission|access boundar|who can read|read access|can read|entitle|access' && { ok=1; break; }
done
report "$ok" "access scoping: the recipe names per-domain contextualizers aligned to repository permissions as the mitigation"

# ════════════════════════════════════════════════════════════════════════
# zero hooks — the shipped template, and the validator that reaches it
# ════════════════════════════════════════════════════════════════════════

ok=1
manifest_is_json "$PLUGIN_MANIFEST_TEMPLATE" || ok=0
report "$ok" "plugin manifest: the contextualizer manifest template is a JSON object"

ok=1
manifest_declares_no_hooks "$PLUGIN_MANIFEST_TEMPLATE" || ok=0
report "$ok" "zero hooks: the contextualizer manifest template declares no hooks key"

ok=1
json_paths "$CI_LOCAL_SH" | grep -qxF -- "$MANIFEST_TEMPLATE_PATH" || ok=0
report "$ok" "zero hooks: the json validator walks the contextualizer manifest template"

# ════════════════════════════════════════════════════════════════════════
# cross-links — the recipe is reachable from what a reader already has open
# ════════════════════════════════════════════════════════════════════════

ok=1
printf '%s' "$DELIVERY_SURFACES" | grep -qE \
  'https://github\.com/[^[:space:])]*docs/recipes/distribute\.md' || ok=0
report "$ok" "cross-links: the delivery chapter reaches the recipe by an absolute URL from its delivery-surfaces material"

ok=1
printf '%s' "$DISTRIBUTED_SECTION" | grep -qE 'recipe|distribute\.md' || ok=0
printf '%s' "$DISTRIBUTED_SECTION" | grep -qE 'context repositor|shared repositor|context repo\b|repository of contextualizer' || ok=0
report "$ok" "cross-links: the ledger's distribution chapter names the recipe and both contextualizer-distribution shapes"

ok=1
CONTENTS_ENTRY="$(grep -F -- '(#how-its-distributed)' "$CAPABILITIES_MD" 2>/dev/null | head -n1)"
[ -n "$CONTENTS_ENTRY" ] || ok=0
printf '%s' "$CONTENTS_ENTRY" | grep -qiE 'contextualizer|recipe' || ok=0
report "$ok" "cross-links: the ledger's contents entry for that chapter says it covers contextualizer distribution too"

# ════════════════════════════════════════════════════════════════════════
# templates index — the README enumerates the directory exhaustively
# ════════════════════════════════════════════════════════════════════════

# Table rows only, and any row naming the template satisfies it. The
# README's intro prose also names files, so a first-match read would reject
# a correct table because of a sentence sitting above it.
ok=1
TEMPLATE_ROWS="$(grep '^|' "$TEMPLATES_README_MD" 2>/dev/null | grep -F -- 'contextualizer-plugin.json.template')"
[ -n "$TEMPLATE_ROWS" ] || ok=0
printf '%s' "$TEMPLATE_ROWS" | grep -qiE 'not\*\* stamped|not stamped' || ok=0
report "$ok" "templates index: the templates README carries a row for the new template, marked as one bootstrap does not stamp"

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
