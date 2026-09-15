#!/usr/bin/env bash
# The properties the recipe work must not break. Every one of them already
# holds, and every one of them is owned somewhere else — the capability
# ledger's own oracle, the review-budget oracle, the hook-decision oracle,
# the sparse-clone oracle, the bootstrap-stamping oracle. Those suites are
# what enforce them in a full run; this file restates the same facts in one
# place so each can be mutated in a scratch copy and watched to flip, which
# is what the controls beside it do.
#
# Deliberately NOT called by `run.sh`. Everything `run.sh` reports is a fact
# the change still owes; a fact that already holds reported there would read
# green on the first run and prove nothing.
#
# ENV INDIRECTION. Each file is pointed at through the variable named beside
# it, so a control copies one file, breaks the copy, and leaves every other
# file resolving to the real tree — which is what makes the pristine run a
# meaningful baseline rather than an artefact of a partial copy.
#
# -e is intentionally omitted: every assertion runs and reports, rather than
# the run aborting at the first failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

CAPABILITIES_MD="${CAPABILITIES_MD:-$REPO_ROOT/CAPABILITIES.md}"
DELIVERY_MD="${DELIVERY_MD:-$PLUGIN_ROOT/docs/04-delivery.md}"
TEMPLATES_README_MD="${TEMPLATES_README_MD:-$PLUGIN_ROOT/engine-bootstrap-templates/README.md}"
CI_LOCAL_SH="${CI_LOCAL_SH:-$REPO_ROOT/scripts/ci-local.sh}"
# The directory the json validator's relative paths resolve against.
JSON_ROOT="${JSON_ROOT:-$REPO_ROOT}"

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
# Text helpers — the same shapes the suite beside this one uses
# ────────────────────────────────────────────────────────────────────────

flatten_stdin() {
  tr '\n' ' ' | tr -s '[:space:]' ' ' | tr '[:upper:]' '[:lower:]'
}

flatten() {
  [ -f "$1" ] || { printf ''; return 0; }
  flatten_stdin < "$1"
}

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

# h3_section <file> <h2-text> <h3-text> — the body of one `### ` section,
# selected by the `## ` section it sits under. `### what's deliberately not
# built` occurs four times in the ledger, so a first-match extraction reads
# the wrong one. The h3 text is matched literally, emphasis markers
# included: the heading on disk carries asterisks inside it, and an
# extraction spelled without them silently finds nothing and then reports
# the good news about a section it never read.
h3_section() {
  [ -f "$1" ] || { printf ''; return 0; }
  awk -v h2="$2" -v h3="$3" '
    /^### / { cur3 = substr($0, 5); cap = (cur2 == h2 && cur3 == h3) ? 1 : 0; next }
    /^## /  { cur2 = substr($0, 4); cap = 0; next }
    /^# /   { cur2 = ""; cap = 0; next }
    cap { print }
  ' "$1"
}

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

CAPABILITIES="$(flatten "$CAPABILITIES_MD")"
DELIVERY="$(flatten "$DELIVERY_MD")"

# ════════════════════════════════════════════════════════════════════════
# capability ledger
# ════════════════════════════════════════════════════════════════════════

# The heading carries markdown emphasis and is matched with the asterisks in
# place. Its three claims — naming conventions across forks, conflict
# auto-resolution, a federation layer — are pinned by the oracle that owns
# them, and this chapter's edits happen elsewhere in the file precisely so
# that they survive.
NOT_SECTION="$(h3_section "$CAPABILITIES_MD" 'How it synthesizes across sources' 'What this is *not*' | flatten_stdin)"
ok=1
[ -n "$NOT_SECTION" ] || ok=0
printf '%s' "$NOT_SECTION" | grep -qiE 'naming conventions across forks' || ok=0
printf '%s' "$NOT_SECTION" | grep -qiE 'auto-resolve conflicts' || ok=0
printf '%s' "$NOT_SECTION" | grep -qiE 'federation layer' || ok=0
printf '%s' "$NOT_SECTION" | grep -qF -- '--all' && ok=0
report "$ok" "capability ledger: the what-this-is-not section keeps all three of its claims and states no enumeration behaviour"

# The enumeration flag and the workflows it is stated for are bound by
# proximity over the whole file, so any insertion that pushes them apart —
# or that renames the flag — breaks the oracle that owns this.
ok=1
[ -n "$CAPABILITIES" ] || ok=0
window_has "$CAPABILITIES" '--all' 700 700 'status' || ok=0
window_has "$CAPABILITIES" '--all' 700 700 'refresh' || ok=0
window_has "$CAPABILITIES" '--all' 700 700 'self-audit' || ok=0
window_has "$CAPABILITIES" '--all' 900 900 'table' || ok=0
report "$ok" "capability ledger: the enumeration flag stays within reach of the three workflows and the table it is stated for"

# ════════════════════════════════════════════════════════════════════════
# delivery chapter
# ════════════════════════════════════════════════════════════════════════

ok=1
[ -n "$DELIVERY" ] || ok=0
window_has "$DELIVERY" 'owner' 250 250 'sign' || ok=0
printf '%s' "$DELIVERY" | grep -qF -- 'source-paths.json' || ok=0
window_has "$DELIVERY" 'provisional' 250 250 'spot' || ok=0
window_has "$DELIVERY" 'provisional' 250 250 'reviewed' || ok=0
report "$ok" "delivery chapter: the federated-review policy still states who signs what, spot-checks, and ticks which tier"

# The zero-hooks prose the recipe work adds is adjacent in subject matter to
# a claim this chapter used to carry and no longer does. It must not come
# back in through the side door.
ok=1
[ -f "$DELIVERY_MD" ] || ok=0
[ -f "$DELIVERY_MD" ] && grep -qF -- 'A future engine plugin will ship exactly one inline' "$DELIVERY_MD" && ok=0
report "$ok" "delivery chapter: no single-inline-hook claim has come back"

# ════════════════════════════════════════════════════════════════════════
# json validator
# ════════════════════════════════════════════════════════════════════════

# Every path the validator walks that is actually present must parse. A path
# that is not present degrades to a skip by design, so listing one before
# writing it is safe; listing one that is unparseable is not, and that is
# what a downstream suite executing the validator would report.
ok=1
if ! command -v jq >/dev/null 2>&1; then
  ok=0
else
  listed="$(json_paths "$CI_LOCAL_SH")"
  [ -n "$listed" ] || ok=0
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    [ -f "$JSON_ROOT/$rel" ] || continue
    jq empty "$JSON_ROOT/$rel" >/dev/null 2>&1 || ok=0
  done <<< "$listed"
fi
report "$ok" "json validator: every manifest path it walks that is present on disk parses as JSON"

# ════════════════════════════════════════════════════════════════════════
# templates index
# ════════════════════════════════════════════════════════════════════════

EVAL_ROWS="$(grep -E '`eval/(run-eval\.sh|eval-viewer\.html|render-eval-results\.sh)\.template`' "$TEMPLATES_README_MD" 2>/dev/null)"
ok=1
[ -n "$EVAL_ROWS" ] || ok=0
printf '%s' "$EVAL_ROWS" | grep -qiE 'not\*\* stamped|not stamped' && ok=0
report "$ok" "templates index: the three eval harness rows are still recorded as ones bootstrap stamps"

# A copy-yourself row is added to the table without changing how many things
# bootstrap stamps, so the sentence that states the count must survive the
# edit verbatim.
ok=1
[ -f "$TEMPLATES_README_MD" ] || ok=0
[ -f "$TEMPLATES_README_MD" ] && grep -qF -- 'stamps four things' "$TEMPLATES_README_MD" && ok=0
[ -f "$TEMPLATES_README_MD" ] && { grep -qF -- 'stamps five things' "$TEMPLATES_README_MD" || ok=0; }
report "$ok" "templates index: the intro still states the same number of things bootstrap stamps"

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
